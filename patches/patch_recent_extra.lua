-- patches/patch_recent_extra.lua — SimpleUI Extra Modules
-- Adds extra display options to SimpleUI's built-in "Recent Books" module
-- (module_recent):
--
--   1. "Exclude Paths from Recent" — same path-fragment filter already
--      available on Cover Deck (patch_coverdeck_exclude) and other
--      recent-books-based modules.
--
--   2. "Rows" + "Row Spacing" — show more than one row of book covers.
--      Each row holds up to 5 books (module_recent's fixed column count),
--      so e.g. 3 rows shows up to 15 recent books.
--
-- CONTRACT (required by main.lua's patch discovery):
--   P.id              string  — unique identifier used in log messages
--   P.apply           func()  — called once after SimpleUI has initialised; idempotent
--   P.name            string  — display name for menu
--   P.description     string  — help text for menu
--   P.default_enabled bool    — first-run default (false = opt-in for patches)
--
-- HOW IT WORKS
--   module_recent.build() always renders ONE row of up to 5 covers, sized
--   for ctx.recent_fps (which SimpleUI's homescreen pre-fetches with a fixed
--   max of 5 entries). To add extra rows / exclude paths without touching
--   module_recent.lua, this patch:
--
--     M.build() — when "Rows" > 1 or exclude paths are configured, collects
--                  its own list of recent file paths from ReadHistory
--                  (mirroring SH.prefetchBooks' "finished book" filter),
--                  then calls the original M.build() once per row with a
--                  5-entry slice of ctx.recent_fps, stacking the resulting
--                  row widgets in a VerticalGroup separated by the
--                  configured row spacing. ctx is restored afterwards so
--                  later refreshes see the original lists.
--
--     M.getHeight() — scales the single-row height returned by the original
--                  M.getHeight() by the configured row count, adding the
--                  row spacing between rows.
--
--     M.getMenuItems() — appends "Rows", "Row Spacing" and
--                  "Exclude Paths from Recent" items.
--
-- SETTING KEYS (all prefixed by pfx, e.g. "simpleui_hs_")
--   recent_rows           integer 1..MAX_ROWS, default 1
--   recent_row_gap_pct    integer 0..300 (%), default 100
--   recent_exclude_paths  comma/newline-separated path fragments

local logger = require("logger")

local PATCH_ID = "recent_extra"

local P = {}
P.id              = PATCH_ID
P.name            = "Recent Books Extra Options"
P.description     = "Adds multi-row layout, row spacing and 'Exclude Paths from Recent' to the Recent Books module"
P.default_enabled = false  -- Opt-in: patches default to disabled
local _applied   = false

local SETTING_ROWS        = "recent_rows"
local SETTING_ROW_GAP_PCT = "recent_row_gap_pct"
local SETTING_EXCLUDE     = "recent_exclude_paths"

local MAX_ROWS = 4
local PER_ROW  = 5  -- matches module_recent's fixed `cols = math.min(#recent_fps, 5)`

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
        if t ~= "" then result[#result + 1] = t end
    end
    return result
end

local function _isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- Collects up to `needed` recent file paths from ReadHistory, applying the
-- same "finished book" filter as SH.prefetchBooks (percent >= 100% counts as
-- finished) plus the exclude-paths filter. Skips current_fp so the result
-- never duplicates the "Currently Reading" book. `prefetched` (ctx.prefetched)
-- is used so the first MAX_RECENT entries — already fetched by the homescreen
-- — don't trigger an extra DocSettings open.
local function _collectRecentFps(needed, excludes, current_fp, show_finished, prefetched, SH)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_rh,  RH  = pcall(require, "readhistory")
    if not ok_rh or not RH then return nil end
    if not (RH.hist and #RH.hist > 0) then
        pcall(function() RH:reload() end)
    end
    if not RH.hist then return nil end

    local result = {}
    for _, e in ipairs(RH.hist) do
        local fp = e and e.file
        if fp and fp ~= current_fp
            and (not ok_lfs or lfs.attributes(fp, "mode") == "file")
            and not _isExcluded(fp, excludes)
        then
            local include = show_finished
            if not include then
                local bd = SH and SH.getBookData(fp, prefetched and prefetched[fp])
                include = not bd or (bd.percent or 0) < 1.0
            end
            if include then
                result[#result + 1] = fp
                if #result >= needed then break end
            end
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- apply()
-- ---------------------------------------------------------------------------
function P.apply()
    if _applied then return end

    local ok, M = pcall(require, "desktop_modules/module_recent")
    if not ok or not M then
        logger.warn("recent_extra patch: cannot load module_recent — skipped")
        return
    end
    local ok_ss, SUISettings = pcall(require, "sui_store")
    if not ok_ss or not SUISettings then
        logger.warn("recent_extra patch: cannot load sui_store — skipped")
        return
    end
    _applied = true

    -- ── wrap build() ──────────────────────────────────────────────────────
    local orig_build = M.build
    M.build = function(w, ctx)
        local pfx     = ctx.pfx or ""
        local rows     = _getRows(SUISettings, pfx)
        local excludes = _getExcludePaths(SUISettings, pfx)

        if rows <= 1 and #excludes == 0 then
            return orig_build(w, ctx)
        end

        local ok_sh, SH = pcall(require, "desktop_modules/module_books_shared")
        local show_finished = SUISettings:readSetting(pfx .. "recent_show_finished") == true
        local fps = _collectRecentFps(rows * PER_ROW, excludes, ctx.current_fp,
                                       show_finished, ctx.prefetched, ok_sh and SH)
        if not fps then
            return orig_build(w, ctx)
        end

        local orig_recent_fps = ctx.recent_fps
        local orig_focus_idx  = ctx.kb_recent_focus_idx

        if rows <= 1 then
            ctx.recent_fps = fps
            local result = orig_build(w, ctx)
            ctx.recent_fps = orig_recent_fps
            return result
        end

        local row_widgets     = {}
        local all_cover_slots = {}
        for r = 1, rows do
            local from = (r - 1) * PER_ROW + 1
            if from > #fps then break end
            local to = math.min(r * PER_ROW, #fps)
            local slice = {}
            for i = from, to do slice[#slice + 1] = fps[i] end
            ctx.recent_fps = slice

            if orig_focus_idx then
                local local_idx = orig_focus_idx - (from - 1)
                ctx.kb_recent_focus_idx = (local_idx >= 1 and local_idx <= #slice) and local_idx or nil
            else
                ctx.kb_recent_focus_idx = nil
            end

            local row_widget = orig_build(w, ctx)
            if row_widget then
                row_widgets[#row_widgets + 1] = row_widget
                if row_widget._cover_slots then
                    for _, slot in ipairs(row_widget._cover_slots) do
                        all_cover_slots[#all_cover_slots + 1] = slot
                    end
                end
            end
        end

        ctx.recent_fps          = orig_recent_fps
        ctx.kb_recent_focus_idx = orig_focus_idx

        if #row_widgets == 0 then return nil end
        if #row_widgets == 1 then return row_widgets[1] end

        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan  = require("ui/widget/verticalspan")
        local row_gap = _getRowGapPx(SUISettings, pfx)

        local stack = VerticalGroup:new{ align = "left" }
        for idx, rw in ipairs(row_widgets) do
            if idx > 1 then
                stack[#stack + 1] = VerticalSpan:new{ width = row_gap }
            end
            stack[#stack + 1] = rw
        end
        stack._cover_slots = all_cover_slots
        return stack
    end

    -- ── wrap getHeight() ──────────────────────────────────────────────────
    local orig_getHeight = M.getHeight
    M.getHeight = function(ctx)
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
    local orig_getMenuItems = M.getMenuItems
    M.getMenuItems = function(ctx_menu)
        local items   = orig_getMenuItems(ctx_menu) or {}
        local pfx     = ctx_menu.pfx or ""
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._ or function(x) return x end

        items[#items + 1] = {
            text_func      = function() return _lc("Rows") end,
            value_func     = function() return tostring(_getRows(SUISettings, pfx)) end,
            separator      = true,
            keep_menu_open = true,
            callback       = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager  = require("ui/uimanager")
                UIManager:show(SpinWidget:new{
                    title_text    = _lc("Rows"),
                    info_text     = _lc("Number of rows of recent books to display.\nEach row shows up to 5 books."),
                    value         = _getRows(SUISettings, pfx),
                    value_min     = 1,
                    value_max     = MAX_ROWS,
                    value_step    = 1,
                    ok_text       = _lc("Apply"),
                    cancel_text   = _lc("Cancel"),
                    default_value = 1,
                    callback      = function(spin)
                        SUISettings:saveSetting(pfx .. SETTING_ROWS, spin.value)
                        refresh()
                    end,
                })
            end,
        }

        local row_gap_item = require("sui_config").makeGapItem({
            text_func = function() return _lc("Row Spacing") end,
            title     = _lc("Row Spacing"),
            info      = _lc("Vertical spacing between rows.\nOnly used when \"Rows\" is greater than 1."),
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
                    return _lc("Exclude Paths from Recent")
                end
                local n = 0
                for _ in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _lc("Exclude Paths from Recent"), n)
            end,
            keep_menu_open = true,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local UIManager   = require("ui/uimanager")
                local raw = SUISettings:readSetting(pfx .. SETTING_EXCLUDE) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _lc("Exclude Paths from Recent"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss, instapaper",
                    description = _lc("Comma-separated path fragments.\nBooks whose path contains any fragment will be skipped."),
                    allow_newline = false,
                    buttons = {{
                        {
                            text     = _lc("Cancel"),
                            callback = function() UIManager:close(dlg) end,
                        },
                        {
                            text             = _lc("Save"),
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

    logger.info("simpleui_ext: patch_recent_extra: applied")
end

return P
