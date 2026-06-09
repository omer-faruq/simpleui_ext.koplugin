-- patches/patch_screensaver_homescreen.lua — SimpleUI Extra Modules
--
-- Adds a "Show SimpleUI home screen on sleep screen" option to KOReader's
-- Wallpaper (sleep screen) settings.  When the option is selected, the
-- SimpleUI home screen modules for the chosen page are rendered without the
-- top status bar and bottom navigation bar, and displayed as the sleep screen.
--
-- If the user has multiple home screen pages they can choose which one to
-- display via the "Home screen page" sub-item that becomes active only when
-- this mode is selected.
--
-- CONTRACT (required by main.lua's patch discovery):
--   P.id              string  — unique identifier used in log messages
--   P.apply           func()  — called once after SimpleUI has initialised; idempotent
--   P.name            string  — display name in the patch toggle menu
--   P.description     string  — help text for the patch toggle menu
--   P.default_enabled bool    — first-run default (false = opt-in)
--
-- HOW IT WORKS
--   Follows the same pattern as 2-book-receipt-shortcut-and-lockscreen.lua:
--   all module dependencies are loaded ONCE at P.apply() time and captured
--   via closure.  Screensaver.show() and dofile() are patched at apply()
--   time and remain in effect for the lifetime of the session.
--
--   1. screensaver_menu patch
--      KOReader loads screensaver_menu.lua via dofile() (not require()), which
--      bypasses Lua's module cache and produces a fresh table every call.  We
--      wrap the global dofile() once; every time screensaver_menu.lua is
--      loaded we inject our items into the freshly-built table.
--        • A radio item that sets screensaver_type = "simpleui_homescreen".
--        • A page-selector item (enabled only when the radio is active) that
--          writes the chosen page index to "screensaver_simpleui_hs_page".
--
--   2. Screensaver.show() patch
--      `ui/screensaver` is monkey-patched so that when screensaver_type ==
--      "simpleui_homescreen" our custom show path runs instead of the built-in
--      one.  The custom path:
--        a. Enforces portrait orientation (matching cover/image modes).
--        b. Flashes the e-ink screen white to clear ghosting.
--        c. Builds the homescreen widget from module.build() calls.
--        d. Wraps the result in KOReader's standard ScreenSaverWidget.
--           If the build fails or yields no content, shows a plain white
--           screen rather than revealing the current UI.
--
-- SETTING KEYS
--   screensaver_type               "simpleui_homescreen" — KOReader built-in key
--   screensaver_simpleui_hs_page   number  — page to show (default 1)

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local PATCH_ID   = "screensaver_homescreen"
local TYPE_VALUE = "simpleui_homescreen"   -- value stored in screensaver_type
local SK_TYPE    = "screensaver_type"      -- KOReader's built-in setting key
local SK_PAGE    = "screensaver_simpleui_hs_page"
local PFX        = "simpleui_hs_"

local P = {}
P.id              = PATCH_ID
P.name            = "Sleep Screen: SimpleUI Home"
P.description     = "Adds a 'Show SimpleUI Home Screen' option to the sleep screen Wallpaper settings"
P.default_enabled = false   -- Opt-in

local _applied = false

-- ---------------------------------------------------------------------------
-- P.apply — monkey-patch screensaver_menu and Screensaver.show()
--
-- All module dependencies are loaded here, at apply() time, which is called
-- once after SimpleUI has initialised.  The show() wrapper closes over them
-- so no require() calls happen during the screensaver path.
-- ---------------------------------------------------------------------------
function P.apply()
    if _applied then return end
    _applied = true

    -- ── 1. Patch screensaver_menu via dofile() interception ─────────────────
    -- Installed unconditionally so the menu item always appears even if the
    -- SimpleUI module load below somehow fails.
    local function _injectIntoMenuTable(tbl)
        if not (type(tbl) == "table"
                and type(tbl[1]) == "table"
                and type(tbl[1].sub_item_table) == "table") then
            logger.warn("screensaver_homescreen: unexpected screensaver_menu structure")
            return
        end

        local sub = tbl[1].sub_item_table

        -- Insert before the first radio item that has separator=true
        -- ("Leave screen as-is" / disable in the stock menu).
        local insert_before = #sub + 1
        for i, item in ipairs(sub) do
            if item.radio and item.separator then
                insert_before = i
                break
            end
        end

        -- Radio item: activate the SimpleUI home screen screensaver type.
        table.insert(sub, insert_before, {
            text = _("Show SimpleUI home screen on sleep screen"),
            checked_func = function()
                return G_reader_settings:readSetting(SK_TYPE) == TYPE_VALUE
            end,
            callback = function()
                G_reader_settings:saveSetting(SK_TYPE, TYPE_VALUE)
            end,
            radio = true,
        })

        -- Page selector: enabled only when our type is active.
        table.insert(sub, insert_before + 1, {
            text_func = function()
                local page = G_reader_settings:readSetting(SK_PAGE) or 1
                if page == 0 then return _("Home screen page: Random") end
                return T(_("Home screen page: %1"), page)
            end,
            enabled_func = function()
                return G_reader_settings:readSetting(SK_TYPE) == TYPE_VALUE
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager2 = require("ui/uimanager")
                UIManager2:show(SpinWidget:new{
                    title_text      = _("Home screen page"),
                    info_text       = _("Select which SimpleUI home screen page to display on the sleep screen.\n0 = a different random page each time."),
                    value           = G_reader_settings:readSetting(SK_PAGE) or 1,
                    value_min       = 0,
                    value_max       = 10,
                    value_step      = 1,
                    value_hold_step = 1,
                    default_value   = 1,
                    ok_text         = _("Set page"),
                    callback        = function(w)
                        G_reader_settings:saveSetting(SK_PAGE, w.value)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        })
    end

    -- ── 2. Load all dependencies at apply() time ──────────────────────────
    -- By contract apply() runs after SimpleUI has initialised, so all
    -- SimpleUI modules are already in package.loaded.
    local Device            = require("device")
    local Screen            = Device.screen
    local bit               = require("bit")
    local UIManager         = require("ui/uimanager")
    local Blitbuffer        = require("ffi/blitbuffer")
    local ScreenSaverWidget = require("ui/widget/screensaverwidget")
    local ffiUtil           = require("ffi/util")
    local VerticalGroup     = require("ui/widget/verticalgroup")
    local VerticalSpan      = require("ui/widget/verticalspan")
    local FrameContainer    = require("ui/widget/container/framecontainer")
    local CenterContainer   = require("ui/widget/container/centercontainer")
    local OverlapGroup      = require("ui/widget/overlapgroup")
    local TextBoxWidget     = require("ui/widget/textboxwidget")
    local Font              = require("ui/font")
    local Geom              = require("ui/geometry")
    local ImageWidget       = require("ui/widget/imagewidget")

    local ok_reg, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok_reg or not Registry then
        logger.warn("screensaver_homescreen: moduleregistry unavailable — show() not patched")
        return
    end

    local ok_hs, Homescreen = pcall(require, "sui_homescreen")
    if not ok_hs or not Homescreen then
        logger.warn("screensaver_homescreen: sui_homescreen unavailable — show() not patched")
        return
    end

    local ok_cfg, Config = pcall(require, "sui_config")
    if not ok_cfg or not Config then
        logger.warn("screensaver_homescreen: sui_config unavailable — show() not patched")
        return
    end

    local ok_sts, SUISettings = pcall(require, "sui_store")
    if not ok_sts or not SUISettings then
        logger.warn("screensaver_homescreen: sui_store unavailable — show() not patched")
        return
    end

    local PAGE_BREAK_ID = Homescreen.PAGE_BREAK_ID  -- "__page_break__"

    -- Layout constants — prefer sui_core values, fall back to Device-scaled.
    local ok_ui, UI = pcall(require, "sui_core")
    local SIDE_PAD = (ok_ui and UI and UI.SIDE_PAD) or Screen:scaleBySize(16)
    local MOD_GAP  = (ok_ui and UI and UI.MOD_GAP)  or Screen:scaleBySize(8)

    -- ── 3. Helper: build minimal context for module.build() calls ─────────
    local function _buildSleepCtx()
        -- Re-acquire modules that SimpleUI's onTeardown() may have evicted from
        -- package.loaded during a context switch (FM<->Reader).  The new plugin
        -- instance re-requires them before any sleep can occur, so
        -- package.loaded holds fresh, properly-initialised objects.  Fall back
        -- to the P.apply() closure captures only on the very first sleep.
        local live_Registry = package.loaded["desktop_modules/moduleregistry"] or Registry
        local live_Config   = package.loaded["sui_config"]                     or Config

        local bs = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
        local ok_sh, SH = pcall(require, "desktop_modules/module_books_shared")
        if ok_sh and SH then
            local mod_c  = live_Registry.get("currently")
            local mod_r  = live_Registry.get("recent")
            local mod_cd = live_Registry.get("coverdeck")
            local show_c = mod_c  and live_Registry.isEnabled(mod_c,  PFX)
            local show_r = (mod_r  and live_Registry.isEnabled(mod_r,  PFX))
                        or (mod_cd and live_Registry.isEnabled(mod_cd, PFX))
            if show_c or show_r then
                local ok_bs, result = pcall(SH.prefetchBooks, show_c, show_r, 5, false)
                if ok_bs and result then bs = result end
            end
        end

        local db_conn = nil
        if live_Config.openStatsDB then
            local ok_db, conn = pcall(live_Config.openStatsDB)
            if ok_db then db_conn = conn end
        end

        local stats_data = nil
        local mod_rg = live_Registry.get("reading_goals")
        local mod_rs = live_Registry.get("reading_stats")
        local wants_stats = (mod_rg and live_Registry.isEnabled(mod_rg, PFX))
                         or (mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(PFX))
        if wants_stats and db_conn then
            local ok_sp, SP = pcall(require, "desktop_modules/module_stats_provider")
            if ok_sp and SP and SP.get then
                local ok_s, sd = pcall(SP.get, db_conn, os.date("%Y"), false)
                if ok_s then stats_data = sd end
            end
        end

        local mod_c  = live_Registry.get("currently")
        local mod_r  = live_Registry.get("recent")
        local mod_cd = live_Registry.get("coverdeck")
        local show_c = mod_c  and live_Registry.isEnabled(mod_c,  PFX)
        local show_r = (mod_r  and live_Registry.isEnabled(mod_r,  PFX))
                    or (mod_cd and live_Registry.isEnabled(mod_cd, PFX))

        return {
            pfx          = PFX,
            pfx_qa       = "simpleui_qa_",
            close_fn     = function() end,
            open_fn      = function() end,
            on_qa_tap    = function() end,
            on_goal_tap  = function() end,
            db_conn      = db_conn,
            stats        = stats_data,
            vspan_pool   = {},
            prefetched   = bs.prefetched_data,
            current_fp   = bs.current_fp,
            recent_fps   = bs.recent_fps,
            sectionLabel = function() return nil end,
            _hs_widget   = nil,
            _show_c      = show_c,
            _show_r      = show_r,
            _has_content = (bs.current_fp and show_c)
                        or (bs.recent_fps and #bs.recent_fps > 0 and show_r)
                        or false,
            has_wallpaper = false,
            cfg           = nil,
        }, db_conn
    end

    -- ── 4a. Helper: build background ImageWidget if SimpleUI wallpaper is active ──
    -- We track the widget created during the previous sleep cycle so we can
    -- explicitly free its bitmap data before allocating a new one.  On
    -- memory-constrained e-ink devices this prevents OOM failures on the
    -- second (and subsequent) sleep cycles.
    local _last_wp_widget   = nil
    -- Tracks the frozen Blitbuffer snapshot from the previous sleep cycle so
    -- we can free it before allocating a new one.
    local _last_snap_widget = nil

    local function _getBgWidget(screen_w, screen_h)
        -- Eagerly free the bitmap from the previous cycle.  By the time show()
        -- is called again the old ScreenSaverWidget has already been
        -- UIManager:close'd and its onCloseWidget / Screensaver:cleanup() have
        -- run, so the old paintTo closure will never be invoked again.
        if _last_wp_widget then
            pcall(function() _last_wp_widget:free() end)
            _last_wp_widget = nil
        end

        -- Use the freshest sui_homescreen reference available (the new plugin
        -- instance re-requires it after every context switch).
        local live_HS = package.loaded["sui_homescreen"] or Homescreen
        if not live_HS.styleGetWallpaperEnabled() then return nil end
        local path = live_HS.styleGetWallpaper()
        if not path then return nil end
        local ok, w = pcall(ImageWidget.new, ImageWidget, {
            file          = path,
            width         = screen_w,
            height        = screen_h,
            scale_factor  = 0,       -- proportional fit (letterbox/pillarbox)
            file_do_cache = false,
            alpha         = true,
        })
        if ok and w then
            _last_wp_widget = w   -- remember for cleanup on next call
            return w
        end
        logger.warn("screensaver_homescreen: wallpaper load failed: " .. tostring(path))
        return nil
    end

    -- ── 4b. Helper: build the full-screen homescreen widget ───────────────
    -- Always returns a widget (at minimum a plain white FrameContainer).
    -- Never returns nil, so the screensaver_widget is always shown.
    local function _buildHomescreenWidget(screen_w, screen_h, target_page)
        local function _whiteWidget()
            return FrameContainer:new{
                bordersize = 0,
                padding    = 0,
                dimen      = Geom:new{ w = screen_w, h = screen_h },
                background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new{},
            }
        end

        -- Re-acquire modules fresh after a context switch (SimpleUI's
        -- onTeardown() clears package.loaded for all SimpleUI modules; the
        -- new plugin instance re-populates them before the next sleep).
        local live_Registry   = package.loaded["desktop_modules/moduleregistry"] or Registry
        local live_SUISettings = package.loaded["sui_store"]                     or SUISettings
        local live_Config     = package.loaded["sui_config"]                     or Config

        -- Determine which modules are on the requested page.
        -- Mirrors sui_homescreen._updatePage: prefer the new simpleui_layout
        -- structure (layout.pages[i].modules); fall back to the legacy
        -- PAGE_BREAK_ID approach when simpleui_layout is absent.
        local pages_of_ids = {}
        local layout = live_SUISettings:readSetting("simpleui_layout")
        if layout and type(layout.pages) == "table" then
            for _, page in ipairs(layout.pages) do
                local page_ids = {}
                if type(page.modules) == "table" then
                    for _, mod_id in ipairs(page.modules) do
                        page_ids[#page_ids + 1] = mod_id
                    end
                end
                pages_of_ids[#pages_of_ids + 1] = page_ids
            end
        else
            local raw_order = live_Registry.loadOrder(PFX)
            local cur_page = {}
            for _, id in ipairs(raw_order) do
                if id == PAGE_BREAK_ID then
                    pages_of_ids[#pages_of_ids + 1] = cur_page
                    cur_page = {}
                else
                    cur_page[#cur_page + 1] = id
                end
            end
            pages_of_ids[#pages_of_ids + 1] = cur_page  -- last (or only) page
        end

        local chosen_pages = layout and type(layout.pages) == "table"
            and #layout.pages
            or live_SUISettings:readSetting(PFX .. "homescreen_num_pages")
        if chosen_pages and chosen_pages > #pages_of_ids then
            for _ = #pages_of_ids + 1, chosen_pages do
                pages_of_ids[#pages_of_ids + 1] = {}
            end
        end

        local page_idx
        if not target_page or target_page <= 0 then
            math.randomseed(os.time())
            page_idx = math.random(1, math.max(1, #pages_of_ids))
        else
            page_idx = math.max(1, math.min(target_page, #pages_of_ids))
        end
        local page_ids = pages_of_ids[page_idx] or {}

        local mods = {}
        for _, mod_id in ipairs(page_ids) do
            local mod = live_Registry.get(mod_id)
            if mod and live_Registry.isEnabled(mod, PFX) then
                mods[#mods + 1] = mod
            end
        end

        if #mods == 0 then
            logger.info("screensaver_homescreen: page " .. tostring(page_idx)
                        .. " has no enabled modules — showing white screen")
            return _whiteWidget()
        end

        -- Check wallpaper BEFORE building context so ctx.has_wallpaper is
        -- correct when module.build() is called — modules use it to decide
        -- whether to render transparent text areas.
        local wp_widget  = _getBgWidget(screen_w, screen_h)
        local has_wp     = (wp_widget ~= nil)

        -- Build data context.
        local ctx, db_conn = _buildSleepCtx()
        ctx.has_wallpaper  = has_wp   -- override the default false
        local inner_w = screen_w - SIDE_PAD * 2

        -- Render module widgets.
        local body  = VerticalGroup:new{ align = "left" }
        local first = true
        for _, mod in ipairs(mods) do
            local ok_w, widget = pcall(mod.build, inner_w, ctx)
            if ok_w and widget then
                if first then
                    first = false
                    -- Double gap at top (no topbar on sleep screen).
                    body[#body + 1] = VerticalSpan:new{ width = MOD_GAP * 2 }
                else
                    local gap_px = MOD_GAP
                    if live_Config.getModuleGapPx then
                        local ok_g, gv = pcall(live_Config.getModuleGapPx, mod.id, PFX, MOD_GAP)
                        if ok_g and gv then gap_px = gv end
                    end
                    body[#body + 1] = VerticalSpan:new{ width = gap_px }
                end
                body[#body + 1] = widget
            else
                logger.warn("screensaver_homescreen: build() failed for "
                            .. tostring(mod.id) .. ": " .. tostring(widget))
            end
        end

        -- Close DB connection — all data is now baked into widget properties.
        if db_conn then
            pcall(function() db_conn:close() end)
        end

        -- If every build() call failed, body is empty → show white.
        if #body == 0 then
            logger.warn("screensaver_homescreen: all module builds failed — showing white screen")
            return _whiteWidget()
        end

        local content = FrameContainer:new{
            bordersize    = 0,
            padding       = 0,
            padding_left  = SIDE_PAD,
            padding_right = SIDE_PAD,
            dimen         = Geom:new{ w = screen_w, h = screen_h },
            body,
        }

        -- If a wallpaper is active, override paintTo to draw it behind the
        -- content (exactly as the live homescreen does).
        if wp_widget then
            local _orig_paintTo = content.paintTo
            local _bg           = wp_widget
            local _opacity      = live_SUISettings:readSetting(
                                    "simpleui_style_wallpaper_opacity", 0) or 0
            function content:paintTo(bb, x, y)
                -- Paint wallpaper anchored at the top of the screen.
                _bg:paintTo(bb, x, 0)
                -- Optional white-fade on top (0 = fully opaque, 1-99 = fade).
                if _opacity > 0 then
                    bb:lightenRect(x, 0, screen_w, screen_h, _opacity / 100)
                end
                _orig_paintTo(self, bb, x, y)
            end
        end

        -- Sleep screen message overlay (respects KOReader's screensaver_show_message setting).
        local msg_text = G_reader_settings:isTrue("screensaver_show_message")
                      and G_reader_settings:readSetting("screensaver_message")
        if msg_text and msg_text ~= "" then
            local face  = Font:getFace("infofont")
            local max_w = screen_w - SIDE_PAD * 4
            local tbw   = TextBoxWidget:new{
                text      = msg_text,
                face      = face,
                width     = max_w,
                alignment = "center",
                fgcolor   = Blitbuffer.COLOR_BLACK,
            }
            -- Calling getSize() ensures _bb is rendered.
            local tbh = tbw:getSize().h
            -- Build a custom widget that multiply-blits the text BB onto the
            -- destination.  Multiply blend: white source = transparent (dest unchanged),
            -- dark source = darkens destination.  This gives perfectly transparent
            -- text without any white box, regardless of wallpaper.
            local mul_widget = {
                _tbw = tbw,
                _w   = max_w,
                _h   = tbh,
                getSize  = function(s) return Geom:new{ w = s._w, h = s._h } end,
                paintTo  = function(s, dst_bb, x, y)
                    if s._tbw and s._tbw._bb then
                        dst_bb:blitFrom(s._tbw._bb, x, y, 0, 0, s._w, s._h,
                                        dst_bb.setPixelMultiply)
                    end
                end,
                free = function(s)
                    if s._tbw then
                        pcall(function() s._tbw:free() end)
                        s._tbw = nil
                    end
                end,
            }
            local bottom_margin = Screen:scaleBySize(24)
            local msg_y = screen_h - tbh - bottom_margin
            local msg_at_bottom = CenterContainer:new{
                dimen          = Geom:new{ w = screen_w, h = tbh },
                overlap_offset = { 0, msg_y },
                mul_widget,
            }
            content = OverlapGroup:new{
                dimen           = Geom:new{ w = screen_w, h = screen_h },
                allow_mirroring = false,
                content,
                msg_at_bottom,
            }
        end

        return content
    end

    -- ── 5. Patch Screensaver.show() via require() interception ───────────
    -- package.loaded["ui/screensaver"] may already be set but in a partial
    -- state (show = table not function) due to Lua's circular-require guard.
    -- We wrap _G.require once; the FIRST successful call to
    -- require("ui/screensaver") that returns a table with a function `show`
    -- is our opportunity to patch it.  After that we restore the original
    -- require immediately.
    local _show_patched  = false
    local _our_show_fn   = nil   -- reference to the exact function we installed
    local _orig_require_for_ss = _G.require

    local function _patchScreensaverShow(Screensaver)
        if _show_patched then return true end
        if type(Screensaver) ~= "table" then
            logger.warn("screensaver_homescreen: _patchScreensaverShow: not a table")
            return false
        end
        -- `show` may be a plain function OR a callable table (e.g. a KOReader
        -- event-dispatch table with a __call metamethod).  Both are valid; we
        -- store orig_show and replace the key with our own function.
        -- Calling orig_show(self) works for both cases.
        local orig_show      = Screensaver.show
        local orig_show_type = type(orig_show)
        if orig_show_type ~= "function" then
            local mt = type(orig_show) == "table" and getmetatable(orig_show)
            if not (mt and mt.__call) then
                -- Not callable at all — do not patch, as orig_show(self) would crash.
                logger.warn("screensaver_homescreen: Screensaver.show is not callable (type="
                            .. orig_show_type .. ") — cannot patch")
                return false
            end
            logger.info("screensaver_homescreen: Screensaver.show is callable table — patching")
        end
        _show_patched = true

        Screensaver.show = function(self)
            if self.screensaver_type ~= TYPE_VALUE then
                return orig_show(self)
            end
            if not self.ui then
                logger.warn("screensaver_homescreen: show() aborting — self.ui is nil (setup() may have failed)")
                return
            end

            Device.screen_saver_mode = true

            local with_gesture_lock = Device:isTouchDevice()
                and G_reader_settings:readSetting("screensaver_delay") == "gesture"

            local screen_w = Screen:getWidth()
            local screen_h = Screen:getHeight()
            local rotation_mode = Screen:getRotationMode()
            local orig_dimen

            Device.orig_rotation_mode = rotation_mode
            if bit.band(rotation_mode, 1) == 1 then
                Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
                if with_gesture_lock then
                    orig_dimen = { w = screen_w, h = screen_h }
                end
                screen_w, screen_h = screen_h, screen_w
            else
                Device.orig_rotation_mode = nil
            end

            if Device:hasEinkScreen() then
                Screen:clear()
                Screen:refreshFull(0, 0, screen_w, screen_h)
                if Device:isKobo() and Device:isSunxi() then
                    ffiUtil.usleep(150 * 1000)
                end
            end

            local target_page = G_reader_settings:readSetting(SK_PAGE) or 1

            -- Step 1: build the homescreen widget tree
            local ok_build, hs_widget = pcall(_buildHomescreenWidget, screen_w, screen_h, target_page)
            if not ok_build then
                logger.warn("screensaver_homescreen: _buildHomescreenWidget threw: " .. tostring(hs_widget))
                hs_widget = nil
            end

            -- Step 2: render widget → frozen Blitbuffer snapshot
            -- Rendered now while module closures are valid; widget tree freed after.
            local snap_widget
            if hs_widget then
                local ok_bb, bb = pcall(Blitbuffer.new, screen_w, screen_h, Screen.bb:getType())
                if ok_bb and bb then
                    -- Pre-fill white so areas not covered by modules show white.
                    pcall(function() bb:paintRect(0, 0, screen_w, screen_h, Blitbuffer.COLOR_WHITE) end)
                    local ok_paint = pcall(function() hs_widget:paintTo(bb, 0, 0) end)
                    -- Free the widget tree — snapshot is now self-contained.
                    pcall(function() if hs_widget.free then hs_widget:free() end end)
                    hs_widget = nil
                    if ok_paint then
                        local _bb   = bb
                        local _w, _h = screen_w, screen_h
                        snap_widget = FrameContainer:new{
                            bordersize = 0,
                            padding    = 0,
                            dimen      = Geom:new{ w = _w, h = _h },
                            background = Blitbuffer.COLOR_WHITE,
                            VerticalGroup:new{},
                        }
                        -- Override paintTo: blit the frozen snapshot instead of the
                        -- (now-freed) widget tree.  UIManager calls this during refresh.
                        function snap_widget:paintTo(dst_bb, x, y)
                            if _bb then
                                dst_bb:blitFrom(_bb, x, y, 0, 0, _w, _h)
                            end
                        end
                        function snap_widget:free()
                            if _bb then pcall(function() _bb:free() end); _bb = nil end
                        end
                    else
                        logger.warn("screensaver_homescreen: paintTo failed — using white fallback")
                        pcall(function() bb:free() end)
                    end
                else
                    logger.warn("screensaver_homescreen: Blitbuffer.new failed — using white fallback")
                    pcall(function() if hs_widget and hs_widget.free then hs_widget:free() end end)
                    hs_widget = nil
                end
            end

            -- Step 3: free snapshot from previous sleep cycle
            if _last_snap_widget then
                pcall(function()
                    if _last_snap_widget.free then _last_snap_widget:free() end
                end)
                _last_snap_widget = nil
            end

            -- Step 4: fallback to white screen if build/render failed
            if not snap_widget then
                snap_widget = FrameContainer:new{
                    bordersize = 0,
                    padding    = 0,
                    dimen      = Geom:new{ w = screen_w, h = screen_h },
                    background = Blitbuffer.COLOR_WHITE,
                    VerticalGroup:new{},
                }
            end
            _last_snap_widget = snap_widget

            UIManager:setIgnoreTouchInput(false)

            -- Step 5: show the static snapshot in ScreenSaverWidget
            local ok_sw, sw_or_err = pcall(ScreenSaverWidget.new, ScreenSaverWidget, {
                widget            = snap_widget,
                background        = Blitbuffer.COLOR_WHITE,
                covers_fullscreen = true,
            })
            if not ok_sw then
                logger.err("screensaver_homescreen: ScreenSaverWidget:new failed: "
                           .. tostring(sw_or_err)
                           .. " — resetting screen_saver_mode to prevent permanent lock")
                Device.screen_saver_mode = false
                Device.orig_rotation_mode = nil
                return orig_show(self)
            end
            self.screensaver_widget          = sw_or_err
            self.screensaver_widget.modal    = true
            self.screensaver_widget.dithered = true
            local ok_us, us_err = pcall(UIManager.show, UIManager, self.screensaver_widget, "full")
            if not ok_us then
                logger.err("screensaver_homescreen: UIManager:show failed: "
                           .. tostring(us_err)
                           .. " — resetting screen_saver_mode")
                Device.screen_saver_mode = false
                Device.orig_rotation_mode = nil
                return orig_show(self)
            end

            if with_gesture_lock then
                local ScreenSaverLockWidget = require("ui/widget/screensaverlockwidget")
                self.screensaver_lock_widget = ScreenSaverLockWidget:new{
                    ui         = self.ui,
                    orig_dimen = orig_dimen,
                }
                UIManager:show(self.screensaver_lock_widget)
            end
        end

        _our_show_fn = Screensaver.show

        -- Patch setup() once to self-heal show() immediately before every sleep.
        if not Screensaver._hs_setup_patched then
            Screensaver._hs_setup_patched = true
            local orig_setup = Screensaver.setup
            Screensaver.setup = function(self_ss, event, event_message)
                if _our_show_fn and Screensaver.show ~= _our_show_fn then
                    _show_patched = false
                    _patchScreensaverShow(Screensaver)
                end
                return orig_setup(self_ss, event, event_message)
            end
        end

        return true
    end

    local _cached = package.loaded["ui/screensaver"]
    if type(_cached) == "table" and _cached.show ~= nil then
        _patchScreensaverShow(_cached)
    end

    -- If not patched yet, wrap _G.require to catch the first successful load.
    if not _show_patched then
        _G.require = function(modname, ...)
            local result = _orig_require_for_ss(modname, ...)
            if modname == "ui/screensaver" then
                if not _show_patched then
                    if type(result) == "table" then
                        if _patchScreensaverShow(result) then
                            -- Restore immediately — no further interception needed.
                            _G.require = _orig_require_for_ss
                        else
                            logger.warn("screensaver_homescreen: require(ui/screensaver) patch failed: "
                                        .. "show=" .. type(result.show)
                                        .. " setup=" .. type(result.setup))
                        end
                    else
                        logger.warn("screensaver_homescreen: require(ui/screensaver) returned non-table: "
                                    .. type(result))
                    end
                else
                    -- Already patched by another code path; restore.
                    _G.require = _orig_require_for_ss
                end
            end
            return result
        end
    end

    -- Wrap dofile() for screensaver_menu injection
    local _orig_dofile = _G.dofile
    _G.dofile = function(path, ...)
        local result = _orig_dofile(path, ...)
        if type(path) == "string" and path:find("screensaver_menu%.lua$") then
            _injectIntoMenuTable(result)
            local ss = package.loaded["ui/screensaver"]
            if ss then
                if _our_show_fn and ss.show ~= _our_show_fn then
                    _show_patched = false
                    _patchScreensaverShow(ss)
                elseif not _show_patched then
                    if not _patchScreensaverShow(ss) then
                        logger.warn("screensaver_homescreen: show() not patched after dofile; type="
                                    .. type(ss.show))
                    end
                    _G.require = _orig_require_for_ss
                end
            end
        end
        return result
    end
end

return P
