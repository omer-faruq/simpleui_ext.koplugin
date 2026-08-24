-- patches/patch_recent_extra.lua — SimpleUI Extra Modules
-- Adds extra display options to SimpleUI's "Recent Books" module
-- (modules/module_recent.lua):
--
--   1. "Rows" + "Row Spacing" — show multiple rows of book covers. Each row
--      holds up to 5 books (module_recent's hard-coded `max_items`), so e.g.
--      3 rows shows up to 15 recent books.
--
--   2. "Exclude Paths from Recent" — same path-fragment filter already
--      available on Cover Deck (patch_coverdeck_exclude) and other
--      recent-books-based modules.
--
--   3. "Skip Currently Reading" (automatic, no setting) — when
--      modules/module_hero_currently.lua from simpleui_ext is also enabled
--      on the homescreen, the recent list skips ReadHistory[1] so the
--      "Currently Reading" hero card and the recent row don't display the
--      same book simultaneously. 
--
-- CONTRACT (required by main.lua's patch discovery):
--   P.id              string  — unique identifier used in log messages
--   P.apply           func()  — called once after SimpleUI has initialised; idempotent
--   P.name            string  — display name for menu
--   P.description     string  — help text for menu
--   P.default_enabled bool    — first-run default (false = opt-in for patches)
--
--   M.build() — when "Rows" > 1 or exclude paths are configured,
--                collects its own list of recent file paths from
--                ReadHistory (mirroring module_recent's
--                "finished book" filter), then drives the original
--                M.build() once per row by writing the per-row slice
--                (`fps[(r-1)*5+1 .. r*5]`) into ctx.recent_fps
--                before each call. The resulting row widgets are stacked
--                in a VerticalGroup separated by the configured row
--                spacing, with each row's _cover_slots merged onto the
--                stack so GridRenderer's updateCovers() can refresh every
--                cover asynchronously. The original ctx.recent_fps value
--                is restored afterwards so the homescreen's next pass
--                through M.build() starts from getFileList/filterItem
--                instead of a stale slice.
--
--   The patch restores ctx.kb_recent_focus_idx (the keyboard/d-pad
--   focus highlight index — see engines/sui_book_grid.lua's
--   `ctx.kb_recent_focus_idx == i` check) translated to each row's
--   local index, so the focus outline lands on the right cover
--   instead of only ever considering row 1.
--
--   M.getHeight() — scales the single-row height returned by the original
--                M.getHeight() by the configured row count, adding the
--                row spacing between rows.
--
--   M.getMenuItems() — appends "Rows", "Row Spacing" and "Exclude Paths
--                from Recent" items to the target module's menu.
--
-- SETTING KEYS (all prefixed by pfx, e.g. "simpleui_hs_")
--   recent_rows              integer 1..MAX_ROWS, default 1
--   recent_row_gap_pct       integer 0..300 (%), default 100
--   recent_exclude_paths     comma/newline-separated path fragments
--
-- Read-only dependencies (settings owned by other modules):
--   hero_currently           when true, ReadHistory[1] is dropped from
--                            the recent list — see item 3 in the contract
--                            above. Mirrors Registry.isEnabled() in
--                            simpleui.koplugin/modules/moduleregistry.lua:
--                            hero_currently.enabled_key = "hero_currently",
--                            hero_currently.default_on = false.

local logger = require("logger")
local _      = require("sui_ext_i18n").translate

local PATCH_ID = "recent_extra"

local P = {}
P.id              = PATCH_ID
P.name            = _("Recent Books Extra Options")
P.description     = _("Adds multi-row layout, row spacing and 'Exclude Paths from Recent' to the Recent Books module")
P.default_enabled = false  -- Opt-in: patches default to disabled
local _applied = false

local SETTING_ROWS         = "recent_rows"
local SETTING_ROW_GAP_PCT  = "recent_row_gap_pct"
local SETTING_EXCLUDE      = "recent_exclude_paths"

local MAX_ROWS = 4
local PER_ROW  = 5  -- fallback: the recent module's default max_items

-- Cap the exclude-paths fragment count to neutralise the quadratic DoS surface:
local MAX_EXCLUDE_FRAGMENTS = 200

-- Covers per row. module_recent lets the user choose 4 or 5 columns
-- (GridRenderer spec.cols_choice), and its build() only paints that
-- many cells — so slicing at a hard-coded 5 would silently drop the
-- last book of every row for anyone who picked 4. Ask the grid engine
-- for the effective value where it exists; PER_ROW covers SimpleUI
-- versions without this setting.
local function _perRow(pfx)
    local ok, GridRenderer = pcall(require, "engines/sui_book_grid")
    if ok and GridRenderer and type(GridRenderer.getGridCols) == "function" then
        local n = GridRenderer.getGridCols(pfx or "", "recent", PER_ROW)
        if type(n) == "number" and n > 0 then return n end
    end
    return PER_ROW
end

local BASE_ROW_GAP = require("device").screen:scaleBySize(12)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function _getRows(SUISettings, pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_ROWS))
    if not v then return 1 end
    v = math.floor(v)
    if v < 1 then return 1 end
    if v > MAX_ROWS then return MAX_ROWS end
    return v
end

local function _getRowGapPct(SUISettings, pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_ROW_GAP_PCT))
    if not v then return 100 end
    if v < 0 then return 0 end
    if v > 300 then return 300 end
    return v
