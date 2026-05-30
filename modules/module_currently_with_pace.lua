-- module_currently_with_pace.lua — SimpleUI Extra Modules
-- Currently Reading module with pace statistics.
--
-- Based on SimpleUI's module_currently.lua with added pace stats:
--   • avg_time_per_day  — average reading time per day (e.g. "42m/day")
--   • pages_per_minute  — reading speed in pages per minute (e.g. "250wpm")
--   • percent_per_day   — average progress per day (e.g. "4.3%/day")

-- External dependencies
local Device  = require("device")
local Screen  = Device.screen
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

-- Internal dependencies
local Config       = require("sui_config")
local UI           = require("sui_core")
local SUISettings = require("sui_store")
local PAD          = UI.PAD
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Lazy-loaded shared book helpers (cover, progress bar, book data).
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui_ext: module_currently_with_pace: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Colours
local _CLR_DARK   = Blitbuffer.COLOR_BLACK
local _CLR_BAR_BG = Blitbuffer.gray(0.15)
local _CLR_BAR_FG = Blitbuffer.gray(0.75)

-- Vertical gaps between elements (base values at 100% scale; scaled in build()).
local _BASE_COVER_GAP  = Screen:scaleBySize(16)  -- between cover and text column
local _BASE_TITLE_GAP  = Screen:scaleBySize(4)   -- before title
local _BASE_AUTHOR_GAP = Screen:scaleBySize(6)   -- before author
-- Vertical gaps around the progress bar.
-- The bar (LineWidget) has no internal padding — it starts and ends at exact pixels.
-- TextWidget includes ascender/descender space inside its reported height, which
-- the eye reads as part of the gap. To look balanced:
--   before the bar: slightly smaller because the author text's descender space
--                   adds ~2px of visual gap "for free" from inside the widget.
--   after the bar:  larger to compensate for the ascender space of the next text
--                   being consumed from the gap, making it look narrower.
local _BASE_BAR_GAP_BEFORE = Screen:scaleBySize(6)   -- gap above the progress bar
local _BASE_BAR_GAP_AFTER  = Screen:scaleBySize(10)  -- gap below the progress bar
local _BASE_PCT_GAP    = Screen:scaleBySize(3)   -- before percent / stats rows

-- Progress bar dimensions
local _BASE_BAR_H       = Screen:scaleBySize(7)   -- bar height (matches module_reading_goals)
local _BASE_BAR_PCT_GAP = Screen:scaleBySize(6)   -- horizontal gap between bar and inline pct label
local _BASE_STATS_SEP_W = Screen:scaleBySize(8)   -- horizontal gap between inline stats items
local _BASE_PCT_W       = Screen:scaleBySize(32)  -- width reserved for inline pct label (e.g. "100%")

-- Font sizes (base values at 100% scale; scaled by both scale and lbl_scale in build()).
local _BASE_TITLE_FS     = Screen:scaleBySize(11)
local _BASE_AUTHOR_FS    = Screen:scaleBySize(10)
local _BASE_PCT_FS       = Screen:scaleBySize(8)
local _BASE_STATS_FS     = Screen:scaleBySize(8)
local _BASE_INLINEPCT_FS = Screen:scaleBySize(11)  -- pct label inside the bar (with_pct style)

-- Setting key for progress bar style: "simple" (default) or "with_pct"
local BAR_STYLE_KEY = "currently_with_pace_bar_style"

local function getBarStyle(pfx)
    return SUISettings:readSetting(pfx .. BAR_STYLE_KEY) or "with_pct"
end

-- Setting key for stats layout: "default" (one line per stat) or "compact" (single row with · separator + ETA)
local STATS_STYLE_KEY = "currently_with_pace_stats_style"

local function getStatsStyle(pfx)
    return SUISettings:readSetting(pfx .. STATS_STYLE_KEY) or "default"
end

-- Setting key for stats grouping in default mode: "none", "pairs", or "triples"
local STATS_GROUPING_KEY = "currently_with_pace_stats_grouping"

local function getStatsGrouping(pfx)
    return SUISettings:readSetting(pfx .. STATS_GROUPING_KEY) or "pairs"
end

local COVER_GAP_KEY = "currently_with_pace_cover_gap"

local function getCoverGapPct(pfx)
    local v = SUISettings:readSetting(pfx .. COVER_GAP_KEY)
    local n = tonumber(v)
    return n and math.max(0, math.min(300, math.floor(n))) or 100
end

-- Setting key for exclude paths from recent
local EXCLUDE_PATHS_KEY = "currently_with_pace_exclude_paths"

local function getExcludePaths(pfx)
    if not SUISettings then return {} end
    local raw = SUISettings:readSetting(pfx .. EXCLUDE_PATHS_KEY)
    if not raw or raw == "" then return {} end
    local result = {}
    for token in raw:gmatch("[^,\n]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then result[#result + 1] = t end
    end
    return result
end

-- Maximum title length in UTF-8 characters before truncation.
local TITLE_MAX_LEN = 60

-- Caps per-page duration at 120 s when computing avg reading time,
-- matching KOReader's STATISTICS_SQL_BOOK_CAPPED_TOTALS_QUERY.
local _MAX_SEC = 120

-- Per-book stats cache (md5 → { days, total_secs, avg_time }).
-- Cleared by invalidateCache(), called from main.lua:onCloseDocument.
local _bstats_cache = {}


-- Builds a progress bar with an inline percentage label: [▓▓▓░░░░] XX%
-- Spacing below the bar is handled by gap_before() on the next element,
-- consistent with how every other element in the layout works.
local function buildProgressBarWithPct(w, pct, bar_h, scale, lbl_scale, face_inline, fg_color)
    local PCT_W   = math.max(16, math.floor(_BASE_PCT_W       * scale * lbl_scale))
    local GAP     = math.max(2,  math.floor(_BASE_BAR_PCT_GAP * scale))
    local bar_w   = math.max(10, w - GAP - PCT_W)
    local fw      = math.max(0, math.floor(bar_w * math.min(pct, 1.0)))
    local pct_str = string.format("%.0f%%", (pct or 0) * 100)
    -- face_inline is pre-resolved by build(); fallback for direct calls.
    local _face   = face_inline or Font:getFace("smallinfofont", math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))
    local _fg     = fg_color or _CLR_DARK

    local bar
    if fw <= 0 then
        bar = LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bar_h }, background = _CLR_BAR_BG }
    else
        bar = OverlapGroup:new{
            dimen = Geom:new{ w = bar_w, h = bar_h },
            LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bar_h }, background = _CLR_BAR_BG },
            LineWidget:new{ dimen = Geom:new{ w = fw,    h = bar_h }, background = _CLR_BAR_FG },
        }
    end

    return HorizontalGroup:new{
        align = "center",
        bar,
        HorizontalSpan:new{ width = GAP },
        UI.makeColoredText{
            text    = pct_str,
            face    = _face,
            bold    = true,
            fgcolor = _fg,
            width   = PCT_W,
        },
    }
