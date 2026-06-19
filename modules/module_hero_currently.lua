-- modules/module_hero_currently.lua — SimpleUI Extra Modules
-- Hero Currently Reading card.
--
-- Displays the currently-reading book as a large hero card:
--   • Book cover (left)
--   • Title, author, description blurb, progress bar, page/time info (right)
--
-- Modelled after SimpleUI's module_currently.lua; uses the same shared
-- helpers (module_books_shared, sui_config, sui_style, …).

local Device          = require("device")
local Screen          = Device.screen
local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local BottomContainer  = require("ui/widget/container/bottomcontainer")
local FrameContainer   = require("ui/widget/container/framecontainer")
local TopContainer     = require("ui/widget/container/topcontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local InputContainer   = require("ui/widget/container/inputcontainer")
local LineWidget       = require("ui/widget/linewidget")
local OverlapGroup     = require("ui/widget/overlapgroup")
local ProgressWidget   = require("ui/widget/progresswidget")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local TextWidget       = require("ui/widget/textwidget")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local Size             = require("ui/size")
local logger           = require("logger")

-- ---------------------------------------------------------------------------
-- Lazy-loaded SimpleUI helpers (not available until SimpleUI is loaded)
-- ---------------------------------------------------------------------------
local _SH, _Config, _SUISettings, _UI

local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m else
            logger.warn("simpleui_ext: hero_currently: cannot load module_books_shared")
        end
    end
    return _SH
end

local function getConfig()
    if not _Config then
        local ok, m = pcall(require, "sui_config")
        if ok and m then _Config = m end
    end
    return _Config
end

local function getSettings()
    if not _SUISettings then
        local ok, m = pcall(require, "sui_store")
        if ok and m then _SUISettings = m end
    end
    return _SUISettings
end

local function getUI()
    if not _UI then
        local ok, m = pcall(require, "sui_core")
        if ok and m then _UI = m end
    end
    return _UI
end

-- ---------------------------------------------------------------------------
-- HTML stripping (book descriptions from EPUBs often contain markup)
-- ---------------------------------------------------------------------------
local function stripHTML(s)
    if not s or s == "" then return nil end
    -- Convert block-level tags to a space so words don't run together
    s = s:gsub("<br%s*/?>",  " ")
    s = s:gsub("<p[^>]*>",   " ")
    s = s:gsub("</p>",       " ")
    s = s:gsub("<div[^>]*>", " ")
    s = s:gsub("</div>",     " ")
    -- Strip remaining tags
    s = s:gsub("<[^>]+>", "")
    -- Decode common HTML entities
    s = s:gsub("&amp;",  "&")
    s = s:gsub("&lt;",   "<")
    s = s:gsub("&gt;",   ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&#(%d+);", function(n)
        local cp = tonumber(n)
        if cp and cp >= 32 and cp < 128 then return string.char(cp) end
        return " "
    end)
    -- Collapse whitespace
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s ~= "" and s or nil
end

-- ---------------------------------------------------------------------------
-- Time formatter: seconds → "Xh Ym" / "Xh" / "Ym"
-- ---------------------------------------------------------------------------
local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- ---------------------------------------------------------------------------
-- Description reader — opens the book sidecar and returns the blurb string,
-- or nil when absent.  Tries custom_metadata.lua overrides first.
-- ---------------------------------------------------------------------------
local function getBookDescription(fp)
    if not fp then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or lfs.attributes(fp, "mode") ~= "file" then return nil end

    local raw

    -- 1) DocSettings custom_metadata.lua — highest priority (user edits)
    local ok_ds, DS = pcall(require, "docsettings")
    if ok_ds and DS then
        local ok3, custom_file = pcall(DS.findCustomMetadataFile, DS, fp)
        if ok3 and custom_file then
            local ok4, cs = pcall(DS.openSettingsFile, custom_file)
            if ok4 and cs then
                local cp = cs:readSetting("custom_props") or {}
                raw = cp.description or cp.comments
            end
        end
    end

    -- 2) BookInfoManager (BIM) — populated by the CoverBrowser book scanner;
    --    the richest source for description / comments on most EPUB/CBZ books.
    --    Use Config.getBookInfoManager() so the same two-path fallback that
    --    SimpleUI and Bookshelf use is applied (plain require → coverbrowser
    --    plugin path), instead of only trying the plain require.
    if not raw then
        local ok_cfg, Config = pcall(require, "sui_config")
        local BIM = ok_cfg and Config and Config.getBookInfoManager()
        if BIM then
            local ok_i, info = pcall(BIM.getBookInfo, BIM, fp, false)
            if ok_i and info then
                raw = (type(info.description) == "string" and info.description ~= "" and info.description)
                   or (type(info.comments)    == "string" and info.comments    ~= "" and info.comments)
            end
        end
    end

    -- 3) DocSettings sidecar doc_props — fallback when BIM has no entry yet
    if not raw and ok_ds and DS then
        local ok2, ds = pcall(DS.open, DS, fp)
        if ok2 and ds then
            local rp = ds:readSetting("doc_props") or {}
            raw = rp.description or rp.comments
            pcall(function() ds:close() end)
        end
    end

    return raw and stripHTML(raw)
