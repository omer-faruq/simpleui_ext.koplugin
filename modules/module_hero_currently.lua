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
local StablePages      = require("utils/sui_ext_pages")
local Text             = require("utils/sui_ext_text")
local _                = require("sui_ext_i18n").translate

-- ---------------------------------------------------------------------------
-- Lazy-loaded SimpleUI helpers (not available until SimpleUI is loaded)
-- ---------------------------------------------------------------------------
local _SH, _Config, _SUISettings, _UI

local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m else
            logger.dbg("simpleui_ext: hero_currently: cannot load module_books_shared")
        end
    end
    return _SH
end

-- ---------------------------------------------------------------------------
-- fetchCover(SH, fp, w, h, stretch_limit)
--
-- SimpleUI <=2.4 had ONE cover getter with a hybrid policy:
--   SH.getBookCover(fp, w, h, align, stretch_limit)
--     -> stretch when the aspect distortion is within stretch_limit,
--        crop-to-fill otherwise.
--
-- SimpleUI 2.5 split that in two and dropped the hybrid:
--   SH.getBookCover(fp, w, h)                 -> always stretch
--   SH.getCroppedBookCover(fp, w, h, align)   -> always crop-to-fill
-- The old call still "works" there, but silently ignores the extra args —
-- which is why "Prevent Cover Cropping" stopped doing anything after the
-- 2.5 upgrade.
--
-- On 2.5 we map the toggle onto the two endpoints it used to be able to
-- reach (threshold 100% and 0%):
--   Prevent Cover Cropping ON  -> stretch, never crops
--   Prevent Cover Cropping OFF -> crop-to-fill
-- The threshold slider only has a middle ground to express on <=2.4, which
-- still gets the original 5-arg hybrid call.
-- ---------------------------------------------------------------------------
local function fetchCover(SH, fp, w, h, stretch_limit)
    if type(SH.getCroppedBookCover) == "function" then     -- SimpleUI 2.5+
        if stretch_limit then return SH.getBookCover(fp, w, h) end
        return SH.getCroppedBookCover(fp, w, h, nil)
    end
    return SH.getBookCover(fp, w, h, nil, stretch_limit)   -- SimpleUI <=2.4
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

-- Theme colours go through the compat layer, never sui_style directly:
-- SimpleUI 2.6 removed getThemeColor(). See M.themeColor in utils/sui_compat.
local _SUICompat
local function getSUICompat()
    if not _SUICompat then
        local ok, m = pcall(require, "utils/sui_compat")
        if ok and m then _SUICompat = m end
    end
    return _SUICompat
end

local function themeColor(role)
    local Compat = getSUICompat()
    if not (Compat and Compat.themeColor) then return nil end
    return Compat.themeColor(role)
end

-- SimpleUI 3.0 dropped makeLabelToggleItem's default_label argument: it is
-- (mod_id, refresh, _lc) there, (mod_id, default_label, refresh, _lc) before.
-- applyLabelToggle went away in the same change, so it tells the two apart.
local function makeLabelToggleItem(Config, mod_id, label, refresh, _lc)
    if type(Config.applyLabelToggle) == "function" then
        return Config.makeLabelToggleItem(mod_id, label, refresh, _lc)
    end
    return Config.makeLabelToggleItem(mod_id, refresh, _lc)
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
-- Format a (possibly multi-author) string for a single-line label or title.
-- Responsive to available width: greedily fits as many authors as possible,
-- falling back to "first author et al."
--
-- Strategy:
--   1. Split on newlines only — see below.
--   2. Cap the author count at MAX_AUTHORS (5). Anything beyond is dropped;
--      this bounds the worst-case FFI call count below and avoids spending
--      any cycles on author #6+ for anthology / collection volumes where the
--      marginal names carry diminishing information.
--   3. If only one author remains, return it verbatim (no et al.).
--   4. Try "A, B, C, ..." (all of them); if it fits, return it.
--   5. Otherwise try "A, B, ..., k et al." for k = #parts, #parts-1, ..., 3.
--   6. Fallback: "first author et al." (best-effort; never empty).
-- ---------------------------------------------------------------------------
local MAX_AUTHORS = 5