end


-- Formats a duration in seconds as "Xh Ym", "Xh", or "Ym".
local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end


-- Truncates a UTF-8 title to TITLE_MAX_LEN characters, appending "…" if needed.
local function truncateTitle(title)
    if not title then return title end
    local count, i = 0, 1
    while i <= #title do
        local byte    = title:byte(i)
        local charLen = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        count = count + 1
        if count > TITLE_MAX_LEN then
            return title:sub(1, i - 1) .. "…"
        end
        i = i + charLen
    end
    return title
end


-- Fetches reading stats for a book from SQLite (days read, total time, avg time per page).
-- Results are cached by md5 for the duration of the homescreen session.
-- Cache is cleared by invalidateCache() (called from onCloseDocument) before
-- each post-reading rebuild, so data is always fresh when it matters.
-- Uses shared_conn when available to avoid opening a second DB connection.
-- ctx is optional: when provided and a fatal DB error occurs on the shared_conn,
-- ctx.db_conn_fatal is set to true so the homescreen can discard the connection.
local function fetchBookStats(md5, shared_conn, ctx)
    if not md5 then return nil end

    if _bstats_cache[md5] then
        return _bstats_cache[md5]
    end

    local conn     = shared_conn or Config.openStatsDB()
    local own_conn = not shared_conn
    if not conn then return nil end

    local result = nil
    local ok, err = pcall(function()
        -- ps_agg accumulates per-page totals; the outer SELECT aggregates them.
        -- sum(page_dur) replaces a correlated subquery that caused a second
        -- full scan of page_stat on every call.
        -- Relies on idx_simpleui_book_md5 / idx_simpleui_pagestat_book indexes
        -- created by openStatsDB() for O(log n) lookup instead of full-table scan.
        local row = conn:exec(string.format([[
            WITH b AS (
                SELECT id FROM book WHERE md5 = %q LIMIT 1
            ),
            ps_agg AS (
                SELECT ps.page,
                       sum(ps.duration)   AS page_dur,
                       min(ps.start_time) AS first_start
                FROM page_stat ps
                WHERE ps.id_book = (SELECT id FROM b)
                GROUP BY ps.page
            )
            SELECT
                count(DISTINCT date(first_start, 'unixepoch', 'localtime')),
                sum(page_dur),
                count(*),
                sum(min(page_dur, %d))
            FROM ps_agg;
        ]], md5, _MAX_SEC))

        if row and row[1] and row[1][1] then
            local days   = tonumber(row[1][1]) or 0
            local secs   = tonumber(row[2] and row[2][1]) or 0
            local pages  = tonumber(row[3] and row[3][1]) or 0
            local capped = tonumber(row[4] and row[4][1]) or 0
            result = {
                days       = days,
                total_secs = secs,
                avg_time   = (pages > 0 and capped > 0) and (capped / pages) or nil,
            }
        end
    end)
    if not ok then
        logger.warn("simpleui: module_currently: fetchBookStats failed: " .. tostring(err))
        -- Signal to the homescreen that the shared connection is unusable so it
        -- can be discarded and reopened on the next render.
        if shared_conn and ctx and Config.isFatalDbError(err) then
            ctx.db_conn_fatal = true
        end
    end
    if own_conn then pcall(function() conn:close() end) end
    if result then _bstats_cache[md5] = result end
    return result
end


-- Returns true if the element with the given key is visible (default on).
local function _showElem(pfx, key)
    return SUISettings:nilOrTrue(pfx .. "currently_with_pace_show_" .. key)
end

-- Toggles the visibility of an element.
local function _toggleElem(pfx, key)
    local cur = SUISettings:nilOrTrue(pfx .. "currently_with_pace_show_" .. key)
    SUISettings:saveSetting(pfx .. "currently_with_pace_show_" .. key, not cur)
end


-- Element order and labels used by build() and the Arrange Items SortWidget.
local ELEM_ORDER_KEY = "currently_with_pace_elem_order"

local _ELEM_DEFAULT_ORDER = {
    "title", "author", "progress", "percent",
    "book_days", "book_time", "book_remaining", "days_remaining",
    "avg_time_per_day", "pages_per_minute", "percent_per_day",
}

local _ELEM_LABELS = {
    title            = _("Title"),
    author           = _("Author"),
    progress         = _("Progress bar"),
    percent          = _("Percentage read"),
    book_days        = _("Days of reading"),
    book_time        = _("Time read"),
    book_remaining   = _("Time remaining"),
    days_remaining   = _("Days to finish"),
    avg_time_per_day = _("Avg time per day"),
    pages_per_minute = _("Reading speed (WPM)"),
    percent_per_day  = _("%/day"),
}