end

-- ---------------------------------------------------------------------------
-- Highlight reader — returns a list of highlights for the given book
-- (KOReader annotations with a highlight-type drawer), or nil when the book
-- has none. Each entry is { text, chapter, pageno, pageref }.
-- ---------------------------------------------------------------------------
local _HIGHLIGHT_DRAWERS = {
    highlight  = true,
    lighten    = true,
    underscore = true,
}

-- Collapses whitespace/newlines in highlight text (plain text extracted from
-- the book, not HTML — unlike descriptions, so stripHTML's tag-stripping
-- would risk eating legitimate "<"/">" characters).
local function normalizeHighlightText(t)
    t = t:gsub("%s+", " ")
    t = t:match("^%s*(.-)%s*$") or t
    return t ~= "" and t or nil
end

local function getBookHighlights(fp)
    if not fp then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or lfs.attributes(fp, "mode") ~= "file" then return nil end
    local ok_ds, DS = pcall(require, "docsettings")
    if not ok_ds or not DS then return nil end
    local ok, ds = pcall(DS.open, DS, fp)
    if not ok or not ds then return nil end
    local annotations = ds:readSetting("annotations")
    pcall(function() ds:close() end)
    if type(annotations) ~= "table" or #annotations == 0 then return nil end

    local result = {}
    for _, a in ipairs(annotations) do
        if a.drawer and _HIGHLIGHT_DRAWERS[a.drawer]
           and type(a.text) == "string" and a.text ~= "" then
            local t = normalizeHighlightText(a.text)
            if t then
                result[#result + 1] = {
                    text    = t,
                    chapter = (type(a.chapter) == "string" and a.chapter ~= "") and a.chapter or nil,
                    pageno  = a.pageno,
                    pageref = a.pageref,
                }
            end
        end
    end
    return #result > 0 and result or nil
end

-- Wraps a highlight's text in curly quotes (stripping any quote marks /
-- leading dashes already present, mirroring SimpleUI's quote module) and, if
-- the annotation carries chapter/page info, appends it as a second paragraph:
--   “Some highlighted text.”
--
--   — Chapter 3 · p. 42
local _LEADING_QUOTES  = '^["\'\u{201C}\u{2018}\u{201E}\u{201A}\u{00AB}\u{2039}%s]+'
local _TRAILING_QUOTES = '["\'\u{201D}\u{2019}\u{201E}\u{201A}\u{00BB}\u{203A}%s]+$'