local function formatAuthors(authors_str, available_width, face)
    if not authors_str or authors_str == "" then return nil end

    -- KOReader separates multiple authors with newlines, never commas:
    -- filemanagerbookinfo sets allow_newline for the "authors" prop, and core
    -- itself does authors:gsub("\n.*", " et al.") in bookmarkbrowser and
    -- bookmetadataarchive.  SimpleUI's own coverPlaceholder splits on "\n" too.
    -- Splitting on commas would break "Tolkien, J. R. R." — a single author in
    -- "Last, First" form, as OPF dc:creator and PDF metadata commonly store it —
    -- into two names and render it as "Tolkien et al.".
    local parts = {}
    for piece in (authors_str .. "\n"):gmatch("(.-)\r?\n") do
        local trimmed = piece:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            parts[#parts + 1] = trimmed
        end
    end

    if #parts > MAX_AUTHORS then
        local trimmed = {}
        for i = 1, MAX_AUTHORS do trimmed[i] = parts[i] end
        parts = trimmed
    end
    if #parts == 0 then return nil end
    if #parts == 1 then return parts[1] end

    local RenderText = require("ui/rendertext")
    local function fits(s)
        return RenderText:sizeUtf8Text(0, available_width, face, s, true).x
            <= available_width
    end

    local all_str = table.concat(parts, ", ")
    if fits(all_str) then return all_str end
    for k = #parts, 3, -1 do
        local candidate = table.concat(parts, ", ", 1, k - 1) .. _(" et al.")
        if fits(candidate) then return candidate end
    end
    -- k == 2 would produce exactly this, so it doubles as the last resort.
    return parts[1] .. _(" et al.")
end

-- ---------------------------------------------------------------------------
-- Time formatter: seconds → "Xh Ym" / "Xh" / "Ym"
-- ---------------------------------------------------------------------------
local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return _("0m") end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format(_("%dh %dm"), h, m)
    elseif h > 0        then return string.format(_("%dh"), h)
    else                     return string.format(_("%dm"), m) end
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
    for _i, a in ipairs(annotations) do
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

local _LEADING_QUOTES  = '^["\'\xE2\x80\x9C\xE2\x80\x98\xE2\x80\x9E\xE2\x80\x9A\xC2\xAB\xE2\x80\xB9%s]+'
local _TRAILING_QUOTES = '["\'\xE2\x80\x9D\xE2\x80\x99\xE2\x80\x9E\xE2\x80\x9A\xC2\xBB\xE2\x80\xBA%s]+$'

local function formatHighlight(h)
    local text = h.text:gsub(_LEADING_QUOTES, ''):gsub(_TRAILING_QUOTES, '')
    text = text:gsub('^[\xE2\x80\x94\xE2\x80\x93]%s*', '')
    local quoted = "\xE2\x80\x9C" .. text .. "\xE2\x80\x9D"

    local meta = {}
    if h.chapter then meta[#meta + 1] = h.chapter end
    local pn = h.pageref or h.pageno
    if pn then meta[#meta + 1] = "p. " .. tostring(pn) end

    if #meta > 0 then
        return quoted .. "\n\n\xE2\x80\x94 " .. table.concat(meta, " \xC2\xB7 ")
    end
    return quoted
end

-- ---------------------------------------------------------------------------
-- Stats DB
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

-- Module-level upvalue, NOT M._prewarm_cache: fetchStatsFromDB is defined
-- above `local M = {}`, so it must read the cache via lexical scope. A
-- later `local M = {}` is a different binding from the global _ENV.M the
-- closure was already bound to — see git history for the runtime crash
-- this comment exists to prevent re-introducing.
local _PREWARM_TTL = 3600   -- seconds; entries older than this are re-queried
local _prewarm_cache = {}   -- [md5] = { days, total_secs, avg_secs_per_page, fetched_at }

-- Single source of truth for the stats-DB roundtrip, shared by
-- fetchStatsFromDB, M.refreshStats and M.prewarm (previously copy-pasted
-- in all three, which meant a future fix to this query had to be applied
-- three times or risk cache/DB drift).
-- Returns (result, query_ok):
--   query_ok=false means the pcall itself threw (e.g. DB busy) — callers
--   must NOT treat this as "no data" and must leave any existing cache
--   entry untouched rather than wiping known-good stats on a transient error.
--   query_ok=true, result=nil/avg_time=nil means the query ran fine and the
--   book genuinely has no (capped) page_stat data.
local function queryBookStats(md5, db_conn, max_sec)
    local result = nil
    local query_ok = pcall(function()
        local row = db_conn:exec(string.format([[
            WITH b AS (SELECT id FROM book WHERE md5 = '%s' LIMIT 1),
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
        ]], md5:gsub("'", "''"), max_sec))
        if row and row[1] and row[1][1] then
            local days   = tonumber(row[1][1]) or 0
            local secs   = tonumber(row[2] and row[2][1]) or 0
            local pages  = tonumber(row[3] and row[3][1]) or 0
            local capped = tonumber(row[4] and row[4][1]) or 0
            local avg    = (pages > 0 and capped > 0) and (capped / pages) or nil
            result = {
                days       = days,
                total_secs = secs,
                avg_time   = avg,
            }
        end
    end)
    return result, query_ok
end

-- Returns { days, total_secs, avg_time } for the given md5.
-- avg_time is the capped per-page average in seconds (nil when the book
-- has no page_stat rows). Single roundtrip; consults _prewarm_cache first.
local function fetchStatsFromDB(md5, db_conn)
    if not md5 then return nil end

    local entry = _prewarm_cache[md5]
    local now   = os.time()
    if entry and (now - (entry.fetched_at or 0)) < _PREWARM_TTL then
        return {
            days       = entry.days,
            total_secs = entry.total_secs,
            avg_time   = entry.avg_secs_per_page,
        }
    end

    -- Stale fallback: homescreen's deferred first paint runs under
    -- _defer_stats=true (db_conn=nil). Without this, the stats row would
    -- flash-and-vanish on first render. The async refresh 50ms later
    -- replaces it with fresh data.
    if not db_conn then
        if entry then
            return {
                days       = entry.days,
                total_secs = entry.total_secs,
                avg_time   = entry.avg_secs_per_page,
            }
        end
        return nil
    end

    local max_sec = getMaxTimePage()
    local result = queryBookStats(md5, db_conn, max_sec)
    -- Backfill the cache so subsequent builds within TTL skip the DB.
    if result and result.avg_time then
        _prewarm_cache[md5] = {
            days              = result.days,
            total_secs        = result.total_secs,
            avg_secs_per_page = result.avg_time,
            fetched_at        = now,
        }
    end
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
local SK_COVER_SCALE   = "hero_currently_cover_scale"

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

local function getCoverScale(pfx)
    local S = getSettings()
    local v = S and tonumber(S:readSetting(pfx .. SK_COVER_SCALE))
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
    for _i, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Module table
-- ---------------------------------------------------------------------------
local M = {}

-- Kept separate from M.label: applyLabelToggle() (SimpleUI <= 2.6) mutates
-- M.label to nil when the section label is hidden, so it can't also serve as
-- its own default.
local _DEFAULT_LABEL = _("Currently Reading")

M.id              = "hero_currently"
M.name            = _("Hero Currently Reading")
M.description     = _("Large hero card showing currently reading book with cover, progress, and details")
M.default_enabled = true   -- Loaded by simpleui_ext by default
M.label           = _DEFAULT_LABEL
M.enabled_key     = "hero_currently"
M.default_on      = false
M.has_covers      = true    -- activates e-ink dithering and cover poll
M.is_book_mod     = true    -- suppresses "No books opened yet" empty-state
-- Declare DB need so the homescreen opens a stats connection when we are active.
M.needs           = { db = true, books = true }

-- Text elements with a user-selectable font, style and size (SimpleUI 3.0+).
local TEXT_ELEMS = { "title", "author", "description", "progress", "stats" }
M.text_elems     = TEXT_ELEMS
Text.declare(M.id, { title = "bold", progress = "bold" })

local function legacyFace(fs) return Font:getFace("smallinfofont", fs) end

-- Called by the homescreen on hot-reload to drop cached references
function M.reset()
    _SH = nil
    _hl_pick = { ctx = nil, fp = nil, text = nil }
    _prewarm_cache = {}
end

-- Called by simpleui_ext/main.lua when the user closes a book. Without an
-- argument the entire prewarm cache is dropped (next build re-queries the
-- currently-displayed book from SQLite, harmless for other entries). Pass a
-- specific md5 to drop just that one entry.
function M.invalidateCache(md5)
    if md5 then
        _prewarm_cache[md5] = nil
    else
        _prewarm_cache = {}
    end
end

-- Forwarded from simpleui_ext/main.lua when the homescreen becomes visible
-- after a book close. Invalidates cache entries for books_state's current +
-- recent fps, then re-queries so the next M.build() hits the cache.
-- When books_state is nil, SH.prefetchBooks() is consulted to resolve it.
-- db_conn=nil is a no-op — the stale fallback in fetchStatsFromDB keeps
-- serving previous values until the homescreen opens its own connection.
function M.refreshStats(books_state, db_conn)
    if not db_conn then return end

    local md5s = {}
    pcall(function()
        if not books_state then
            local ok_sh, SH = pcall(require, "desktop_modules/module_books_shared")
            if not ok_sh or not SH or type(SH.prefetchBooks) ~= "function" then return end
            books_state = SH.prefetchBooks(true, true, 5)
        end
        if not books_state then return end

        local ok_ds, DS = pcall(require, "docsettings")
        local fps = {}
        if books_state.current_fp then fps[#fps + 1] = books_state.current_fp end
        if books_state.recent_fps then
            for _, fp in ipairs(books_state.recent_fps) do
                if fp then fps[#fps + 1] = fp end
            end
        end
        for _, fp in ipairs(fps) do
            if fp then
                local pe  = books_state.prefetched_data and books_state.prefetched_data[fp]
                local md5 = pe and pe.partial_md5_checksum
                if not md5 and ok_ds and DS then
                    local ok2, ds = pcall(DS.open, DS, fp)
                    if ok2 and ds then
                        md5 = ds:readSetting("partial_md5_checksum")
                        pcall(function() ds:close() end)
                    end
                end
                if md5 then md5s[#md5s + 1] = md5 end
            end
        end
    end)

    if #md5s == 0 then return end

    local max_sec = getMaxTimePage()
    local now     = os.time()
    for _, md5 in ipairs(md5s) do
        local result, query_ok = queryBookStats(md5, db_conn, max_sec)
        -- Only touch the cache once we know the query actually ran: a
        -- transient failure (e.g. DB busy) must leave any existing entry
        -- alone rather than wiping known-good stats out from under a
        -- render that's relying on the stale-fallback path.
        if query_ok then
            if result and result.avg_time then
                _prewarm_cache[md5] = {
                    days              = result.days,
                    total_secs        = result.total_secs,
                    avg_secs_per_page = result.avg_time,
                    fetched_at        = now,
                }
            else
                _prewarm_cache[md5] = nil
            end
        end
    end
end

-- Populated at KOReader startup by SimpleUIExtPlugin:_prewarmBookModuleCaches.
-- Walks current + recent books, resolves each md5 (prefetched first,
-- DocSettings sidecar fallback), runs a single SQLite roundtrip per md5,
-- and stores the result in _prewarm_cache. pcall-wrapped per book so a
-- single broken sidecar does not abort the whole pass.
function M.prewarm(books_state, db_conn)
    if not books_state or not db_conn then return end

    local fps = {}
    if books_state.current_fp then fps[#fps + 1] = books_state.current_fp end
    if books_state.recent_fps then
        for _, fp in ipairs(books_state.recent_fps) do
            if fp then fps[#fps + 1] = fp end
        end
    end

    local ok_ds, DS = pcall(require, "docsettings")
    local max_sec    = getMaxTimePage()
    local now        = os.time()

    for _, fp in ipairs(fps) do
        if fp then
            pcall(function()
                local pe  = books_state.prefetched_data and books_state.prefetched_data[fp]
                local md5 = pe and pe.partial_md5_checksum
                if not md5 and ok_ds and DS then
                    local ok2, ds = pcall(DS.open, DS, fp)
                    if ok2 and ds then
                        md5 = ds:readSetting("partial_md5_checksum")
                        pcall(function() ds:close() end)
                    end
                end
                if md5 and not _prewarm_cache[md5] then
                    local result, query_ok = queryBookStats(md5, db_conn, max_sec)
                    if query_ok and result and result.avg_time then
                        _prewarm_cache[md5] = {
                            days              = result.days,
                            total_secs        = result.total_secs,
                            avg_secs_per_page = result.avg_time,
                            fetched_at        = now,
                        }
                    end
                end
            end)
        end
    end
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
    for _i, e in ipairs(RH.hist) do
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

    local Compat = getSUICompat()
    if Compat and Compat.applyLabel then
        Compat.applyLabel(M, _DEFAULT_LABEL)
    else
        M.label = _DEFAULT_LABEL
    end

    local pfx      = ctx.pfx or ""
    local excludes = getExcludePaths(pfx)
    local fp       = _getCurrentFP(ctx, excludes)
    if not fp then return nil end

    local scale = Config.getModuleScale("hero_currently", pfx)
    local PAD   = UI.PAD

    local COVER_W = math.floor(w * 0.30 * getCoverScale(pfx))  -- bookshelf: hero_cover_w = content_w * 0.30, scaled by user setting
    local COVER_H = math.floor(COVER_W * 1.5)  -- bookshelf: hero_cover_h = hero_cover_w * 1.5

    local cover_gap  = math.max(0, math.floor(_BASE_COVER_GAP  * scale))
    local styles     = Text.styles(ctx, M.id, TEXT_ELEMS)
    local function ts(elem) return Text.scale(styles, elem) end
    local title_fs   = math.max(8, math.floor(_BASE_TITLE_FS   * scale * ts("title")))
    local author_fs  = math.max(7, math.floor(_BASE_AUTHOR_FS  * scale * ts("author")))
    local desc_fs    = math.max(7, math.floor(_BASE_DESC_FS    * scale * getDescFsScale(pfx) * ts("description")))
    local prog_fs    = math.max(7, math.floor(_BASE_PROG_FS    * scale * ts("progress")))
    local stats_fs   = math.max(7, math.floor(_BASE_PROG_FS    * scale * ts("stats")))
    local bar_h      = prog_fs  -- bookshelf: bar_height = 100% of face.size
    local title_gap  = math.max(1, math.floor(_BASE_TITLE_GAP  * scale))
    local author_gap = math.max(1, math.floor(_BASE_AUTHOR_GAP * scale))
    local desc_gap   = math.max(1, math.floor(_BASE_DESC_GAP   * scale))

    -- Each face follows the user's Font / Style; the flags say whether to embolden.
    local face_title,  title_bold  = Text.face(styles, M.id, "title",       title_fs,  legacyFace, true)
    local face_author, author_bold = Text.face(styles, M.id, "author",      author_fs, legacyFace, false)
    local face_desc,   desc_bold   = Text.face(styles, M.id, "description", desc_fs,   legacyFace, false)
    local face_prog,   prog_bold   = Text.face(styles, M.id, "progress",    prog_fs,   legacyFace, true)
    local face_stats,  stats_bold  = Text.face(styles, M.id, "stats",       stats_fs,  legacyFace, false)

    local prefetched = ctx.prefetched and ctx.prefetched[fp]
    local bd         = SH.getBookData(fp, prefetched)

    -- Cover — may be replaced by updateCovers() asynchronously
    -- Apply stretch_limit based on user settings to prevent/allow cropping.
    local stretch_limit = nil
    if Settings:readSetting(pfx .. SK_PREVENT_CROP) ~= false then
        local threshold = Settings:readSetting(pfx .. SK_CROP_THRESHOLD) or 50
        stretch_limit = threshold / 100.0
    end
    local cover = fetchCover(SH, fp, COVER_W, COVER_H, stretch_limit)
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
    CLR_TEXT = themeColor("fg")                                or CLR_TEXT
    CLR_SUB  = themeColor("text_secondary") or themeColor("fg") or CLR_SUB

    -- Text column width
    local tw = w - PAD - COVER_W - cover_gap - PAD

    -- ── right_top: title + author (description added below after measuring) ──
    local right_top = VerticalGroup:new{ align = "left" }

    local title_args = {
        text      = bd.title or "?",
        face      = face_title,
        width     = tw,
        alignment = "left",
        fgcolor   = CLR_TEXT,
        bold      = title_bold,
    }
    local title_widget = ((ctx.text_alpha or ctx.has_wallpaper) and UI and UI.makeAlphaTextBox(title_args))
                          or TextBoxWidget:new(title_args)

    -- Tappable wrapper: tapping the title also opens the book, same as the
    -- cover image (right-handed users tend to reach for the title text,
    -- which sits closer to their thumb than the cover on the left).
    local TitleTap = InputContainer:extend{}
    function TitleTap:onTap()
        if ctx.open_fn then ctx.open_fn(fp) end
        return true
    end
    local title_size = title_widget:getSize()
    local title_tap = TitleTap:new{
        dimen = Geom:new{ w = title_size.w, h = title_size.h },
        title_widget,
    }
    title_tap.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = title_tap.dimen } },
    }
    right_top[#right_top + 1] = title_tap
    if bd.authors and bd.authors ~= "" then
        right_top[#right_top + 1] = VerticalSpan:new{ width = author_gap }
        local author_args = {
            text      = formatAuthors(bd.authors, tw, face_author),
            face      = face_author,
            width     = tw,
            alignment = "left",
            height    = math.ceil(face_author.size * 1.3),
            height_overflow_show_ellipsis = true,
            fgcolor   = CLR_SUB,
            bold      = author_bold,
        }
        right_top[#right_top + 1] = ((ctx.text_alpha or ctx.has_wallpaper) and UI and UI.makeAlphaTextBox(author_args))
                                      or TextBoxWidget:new(author_args)
    end

    -- ── right_bottom: progress row + optional stats, bottom-anchored ─────────
    local right_bottom = VerticalGroup:new{ align = "left" }
    -- Pin the group width to tw so BottomContainer left-aligns it regardless
    -- of whether the progress bar (which naturally fills tw) is visible or not.
    right_bottom[1] = HorizontalSpan:new{ width = tw }
    local pct = bd.percent or 0

    -- Book MD5: prefetch → sidecar; 
    -- must not depend on ctx.db_conn, or stats are lost during deferred first render.
    local book_md5 = prefetched and prefetched.partial_md5_checksum
    if not book_md5 then
        local ok_ds, DS = pcall(require, "docsettings")
        if ok_ds and DS then
            local ok2, ds = pcall(DS.open, DS, fp)
            if ok2 and ds then
                book_md5 = ds:readSetting("partial_md5_checksum")
                pcall(function() ds:close() end)
            end
        end
    end

    -- Single stats fetch shared by the progress bar ("Xh Ym left") and the
    -- stats row (days / read time). fetchStatsFromDB consults the prewarm
    -- cache first, so a warm home screen needs zero DB queries.
    local bstats = book_md5 and fetchStatsFromDB(book_md5, ctx.db_conn) or nil

    -- Progress row: default on; hidden when the setting is explicitly false.
    if Settings:readSetting(pfx .. SK_SHOW_PROGRESS) ~= false then
        -- Prefer stats DB avg; fall back to DocSettings sidecar total.
        local avg_time = bstats and bstats.avg_time
        if not avg_time or avg_time <= 0 then avg_time = bd.avg_time end

        local prog_left, prog_right
        -- Stable page numbers: show the reader's labels; the time-left
        -- estimate below stays in screen pages, like the Statistics plugin.
        local stable = StablePages.read(fp)
        if stable then
            local cur, total, cur_lbl, last_lbl = StablePages.position(stable, pct)
            if cur_lbl then
                prog_left = string.format("%s / %s", cur_lbl, last_lbl)
            else
                prog_left = string.format("%d / %d", cur, total)
            end
        end
        if bd.pages and bd.pages > 0 then
            local cur  = math.floor(pct * bd.pages)
            prog_left  = prog_left or string.format("%d / %d", cur, bd.pages)  -- matches bookshelf: no "p." prefix
            -- Local format rather than SH.formatTimeLeft — ours is translatable
            -- via fmtTime(); the base plugin's helper hardcodes English h/m.
            if avg_time and avg_time > 0 then
                local remaining = math.floor(bd.pages * (1.0 - pct))
                if remaining > 0 then
                    local secs_left = math.floor(remaining * avg_time)
                    if secs_left > 0 then
                        prog_right = string.format(_("%s left"), fmtTime(secs_left))
                    end
                end
            end
        else
            prog_left = prog_left or string.format("%.0f%%", pct * 100)
        end

        -- Bold TextWidgets (bookshelf progress region: bold = true)
        local lw    = TextWidget:new{ text = prog_left,  face = face_prog, fgcolor = CLR_SUB, bold = prog_bold }
        local rw    = prog_right and TextWidget:new{ text = prog_right, face = face_prog, fgcolor = CLR_SUB, bold = prog_bold }
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
            fillcolor  = Blitbuffer.COLOR_BLACK,
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

    -- Optional stats row (below progress). Built before the description so
    -- right_bottom:getSize().h is accurate for layout. bstats already came
    -- from the shared fetchStatsFromDB call above — no DB check needed here.
    if Settings:isTrue(pfx .. SK_SHOW_STATS) and bstats then
        local parts = {}
        if bstats.days and bstats.days > 0 then
            parts[#parts+1] = string.format(
                bstats.days == 1 and _("%d day") or _("%d days"), bstats.days)
        end
        if bstats.total_secs and bstats.total_secs > 0 then
            parts[#parts+1] = string.format(_("%s read"), fmtTime(bstats.total_secs))
        end
        if #parts > 0 then
            local stats_row = HorizontalGroup:new{ align = "center" }
            for i, part in ipairs(parts) do
                if i > 1 then
                    stats_row[#stats_row+1] = TextWidget:new{
                        text    = " · ",
                        face    = face_stats,
                        bold    = stats_bold,
                        fgcolor = CLR_SUB,
                    }
                end
                stats_row[#stats_row+1] = TextWidget:new{
                    text    = part,
                    face    = face_stats,
                    bold    = stats_bold,
                    fgcolor = CLR_SUB,
                }
            end
            right_bottom[#right_bottom+1] = VerticalSpan:new{
                width = math.max(1, math.floor(Screen:scaleBySize(3) * scale))
            }
            right_bottom[#right_bottom+1] = stats_row
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
                    bold        = desc_bold,
                }
                local pwid = ((ctx.text_alpha or ctx.has_wallpaper) and UI and UI.makeAlphaTextBox(desc_args))
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
                -- The viewer is fullscreen, so it has room for every author:
                -- only normalise the separators, don't width-fit against tw.
                local _book_author = bd.authors
                                     and bd.authors:gsub("%s*[\r\n]+%s*", ", ")
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
    border_clr = themeColor("separator") or border_clr
    if solid_bg then
        bg_color = themeColor("bg") or Blitbuffer.COLOR_WHITE
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
    for _i, slot in ipairs(tappable._cover_slots) do
        local new_cover = fetchCover(SH, slot.fp, slot.w, slot.h, slot.stretch)
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

    -- Right column height = cover height = 30% of content width × 1.5, scaled by user setting
    local approx_content_w = Screen:getWidth() - PAD * 2
    local content_h = math.floor(approx_content_w * 0.30 * getCoverScale(pfx) * 1.5)

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
    local Settings = getSettings()

    local function toggle_item(label, key)
        return {
            text_func      = function() return label end,
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
            text_func      = function() return label end,
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

    local items = {
        makeLabelToggleItem(Config, M.id, M.name, refresh, _),
        Config.makeScaleItem({
            text_func    = function()
                local pct = Config.getModuleScalePct("hero_currently", pfx)
                return pct == 100
                    and _("Scale")
                    or  string.format("%s (%d%%)", _("Scale"), pct)
            end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _("Scale"),
            info         = _("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct("hero_currently", pfx) end,
            set          = function(v) Config.setModuleScale(v, "hero_currently", pfx) end,
            refresh      = refresh,
        }),
        {
            text_func  = function() return _("Description Content") end,
            value_func = function()
                return (getDescSource(pfx) == "highlight")
                    and _("Highlight") or _("Description")
            end,
            sub_item_table = {
                {
                    text           = _("Description"),
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
                    text           = _("Highlight (random, falls back to description)"),
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
                    and _("Description Text Size")
                    or  string.format("%s (%d%%)", _("Description Text Size"), v)
            end,
            keep_menu_open = true,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager  = require("ui/uimanager")
                local S = getSettings()
                local current = (S and tonumber(S:readSetting(pfx .. SK_DESC_FS_SCALE))) or 100
                local spin
                spin = SpinWidget:new{
                    title_text      = _("Description Text Size"),
                    info_text       = _("Scales the description font size relative to default.\nLarger text shows fewer lines; smaller shows more."),
                    value           = current,
                    value_min       = 50,
                    value_max       = 300,
                    value_step      = 5,
                    value_hold_step = 25,
                    unit            = "%",
                    ok_text         = _("Set"),
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
        {
            text_func = function()
                local S = getSettings()
                local v = S and S:readSetting(pfx .. SK_COVER_SCALE)
                v = v and tonumber(v) or 100
                return v == 100
                    and _("Cover Size")
                    or  string.format("%s (%d%%)", _("Cover Size"), v)
            end,
            keep_menu_open = true,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager  = require("ui/uimanager")
                local S = getSettings()
                local current = (S and tonumber(S:readSetting(pfx .. SK_COVER_SCALE))) or 100
                local spin
                spin = SpinWidget:new{
                    title_text      = _("Cover Size"),
                    info_text       = _("Scales the hero card's book cover relative to default, independently of the card's text Scale setting.\nAspect ratio (3:2) is preserved; the text column resizes to fit."),
                    value           = current,
                    value_min       = 50,
                    value_max       = 150,
                    value_step      = 5,
                    value_hold_step = 25,
                    unit            = "%",
                    ok_text         = _("Set"),
                    callback        = function(spin_widget)
                        if S then
                            S:saveSetting(pfx .. SK_COVER_SCALE, spin_widget.value)
                        end
                        UIManager:close(spin)
                        refresh()
                    end,
                }
                UIManager:show(spin)
            end,
        },
        toggle_item(   _("Show Frame"), "hero_currently_show_frame"),
        toggle_item(   _("Solid Background"), "hero_currently_solid_bg"),
        toggle_item_on(_("Show Progress Bar"), SK_SHOW_PROGRESS),
        toggle_item(   _("Show Statistics"), SK_SHOW_STATS),
        toggle_item_on(_("Prevent Cover Cropping"), SK_PREVENT_CROP),
        {
            text_func = function()
                if Settings:readSetting(pfx .. SK_PREVENT_CROP) == false then
                    return _("Crop Threshold (disabled)")
                end
                local threshold = Settings:readSetting(pfx .. SK_CROP_THRESHOLD) or 50
                return string.format("%s (%d%%)", _("Crop Threshold"), threshold)
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
                    title_text = _("Crop Threshold"),
                    info_text  = _("Maximum aspect ratio distortion to prevent cropping.\n0% = always crop, 100% = never crop (allow stretching)"),
                    value      = threshold,
                    value_min  = 0,
                    value_max  = 100,
                    value_step = 5,
                    value_hold_step = 10,
                    unit       = "%",
                    ok_text    = _("Set"),
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
                    return _("Exclude Paths from Recent")
                end
                local n = 0
                for _i in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _("Exclude Paths from Recent"), n)
            end,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local UIManager   = require("ui/uimanager")
                local raw = (Settings and Settings:readSetting(pfx .. SK_EXCLUDE_PATHS)) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _("Exclude Paths from Recent"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss,instapaper,cache",
                    description = _("Comma-separated path fragments.\nBooks whose path contains any fragment will be skipped."),
                    allow_newline    = false,
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

    -- Per-element Font / Style / Size after Scale (SimpleUI 3.0+ only).
    local text_item = Text.menu(M.id, TEXT_ELEMS, {
        title       = _("Title"),
        author      = _("Author"),
        description = _("Description"),
        progress    = _("Progress"),
        stats       = _("Statistics"),
    }, pfx, refresh)
    if text_item then table.insert(items, 3, text_item) end
    return items
end

return M
