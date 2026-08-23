-- patches/patch_recent_extra.lua — SimpleUI Extra Modules
-- Adds extra display options to SimpleUI's "Recent Books" sub-module
-- (registered by desktop_modules/module_book_rows.lua, sub-module id = "recent"):
--
--   1. "Rows" + "Row Spacing" — show multiple rows of book covers. Each row
--      holds up to 5 books (the sub-module's hard-coded `max_items`), so e.g.
--      3 rows shows up to 15 recent books.
--
--   2. "Exclude Paths from Recent" — same path-fragment filter already
--      available on Cover Deck (patch_coverdeck_exclude) and other
--      recent-books-based modules.
--
-- CONTRACT (required by main.lua's patch discovery):
--   P.id              string  — unique identifier used in log messages
--   P.apply           func()  — called once after SimpleUI has initialised; idempotent
--   P.name            string  — display name for menu
--   P.description     string  — help text for menu
--   P.default_enabled bool    — first-run default (false = opt-in for patches)
--
-- COMPATIBILITY: SimpleUI's stable release (2.1.1) still ships the old
-- top-level desktop_modules/module_recent.lua. The rewrite described below
-- (module_book_rows.lua's "recent" sub-module) only exists on SimpleUI's
-- unreleased main branch as of this writing. Until SimpleUI cuts a release
-- containing that rewrite, P.apply() below detects which API is present at
-- runtime and wraps whichever one it finds:
--
--   api_mode = "sub"  — new sub-module (module_book_rows.lua), tried first
--   api_mode = "flat" — old module_recent.lua, fallback for 2.1.1 and earlier
--
-- TODO: once SimpleUI releases a version containing module_book_rows.lua,
-- drop the "flat" fallback path (and this compatibility note) and require
-- that release as the plugin's minimum SimpleUI version.
--
-- HOW IT WORKS (api_mode == "sub")
--   Since the SimpleUI refactor, the Recent Books sub-module is no longer
--   the top-level module_recent.lua — it is one of three "row" sub-modules
--   (recent / new_books / tbr) created by RowRenderer.makeModule() in
--   desktop_modules/sui_book_row.lua, exported together by
--   desktop_modules/module_book_rows.lua's M.sub_modules list. The
--   sub-module exposes the same M.build / M.getHeight / M.getMenuItems
--   contract as the old module_recent, but its build() reads from
--   ctx["_row_fps_recent"] (the row cache) instead of ctx.recent_fps
--   directly, and paginates via ctx["_row_page_recent"].
--
--   This patch targets the "recent" sub-module only (the others — TBR,
--   New Books — are not affected).
--
--   M.build() — when "Rows" > 1, exclude paths are configured, or
--                "Skip Most Recent" is on, collects its own list of recent
--                file paths from ReadHistory (mirroring module_book_rows'
--                "finished book" filter), then drives the original
--                M.build() once per row by writing the per-row slice
--                (`fps[(r-1)*5+1 .. r*5]`) into ctx["_row_fps_recent"]
--                before each call. The resulting row widgets are stacked
--                in a VerticalGroup separated by the configured row
--                spacing, with each row's _cover_slots merged onto the
--                stack so RowRenderer.updateCovers() can refresh every
--                cover asynchronously. The original cache value is
--                restored afterwards so the homescreen's next pass
--                through M.build() starts from getFileList/filterItem
--                instead of a stale slice.
--  
--                Note: ctx["_row_page_recent"] is intentionally not modified.
--                The recent sub-module does not enable `paged = true` in
--                its spec (only tbr does), so RowRenderer.build's paged
--                branch is never taken for recent — the page key is read
--                but `local paged = opts.paged and #fps > max_items`
--                short-circuits to false and page_fps always becomes
--                `fps[1..min(5, #fps)]`. The only reliable way to make
--                row r render `fps[(r-1)*5+1 .. r*5]` is to overwrite
--                ctx["_row_fps_recent"] with that slice for the duration
--                of that single orig_build() call.
--
--   Both api_mode branches restore ctx.kb_recent_focus_idx (the keyboard/
--   d-pad focus highlight index — see sui_book_row.lua's `ctx.kb_recent_
--   focus_idx == i` check) translated to each row's local index, so the
--   focus outline lands on the right cover instead of only ever
--   considering row 1.
--
-- HOW IT WORKS (api_mode == "flat")
--   Same idea, but against the old module_recent.lua contract: instead of
--   writing the per-row slice into ctx["_row_fps_recent"], it's written
--   directly to ctx.recent_fps (module_recent.build() reads that field,
--   not a cache dict), and there's no _row_page_recent / paged concern
--   because module_recent never had pagination.
--
--   M.getHeight() — scales the single-row height returned by the original
--                M.getHeight() by the configured row count, adding the
--                row spacing between rows.
--
--   M.getMenuItems() — appends "Rows", "Row Spacing" and "Exclude Paths
--                from Recent" items to the target module's menu
--                (identical shape/behavior in both api_modes).
--
-- SETTING KEYS (all prefixed by pfx, e.g. "simpleui_hs_")
--   recent_rows              integer 1..MAX_ROWS, default 1
--   recent_row_gap_pct       integer 0..300 (%), default 100
--   recent_exclude_paths     comma/newline-separated path fragments

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

-- Covers per row. SimpleUI 2.5's Recent Books lets the user choose 4 or 5
-- columns (GridRenderer spec.cols_choice), and its build() only paints that
-- many cells — so slicing at a hard-coded 5 would silently drop the last
-- book of every row for anyone who picked 4. Ask the grid engine for the
-- effective value where it exists; PER_ROW covers SimpleUI <=2.4, which had
-- no such setting.
local function _perRow(pfx)
    local ok, GridRenderer = pcall(require, "engines/sui_book_grid")
    if ok and GridRenderer and type(GridRenderer.getGridCols) == "function" then
        local n = GridRenderer.getGridCols(pfx or "", "recent", PER_ROW)
        if type(n) == "number" and n > 0 then return n end
    end
    return PER_ROW
end

-- Cache key used by RowRenderer.build() for the "recent" sub-module
-- (default = "_row_fps_" .. id). Matches the hard-coded default in
-- desktop_modules/sui_book_row.lua's makeModule; the "recent" spec in
-- module_book_rows.lua does not override it.
--
-- We deliberately do NOT also store a PAGE_KEY constant: the recent
-- sub-module does not enable `paged = true`, so RowRenderer.build's
-- paged branch is dead code for recent and writing to
-- `ctx["_row_page_recent"]` has no effect. See the long-form comment in
-- M.build() for the full reasoning.
local CACHE_KEY = "_row_fps_recent"

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
    for _i, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- Mirrors module_book_rows's recent sub-module filterItem: excludes finished
-- books unless "Show finished books" is on. Prefetched data is preferred; if
-- missing, falls back to opening DocSettings directly.
local function _isFinished(fp, show_finished, ctx)
    if show_finished then return false end
    local pd = ctx and ctx.prefetched and ctx.prefetched[fp]
    if pd and pd ~= false then
        local pct = pd.percent or 0
        local is_done = (pct >= 1.0) or
                        (type(pd) == "table" and type(pd.summary) == "table"
                         and pd.summary.status == "complete")
        return is_done
    end
    -- Slow path: open DocSettings directly. Done outside the hot render
    -- loop in practice (the prewarm hook in main.lua populates prefetched
    -- for the first ~15 entries).
    local ok, DS = pcall(require, "docsettings")
    if not ok or not DS then return false end
    local ok2, ds = pcall(DS.open, DS, fp)
    if not ok2 or not ds then return false end
    local pct = ds:readSetting("percent_finished") or 0
    local summary = ds:readSetting("summary")
    local is_complete = type(summary) == "table" and summary.status == "complete"
    pcall(function() ds:close() end)
    return (pct >= 1.0) or is_complete
end

-- Single predicate that mirrors the recent sub-module's filterItem (in
-- desktop_modules/module_book_rows.lua) plus this patch's exclude-paths
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

-- Collects up to `needed` recent file paths from ReadHistory, applying the
-- same "finished book" filter as the recent sub-module's filterItem plus
-- the exclude-paths filter. Skips current_fp so the result never duplicates
-- the "Currently Reading" book.
-- Returns {} when ReadHistory is unavailable; the caller then falls back
-- to the original build() to render the empty state.
local function _collectRecentFps(needed, excludes, show_finished, ctx)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_rh,  RH  = pcall(require, "readhistory")
    if not ok_rh or not RH then return {} end
    if not (RH.hist and #RH.hist > 0) then
        pcall(function() RH:reload() end)
    end
    if not RH.hist then return {} end

    local result = {}
    for i = 1, #(RH.hist) do
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

    -- Locate the target module, preferring the new sub-module API and
    -- falling back to the old flat module_recent.lua API. See the
    -- "COMPATIBILITY" note at the top of this file.
    local target_mod, api_mode = nil, nil

    local ok_br, BR = pcall(require, "desktop_modules/module_book_rows")
    if ok_br and BR and type(BR.sub_modules) == "table" then
        for _, sub in ipairs(BR.sub_modules) do
            if sub and sub.id == "recent" then
                target_mod, api_mode = sub, "sub"
                break
            end
        end
    end

    if not target_mod then
        local ok_mr, MR = pcall(require, "desktop_modules/module_recent")
        if ok_mr and MR then
            target_mod, api_mode = MR, "flat"
        end
    end

    if not target_mod then
        logger.dbg("recent_extra patch: neither module_book_rows ('recent' sub-module) "
                     .. "nor module_recent found — skipped")
        return
    end

    -- api_mode is now only a label for the log: build() below writes the
    -- per-row slice into both possible slots, so nothing depends on getting
    -- this right. See the comment on orig_recent/orig_cache_key in build().

    _applied = true

    -- ── wrap build() ──────────────────────────────────────────────────────
    local orig_build = target_mod.build
    target_mod.build = function(w, ctx)
        local pfx          = (ctx and ctx.pfx) or ""
        local rows         = _getRows(SUISettings, pfx)
        local excludes     = _getExcludePaths(SUISettings, pfx)
        local show_finished = SUISettings:readSetting(pfx .. "recent_show_finished") == true

        -- All options at default: take the fast path through the original.
        if rows <= 1 and #excludes == 0 then
            return orig_build(w, ctx)
        end

        -- Self-collect up to (rows * PER_ROW) entries from ReadHistory,
        -- applying excludes + the recent module's own finished-book
        -- filter. ctx is the live homescreen ctx. This collection logic
        -- is identical in both api_modes: it only reads generic ctx
        -- fields (current_fp, prefetched), never the module-specific
        -- cache.
        local per_row = _perRow(pfx)
        local fps = _collectRecentFps(rows * per_row, excludes,
                                      show_finished, ctx)
        if not fps or #fps == 0 then
            return orig_build(w, ctx)
        end

        -- Save originals so subsequent re-renders (e.g. the homescreen
        -- refresh loop calling build() again) see the unmodified state.
        --
        -- Both slots, because the per-row slice below is written to both
        -- rather than to whichever one a detection heuristic picks:
        --   ctx.recent_fps  — read by the pre-2.5 hand-written module_recent
        --   ctx[CACHE_KEY]  — read by GridRenderer's per-module file-list
        --                     cache (SimpleUI 2.5's module_recent)
        -- Exactly one is consulted by the installed SimpleUI; the other is an
        -- unused key, so writing both is always correct and never needs to
        -- know which implementation is in front of it. The previous version
        -- guessed from which FILE the module lived in, and SimpleUI 2.5 broke
        -- that guess: module_book_rows was split back into module_recent.lua
        -- while keeping the grid implementation, so the test said "flat", the
        -- slice went to the ignored slot, and rows 2..n silently re-rendered
        -- row 1's books.
        local orig_recent    = ctx.recent_fps
        local orig_cache_key = ctx[CACHE_KEY]
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
            --
            -- (For api_mode == "sub", setting `ctx[PAGE_KEY] = r` is NOT
            -- enough: the recent sub-module does not enable `paged = true`
            -- in its spec, so RowRenderer.build's paged branch is never
            -- taken and the page key is ignored — see RowRenderer.build
            -- line 152.)
            local slice = {}
            for i = from, to do slice[#slice + 1] = fps[i] end
            ctx.recent_fps = slice
            ctx[CACHE_KEY] = slice

            -- Translate the global focus index into this row's local
            -- index (both api_modes read ctx.kb_recent_focus_idx), so the
            -- keyboard/d-pad highlight lands on the right cover instead of
            -- only ever being checked against row 1's indices.
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
        ctx[CACHE_KEY]          = orig_cache_key
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
            -- Merge each row's _cover_slots so RowRenderer.updateCovers()
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

    logger.dbg("simpleui_ext: patch_recent_extra: applied")
end

return P