local function formatHighlight(h)
    local text = h.text:gsub(_LEADING_QUOTES, ''):gsub(_TRAILING_QUOTES, '')
    text = text:gsub('^[\u{2014}\u{2013}]%s*', '')
    local quoted = "\u{201C}" .. text .. "\u{201D}"

    local meta = {}
    if h.chapter then meta[#meta + 1] = h.chapter end
    local pn = h.pageref or h.pageno
    if pn then meta[#meta + 1] = "p. " .. tostring(pn) end

    if #meta > 0 then
        return quoted .. "\n\n\u{2014} " .. table.concat(meta, " \u{00B7} ")
    end
    return quoted
end

-- ---------------------------------------------------------------------------
-- Stats DB: avg reading time per page (same query as module_currently)
-- ---------------------------------------------------------------------------
-- Read the cap from the Statistics plugin's own settings so the value always
-- matches KOReader's "Time spent reading" figure (default 120 s = 2 minutes).
local _DEFAULT_MAX_TIME_PER_PAGE = 120
local function getMaxTimePage()
    local ok, max = pcall(function()
        local s = G_reader_settings:readSetting("statistics")
        return s and tonumber(s.max_sec)
    end)
    return (ok and max and max > 0) and max or _DEFAULT_MAX_TIME_PER_PAGE
end

local function fetchAvgTimeFromDB(md5, db_conn)
    if not md5 or not db_conn then return nil end
    local max_sec = getMaxTimePage()
    local result = nil
    pcall(function()
        local row = db_conn:exec(string.format([[
            WITH b AS (SELECT id FROM book WHERE md5 = %q LIMIT 1),
            ps_agg AS (
                SELECT ps.page, sum(ps.duration) AS page_dur
                FROM page_stat ps
                WHERE ps.id_book = (SELECT id FROM b)
                GROUP BY ps.page
            )
            SELECT sum(min(page_dur, %d)), count(*)
            FROM ps_agg;
        ]], md5, max_sec))
        if row and row[1] and row[1][1] then
            local capped = tonumber(row[1][1]) or 0
            local pages  = tonumber(row[2] and row[2][1]) or 0
            if pages > 0 and capped > 0 then
                result = capped / pages
            end
        end
    end)
    return result
end

-- Fetches days read, total time read, and capped avg time per page from the
-- Stats DB.  Returns { days, total_secs, avg_time } or nil.
local function fetchStatsFromDB(md5, db_conn)
    if not md5 or not db_conn then return nil end
    local max_sec = getMaxTimePage()
    local result  = nil
    pcall(function()
        local row = db_conn:exec(string.format([[
            WITH b AS (SELECT id FROM book WHERE md5 = %q LIMIT 1),
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
        ]], md5, max_sec))
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
    return result
end

-- ---------------------------------------------------------------------------
-- Base dimensions (100% scale reference values)
-- ---------------------------------------------------------------------------
-- Hero cover: proportional — 30% of content width, 3:2 aspect ratio.
-- Actual COVER_W / COVER_H computed in build() from the passed 'w' argument.
local _BASE_COVER_GAP  = Screen:scaleBySize(12)
local _BASE_TITLE_FS   = Screen:scaleBySize(13)
local _BASE_AUTHOR_FS  = Screen:scaleBySize(9)   -- matches bookshelf author (16pt)
local _BASE_DESC_FS    = Screen:scaleBySize(8)   -- smaller than author (bookshelf desc=14pt < author=16pt)
local _BASE_PROG_FS    = 14                      -- bookshelf: font_size=14 (raw, no scaleBySize); bar_height = face.size
local _BASE_TITLE_GAP  = Screen:scaleBySize(2)
local _BASE_AUTHOR_GAP = Screen:scaleBySize(4)
local _BASE_DESC_GAP   = Screen:scaleBySize(6)

-- Setting keys (prepended with pfx at runtime)
local SCALE_KEY        = "hero_currently_scale"
local SK_EXCLUDE_PATHS = "hero_currently_exclude_paths"
local SK_SHOW_STATS    = "hero_currently_show_stats"
local SK_SHOW_PROGRESS = "hero_currently_show_progress"
local SK_PREVENT_CROP  = "hero_currently_prevent_crop"
local SK_CROP_THRESHOLD = "hero_currently_crop_threshold"
local SK_DESC_SOURCE   = "hero_currently_desc_source"
local SK_DESC_FS_SCALE = "hero_currently_desc_fs_scale"

-- ---------------------------------------------------------------------------
-- Description-source setting helper: "description" (default) shows the book
-- blurb; "highlight" shows a random highlight from the book's annotations,
-- falling back to the description when the book has none.
-- ---------------------------------------------------------------------------
local function getDescFsScale(pfx)
    local S = getSettings()
    local v = S and tonumber(S:readSetting(pfx .. SK_DESC_FS_SCALE))
    return (v and v > 0) and (v / 100.0) or 1.0
end

local function getDescSource(pfx)
    local S = getSettings()
    local v = S and S:readSetting(pfx .. SK_DESC_SOURCE)
    return (v == "highlight") and "highlight" or "description"
end

-- Cache for the randomly-picked highlight, keyed by ctx table identity so the
-- pick stays stable across clock-tick refreshes (which reuse the same ctx
-- table) and only re-rolls on a full homescreen rebuild (new ctx) or when the
-- currently-reading book changes.
local _hl_pick = { ctx = nil, fp = nil, text = nil }

-- ---------------------------------------------------------------------------
-- Exclude-path helpers (mirrors module_recent_book_stats implementation)
-- ---------------------------------------------------------------------------
local function getExcludePaths(pfx)
    local S = getSettings()
    if not S then return {} end
    local raw = S:readSetting(pfx .. SK_EXCLUDE_PATHS)
    if not raw or raw == "" then return {} end
    local result = {}
    for token in raw:gmatch("[^,\n]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then result[#result + 1] = t end
    end
    return result
end

local function isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Module table
-- ---------------------------------------------------------------------------
local M = {}

-- Kept separate from M.label: applyLabelToggle() mutates M.label to nil when
-- the section label is hidden, so it can't also serve as its own default.
local _DEFAULT_LABEL = "Currently Reading"

M.id              = "hero_currently"
M.name            = "Hero Currently Reading"
M.description     = "Large hero card showing currently reading book with cover, progress, and details"
M.default_enabled = true   -- Loaded by simpleui_ext by default
M.label           = _DEFAULT_LABEL
M.enabled_key     = "hero_currently"
M.default_on      = false
M.has_covers      = true    -- activates e-ink dithering and cover poll
M.is_book_mod     = true    -- suppresses "No books opened yet" empty-state
-- Declare DB need so the homescreen opens a stats connection when we are active.
M.needs           = { db = true }

-- Called by the homescreen on hot-reload to drop cached references
function M.reset()
    _SH = nil
    _hl_pick = { ctx = nil, fp = nil, text = nil }
end

-- ---------------------------------------------------------------------------
-- _getCurrentFP(ctx, excludes) — returns the filepath to display.
--
-- ctx.current_fp is only populated by the homescreen when the built-in
-- "currently" module is also enabled.  When it is off (the common case
-- when using this module as a standalone replacement) we fall back to
-- ReadHistory — walking entries in order until one passes the exclude
-- filter, mirroring the behaviour of module_recent_book_stats.
-- ---------------------------------------------------------------------------
local function _getCurrentFP(ctx, excludes)
    excludes = excludes or {}
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

-- ---------------------------------------------------------------------------
-- build(w, ctx) → widget | nil
--
-- Layout mirrors bookshelf's hero card architecture:
--   cover (left, full COVER_H) | right column (OverlapGroup):
--       TopContainer    → right_top:    title, author, [description fills slack]
--       BottomContainer → right_bottom: "p.73 [████░░] 3h 27m left"
-- ---------------------------------------------------------------------------
function M.build(w, ctx)
    local Config   = getConfig()
    local Settings = getSettings()
    local UI       = getUI()
    local SH       = getSH()
    if not Config or not Settings or not UI or not SH then return nil end

    Config.applyLabelToggle(M, _DEFAULT_LABEL)

    local pfx      = ctx.pfx or ""
    local excludes = getExcludePaths(pfx)
    local fp       = _getCurrentFP(ctx, excludes)
    if not fp then return nil end

    local scale = Config.getModuleScale("hero_currently", pfx)
    local PAD   = UI.PAD

    local COVER_W = math.floor(w * 0.30)      -- bookshelf: hero_cover_w = content_w * 0.30
    local COVER_H = math.floor(COVER_W * 1.5)  -- bookshelf: hero_cover_h = hero_cover_w * 1.5

    local cover_gap  = math.max(0, math.floor(_BASE_COVER_GAP  * scale))
    local title_fs   = math.max(8, math.floor(_BASE_TITLE_FS   * scale))
    local author_fs  = math.max(7, math.floor(_BASE_AUTHOR_FS  * scale))
    local desc_fs    = math.max(7, math.floor(_BASE_DESC_FS    * scale * getDescFsScale(pfx)))
    local prog_fs    = math.max(7, math.floor(_BASE_PROG_FS    * scale))
    local bar_h      = prog_fs  -- bookshelf: bar_height = 100% of face.size
    local title_gap  = math.max(1, math.floor(_BASE_TITLE_GAP  * scale))
    local author_gap = math.max(1, math.floor(_BASE_AUTHOR_GAP * scale))
    local desc_gap   = math.max(1, math.floor(_BASE_DESC_GAP   * scale))

    local face_title  = Font:getFace("smallinfofont", title_fs)
    local face_author = Font:getFace("smallinfofont", author_fs)
    local face_desc   = Font:getFace("smallinfofont", desc_fs)
    local face_prog   = Font:getFace("smallinfofont", prog_fs)

    local prefetched = ctx.prefetched and ctx.prefetched[fp]
    local bd         = SH.getBookData(fp, prefetched)

    -- Cover — may be replaced by updateCovers() asynchronously
    -- Apply stretch_limit based on user settings to prevent/allow cropping.
    local stretch_limit = nil
    if Settings:readSetting(pfx .. SK_PREVENT_CROP) ~= false then
        local threshold = Settings:readSetting(pfx .. SK_CROP_THRESHOLD) or 50
        stretch_limit = threshold / 100.0
    end
    local cover = SH.getBookCover(fp, COVER_W, COVER_H, nil, stretch_limit)
                  or SH.coverPlaceholder(bd.title, bd.authors, COVER_W, COVER_H)

    -- Description-area content: either the book blurb, or (when the
    -- "Highlight" source is selected) a randomly-picked highlight from this
    -- book's annotations, falling back to the description if it has none.
    local desc_text
    if getDescSource(pfx) == "highlight" then
        if _hl_pick.ctx ~= ctx or _hl_pick.fp ~= fp then
            local hls    = getBookHighlights(fp)
            local picked = hls and hls[math.random(#hls)]
            _hl_pick.ctx  = ctx
            _hl_pick.fp   = fp
            _hl_pick.text = picked and formatHighlight(picked)
        end
        desc_text = _hl_pick.text or getBookDescription(fp)
    else
        desc_text = getBookDescription(fp)
    end

    -- Colour theme
    local CLR_TEXT = Blitbuffer.COLOR_BLACK
    local CLR_SUB  = UI.CLR_TEXT_SUB or Blitbuffer.gray(0.45)
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    if ok_ss and SUIStyle then
        CLR_TEXT = SUIStyle.getThemeColor("fg")              or CLR_TEXT
        CLR_SUB  = SUIStyle.getThemeColor("text_secondary")
                   or SUIStyle.getThemeColor("fg")           or CLR_SUB
    end

    -- Text column width
    local tw = w - PAD - COVER_W - cover_gap - PAD

    -- ── right_top: title + author (description added below after measuring) ──
    local right_top = VerticalGroup:new{ align = "left" }

    local title_args = {
        text      = bd.title or "?",
        face      = face_title,
        width     = tw,
        alignment = "left",
        max_lines = 2,
        fgcolor   = CLR_TEXT,
        bold      = true,
    }
    right_top[#right_top + 1] = (ctx.has_wallpaper and UI and UI.makeAlphaTextBox(title_args))
                                  or TextBoxWidget:new(title_args)
    if bd.authors and bd.authors ~= "" then
        right_top[#right_top + 1] = VerticalSpan:new{ width = author_gap }
        right_top[#right_top + 1] = TextWidget:new{
            text    = bd.authors,
            face    = face_author,
            fgcolor = CLR_SUB,
        }
    end

    -- ── right_bottom: progress row + optional stats, bottom-anchored ─────────
    local right_bottom = VerticalGroup:new{ align = "left" }
    -- Pin the group width to tw so BottomContainer left-aligns it regardless
    -- of whether the progress bar (which naturally fills tw) is visible or not.
    right_bottom[1] = HorizontalSpan:new{ width = tw }
    local pct = bd.percent or 0

    -- Get book MD5 for Stats DB query (used by both progress and stats rows)
    local book_md5 = prefetched and prefetched.partial_md5_checksum
    if not book_md5 and ctx.db_conn then
        local ok_ds, DS = pcall(require, "docsettings")
        if ok_ds and DS then
            local ok2, ds = pcall(DS.open, DS, fp)
            if ok2 and ds then
                book_md5 = ds:readSetting("partial_md5_checksum")
                pcall(function() ds:close() end)
            end
        end
    end

    -- Progress row: default on; hidden when the setting is explicitly false.
    if Settings:readSetting(pfx .. SK_SHOW_PROGRESS) ~= false then
        -- avg_time: prefer Stats DB (capped per-page) over DocSettings totals
        local avg_time = nil
        if book_md5 and ctx.db_conn then
            avg_time = fetchAvgTimeFromDB(book_md5, ctx.db_conn)
        end
        if not avg_time or avg_time <= 0 then avg_time = bd.avg_time end

        local prog_left, prog_right
        if bd.pages and bd.pages > 0 then
            local cur  = math.floor(pct * bd.pages)
            prog_left  = string.format("%d / %d", cur, bd.pages)  -- no "p." prefix (matches bookshelf)
            local tl   = SH.formatTimeLeft(pct, bd.pages, avg_time)
            if tl then prog_right = tl .. " left" end
        else
            prog_left = string.format("%.0f%%", pct * 100)
        end

        -- Bold TextWidgets (bookshelf progress region: bold = true)
        local lw    = TextWidget:new{ text = prog_left,  face = face_prog, fgcolor = CLR_SUB, bold = true }
        local rw    = prog_right and TextWidget:new{ text = prog_right, face = face_prog, fgcolor = CLR_SUB, bold = true }
        local lw_w  = lw:getSize().w
        local rw_w  = rw and rw:getSize().w or 0
        -- Bookshelf uses two literal spaces as gap (Size.padding.small * 2 ≈ that)
        local pad_s = Size.padding.small * 2
        local bar_w = math.max(1, tw - lw_w - rw_w
                                  - (lw_w > 0 and pad_s or 0)
                                  - (rw_w > 0 and pad_s or 0))

        local inline_bar = ProgressWidget:new{
            width      = bar_w,
            height     = bar_h,
            percentage = math.min(pct, 1.0),
            style      = "bordered",  -- matches bookshelf bar_style = "bordered"
            ticks      = nil,
            last       = nil,
        }
        local prog_row = HorizontalGroup:new{ align = "center" }
        prog_row[#prog_row + 1] = lw
        prog_row[#prog_row + 1] = HorizontalSpan:new{ width = pad_s }
        prog_row[#prog_row + 1] = inline_bar
        if rw then
            prog_row[#prog_row + 1] = HorizontalSpan:new{ width = pad_s }
            prog_row[#prog_row + 1] = rw
        end
        right_bottom[#right_bottom + 1] = prog_row
    end

    -- ── Optional statistics row (below progress bar) ──────────────────────────
    -- Shown only when "Show Statistics" is enabled in the module settings.
    -- Displays days read and total time read in a compact single row.
    -- Must be built before the description block so right_bottom:getSize().h
    -- reflects the stats row when computing available space for the description.
    if Settings:isTrue(pfx .. SK_SHOW_STATS) and book_md5 and ctx.db_conn then
        local bstats = fetchStatsFromDB(book_md5, ctx.db_conn)
        if bstats then
            local parts = {}
            if bstats.days and bstats.days > 0 then
                parts[#parts+1] = string.format(
                    bstats.days == 1 and "%d day" or "%d days", bstats.days)
            end
            if bstats.total_secs and bstats.total_secs > 0 then
                parts[#parts+1] = fmtTime(bstats.total_secs) .. " read"
            end
            if #parts > 0 then
                local stats_row = HorizontalGroup:new{ align = "center" }
                for i, part in ipairs(parts) do
                    if i > 1 then
                        stats_row[#stats_row+1] = TextWidget:new{
                            text    = " · ",
                            face    = face_prog,
                            fgcolor = CLR_SUB,
                        }
                    end
                    stats_row[#stats_row+1] = TextWidget:new{
                        text    = part,
                        face    = face_prog,
                        fgcolor = CLR_SUB,
                    }
                end
                right_bottom[#right_bottom+1] = VerticalSpan:new{
                    width = math.max(1, math.floor(Screen:scaleBySize(3) * scale))
                }
                right_bottom[#right_bottom+1] = stats_row
            end
        end
    end

    -- ── Description: fills the slack between right_top and right_bottom ──────
    -- Matches bookshelf's dynamic layout: measure top_used + bottom_h at
    -- runtime, give description every remaining pixel, split on \n\n paragraphs.
    if desc_text then
        right_top[#right_top + 1] = VerticalSpan:new{ width = desc_gap }
        local top_used = 0
        for i = 1, #right_top do
            local g = right_top[i]:getSize()
            top_used = top_used + (g and g.h or 0)
        end
        local bottom_h  = right_bottom:getSize().h
        local breath    = Size.padding.default
        local available = COVER_H - top_used - bottom_h - breath

        if available > face_desc.size then
            -- Normalise line-endings; collapse blank/whitespace-only lines to \n\n
            desc_text = desc_text:gsub("\r\n", "\n"):gsub("\n%s*\n", "\n\n")
            desc_text = desc_text:match("^%s*(.-)%s*$") or desc_text

            local para_gap   = math.floor(face_desc.size * 0.4)
            local paragraphs = {}
            for para in (desc_text .. "\n\n"):gmatch("(.-)\n\n") do
                if para ~= "" then paragraphs[#paragraphs + 1] = para end
            end
            if #paragraphs == 0 then paragraphs[1] = desc_text end

            local desc_group = VerticalGroup:new{ align = "left" }
            local total_h    = 0
            for i, ptext in ipairs(paragraphs) do
                local gap = (i > 1) and para_gap or 0
                if total_h + gap >= available then break end
                local rem = available - total_h - gap
                if rem < face_desc.size then break end
                if gap > 0 then
                    desc_group[#desc_group + 1] = VerticalSpan:new{ width = gap }
                    total_h = total_h + gap
                end
                local desc_args = {
                    text        = ptext,
                    face        = face_desc,
                    width       = tw,
                    height      = rem,
                    alignment   = "left",
                    height_overflow_show_ellipsis = true,
                    height_adjust                 = true,
                    line_height = 0.3,
                    fgcolor     = CLR_SUB,
                }
                local pwid = (ctx.has_wallpaper and UI and UI.makeAlphaTextBox(desc_args))
                              or TextBoxWidget:new(desc_args)
                desc_group[#desc_group + 1] = pwid
                total_h = total_h + pwid:getSize().h
            end
            if #desc_group > 0 then
                -- Tappable wrapper: tapping the description opens the full
                -- text in a scrollable viewer, mirroring bookshelf's
                -- on_description_tap / DescTap pattern. Consuming the tap
                -- here prevents the cover's open-book zone from firing.
                local DescTap = InputContainer:extend{}
                local _full_desc  = desc_text
                local _book_title  = bd.title or ""
                local _book_author = bd.authors
                function DescTap:onTap()
                    local TextViewer = require("ui/widget/textviewer")
                    local UIManager  = require("ui/uimanager")
                    local title = _book_title
                    if _book_author and _book_author ~= "" then
                        title = title .. " \xE2\x80\x94 " .. _book_author
                    end
                    local viewer = TextViewer:new{
                        title = title,
                        text  = _full_desc,
                    }
                    UIManager:show(viewer)
                    return true
                end
                local desc_size = desc_group:getSize()
                local dtap_h    = desc_size and desc_size.h or 0
                if dtap_h > 0 then
                    local dtap = DescTap:new{
                        dimen = Geom:new{ w = tw, h = dtap_h },
                        desc_group,
                    }
                    dtap.ges_events = {
                        Tap = { GestureRange:new{ ges = "tap", range = dtap.dimen } },
                    }
                    right_top[#right_top + 1] = dtap
                else
                    right_top[#right_top + 1] = desc_group
                end
            end
        end
    end

    -- ── Assemble right column ─────────────────────────────────────────────────
    -- OverlapGroup: right_top pinned to top, right_bottom pinned to bottom.
    -- The right column is always exactly COVER_H tall — no "max(cover, text)"
    -- needed because description fills every available pixel of the slack.
    local rd = Geom:new{ w = tw, h = COVER_H }
    local right_col = OverlapGroup:new{
        dimen = rd,
        TopContainer:new{    dimen = rd, right_top    },
        BottomContainer:new{ dimen = rd, right_bottom },
    }

    -- ── Frame / background ────────────────────────────────────────────────────
    local show_frame = Settings:isTrue(pfx .. "hero_currently_show_frame")
    local solid_bg   = Settings:isTrue(pfx .. "hero_currently_solid_bg")
    local has_box    = show_frame or solid_bg
    local border_sz  = show_frame and Size.border.thin or 0
    local radius     = has_box and math.floor(Screen:scaleBySize(12) * scale) or 0
    local border_clr = Blitbuffer.gray(0.72)
    local bg_color   = false  -- transparent by default; wallpaper shows through
    if ok_ss and SUIStyle then
        border_clr = SUIStyle.getThemeColor("separator") or border_clr
    end
    if solid_bg then
        bg_color = (ok_ss and SUIStyle and SUIStyle.getThemeColor("bg"))
                   or Blitbuffer.COLOR_WHITE
    end

    -- cover_tap wraps the cover image with a Tap zone that opens the book.
    -- Only the cover opens the book; the description has its own tap zone.
    -- cover_tap holds the actual cover image at [1] so updateCovers() can
    -- swap it without touching the surrounding layout.
    local CoverTap = InputContainer:extend{}
    local _open_fn_ref = ctx.open_fn
    local _fp_ref      = fp
    function CoverTap:onTap()
        if _open_fn_ref then _open_fn_ref(_fp_ref) end
        return true
    end
    local cover_tap = CoverTap:new{
        dimen = Geom:new{ w = COVER_W, h = COVER_H },
        cover,
    }
    cover_tap.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = cover_tap.dimen } },
    }
    local cover_frame = HorizontalGroup:new{
        align = "top",
        cover_tap,
        HorizontalSpan:new{ width = cover_gap },
    }

    local row = HorizontalGroup:new{
        align = "top",
        cover_frame,
        right_col,
    }

    local content_h = COVER_H  -- right column is always exactly COVER_H
    local full_h    = content_h + (has_box and PAD * 2 or 0)

    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = w, h = full_h },
        _fp      = fp,
        _open_fn = ctx.open_fn,
        [1] = FrameContainer:new{
            bordersize     = border_sz,
            radius         = radius,
            color          = border_clr,
            background     = bg_color,
            padding        = 0,
            padding_left   = PAD,
            padding_right  = PAD,
            padding_top    = has_box and PAD or 0,
            padding_bottom = has_box and PAD or 0,
            row,
        },
    }
    -- No whole-card tap gesture: only the cover (cover_tap) opens the book
    -- and the description (DescTap) opens the viewer. All other taps fall
    -- through; this matches bookshelf's HeroCard interaction model.
    tappable._cover_slots = {
        { container = cover_tap, idx = 1,
          fp = fp, w = COVER_W, h = COVER_H,
          align = nil, stretch = stretch_limit },
    }

    -- Keyboard focus: border overlay
    if ctx.kb_currently_focused then
        local bw = Screen:scaleBySize(3)
        return OverlapGroup:new{
            dimen = Geom:new{ w = w, h = full_h },
            tappable,
            LineWidget:new{ dimen = Geom:new{ w = w,  h = bw }, background = CLR_TEXT },
            LineWidget:new{ dimen = Geom:new{ w = w,  h = bw }, background = CLR_TEXT, overlap_offset = { 0, full_h - bw } },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = full_h }, background = CLR_TEXT },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = full_h }, background = CLR_TEXT, overlap_offset = { w - bw, 0 } },
        }
    end

    return tappable
end

-- ---------------------------------------------------------------------------
-- updateCovers(widget, ctx) — swap cover images asynchronously
-- ---------------------------------------------------------------------------
function M.updateCovers(widget, _ctx)
    -- Widget may be wrapped in an OverlapGroup (kb focus)
    local tappable = widget._cover_slots and widget
                     or (widget[1] and widget[1]._cover_slots and widget[1])
    if not tappable or not tappable._cover_slots then return true end

    local SH     = getSH()
    local Config = getConfig()
    if not SH then return true end

    local all_done = true
    for _, slot in ipairs(tappable._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif Config and not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

-- ---------------------------------------------------------------------------
-- getHeight(ctx) → number  (includes section-label height)
-- ---------------------------------------------------------------------------
function M.getHeight(ctx)
    local Config   = getConfig()
    local Settings = getSettings()
    local UI       = getUI()
    if not Config or not UI then
        return Screen:scaleBySize(160)
    end

    local pfx   = ctx and ctx.pfx or ""
    local scale = Config.getModuleScale("hero_currently", pfx)
    local PAD   = UI.PAD

    -- Right column height = cover height = 30% of content width × 1.5
    local approx_content_w = Screen:getWidth() - PAD * 2
    local content_h = math.floor(approx_content_w * 0.30 * 1.5)

    local show_frame = Settings and Settings:isTrue(pfx .. "hero_currently_show_frame")
    local solid_bg   = Settings and Settings:isTrue(pfx .. "hero_currently_solid_bg")
    if show_frame or solid_bg then
        content_h = content_h + PAD * 2
    end

    return Config.getScaledLabelH() + content_h
end

-- ---------------------------------------------------------------------------
-- getMenuItems(ctx_menu) → table  (settings entries for the Arrange screen)
-- ---------------------------------------------------------------------------
function M.getMenuItems(ctx_menu)
    local Config = getConfig()
    if not Config then return nil end

    local pfx      = ctx_menu.pfx
    local refresh  = ctx_menu.refresh
    local _lc      = ctx_menu._ or function(x) return x end
    local Settings = getSettings()

    local function toggle_item(label, key)
        return {
            text_func      = function() return _lc(label) end,
            checked_func   = function()
                return Settings and Settings:isTrue(pfx .. key)
            end,
            keep_menu_open = true,
            callback       = function()
                if Settings then
                    Settings:saveSetting(pfx .. key,
                        not (Settings:isTrue(pfx .. key)))
                end
                refresh()
            end,
        }
    end

    -- Default-on toggle: nil (unset) is treated as true.
    local function toggle_item_on(label, key)
        return {
            text_func      = function() return _lc(label) end,
            checked_func   = function()
                return not Settings or Settings:readSetting(pfx .. key) ~= false
            end,
            keep_menu_open = true,
            callback       = function()
                if Settings then
                    local currently_on = Settings:readSetting(pfx .. key) ~= false
                    Settings:saveSetting(pfx .. key, not currently_on)
                end
                refresh()
            end,
        }
    end

    return {
        Config.makeLabelToggleItem(M.id, M.name, refresh, _lc),
        Config.makeScaleItem({
            text_func    = function()
                local pct = Config.getModuleScalePct("hero_currently", pfx)
                return pct == 100
                    and _lc("Scale")
                    or  string.format("%s (%d%%)", _lc("Scale"), pct)
            end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct("hero_currently", pfx) end,
            set          = function(v) Config.setModuleScale(v, "hero_currently", pfx) end,
            refresh      = refresh,
        }),
        {
            text_func  = function() return _lc("Description Content") end,
            value_func = function()
                return (getDescSource(pfx) == "highlight")
                    and _lc("Highlight") or _lc("Description")
            end,
            sub_item_table = {
                {
                    text           = _lc("Description"),
                    radio          = true,
                    checked_func   = function() return getDescSource(pfx) == "description" end,
                    keep_menu_open = true,
                    callback       = function()
                        if Settings then
                            Settings:saveSetting(pfx .. SK_DESC_SOURCE, "description")
                        end
                        refresh()
                    end,
                },
                {
                    text           = _lc("Highlight (random, falls back to description)"),
                    radio          = true,
                    checked_func   = function() return getDescSource(pfx) == "highlight" end,
                    keep_menu_open = true,
                    callback       = function()
                        if Settings then
                            Settings:saveSetting(pfx .. SK_DESC_SOURCE, "highlight")
                        end
                        refresh()
                    end,
                },
            },
        },
        {
            text_func = function()
                local S = getSettings()
                local v = S and S:readSetting(pfx .. SK_DESC_FS_SCALE)
                v = v and tonumber(v) or 100
                return v == 100
                    and _lc("Description Text Size")
                    or  string.format("%s (%d%%)", _lc("Description Text Size"), v)
            end,
            keep_menu_open = true,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager  = require("ui/uimanager")
                local S = getSettings()
                local current = (S and tonumber(S:readSetting(pfx .. SK_DESC_FS_SCALE))) or 100
                local spin
                spin = SpinWidget:new{
                    title_text      = _lc("Description Text Size"),
                    info_text       = _lc("Scales the description font size relative to default.\nLarger text shows fewer lines; smaller shows more."),
                    value           = current,
                    value_min       = 50,
                    value_max       = 300,
                    value_step      = 5,
                    value_hold_step = 25,
                    unit            = "%",
                    ok_text         = _lc("Set"),
                    callback        = function(spin_widget)
                        if S then
                            S:saveSetting(pfx .. SK_DESC_FS_SCALE, spin_widget.value)
                        end
                        UIManager:close(spin)
                        refresh()
                    end,
                }
                UIManager:show(spin)
            end,
        },
        toggle_item("Show Frame",        "hero_currently_show_frame"),
        toggle_item("Solid Background",  "hero_currently_solid_bg"),
        toggle_item_on("Show Progress Bar", SK_SHOW_PROGRESS),
        toggle_item("Show Statistics",   SK_SHOW_STATS),
        toggle_item_on("Prevent Cover Cropping", SK_PREVENT_CROP),
        {
            text_func = function()
                if Settings:readSetting(pfx .. SK_PREVENT_CROP) == false then
                    return _lc("Crop Threshold (disabled)")
                end
                local threshold = Settings:readSetting(pfx .. SK_CROP_THRESHOLD) or 50
                return string.format("%s (%d%%)", _lc("Crop Threshold"), threshold)
            end,
            enabled_func = function()
                return Settings:readSetting(pfx .. SK_PREVENT_CROP) ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager  = require("ui/uimanager")
                local threshold = Settings:readSetting(pfx .. SK_CROP_THRESHOLD) or 50
                local spin
                spin = SpinWidget:new{
                    title_text = _lc("Crop Threshold"),
                    info_text  = _lc("Maximum aspect ratio distortion to prevent cropping.\n0% = always crop, 100% = never crop (allow stretching)"),
                    value      = threshold,
                    value_min  = 0,
                    value_max  = 100,
                    value_step = 5,
                    value_hold_step = 10,
                    unit       = "%",
                    ok_text    = _lc("Set"),
                    callback   = function(spin_widget)
                        if Settings then
                            Settings:saveSetting(pfx .. SK_CROP_THRESHOLD, spin_widget.value)
                        end
                        UIManager:close(spin)
                        refresh()
                    end,
                }
                UIManager:show(spin)
            end,
        },

        -- Exclude paths from recent
        {
            text_func = function()
                local raw = Settings and Settings:readSetting(pfx .. SK_EXCLUDE_PATHS)
                if not raw or raw == "" then
                    return _lc("Exclude Paths from Recent")
                end
                local n = 0
                for _ in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _lc("Exclude Paths from Recent"), n)
            end,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local UIManager   = require("ui/uimanager")
                local raw = (Settings and Settings:readSetting(pfx .. SK_EXCLUDE_PATHS)) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _lc("Exclude Paths from Recent"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss,instapaper,cache",
                    description = _lc("Comma-separated path fragments.\nBooks whose path contains any fragment will be skipped."),
                    allow_newline    = false,
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
                                if Settings then
                                    Settings:saveSetting(pfx .. SK_EXCLUDE_PATHS, val)
                                end
                                UIManager:close(dlg)
                                refresh()
                            end,
                        },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        },
    }
end

return M