-- Returns the user-saved element order, falling back to the default.
-- Unknown keys are dropped; new keys are appended at the tail.
-- _resolveElemOrder accepts an already-read value (from ctx.cfg bundle or
-- a direct G_reader_settings read) so the caller controls when the read happens.
local function _resolveElemOrder(saved)
    if type(saved) ~= "table" or #saved == 0 then
        return _ELEM_DEFAULT_ORDER
    end
    local seen, result = {}, {}
    for _, v in ipairs(saved) do
        if _ELEM_LABELS[v] then seen[v] = true; result[#result+1] = v end
    end
    for _, v in ipairs(_ELEM_DEFAULT_ORDER) do
        if not seen[v] then result[#result+1] = v end
    end
    return result
end

local function _getElemOrder(pfx)
    return _resolveElemOrder(SUISettings:readSetting(pfx .. ELEM_ORDER_KEY))
end


-- Module API
local M = {}

M.id              = "currently_with_pace"
M.name            = _("Currently Reading (with Pace)")
M.description     = "Currently reading book with pace statistics (avg time/day, pages/min, %/day)"
M.default_enabled = false  -- Opt-in module (disabled by default)
M.label           = _("Currently Reading (with Pace)")
M.enabled_key     = "currently_with_pace"
M.default_on      = false
M.has_covers      = true   -- activates e-ink dithering and cover poll
M.is_book_mod     = true   -- suppresses empty-state when active
M.needs           = { db = true }  -- Declare DB need for stats queries


-- ---------------------------------------------------------------------------
-- _computeContentH — shared height calculation used by build() and getHeight()
-- ---------------------------------------------------------------------------
-- Returns the pixel height of the text column (right side), taking the cover
-- height as a minimum.  All parameters mirror the local vars already resolved
-- in build(); getHeight() reconstructs them independently.
--
-- params fields:
--   scale, lbl_scale  — module and text scale factors
--   D                 — dims table from SH.getDims()
--   show              — visibility flags table (title/author/progress/percent/days/time/remain)
--   stats_style       — "default" or "compact"
--   bstats            — result of fetchBookStats, or nil (conservative fallback)
--   bd                — book-data table; only .authors, .avg_time, .pages, .percent used
local function _computeContentH(params)
    local scale       = params.scale
    local lbl_scale   = params.lbl_scale
    local D           = params.D
    local show        = params.show
    local stats_style = params.stats_style
    local bstats      = params.bstats
    local bd          = params.bd or {}
    local bar_style   = params.bar_style or getBarStyle(params.pfx)

    -- Scaled dimensions (same formulas as build()).
    local title_line_h  = math.max(8, math.floor(_BASE_TITLE_FS       * scale * lbl_scale))
    local author_line_h = math.max(8, math.floor(_BASE_AUTHOR_FS      * scale * lbl_scale))
    local pct_line_h    = math.max(8, math.floor(_BASE_PCT_FS         * scale * lbl_scale))
    local stats_line_h  = math.max(7, math.floor(_BASE_STATS_FS       * scale * lbl_scale))
    local bar_h         = math.max(1, math.floor(_BASE_BAR_H          * scale))
    local title_gap     = math.max(1, math.floor(_BASE_TITLE_GAP      * scale))
    local author_gap    = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))
    local bar_gap_b     = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_gap_a     = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale))
    local pct_gap       = math.max(1, math.floor(_BASE_PCT_GAP        * scale))

    -- Accumulate height element by element, mirroring build()'s gap_before logic.
    -- Each entry is { gap, line_h } in render order.
    local elems = {}

    if show.title then
        -- TextBoxWidget with max_lines=2: reserve up to 2 lines.
        elems[#elems+1] = { title_gap, title_line_h * 2 }
    end
    if show.author and bd.authors and bd.authors ~= "" then
        elems[#elems+1] = { author_gap, author_line_h }
    end
    if show.progress then
        -- bar uses bar_gap_before before it and bar_gap_after after it.
        elems[#elems+1] = { bar_gap_b, bar_h + bar_gap_a }
    end
    if show.percent and bar_style ~= "with_pct" then
        elems[#elems+1] = { pct_gap, pct_line_h }
    end

    -- Stats: when conservative=true (getHeight path) assume all active stats
    -- have data so that height is never under-allocated.
    -- When conservative=false (build path, bstats is real) check actual values.
    local conservative = params.conservative
    local function statsHasData(key)
        if conservative then return show[key] end
        if not bstats then return false end
        if key == "days"   then return show.days   and bstats.days and bstats.days > 0 end
        if key == "time"   then return show.time   and bstats.total_secs and bstats.total_secs > 0 end
        if key == "remain" then
            local avg_t = (bstats.avg_time and bstats.avg_time > 0) and bstats.avg_time
                          or bd.avg_time
            return show.remain and avg_t and avg_t > 0
                   and bd.pages and bd.pages > 0
        end
        return false
    end

    if stats_style == "compact" then
        if statsHasData("days") or statsHasData("time") or statsHasData("remain") then
            elems[#elems+1] = { pct_gap, stats_line_h }
        end
    else
        if statsHasData("days")   then elems[#elems+1] = { pct_gap, stats_line_h } end
        if statsHasData("time")   then elems[#elems+1] = { pct_gap, stats_line_h } end
        if statsHasData("remain") then elems[#elems+1] = { pct_gap, stats_line_h } end
    end

    -- Sum up: first element has no leading gap (mirrors gap_before guard).
    local h = 0
    for i, e in ipairs(elems) do
        if i > 1 then h = h + e[1] end  -- gap (skipped for first element)
        h = h + e[2]                     -- line height
    end

    return math.max(D.COVER_H, h)
end


-- Clears the stats cache (called from main.lua:onCloseDocument before rebuild).
function M.invalidateCache()
    _bstats_cache = {}
end

-- Exposed for pre-computation in _buildCtx (sui_homescreen.lua).
-- Mirrors module_coverdeck.fetchBookStatsForCtx.
-- Returns the stats table or nil; does NOT set ctx.db_conn_fatal (no ctx here).
function M.fetchBookStatsForCtx(md5, db_conn)
    return fetchBookStats(md5, db_conn, nil)
end


-- Helper: check if a filepath matches any exclude fragment
local function isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- Helper: get current filepath, falling back to ReadHistory when ctx.current_fp is absent
local function _getCurrentFP(ctx, pfx)
    local excludes = getExcludePaths(pfx)
    -- ctx.current_fp: honour it only when it is not excluded.
    if ctx.current_fp and not isExcluded(ctx.current_fp, excludes) then
        return ctx.current_fp
    end
    local ok, RH = pcall(require, "readhistory")
    if not ok or not RH then return nil end
    if not (RH.hist and #RH.hist > 0) then
        pcall(function() RH:reload() end)
    end
    if not RH.hist then return nil end
    for _, e in ipairs(RH.hist) do
        if e and e.file and not isExcluded(e.file, excludes) then
            return e.file
        end
    end
    return nil
end

-- Builds the module widget: cover on the left, text column on the right.
-- Elements in the text column are rendered in user-configured order.
function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Currently Reading"))
    
    local SH = getSH()
    if not SH then return nil end

    -- Use pre-read settings bundle from ctx when available (normal HS path).
    -- Falls back to direct reads only when called outside the homescreen.
    local c = ctx.cfg and ctx.cfg.currently_with_pace
    local pfx         = ctx.pfx
    
    -- Get current filepath (independent of SimpleUI's built-in "currently" module)
    -- Respects exclude paths setting
    local current_fp = _getCurrentFP(ctx, pfx)
    if not current_fp then return nil end
    local scale       = c and c.scale       or Config.getModuleScale("currently_with_pace", pfx)
    local thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently_with_pace", pfx)
    local lbl_scale   = c and c.lbl_scale   or Config.getItemLabelScale("currently_with_pace", pfx)
    local bar_style      = c and c.bar_style      or getBarStyle(pfx)
    local stats_style    = c and c.stats_style    or getStatsStyle(pfx)
    local stats_grouping = c and c.stats_grouping or getStatsGrouping(pfx)
    local show        = c and c.show or {
        title            = _showElem(pfx, "title"),
        author           = _showElem(pfx, "author"),
        progress         = _showElem(pfx, "progress"),
        percent          = _showElem(pfx, "percent"),
        days             = _showElem(pfx, "book_days"),
        time             = _showElem(pfx, "book_time"),
        remain           = _showElem(pfx, "book_remaining"),
        days_remain      = _showElem(pfx, "days_remaining"),
        avg_time_per_day = _showElem(pfx, "avg_time_per_day"),
        pages_per_minute = _showElem(pfx, "pages_per_minute"),
        percent_per_day  = _showElem(pfx, "percent_per_day"),
    }
    -- elem_order: use cached raw value from bundle; resolve lazily.
    local elem_order  = _resolveElemOrder(c and c.elem_order or SUISettings:readSetting(pfx .. ELEM_ORDER_KEY))

    local D           = SH.getDims(scale, thumb_scale)

    -- Scale gaps (layout scale only).
    local cover_gap      = math.max(0, math.floor(_BASE_COVER_GAP      * scale * (getCoverGapPct(pfx) / 100)))
    local title_gap      = math.max(1, math.floor(_BASE_TITLE_GAP      * scale))
    local author_gap     = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))
    local bar_gap_before = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_gap_after  = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale))
    local pct_gap        = math.max(1, math.floor(_BASE_PCT_GAP        * scale))
    local bar_h          = math.max(1, math.floor(_BASE_BAR_H          * scale))

    -- Scale font sizes (layout scale × text scale).
    local title_fs   = math.max(8, math.floor(_BASE_TITLE_FS   * scale * lbl_scale))
    local author_fs  = math.max(8, math.floor(_BASE_AUTHOR_FS  * scale * lbl_scale))
    local pct_fs     = math.max(8, math.floor(_BASE_PCT_FS     * scale * lbl_scale))
    local stats_fs   = math.max(7, math.floor(_BASE_STATS_FS   * scale * lbl_scale))

    -- Resolve font faces once so they are not re-created per element.
    local face_title  = Font:getFace("smallinfofont", title_fs)
    local face_author = Font:getFace("smallinfofont", author_fs)
    local face_pct    = Font:getFace("smallinfofont", pct_fs)
    local face_s      = Font:getFace("smallinfofont", stats_fs)

    -- Use prefetched book data. After onCloseDocument, _cached_books_state is
    -- cleared and prefetchBooks() re-reads the sidecar, so this is always fresh.
    local prefetched_entry = ctx.prefetched and ctx.prefetched[current_fp]
    local bd    = SH.getBookData(current_fp, prefetched_entry)
    local cover = SH.getBookCover(current_fp, D.COVER_W, D.COVER_H, nil, 0.10)
                  or SH.coverPlaceholder(bd.title, bd.authors, D.COVER_W, D.COVER_H)

    -- Text column width: full width minus both PADs, cover, and cover gap.
    local tw = w - PAD - D.COVER_W - cover_gap - PAD

    local meta = VerticalGroup:new{ align = "left" }

    -- Fetch stats once if any stats element is active.
    local bstats
    if show.days or show.time or show.remain or show.avg_time_per_day or show.pages_per_minute or show.percent_per_day then
        local book_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
        -- Fallback: if md5 is missing from prefetch, try DocSettings
        if not book_md5 and ctx.db_conn then
            local ok_ds, DS = pcall(require, "docsettings")
            if ok_ds and DS then
                local ok2, ds = pcall(DS.open, DS, current_fp)
                if ok2 and ds then
                    book_md5 = ds:readSetting("partial_md5_checksum")
                    pcall(function() ds:close() end)
                end
            end
        end
        if not book_md5 then
            logger.dbg("simpleui: module_currently_with_pace: no md5 for "
                       .. tostring(current_fp)
                       .. " — stats will not be fetched this render")
        end
        -- Fetch stats from DB (no pre-computation for this module yet)
        bstats = fetchBookStats(book_md5, ctx.db_conn, ctx)
    end

    -- Colour used for placeholder stats text (dimmer than the normal sub-text).
    local CLR_PLACEHOLDER = Blitbuffer.gray(0.55)

    -- Theme: when fg is set use it for all text; otherwise fall back to module defaults.
    local ok_ss, SUIStyle  = pcall(require, "sui_style")
    local _theme_fg        = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
    local _theme_secondary = ok_ss and SUIStyle and SUIStyle.getThemeColor("text_secondary")
    local _CLR_DARK_EFF    = _theme_fg or _CLR_DARK
    local CLR_TEXT_SUB_EFF = _theme_secondary or _theme_fg or CLR_TEXT_SUB
    local CLR_PH_EFF       = _theme_secondary or _theme_fg or CLR_PLACEHOLDER

    -- Pre-resolve the inline-pct font face once for buildProgressBarWithPct.
    local face_inlinepct = Font:getFace("smallinfofont",
        math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))

    -- Flags to ensure stats are rendered only once per mode
    local _compact_stats_rendered = false
    local _default_stats_rendered = false

    -- Adds a vertical gap before the next element, but not before the first one.
    -- _next_gap overrides the default size for exactly one call (used after the
    -- progress bar, where bar_gap_after compensates for font metric asymmetry).
    local meta_has_content = false
    local _next_gap        = nil
    local function gap_before(size)
        if meta_has_content then
            meta[#meta+1] = VerticalSpan:new{ width = _next_gap or size }
        end
        _next_gap = nil
    end

    -- Append each visible element to meta in user-configured order.
    for _i, elem in ipairs(elem_order) do
        if elem == "title" and show.title then
            gap_before(title_gap)

            local title_args = {
                text      = truncateTitle(bd.title) or "?",
                face      = face_title,
                bold      = true,
                width     = tw,
                max_lines = 2,
                fgcolor   = _CLR_DARK_EFF,
            }

            local title_w
            if ctx.has_wallpaper then
                title_w = UI.makeAlphaTextBox(title_args)
            else
                title_w = TextBoxWidget:new(title_args)
            end

            meta[#meta+1] = title_w
            meta_has_content = true

        elseif elem == "author" and show.author and bd.authors and bd.authors ~= "" then
            gap_before(author_gap)
            meta[#meta+1] = UI.makeColoredText{
                text            = bd.authors,
                face            = face_author,
                fgcolor         = CLR_TEXT_SUB_EFF,
                width           = tw,
                max_width       = tw,
                truncation_char = "â¦",  -- "…" UTF-8
            }
            meta_has_content = true

        elseif elem == "progress" and show.progress then
            gap_before(bar_gap_before)
            if bar_style == "with_pct" then
                meta[#meta+1] = buildProgressBarWithPct(tw, bd.percent, bar_h, scale, lbl_scale, face_inlinepct, _CLR_DARK_EFF)
            else
                meta[#meta+1] = SH.progressBar(tw, bd.percent, bar_h)
            end
            meta_has_content = true
            _next_gap = bar_gap_after  -- next element uses the larger post-bar gap

        elseif elem == "percent" and show.percent and bar_style ~= "with_pct" then
            gap_before(pct_gap)
            meta[#meta+1] = UI.makeColoredText{
                text    = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5)),
                face    = face_pct,
                bold    = true,
                fgcolor = _CLR_DARK_EFF,
                width   = tw,
            }
            meta_has_content = true

        elseif (elem == "book_days" or elem == "book_time" or elem == "book_remaining"
                or elem == "avg_time_per_day" or elem == "pages_per_minute" or elem == "percent_per_day")
               and stats_style == "default" then
            -- Default mode with grouping support
            -- This block is entered ONLY ONCE for the first visible stat element
            if not _default_stats_rendered then
                _default_stats_rendered = true
                
                -- Helper to build stat text
                local function buildStatText(e)
                    if e == "book_days" and show.days then
                        local has_data = bstats and bstats.days and bstats.days > 0
                        return has_data and string.format(N_("%d day of reading", "%d days of reading", bstats.days), bstats.days)
                               or string.format(N_("%d day of reading", "%d days of reading", 0), 0), has_data
                    elseif e == "book_time" and show.time then
                        local has_data = bstats and bstats.total_secs and bstats.total_secs > 0
                        return has_data and string.format(_("%s read"), fmtTime(bstats.total_secs))
                               or string.format(_("%s read"), "—"), has_data
                    elseif e == "book_remaining" and show.remain then
                        local avg_t = (bstats and bstats.avg_time and bstats.avg_time > 0) and bstats.avg_time or bd.avg_time
                        local pct_done = bd.percent or 0
                        if avg_t and avg_t > 0 and bd.pages and bd.pages > 0 then
                            local pages_left = bd.pages * (1 - pct_done)
                            local secs_left = math.floor(avg_t * pages_left)
                            if secs_left > 0 then
                                return string.format(_("%s left"), fmtTime(secs_left)), true
                            end
                        end
                        if pct_done < 1.0 then
                            return string.format(_("%s left"), "—"), false
                        end
                        return nil, false
                    elseif e == "avg_time_per_day" and show.avg_time_per_day then
                        local has_data = bstats and bstats.days and bstats.days > 0 and bstats.total_secs and bstats.total_secs > 0
                        if has_data then
                            local avg_per_day = bstats.total_secs / bstats.days
                            local h = math.floor(avg_per_day / 3600)
                            local m = math.floor((avg_per_day % 3600) / 60)
                            local time_str = (h > 0 and m > 0) and string.format("%dh %dm/day", h, m)
                                             or (h > 0) and string.format("%dh/day", h)
                                             or string.format("%dm/day", m)
                            return time_str, true
                        else
                            return "—/day", false
                        end
                    elseif e == "pages_per_minute" and show.pages_per_minute then
                        local has_data = bstats and bstats.avg_time and bstats.avg_time > 0
                        if has_data then
                            local ppm = 60 / bstats.avg_time
                            return (ppm >= 1) and string.format("%.0fwpm", ppm) or string.format("%.1fwpm", ppm), true
                        else
                            return "—wpm", false
                        end
                    elseif e == "percent_per_day" and show.percent_per_day then
                        local has_data = bstats and bstats.days and bstats.days > 0 and bd.percent and bd.percent > 0
                        if has_data then
                            local pct_per_day = (bd.percent * 100) / bstats.days
                            return string.format("%.1f%%/day", pct_per_day), true
                        else
                            return "—%/day", false
                        end
                    elseif e == "days_remaining" and show.days_remain then
                        local has_data = bstats and bstats.days and bstats.days > 0 and bd.percent and bd.percent > 0 and bd.percent < 1.0
                        if has_data then
                            local pct_per_day = bd.percent / bstats.days
                            local pct_left = 1.0 - bd.percent
                            local days_left = math.ceil(pct_left / pct_per_day)
                            return string.format(N_("%dd to go", "%dd to go", days_left), days_left), true
                        else
                            return "—d to go", false
                        end
                    end
                    return nil, false
                end
                
                -- Collect all stats in order
                local stats_to_render = {}
                for _, e in ipairs(elem_order) do
                    local text, has_data = buildStatText(e)
                    if text then
                        stats_to_render[#stats_to_render+1] = { text = text, has_data = has_data }
                    end
                end
                
                -- Render based on grouping setting
                if #stats_to_render > 0 then
                    if stats_grouping == "none" then
                        -- One stat per line
                        for _, stat in ipairs(stats_to_render) do
                            gap_before(pct_gap)
                            local stat_widget
                            if ctx.has_wallpaper then
                                stat_widget = UI.makeAlphaTextBox{
                                    text      = stat.text,
                                    face      = face_s,
                                    fgcolor   = stat.has_data and _CLR_DARK_EFF or CLR_PH_EFF,
                                    width     = tw,
                                    alignment = "left",
                                }
                            else
                                stat_widget = TextBoxWidget:new{
                                    text      = stat.text,
                                    face      = face_s,
                                    fgcolor   = stat.has_data and _CLR_DARK_EFF or CLR_PH_EFF,
                                    width     = tw,
                                    alignment = "left",
                                }
                            end
                            meta[#meta+1] = stat_widget
                            meta_has_content = true
                        end
                    elseif stats_grouping == "pairs" or stats_grouping == "triples" then
                        -- Group stats
                        local group_size = (stats_grouping == "pairs") and 2 or 3
                        local i = 1
                        while i <= #stats_to_render do
                            gap_before(pct_gap)
                            local group_parts = {}
                            for j = i, math.min(i + group_size - 1, #stats_to_render) do
                                group_parts[#group_parts+1] = stats_to_render[j].text
                            end
                            local group_text = table.concat(group_parts, " • ")
                            
                            local stats_widget
                            if ctx.has_wallpaper then
                                stats_widget = UI.makeAlphaTextBox{
                                    text      = group_text,
                                    face      = face_s,
                                    fgcolor   = CLR_TEXT_SUB_EFF,
                                    width     = tw,
                                    alignment = "left",
                                }
                            else
                                stats_widget = TextBoxWidget:new{
                                    text      = group_text,
                                    face      = face_s,
                                    fgcolor   = CLR_TEXT_SUB_EFF,
                                    width     = tw,
                                    alignment = "left",
                                }
                            end
                            meta[#meta+1] = stats_widget
                            meta_has_content = true
                            i = i + group_size
                        end
                    end
                end
            end

        elseif (elem == "book_days" or elem == "book_time" or elem == "book_remaining"
                or elem == "avg_time_per_day" or elem == "pages_per_minute" or elem == "percent_per_day")
               and stats_style == "compact" then
            -- Compact mode: single row following the Arrange Items order.
            -- Fires on the first visible stats element encountered; the others are
            -- consumed here so they don't produce a second row when the loop reaches them.
            if not _compact_stats_rendered then
                _compact_stats_rendered = true

                -- Compute secs_left once (shared by "remain" and ETA).
                local secs_left
                local avg_t = (bstats and bstats.avg_time and bstats.avg_time > 0)
                              and bstats.avg_time or bd.avg_time
                if avg_t and avg_t > 0 and bd.pages and bd.pages > 0 then
                    local pages_left = bd.pages * (1 - (bd.percent or 0))
                    local sl = math.floor(avg_t * pages_left)
                    if sl > 0 then secs_left = sl end
                end

                -- Build parts in Arrange Items order, walking the full element order.
                local parts = {}
                for _i, e in ipairs(elem_order) do
                    if e == "book_time" and show.time and bstats and bstats.total_secs and bstats.total_secs > 0 then
                        parts[#parts+1] = { text = string.format(_("%s read"), fmtTime(bstats.total_secs)), placeholder = false }
                    elseif e == "book_remaining" and show.remain and secs_left then
                        parts[#parts+1] = { text = string.format(_("%s left"), fmtTime(secs_left)), placeholder = false }
                    elseif e == "book_days" and show.days and bstats and bstats.days and bstats.days > 0 then
                        parts[#parts+1] = { text = string.format(N_("%d day of reading", "%d days of reading", bstats.days), bstats.days), placeholder = false }
                    elseif e == "avg_time_per_day" and show.avg_time_per_day and bstats and bstats.days and bstats.days > 0 and bstats.total_secs and bstats.total_secs > 0 then
                        local avg_per_day = bstats.total_secs / bstats.days
                        local h = math.floor(avg_per_day / 3600)
                        local m = math.floor((avg_per_day % 3600) / 60)
                        local time_str = (h > 0 and m > 0) and string.format("%dh %dm/day", h, m)
                                         or (h > 0) and string.format("%dh/day", h)
                                         or string.format("%dm/day", m)
                        parts[#parts+1] = { text = time_str, placeholder = false }
                    elseif e == "pages_per_minute" and show.pages_per_minute and bstats and bstats.avg_time and bstats.avg_time > 0 then
                        local ppm = 60 / bstats.avg_time
                        local wpm_str = (ppm >= 1) and string.format("%.0fwpm", ppm) or string.format("%.1fwpm", ppm)
                        parts[#parts+1] = { text = wpm_str, placeholder = false }
                    elseif e == "percent_per_day" and show.percent_per_day and bstats and bstats.days and bstats.days > 0 and bd.percent and bd.percent > 0 then
                        local pct_per_day = (bd.percent * 100) / bstats.days
                        parts[#parts+1] = { text = string.format("%.1f%%/day", pct_per_day), placeholder = false }
                    elseif e == "days_remaining" and show.days_remain and bstats and bstats.days and bstats.days > 0 and bd.percent and bd.percent > 0 and bd.percent < 1.0 then
                        local pct_per_day = bd.percent / bstats.days
                        local pct_left = 1.0 - bd.percent
                        local days_left = math.ceil(pct_left / pct_per_day)
                        parts[#parts+1] = { text = string.format(N_("%dd to go", "%dd to go", days_left), days_left), placeholder = false }
                    end
                end

                -- Fix 1: when all visible stats items are active but have no data yet,
                -- show at least one placeholder so the row is always visible.
                if #parts == 0 then
                    local any_active = (show.days or show.time or show.remain)
                    if any_active then
                        parts[#parts+1] = { text = string.format(_("%s read"), "—"), placeholder = true }
                    end
                end

                if #parts > 0 then
                    gap_before(pct_gap)
                    -- Build single text string with separators
                    local text_parts = {}
                    for i, part in ipairs(parts) do
                        if i > 1 then
                            text_parts[#text_parts+1] = " · "
                        end
                        text_parts[#text_parts+1] = part.text
                    end
                    local stats_text = table.concat(text_parts)
                    
                    -- Use TextBoxWidget for automatic wrapping when text is too long
                    local stats_widget
                    if ctx.has_wallpaper then
                        stats_widget = UI.makeAlphaTextBox{
                            text      = stats_text,
                            face      = face_s,
                            fgcolor   = CLR_TEXT_SUB_EFF,
                            width     = tw,
                            alignment = "left",
                        }
                    else
                        stats_widget = TextBoxWidget:new{
                            text      = stats_text,
                            face      = face_s,
                            fgcolor   = CLR_TEXT_SUB_EFF,
                            width     = tw,
                            alignment = "left",
                        }
                    end
                    meta[#meta+1] = stats_widget
                    meta_has_content = true
                end
            end
        end
    end

    -- Measure the real height of the text column by asking the VerticalGroup
    -- itself — this is the only reliable way since TextWidget line heights
    -- depend on the font metrics, not just the font size number.
    local meta_h = meta:getSize().h
    local content_h = math.max(D.COVER_H, meta_h)

    -- Layout: cover on left, text column on right.
    -- The cover is wrapped in a CenterContainer sized to content_h so it
    -- stays vertically centred when the text column is taller than the cover.
    local cover_frame = FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        }
    local cover_centered = CenterContainer:new{
        dimen = Geom:new{ w = D.COVER_W + cover_gap, h = content_h },
        cover_frame,
    }

    local meta_centered = CenterContainer:new{
        dimen = Geom:new{ w = tw, h = content_h },
        meta,
    }

    local row = HorizontalGroup:new{
        align = "top",
        cover_centered,
        meta_centered,
    }
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = w, h = content_h },
        _fp      = current_fp,
        _open_fn = ctx.open_fn,
        [1] = FrameContainer:new{
            bordersize    = 0,
            padding       = 0,
            padding_left  = PAD,
            padding_right = PAD,
            row,
        },
    }
    tappable.ges_events = {
        TapBook = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    tappable._cover_slots = {
        { container = cover_frame, idx = 1, fp = current_fp,
          w = D.COVER_W, h = D.COVER_H, align = nil, stretch = 0.10 },
    }
    function tappable:onTapBook()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    -- Keyboard focus: overlay a black rectangular border on the tappable when
    -- this book is the currently selected keyboard-navigation item.
    if ctx.kb_currently_focused then
        local bw = Screen:scaleBySize(3)
        local tw = w
        local th = content_h
        return OverlapGroup:new{
            dimen = Geom:new{ w = tw, h = th },
            tappable,
            LineWidget:new{ dimen = Geom:new{ w = tw, h = bw },    background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = tw, h = bw },    background = _CLR_DARK_EFF, overlap_offset = {0, th - bw} },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = th },    background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = th },    background = _CLR_DARK_EFF, overlap_offset = {tw - bw, 0} },
        }
    end

    return tappable
end

-- updateCovers(widget, ctx) — called by the homescreen cover poll instead of
-- a full build(). Swaps only the cover image(s) inside the existing widget
-- tree, leaving all text, layout, and gesture handlers untouched.
-- Returns true if all covers are now resolved, false if some are still missing.
function M.updateCovers(widget, _ctx)
    -- widget is either tappable (normal) or OverlapGroup{tappable,...} (kb focus)
    local tappable = (widget._cover_slots) and widget
                     or (widget[1] and widget[1]._cover_slots and widget[1])
    if not tappable or not tappable._cover_slots then return true end

    local SH = getSH()
    if not SH then return true end

    local all_done = true
    for _, slot in ipairs(tappable._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end-- Returns the total pixel height of the module including the section label.
-- Measures real font line heights via Font:getFace() so the estimate matches
-- what build() actually renders.  This prevents the homescreen from
-- under-allocating space and causing overlap with the module below.
function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH() end
    local pfx         = _ctx and _ctx.pfx
    local scale       = Config.getModuleScale("currently_with_pace", pfx)
    local lbl_scale   = Config.getItemLabelScale("currently_with_pace", pfx)
    local D           = SH.getDims(scale, Config.getThumbScale("currently_with_pace", pfx))
    local stats_style = getStatsStyle(pfx)
    local bar_style   = getBarStyle(pfx)

    local show = {
        title            = _showElem(pfx, "title"),
        author           = _showElem(pfx, "author"),
        progress         = _showElem(pfx, "progress"),
        percent          = _showElem(pfx, "percent"),
        days             = _showElem(pfx, "book_days"),
        time             = _showElem(pfx, "book_time"),
        remain           = _showElem(pfx, "book_remaining"),
        days_remain      = _showElem(pfx, "days_remaining"),
        avg_time_per_day = _showElem(pfx, "avg_time_per_day"),
        pages_per_minute = _showElem(pfx, "pages_per_minute"),
        percent_per_day  = _showElem(pfx, "percent_per_day"),
    }

    -- Measure real line heights using the same font faces as build().
    local title_fs  = math.max(8, math.floor(_BASE_TITLE_FS  * scale * lbl_scale))
    local author_fs = math.max(8, math.floor(_BASE_AUTHOR_FS * scale * lbl_scale))
    local pct_fs    = math.max(8, math.floor(_BASE_PCT_FS    * scale * lbl_scale))
    local stats_fs  = math.max(7, math.floor(_BASE_STATS_FS  * scale * lbl_scale))
    local bar_h     = math.max(1, math.floor(_BASE_BAR_H          * scale))
    local bar_gap_b = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_gap_a = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale))
    local title_gap = math.max(1, math.floor(_BASE_TITLE_GAP      * scale))
    local author_gap= math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))
    local pct_gap   = math.max(1, math.floor(_BASE_PCT_GAP        * scale))

    -- Ask the font engine for the real line height (includes ascender+descender).
    local function faceH(fs)
        local ok, face = pcall(Font.getFace, Font, "smallinfofont", fs)
        if ok and face and face.size and face.size.height then
            return face.size.height
        end
        -- fallback: font size * 1.8 approximates typical line height
        return math.ceil(fs * 1.8)
    end

    local title_lh  = faceH(title_fs)
    local author_lh = faceH(author_fs)
    local pct_lh    = faceH(pct_fs)
    local stats_lh  = faceH(stats_fs)

    -- Build the same element list as _computeContentH but with real line heights.
    local elems = {}
    if show.title then
        elems[#elems+1] = { title_gap, title_lh }
    end
    if show.author then
        elems[#elems+1] = { author_gap, author_lh }
    end
    if show.progress then
        elems[#elems+1] = { bar_gap_b, bar_h + bar_gap_a }
    end
    if show.percent and bar_style ~= "with_pct" then
        elems[#elems+1] = { pct_gap, pct_lh }
    end
    -- Stats: conservative — always reserve height for every active stats item
    -- (Fix 3: placeholder rows are rendered when data is absent, so height is
    -- always consumed; under-allocating here would cause overlap below the module).
    -- Exception: book_remaining is suppressed only when the book is 100% done,
    -- but getHeight has no percent data, so we keep the conservative assumption.
    local n_stats = (show.days and 1 or 0) + (show.time and 1 or 0) + (show.remain and 1 or 0)
                    + (show.avg_time_per_day and 1 or 0) + (show.pages_per_minute and 1 or 0) + (show.percent_per_day and 1 or 0)
    if n_stats > 0 then
        local lines = stats_style == "compact" and 1 or n_stats
        for _ = 1, lines do
            elems[#elems+1] = { pct_gap, stats_lh }
        end
    end

    local text_h = 0
    for i, e in ipairs(elems) do
        if i > 1 then text_h = text_h + e[1] end
        text_h = text_h + e[2]
    end

    return Config.getScaledLabelH() + math.max(D.COVER_H, text_h)
end


-- Settings menu helpers (scale, text size, cover size).
local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("currently_with_pace", pfx) end,
        set          = function(v) Config.setModuleScale(v, "currently_with_pace", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnail only.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("currently_with_pace", pfx) end,
        set       = function(v) Config.setThumbScale(v, "currently_with_pace", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

local function _makeTextScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for all text elements (title, author, progress, time).\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("currently_with_pace", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "currently_with_pace", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end


local function _makeCoverGapItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function()
            local pct = getCoverGapPct(pfx)
            return pct == 100
                and _lc("Cover Spacing")
                or  string.format("%s (%d%%)", _lc("Cover Spacing"), pct)
        end,
        separator = true,
        title     = _lc("Cover Spacing"),
        info      = _lc("Horizontal space between the cover and the text.\n100% is the default spacing."),
        get       = function() return getCoverGapPct(pfx) end,
        set       = function(v) SUISettings:saveSetting(pfx .. COVER_GAP_KEY, v) end,
        refresh   = ctx_menu.refresh,
        value_min = 0,
        value_max = 300,
        value_step = 10,
        default_value = 100,
    })
end

-- Returns the settings menu items for this module.
function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle_item(label, key)
        return {
            text_func    = function() return _lc(label) end,
            checked_func = function() return _showElem(pfx, key) end,
            keep_menu_open = true,
            callback     = function()
                _toggleElem(pfx, key)
                refresh()
            end,
        }
    end

    local _UIManager  = ctx_menu.UIManager
    local InfoMessage = ctx_menu.InfoMessage
    local SortWidget  = ctx_menu.SortWidget

    local thumb = _makeThumbScaleItem(ctx_menu)

    local gap_item = _makeCoverGapItem(ctx_menu)

    local items_submenu = {
        -- Arrange Items: drag-to-reorder the visible elements. Disabled when fewer than 2 are active.
        {
            text           = _lc("Arrange Items"),
            keep_menu_open = true,
            separator      = true,
            enabled_func   = function()
                local active = 0
                for _, key in ipairs(_ELEM_DEFAULT_ORDER) do
                    if _showElem(pfx, key) then
                        active = active + 1
                        if active >= 2 then return true end
                    end
                end
                return false
            end,
            callback = function()
                local sort_items = {}
                for _, key in ipairs(_getElemOrder(pfx)) do
                    if _showElem(pfx, key) then
                        sort_items[#sort_items+1] = {
                            text      = _lc(_ELEM_LABELS[key]),
                            orig_item = key,
                        }
                    end
                end
                _UIManager:show(SortWidget:new{
                    title             = _lc("Arrange Items"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local new_order = {}
                        for _, item in ipairs(sort_items) do
                            new_order[#new_order+1] = item.orig_item
                        end
                        -- Append inactive elements at the tail so their position is stable.
                        local active_set = {}
                        for _, k in ipairs(new_order) do active_set[k] = true end
                        for _, k in ipairs(_getElemOrder(pfx)) do
                            if not active_set[k] then new_order[#new_order+1] = k end
                        end
                        SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                        refresh()
                    end,
                })
            end,
        },
        -- Visibility toggles (alphabetical order).
        toggle_item("Author",          "author"),
        toggle_item("Days of reading", "book_days"),
        {
            text_func      = function() return _lc("Percentage read") end,
            -- Greyed out when with_pct bar style is active (percentage is already in the bar).
            enabled_func   = function() return getBarStyle(pfx) == "simple" end,
            checked_func   = function() return _showElem(pfx, "percent") end,
            keep_menu_open = true,
            callback       = function()
                _toggleElem(pfx, "percent")
                refresh()
            end,
        },
        toggle_item("Progress bar", "progress"),
        {
            text = _lc("Progress bar style"),
            sub_item_table = {
                {
                    text           = _lc("Simple"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getBarStyle(pfx) == "simple" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "simple")
                        refresh()
                    end,
                },
                {
                    text           = _lc("With percentage"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getBarStyle(pfx) == "with_pct" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "with_pct")
                        refresh()
                    end,
                },
            },
        },
        toggle_item("Time read",         "book_time"),
        toggle_item("Time remaining",    "book_remaining"),
        toggle_item("Days to finish",    "days_remaining"),
        toggle_item("Avg time per day",  "avg_time_per_day"),
        toggle_item("Reading speed (WPM)", "pages_per_minute"),
        toggle_item("%/day",             "percent_per_day"),
        toggle_item("Title",             "title"),
        {
            text = _lc("Stats layout"),
            sub_item_table = {
                {
                    text           = _lc("Default"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsStyle(pfx) == "default" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_STYLE_KEY, "default")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Compact"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsStyle(pfx) == "compact" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_STYLE_KEY, "compact")
                        refresh()
                    end,
                },
            },
        },
        {
            text = _lc("Stats grouping (Default mode)"),
            enabled_func = function() return getStatsStyle(pfx) == "default" end,
            sub_item_table = {
                {
                    text           = _lc("None (one per line)"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsGrouping(pfx) == "none" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_GROUPING_KEY, "none")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Pairs (2 per line)"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsGrouping(pfx) == "pairs" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_GROUPING_KEY, "pairs")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Triples (3 per line)"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsGrouping(pfx) == "triples" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_GROUPING_KEY, "triples")
                        refresh()
                    end,
                },
            },
        },
    }

    return {
        _makeScaleItem(ctx_menu),
        _makeTextScaleItem(ctx_menu),
        thumb,
        gap_item,
        Config.makeLabelToggleItem("currently_with_pace", _("Currently Reading (with Pace)"), refresh, _lc),
        {
            text           = _lc("Items"),
            sub_item_table = items_submenu,
        },
        {
            text_func = function()
                local raw = SUISettings:readSetting(pfx .. EXCLUDE_PATHS_KEY)
                if not raw or raw == "" then
                    return _lc("Exclude Paths from Recent")
                end
                local n = 0
                for _ in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _lc("Exclude Paths from Recent"), n)
            end,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local UIManager = require("ui/uimanager")
                local raw = SUISettings:readSetting(pfx .. EXCLUDE_PATHS_KEY) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _lc("Exclude Paths from Recent"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss,instapaper,cache",
                    description = _lc("Comma-separated path fragments.\nBooks whose path contains any fragment will be skipped."),
                    buttons     = {
                        {
                            {
                                text = _("Cancel"),
                                background = Blitbuffer.COLOR_WHITE,
                                id = "close",
                                callback = function()
                                    UIManager:close(dlg)
                                end,
                            },
                            {
                                text = _("Save"),
                                background = Blitbuffer.COLOR_WHITE,
                                is_enter_default = true,
                                callback = function()
                                    local val = dlg:getInputText()
                                    SUISettings:saveSetting(pfx .. EXCLUDE_PATHS_KEY, val)
                                    UIManager:close(dlg)
                                    refresh()
                                end,
                            },
                        },
                    },
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        },
    }
end

return M