end

local function _getRowGapPx(SUISettings, pfx)
    return math.floor(BASE_ROW_GAP * _getRowGapPct(SUISettings, pfx) / 100)
end

local function _getExcludePaths(SUISettings, pfx)
    local raw = SUISettings:readSetting((pfx or "") .. SETTING_EXCLUDE)
    if not raw or raw == "" then return {} end
    local result = {}
    for token in raw:gmatch("[^,\n]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then
            result[#result + 1] = t
            -- Hard cap to neutralise the quadratic DoS surface
            --  (see MAX_EXCLUDE_FRAGMENTS comment above). 
            if #result >= MAX_EXCLUDE_FRAGMENTS then break end
        end
    end
    return result
end

local function _isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _i, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- Mirrors module_recent's filterItem: excludes finished books unless
-- "Show finished books" is on. Prefetched data is preferred; if
-- missing, falls back to opening DocSettings directly.
local function _isFinished(fp, show_finished, ctx)
    if show_finished then return false end
    local pd = ctx and ctx.prefetched and ctx.prefetched[fp]
    if pd and pd ~= false then
        local ok_f, pct, is_complete = pcall(function()
            local p  = pd.percent or 0
            local sm = pd.summary
            local ic = type(sm) == "table" and sm.status == "complete"
            return p, ic
        end)
        if not ok_f then return false end
        return (pct >= 1.0) or is_complete
    end
    -- Slow path: open DocSettings directly. Done outside the hot render
    -- loop in practice (the prewarm hook in main.lua populates prefetched
    -- for the first ~15 entries).
    local ok, DS = pcall(require, "docsettings")
    if not ok or not DS then return false end
    local ok2, ds = pcall(DS.open, DS, fp)
    if not ok2 or not ds then return false end
    local ok3, pct, is_complete = pcall(function()
        local p  = ds:readSetting("percent_finished") or 0
        local sm = ds:readSetting("summary")
        local ic = type(sm) == "table" and sm.status == "complete"
        return p, ic
    end)
    pcall(function() ds:close() end)
    if not ok3 then return false end
    return (pct >= 1.0) or is_complete
end

-- Single predicate that mirrors module_recent's filterItem (in
-- modules/module_recent.lua) plus this patch's exclude-paths
-- filter. Centralising the predicate makes it easy to spot when the two
-- diverge; if SimpleUI's filterItem changes (e.g. a new status filter),
-- this function must change in lockstep — otherwise users will see the
-- recent books list look different with this patch enabled vs. disabled.
local function _shouldInclude(fp, ctx, excludes, show_finished, lfs)
    if not fp then return false end
    if fp == (ctx and ctx.current_fp) then return false end
    -- lfs.attributes can throw on broken symlinks / permission errors /
    -- filesystems returning EBADF mid-iteration. A single bad fp must
    -- not abort the entire recent-list collection — treat any lfs
    -- error as "file does not exist" and skip.
    if lfs then
        local mode
        local ok = pcall(function() mode = lfs.attributes(fp, "mode") end)
        if not ok or mode ~= "file" then return false end
    end
    if _isExcluded(fp, excludes) then return false end
    if _isFinished(fp, show_finished, ctx) then return false end
    return true
end

-- Detects whether simpleui_ext's hero_currently module is enabled on the
-- homescreen. Read-only — the setting is owned by hero_currently itself,
-- we just gate behaviour on it.
--
-- Mirrors Registry.isEnabled() from simpleui.koplugin/modules/moduleregistry.lua
-- (L261-271): when the setting is absent the value is `default_on` which
-- for hero_currently is false. When present, only an explicit `true` counts.
local function _isHeroCurrentlyOn(SUISettings, pfx)
    local v = SUISettings:readSetting((pfx or "") .. "hero_currently")
    if v == nil then return false end
    return v == true
end

-- Collects up to `needed` recent file paths from ReadHistory, applying the
-- same "finished book" filter as module_recent's filterItem plus
-- the exclude-paths filter. Skips current_fp so the result never duplicates
-- the "Currently Reading" book.
-- Returns {} when ReadHistory is unavailable; the caller then falls back
-- to the original build() to render the empty state.
local function _collectRecentFps(needed, excludes, show_finished, ctx, hero_on)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_rh,  RH  = pcall(require, "readhistory")
    if not ok_rh or not RH then return {} end
    if not (RH.hist and #RH.hist > 0) then
        pcall(function() RH:reload() end)
    end
    if not RH.hist then return {} end

    local skip_hist1 = hero_on == true and (not ctx or not ctx.current_fp)
    local start_i    = skip_hist1 and 2 or 1
    local result = {}
    for i = start_i, #(RH.hist) do
        local fp = RH.hist[i] and RH.hist[i].file
        if _shouldInclude(fp, ctx, excludes, show_finished,
                          ok_lfs and lfs or nil) then
            result[#result + 1] = fp
            if #result >= needed then break end
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- apply()
-- ---------------------------------------------------------------------------
function P.apply()
    if _applied then return end

    local ok_ss, SUISettings = pcall(require, "sui_store")
    if not ok_ss or not SUISettings then
        logger.dbg("recent_extra patch: cannot load sui_store — skipped")
        return
    end

    -- Wrap SimpleUI's module_recent.lua.
    local ok_mr, target_mod = pcall(require, "desktop_modules/module_recent")
    if not ok_mr or not target_mod then
        logger.dbg("recent_extra patch: desktop_modules/module_recent not found — skipped")
        return
    end



    -- ── wrap build() ──────────────────────────────────────────────────────
    local orig_build = target_mod.build
    target_mod.build = function(w, ctx)
        local pfx          = (ctx and ctx.pfx) or ""
        local rows         = _getRows(SUISettings, pfx)
        local excludes     = _getExcludePaths(SUISettings, pfx)
        local show_finished = SUISettings:readSetting(pfx .. "recent_show_finished") == true
        local hero_on      = _isHeroCurrentlyOn(SUISettings, pfx)

        -- All options at default AND hero_currently is off: take the fast
        -- path through the original. hero_currently forces the self-collect
        -- path even at default rows/excludes, so the read of hist[1] by
        -- _collectRecentFps is gated on hero_on rather than user-toggled.
        if rows <= 1 and #excludes == 0 and not hero_on then
            return orig_build(w, ctx)
        end

        -- Self-collect up to (rows * PER_ROW) entries from ReadHistory,
        -- applying excludes + the recent module's own finished-book
        -- filter. ctx is the live homescreen ctx. This only reads
        -- generic ctx fields (current_fp, prefetched), never the
        -- module-specific cache.
        local per_row = _perRow(pfx)
        local fps = _collectRecentFps(rows * per_row, excludes,
                                      show_finished, ctx, hero_on)
        if not fps or #fps == 0 then
            return orig_build(w, ctx)
        end

        -- Save originals so subsequent re-renders (e.g. the homescreen
        -- refresh loop calling build() again) see the unmodified state.
        -- The per-row slice is written into ctx.recent_fps, which
        -- module_recent's getFileList reads directly.
        local orig_recent    = ctx.recent_fps
        local orig_focus_idx = ctx.kb_recent_focus_idx

        local row_widgets = {}
        for r = 1, rows do
            local from = (r - 1) * per_row + 1
            if from > #fps then break end
            local to = math.min(r * per_row, #fps)
            -- Slice `fps[from..to]` and inject it as the row source. The
            -- original build() reads this slot first and renders
            -- `min(#fps, max_items)` covers from index 1 — so writing the
            -- current row's slice here is the only reliable way to get it
            -- to render row 2/3/... differently from row 1.
            local slice = {}
            for i = from, to do slice[#slice + 1] = fps[i] end
            ctx.recent_fps = slice

            -- Translate the global focus index into this row's local
            -- index, so the keyboard/d-pad highlight lands on the right
            -- cover instead of only ever being checked against row 1's
            -- indices.
            if orig_focus_idx then
                local local_idx = orig_focus_idx - (from - 1)
                ctx.kb_recent_focus_idx = (local_idx >= 1 and local_idx <= #slice) and local_idx or nil
            else
                ctx.kb_recent_focus_idx = nil
            end

            local row_widget = orig_build(w, ctx)
            if row_widget then
                row_widgets[#row_widgets + 1] = row_widget
            end
        end

        -- Restore the original state so the next pass through build()
        -- (which the homescreen triggers on its own refresh path) starts
        -- from the unmodified source instead of seeing a stale slice. In
        -- Lua, `t.x = nil` and "key absent" are equivalent, so a single
        -- assignment handles both cases.
        ctx.recent_fps          = orig_recent
        ctx.kb_recent_focus_idx = orig_focus_idx

        if #row_widgets == 0 then return nil end
        if #row_widgets == 1 then return row_widgets[1] end

        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan  = require("ui/widget/verticalspan")
        local row_gap = _getRowGapPx(SUISettings, pfx)

        local stack = VerticalGroup:new{ align = "left" }
        local all_cover_slots = {}
        for idx, rw in ipairs(row_widgets) do
            if idx > 1 then
                stack[#stack + 1] = VerticalSpan:new{ width = row_gap }
            end
            stack[#stack + 1] = rw
            -- Merge each row's _cover_slots so GridRenderer.updateCovers()
            -- can refresh every cover asynchronously. The VerticalGroup
            -- itself doesn't expose _cover_slots, so without this merge
            -- updateCovers() short-circuits to "all done" and skips the
            -- async refresh of the lower rows' covers entirely.
            if rw._cover_slots then
                for _i, slot in ipairs(rw._cover_slots) do
                    all_cover_slots[#all_cover_slots + 1] = slot
                end
            end
        end
        stack._cover_slots = all_cover_slots
        return stack
    end

    -- ── wrap getHeight() ──────────────────────────────────────────────────
    local orig_getHeight = target_mod.getHeight
    target_mod.getHeight = function(ctx)
        local pfx  = (ctx and ctx.pfx) or ""
        local rows = _getRows(SUISettings, pfx)
        local h_one = orig_getHeight(ctx)
        if rows <= 1 then return h_one end

        local label_h = require("sui_config").getScaledLabelH()
        local cell_h  = h_one - label_h
        local row_gap = _getRowGapPx(SUISettings, pfx)
        return label_h + rows * cell_h + (rows - 1) * row_gap
    end

    -- ── wrap getMenuItems() ───────────────────────────────────────────────
    local orig_getMenuItems = target_mod.getMenuItems
    target_mod.getMenuItems = function(ctx_menu)
        local items   = orig_getMenuItems(ctx_menu) or {}
        local pfx     = (ctx_menu and ctx_menu.pfx) or ""
        local refresh = ctx_menu.refresh

        items[#items + 1] = {
            text_func      = function() return _("Rows") end,
            value_func     = function() return tostring(_getRows(SUISettings, pfx)) end,
            separator      = true,
            keep_menu_open = true,
            callback       = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager  = require("ui/uimanager")
                UIManager:show(SpinWidget:new{
                    title_text    = _("Rows"),
                    info_text     = _("Number of rows of recent books to display.\nEach row shows up to 5 books."),
                    value         = _getRows(SUISettings, pfx),
                    value_min     = 1,
                    value_max     = MAX_ROWS,
                    value_step    = 1,
                    ok_text       = _("Apply"),
                    cancel_text   = _("Cancel"),
                    default_value = 1,
                    callback      = function(spin)
                        SUISettings:saveSetting(pfx .. SETTING_ROWS, spin.value)
                        refresh()
                    end,
                })
            end,
        }

        local row_gap_item = require("sui_config").makeGapItem({
            text_func = function() return _("Row Spacing") end,
            title     = _("Row Spacing"),
            info      = _("Vertical spacing between rows.\nOnly used when \"Rows\" is greater than 1."),
            get       = function() return _getRowGapPct(SUISettings, pfx) end,
            set       = function(v) SUISettings:saveSetting(pfx .. SETTING_ROW_GAP_PCT, v) end,
            refresh   = refresh,
        })
        row_gap_item.enabled_func = function() return _getRows(SUISettings, pfx) > 1 end
        items[#items + 1] = row_gap_item

        items[#items + 1] = {
            text_func = function()
                local raw = SUISettings:readSetting(pfx .. SETTING_EXCLUDE)
                if not raw or raw == "" then
                    return _("Exclude Paths from Recent")
                end
                local n = 0
                for _i in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _("Exclude Paths from Recent"), n)
            end,
            keep_menu_open = true,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local UIManager   = require("ui/uimanager")
                local raw = SUISettings:readSetting(pfx .. SETTING_EXCLUDE) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _("Exclude Paths from Recent"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss, instapaper",
                    description = _("Comma-separated path fragments.\nBooks whose path contains any fragment will be skipped."),
                    allow_newline = false,
                    buttons = {{
                        {
                            text = _("Cancel"),
                            callback = function() UIManager:close(dlg) end,
                        },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local val = dlg:getInputText()
                                SUISettings:saveSetting(pfx .. SETTING_EXCLUDE, val)
                                UIManager:close(dlg)
                                refresh()
                            end,
                        },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        }

        return items
    end

    -- Active-refresh hook for the hero_currently ↔ recent_extra linkage.
    do
        local _hero_key_suffix = "hero_currently"
        if type(SUISettings.saveSetting) == "function" then
            local _orig_save = SUISettings.saveSetting
            SUISettings.saveSetting = function(self, key, value, ...)
                local r = _orig_save(self, key, value, ...)
                if type(key) == "string"
                   and key:sub(-#_hero_key_suffix) == _hero_key_suffix then
                    local ok_e, SE = pcall(require, "engines/sui_screen_engine")
                    if ok_e and SE and type(SE._instance) == "table" then
                        local inst = SE._instance
                        if type(inst._updatePage) == "function" then
                            pcall(inst._updatePage, inst, false)
                        end
                        -- Belt-and-braces: flag "hs" so the next onShow
                        -- also picks it up if homescreen wasn't visible.
                        if type(SE.setNeedsRefresh) == "function" then
                            pcall(SE.setNeedsRefresh, "hs")
                        end
                    end
                end
                return r
            end
        end
    end

    -- All three wraps + the saveSetting watch installed successfully:
    -- mark as applied only now. Setting _applied earlier would turn a
    -- mid-apply crash into a permanent no-op (re-applying becomes a no-op
    -- because _applied is true, leaving target_mod half-wrapped forever).
    _applied = true

    logger.dbg("simpleui_ext: patch_recent_extra: applied")
end

return P
