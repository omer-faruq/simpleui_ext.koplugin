-- modules/module_recent_book_stats.lua — SimpleUI Extra Modules
-- Recent Book Stats card.
--
-- Based on 2-reading-stats-popup.lua by quanganhdo:
--   https://github.com/quanganhdo/koreader-user-patches
-- Modified to work as a SimpleUI homescreen module.
--
-- Displays reading statistics for the most recently opened book, drawn
-- directly from the statistics SQLite DB and book sidecars. The layout
-- mirrors the Reading Stats Popup patch (2-reading-stats-popup.lua):
--
--   THIS BOOK  – left: progress% | right: pages read
--              – left: time spent | right: time left
--   PACE       – left: days reading | right: days to go
--              – left: avg time/day | right: pages/min
--   (footer)   – book title; tap anywhere to open the book
--
-- All data is sourced from the statistics SQLite DB and book sidecars.
-- No open document or ReaderUI is required — works entirely from the
-- homescreen.
--
-- Settings (prefixed with ctx.pfx at runtime):
--   rbs_time_format  — "nickel" (human, e.g. "3.5 hours") | "xhym" ("3h30m")
--   rbs_tappable     — tap card to open the book (default: true)
--   scale            — module size (via Config.getModuleScale)
--
-- Changelog:
--   1.0.0  initial release

local Device          = require("device")
local Screen          = Device.screen
local Blitbuffer      = require("ffi/blitbuffer")
local DataStorage     = require("datastorage")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Math            = require("optmath")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local util            = require("util")
local logger          = require("logger")

-- ---------------------------------------------------------------------------
-- Lazy-loaded SimpleUI helpers (unavailable until SimpleUI is fully loaded)
-- ---------------------------------------------------------------------------
local _Config, _SUISettings, _UI, _SUIStyle

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

local function getSUIStyle()
    if not _SUIStyle then
        local ok, m = pcall(require, "sui_style")
        if ok and m then _SUIStyle = m end
    end
    return _SUIStyle
end

-- ---------------------------------------------------------------------------
-- Setting keys
-- ---------------------------------------------------------------------------
local SK_TIME_FMT      = "rbs_time_format"
local SK_TAPPABLE      = "rbs_tappable"
local SK_EXCLUDE_PATHS = "rbs_exclude_paths"
local FMT_NICKEL  = "nickel"   -- human (e.g. "3.5 hours")
local FMT_XHYM    = "xhym"    -- compact (e.g. "3h30m")

local function getTimeFmt(pfx)
    local S = getSettings()
    local v = S and S:readSetting(pfx .. SK_TIME_FMT)
    return (v == FMT_XHYM) and FMT_XHYM or FMT_NICKEL
end

local function isTappable(pfx)
    local S = getSettings()
    if not S then return true end
    local v = S:readSetting(pfx .. SK_TAPPABLE)
    return v ~= false   -- default true: treat nil as enabled
end

-- Returns a list of path fragments the user wants excluded from recent.
-- Accepts comma- or newline-separated entries; trims whitespace.
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

-- Returns true when fp contains any of the exclude fragments (plain substring).
local function isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Formatting helpers  (ported from 2-reading-stats-popup.lua)
-- ---------------------------------------------------------------------------

local function fmtCount(n)
    if n == nil then return "" end
    return util.getFormattedSize(n)
end

local function emptyVal()
    return { value = "", unit = "" }
end

local function fmtFraction(a, b)
    return string.format("%s/%s", fmtCount(a), fmtCount(b))
end

-- Returns { value = "...", unit = "..." }.
-- Mirrors the minute-rounding behaviour of the stock footer and popup.
local function fmtTimeHuman(secs)
    if not secs or secs ~= secs then return emptyVal() end
    if secs <= 0 then
        return { value = fmtCount(0), unit = "minutes" }
    end
    local mins = Math.round(secs / 60)
    if mins <= 0 then
        return { value = fmtCount(0), unit = "minutes" }
    elseif mins < 60 then
        return { value = fmtCount(mins), unit = mins == 1 and "minute" or "minutes" }
    end
    local h = mins / 60
    local val = (h < 100) and string.format("%.1f", h) or string.format("%.0f", h)
    return { value = val, unit = h < 2 and "hour" or "hours" }
end

local function fmtTimeXhym(secs)
    if not secs or secs ~= secs then return emptyVal() end
    local mins = Math.round(secs / 60)
    if mins <= 0 then return { value = "0m", unit = "" } end
    local h = math.floor(mins / 60)
    local m = mins % 60
    return {
        value = (h > 0) and string.format("%dh%02dm", h, m)
                        or  string.format("%dm", m),
        unit  = "",
    }
end

local function pickFormatter(pfx)
    return (getTimeFmt(pfx) == FMT_XHYM) and fmtTimeXhym or fmtTimeHuman
end

-- Returns { value = "N", unit = "days reading" } (or weeks/months).
-- Mirrors humanizeDayCount() from 2-reading-stats-popup.lua.
local function humanDayCount(days, kind)
    local n    = math.max(0, tonumber(days) or 0)
    local unit = "day"
    if n >= 60 then
        unit = "month"
        n    = math.floor((n + 15) / 30)
    elseif n >= 14 then
        unit = "week"
        n    = math.floor((n + 3) / 7)
    end
    local labels = {
        reading = {
            day   = { "day reading",   "days reading"   },
            week  = { "week reading",  "weeks reading"  },
            month = { "month reading", "months reading" },
        },
        to_go = {
            day   = { "day to go",   "days to go"   },
            week  = { "week to go",  "weeks to go"  },
            month = { "month to go", "months to go" },
        },
    }
    local group = labels[kind] or labels.to_go
    local pair  = group[unit]  or group.day
    return { value = fmtCount(n), unit = (n == 1) and pair[1] or pair[2] }
end

-- ---------------------------------------------------------------------------
-- Stats DB helpers
-- ---------------------------------------------------------------------------

-- Per-page duration cap (seconds).
-- Read from G_reader_settings at gather time to match whatever the user
-- has configured in the Statistics plugin (default 120 s = 2 minutes).
-- The constant below is only a fallback for when the global isn't available.
local _DEFAULT_MAX_SEC = 120

local function getMaxSec()
    local ok, max = pcall(function()
        local s = G_reader_settings:readSetting("statistics")
        return s and tonumber(s.max_sec)
    end)
    return (ok and max and max > 0) and max or _DEFAULT_MAX_SEC
end

local function openStatsDB()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn
    pcall(function() conn = SQ3.open(path) end)
    if not conn then return nil end
    return conn
end

-- Returns integer book id from the statistics DB, or nil.
local function dbGetBookId(conn, md5)
    if not md5 then return nil end
    local id
    pcall(function()
        id = conn:rowexec(
            string.format("SELECT id FROM book WHERE md5 = %q LIMIT 1;", md5))
    end)
    return id and tonumber(id) or nil
end

-- Returns { total_time, read_pages, avg_time } or nil.
-- Duration is capped at max_sec per page, matching the Statistics plugin.
local function dbGetTimeStats(conn, book_id, max_sec)
    local result
    pcall(function()
        local rows = conn:exec(string.format([[
            WITH ps AS (
                SELECT   page, sum(duration) AS pd
                FROM     page_stat
                WHERE    id_book = %d
                GROUP BY page
            )
            SELECT sum(min(pd, %d)), count(*)
            FROM   ps;
        ]], book_id, max_sec))
        if rows and rows[1] and rows[1][1] then
            local tt = tonumber(rows[1][1]) or 0
            local rp = tonumber(rows[2] and rows[2][1]) or 0
            result = {
                total_time = tt,
                read_pages = rp,
                avg_time   = (rp > 0 and tt > 0) and (tt / rp) or nil,
            }
        end
    end)
    return result
end

-- Returns count of distinct local calendar days with reading activity, or nil.
local function dbGetTotalDays(conn, book_id)
    local n
    pcall(function()
        n = conn:rowexec(string.format([[
            SELECT count(*)
            FROM   (
                       SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime')
                       FROM   page_stat
                       WHERE  id_book = %d
                       GROUP  BY 1
                   );
        ]], book_id))
    end)
    return n and tonumber(n) or nil
end

-- ---------------------------------------------------------------------------
-- Book data  (most recently opened entry from ReadHistory + DocSettings)
-- ---------------------------------------------------------------------------

local function getMostRecentBook(excludes)
    excludes = excludes or {}
    local ok, RH = pcall(require, "readhistory")
    if not ok or not RH then return nil end
    if not (RH.hist and #RH.hist > 0) then
        pcall(function() RH:reload() end)
    end
    if not RH.hist then return nil end
    -- Walk history and return the first entry whose path is not excluded.
    local entry
    for _, e in ipairs(RH.hist) do
        if e and e.file and not isExcluded(e.file, excludes) then
            entry = e
            break
        end
    end
    if not entry or not entry.file then return nil end

    local fp    = entry.file
    local title = entry.title or fp:match("([^/\\]+)%.[^%.]+$") or "?"
    local md5, percent, pages

    local ok_ds, DS = pcall(require, "docsettings")
    if ok_ds and DS then
        local ok2, ds = pcall(DS.open, DS, fp)
        if ok2 and ds then
            md5     = ds:readSetting("partial_md5_checksum")
            percent = tonumber(ds:readSetting("percent_finished")) or 0
            pages   = tonumber(ds:readSetting("doc_pages"))        or 0
            local props = ds:readSetting("doc_props") or {}
            title = (props.title and props.title ~= "" and props.title) or title
            pcall(function() ds:close() end)
        end
    end

    return {
        fp      = fp,
        title   = title,
        md5     = md5,
        percent = percent or 0,
        pages   = pages   or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Stats gathering
-- ---------------------------------------------------------------------------

-- conn_ext is optional: the homescreen-supplied shared DB connection.
local function gatherStats(book, pfx, conn_ext)
    local fmt  = pickFormatter(pfx)
    local zero = fmt(0)
    local s = {
        book_progress    = emptyVal(),
        book_pages_read  = emptyVal(),
        book_time_spent  = zero,
        book_time_left   = zero,
        avg_time_per_day = zero,
        pages_per_minute = { value = fmtCount(0), unit = "pages/min" },
        days_reading     = humanDayCount(0, "reading"),
        days_to_go       = humanDayCount(0, "to_go"),
    }
    if not book then return s end

    -- Progress fields
    local pct      = book.percent or 0
    local pages    = book.pages   or 0
    local cur_page = (pages > 0) and math.max(1, math.floor(pct * pages)) or 0

    if pct > 0 then
        s.book_progress = { value = string.format("%.0f%%", pct * 100), unit = "" }
    end
    if pages > 0 then
        s.book_pages_read = {
            value = fmtFraction(cur_page, pages),
            unit  = "",
        }
    end

    -- Open the stats DB for the rest of the fields.
    -- Prefer the externally supplied connection (from homescreen framework
    -- via M.needs = { db = true }) to avoid redundant open/close per build.
    local conn     = conn_ext or openStatsDB()
    local owns_conn = not conn_ext
    if not conn then return s end

    local book_id    = dbGetBookId(conn, book.md5)
    if not book_id then
        if owns_conn then conn:close() end
        return s
    end

    local max_sec    = getMaxSec()
    local ts         = dbGetTimeStats(conn, book_id, max_sec)
    local total_days = dbGetTotalDays(conn, book_id)
    if owns_conn then conn:close() end

    if ts and ts.total_time and ts.total_time > 0 then
        s.book_time_spent = fmt(ts.total_time)
    end

    local avg_time   = ts and ts.avg_time
    local pages_left = (pages > 0) and (pages - cur_page) or nil

    if avg_time and avg_time > 0 and pages_left and pages_left > 0 then
        s.book_time_left = fmt(pages_left * avg_time)
    end

    if avg_time and avg_time > 0 then
        local ppm = 60 / avg_time
        s.pages_per_minute = {
            value = (ppm >= 1) and string.format("%.1f", ppm)
                               or  string.format("%.2f", ppm),
            unit  = (ppm < 2) and "page per minute" or "pages per minute",
        }
    end

    if total_days and total_days > 0 then
        s.days_reading = humanDayCount(total_days, "reading")

        if ts and ts.total_time and ts.total_time > 0 then
            s.avg_time_per_day = fmt(ts.total_time / total_days)
        end

        if avg_time and avg_time > 0
           and pages_left and pages_left > 0
           and ts and ts.total_time and ts.total_time > 0
        then
            local avg_per_day = ts.total_time / total_days
            if avg_per_day > 0 then
                local days_to_finish =
                    math.ceil((pages_left * avg_time) / avg_per_day)
                s.days_to_go = humanDayCount(days_to_finish, "to_go")
            end
        end
    end

    return s
end

-- ---------------------------------------------------------------------------
-- Widget helpers  (layout mirrors 2-reading-stats-popup.lua)
-- ---------------------------------------------------------------------------

-- transparent=true: no FrameContainer (avoids opaque fill) — text with
-- padding + a solid bottom line the same color as the header text.
local function mkSectionHeader(face, text, full_w, bg_color, left_pad, transparent)
    left_pad = left_pad or Size.padding.large
    local tw = TextWidget:new{ text = text, face = face }
    if transparent then
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ height = Size.padding.small },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = left_pad },
                tw,
            },
            VerticalSpan:new{ height = Size.padding.small },
            LineWidget:new{
                dimen      = Geom:new{ w = full_w, h = Size.line.thick },
                background = Blitbuffer.COLOR_BLACK,
            },
        }
    end
    return FrameContainer:new{
        background     = bg_color or Blitbuffer.COLOR_GRAY_E,
        bordersize     = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = left_pad,
        padding_right  = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = full_w - left_pad, h = tw:getSize().h },
            tw,
        },
    }
end

-- Builds a single "{value}  {unit} {extra}" cell.
-- make_tbw(args) is a drop-in for TextBoxWidget:new that produces an
-- alpha-composited widget when a wallpaper is active.
local function mkValueLine(face_val, face_lbl, col_w, data, extra, make_tbw)
    local desc = (data and data.unit) or ""
    if extra and extra ~= "" then
        desc = (desc ~= "") and (desc .. " " .. extra) or extra
    end
    if not data or data.value == "" then
        return make_tbw({
            text = desc, face = face_lbl, width = col_w, alignment = "left",
        })
    end
    local vw    = TextWidget:new{ text = data.value, face = face_val }
    local vw_w  = vw:getSize().w
    local lbl_w = math.max(1, col_w - vw_w - Size.padding.large)
    return HorizontalGroup:new{
        align = "center",
        vw,
        HorizontalSpan:new{ width = Size.padding.large },
        make_tbw({
            text = desc, face = face_lbl, width = lbl_w, alignment = "left",
        }),
    }
end

-- Builds a two-column row with a vertical separator.
local function mkTwoColRow(left_w, right_w, col_w, col_gap)
    local row_h = math.max(left_w:getSize().h, right_w:getSize().h)
    local v_pad = Size.padding.default
    local sep   = HorizontalGroup:new{
        HorizontalSpan:new{ width = col_gap },
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ height = v_pad },
            LineWidget:new{
                dimen      = Geom:new{
                    w = Size.line.medium,
                    h = math.max(1, row_h - 2 * v_pad),
                },
                background = Blitbuffer.COLOR_GRAY,
            },
            VerticalSpan:new{ height = v_pad },
        },
        HorizontalSpan:new{ width = col_gap },
    }
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = col_w, h = row_h }, left_w  },
        sep,
        LeftContainer:new{ dimen = Geom:new{ w = col_w, h = row_h }, right_w },
    }
end

-- ---------------------------------------------------------------------------
-- Stats cache
-- ---------------------------------------------------------------------------

-- Stats are cached for _CACHE_TTL seconds keyed by (book filepath + pfx).
-- The cache is also cleared whenever M.reset() is called (hot-reload).
-- 5 s is enough to avoid redundant re-queries during a single home-screen
-- repaint cycle while still showing fresh data after returning from a book.
local _CACHE_TTL = 300  -- seconds (5 min; books invalidate the cache on close anyway)
local _cache     = nil  -- { fp, pfx, ts, stats }

local function cacheGet(book, pfx)
    if not _cache then return nil end
    if _cache.fp  ~= (book and book.fp) then return nil end
    if _cache.pfx ~= pfx               then return nil end
    if (os.time() - _cache.ts) > _CACHE_TTL then return nil end
    return _cache.stats
end

local function cachePut(book, pfx, stats)
    _cache = { fp = book and book.fp, pfx = pfx, ts = os.time(), stats = stats }
end

-- ---------------------------------------------------------------------------
-- Module descriptor
-- ---------------------------------------------------------------------------

local M = {}

M.id              = "recent_book_stats"
M.name            = "Recent Book Stats"
M.description     = "Statistics cards for recently read books with progress and reading time"
M.default_enabled = true   -- Loaded by simpleui_ext by default
M.label           = "Recent Book Stats"
M.enabled_key     = "recent_book_stats"
M.default_on      = false
M.is_book_mod     = true   -- suppresses the homescreen "no books yet" empty-state
M.needs           = { db = true }  -- request shared stats DB conn from homescreen

function M.reset()
    _Config      = nil
    _SUISettings = nil
    _UI          = nil
    _SUIStyle    = nil
    _cache       = nil   -- invalidate on hot-reload
end

-- Called by main.lua's onCloseDocument so stats refresh immediately
-- after the user returns from reading, without waiting for the TTL.
function M.invalidateCache()
    _cache = nil
end

-- ---------------------------------------------------------------------------
-- M.build(w, ctx) → widget | nil
-- ---------------------------------------------------------------------------

function M.build(w, ctx)
    local Config = getConfig()
    local UI     = getUI()
    if not Config or not UI then return nil end

    Config.applyLabelToggle(M, M.label)

    local pfx   = ctx and ctx.pfx or ""
    local scale = Config.getModuleScale("recent_book_stats", pfx)
    local PAD   = UI.PAD

    -- Gather data (use cache when available; ctx.db_conn is the shared
    -- stats DB connection provided by the homescreen via M.needs = { db = true })
    local excludes = getExcludePaths(pfx)
    local book     = getMostRecentBook(excludes)
    local stats    = cacheGet(book, pfx)
    if not stats then
        stats = gatherStats(book, pfx, ctx and ctx.db_conn)
        cachePut(book, pfx, stats)
    end

    -- Colours — honour the active SimpleUI theme when available
    local CLR_HDR_BG = Blitbuffer.COLOR_GRAY_D   -- 0xDD — more prominent than E
    local CLR_TEXT   = Blitbuffer.COLOR_BLACK
    local CLR_SEP    = Blitbuffer.COLOR_BLACK
    local SS = getSUIStyle()
    if SS then
        -- "muted" / "divider" tends to be darker than "surface",
        -- giving a clear visual weight to section headers.
        CLR_HDR_BG = SS.getThemeColor("muted")
                     or SS.getThemeColor("divider")
                     or CLR_HDR_BG
        CLR_TEXT   = SS.getThemeColor("fg")         or CLR_TEXT
        CLR_SEP    = SS.getThemeColor("separator")  or CLR_SEP
    end

    -- Fonts — side-by-side layout: larger values, compact labels
    local base_val_fs = 30
    local base_lbl_fs = 11
    local val_fs  = math.max(14, math.floor(base_val_fs * scale))
    local lbl_fs  = math.max(8,  math.floor(base_lbl_fs * scale))
    local sec_fs  = Font:getFace("x_smallinfofont")
    local face_v  = Font:getFace("NotoSerif-Bold.ttf", val_fs)
                    or Font:getFace("tfont", val_fs)
    local face_l  = Font:getFace("NotoSerif-Regular.ttf", lbl_fs)
                    or Font:getFace("x_smallinfofont")

    -- Layout: two section panels side by side (THIS BOOK left, PACE right)
    -- Each panel has its own two-column value layout.
    local ip       = Size.padding.default              -- inner side padding per panel
    local ig       = Screen:scaleBySize(10)            -- gap around inner column separator
    local isep_w   = 2 * ig + Size.line.medium         -- inner col separator width
    local vsep_w   = isep_w                            -- section separator (same style)
    local panel_w  = math.max(1, math.floor((w - vsep_w) / 2))
    local icol_w   = math.max(1, math.floor((panel_w - 2 * ip - isep_w) / 2))

    -- Wallpaper transparency helper: replaces TextBoxWidget:new when a
    -- wallpaper is active so labels don't paint a white box over the image.
    local has_wp = ctx and ctx.has_wallpaper
    local function make_tbw(args)
        if has_wp and UI and UI.makeAlphaTextBox then
            return UI.makeAlphaTextBox(args)
        end
        return TextBoxWidget:new(args)
    end

    -- Shorthand builders scoped to the narrower panel columns

    -- Auto-shrink value face so the text fits within max_w pixels.
    -- Tries progressively smaller sizes down to min_fs before giving up.
    local function fitValFace(text, max_w)
        if not text or text == "" then return face_v end
        local fs     = val_fs
        local min_fs = math.max(9, val_fs - 12)
        local face   = face_v
        local tw     = TextWidget:new{ text = text, face = face }
        while tw:getSize().w > max_w and fs > min_fs do
            fs   = fs - 1
            face = Font:getFace("NotoSerif-Bold.ttf", fs) or Font:getFace("tfont", fs)
            tw   = TextWidget:new{ text = text, face = face }
        end
        return face
    end

    local function pvline(data, extra)
        if not data or data.value == "" then
            return mkValueLine(face_v, face_l, icol_w, data, extra, make_tbw)
        end
        -- Mirror mkValueLine's label logic to know how much width the value can use.
        local desc = data.unit or ""
        if extra and extra ~= "" then
            desc = (desc ~= "") and (desc .. " " .. extra) or extra
        end
        -- With a label: value gets ~55 % of column; without: almost the full column.
        local max_val_w = (desc ~= "")
            and math.max(1, math.floor(icol_w * 0.55))
            or  math.max(1, icol_w - Size.padding.small)
        local vface = fitValFace(data.value, max_val_w)
        return mkValueLine(vface, face_l, icol_w, data, extra, make_tbw)
    end
    local function ptrow(l, r)
        return HorizontalGroup:new{
            HorizontalSpan:new{ width = ip },
            mkTwoColRow(l, r, icol_w, ig),
        }
    end
    local function hsep()
        return LineWidget:new{
            dimen      = Geom:new{ w = w, h = Size.line.medium },
            background = CLR_SEP,
        }
    end

    -- THIS BOOK header: embed book title, pixel-accurate truncation.
    -- Measures real TextWidget width so no character overflows into PACE panel.
    local tb_title = book and (book.title or "") or ""
    local tb_header_text
    do
        local prefix   = "BOOK: "
        local ellipsis = "\u{2026}"
        local avail_w  = panel_w - Size.padding.large
        if tb_title == "" then
            tb_header_text = "BOOK"
        else
            -- Check if the full header fits
            local tw = TextWidget:new{ text = prefix .. tb_title, face = sec_fs }
            if tw:getSize().w <= avail_w then
                tb_header_text = prefix .. tb_title
            else
                -- Strip last UTF-8 char one by one until it fits
                local s = tb_title
                repeat
                    -- Find start of last UTF-8 char and remove it
                    local i = #s
                    while i > 1 and s:byte(i) >= 0x80 and s:byte(i) <= 0xBF do
                        i = i - 1
                    end
                    s = s:sub(1, i - 1)
                    if s == "" then break end
                    tw = TextWidget:new{ text = prefix .. s .. ellipsis, face = sec_fs }
                until tw:getSize().w <= avail_w
                tb_header_text = (s ~= "") and (prefix .. s .. ellipsis) or "BOOK"
            end
        end
    end

    -- ──  BOOK panel ───────────────────────────────────────────────────────────
    local tb_panel = VerticalGroup:new{ align = "left" }
    tb_panel[#tb_panel+1] = mkSectionHeader(sec_fs, tb_header_text, panel_w, CLR_HDR_BG, nil, has_wp)
    tb_panel[#tb_panel+1] = VerticalSpan:new{ height = Size.padding.default }
    -- Row 1: progress% | pages read
    tb_panel[#tb_panel+1] = ptrow(pvline(stats.book_progress, ""), pvline(stats.book_pages_read, ""))
    tb_panel[#tb_panel+1] = VerticalSpan:new{ height = Size.padding.default }
    -- Row 2: time spent | time left
    tb_panel[#tb_panel+1] = ptrow(pvline(stats.book_time_spent, "read"), pvline(stats.book_time_left, "to go"))
    tb_panel[#tb_panel+1] = VerticalSpan:new{ height = Size.padding.default }

    -- ── PACE panel ────────────────────────────────────────────────────────────
    local pa_panel = VerticalGroup:new{ align = "left" }
    pa_panel[#pa_panel+1] = mkSectionHeader(sec_fs, "PACE", panel_w, CLR_HDR_BG, nil, has_wp)
    pa_panel[#pa_panel+1] = VerticalSpan:new{ height = Size.padding.default }
    -- Row 3: days reading | days to go
    pa_panel[#pa_panel+1] = ptrow(pvline(stats.days_reading, ""), pvline(stats.days_to_go, ""))
    pa_panel[#pa_panel+1] = VerticalSpan:new{ height = Size.padding.default }
    -- Row 4: avg time/day | pages/min
    pa_panel[#pa_panel+1] = ptrow(pvline(stats.avg_time_per_day, "per day"), pvline(stats.pages_per_minute, ""))
    pa_panel[#pa_panel+1] = VerticalSpan:new{ height = Size.padding.default }

    -- Combine panels with a thin vertical separator (same style as inner col separators)
    local panels_h = math.max(tb_panel:getSize().h, pa_panel:getSize().h)
    local card = VerticalGroup:new{ align = "left" }
    card[#card+1] = HorizontalGroup:new{
        align = "top",
        tb_panel,
        HorizontalSpan:new{ width = ig },
        LineWidget:new{
            dimen      = Geom:new{ w = Size.line.medium, h = panels_h },
            background = Blitbuffer.COLOR_GRAY,
        },
        HorizontalSpan:new{ width = ig },
        pa_panel,
    }

    -- Wrap in a tappable InputContainer so the user can open the book.
    if not (book and isTappable(pfx) and ctx and ctx.open_fn) then
        return card
    end

    local card_h   = card:getSize().h
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = w, h = card_h },
        _fp      = book.fp,
        _open_fn = ctx.open_fn,
        [1]      = card,
    }
    tappable.ges_events = {
        TapCard = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    function tappable:onTapCard()
        if self._open_fn and self._fp then
            self._open_fn(self._fp)
        end
        return true
    end

    return tappable
end

-- ---------------------------------------------------------------------------
-- M.getHeight(ctx) → number  (includes section-label height)
-- ---------------------------------------------------------------------------

function M.getHeight(ctx)
    local Config = getConfig()
    local UI     = getUI()
    local pfx    = ctx and ctx.pfx or ""
    local scale  = Config and Config.getModuleScale("recent_book_stats", pfx) or 1.0
    local PAD    = UI and UI.PAD or Screen:scaleBySize(14)

    -- Approximate: 1 row of headers + 2 value rows (side-by-side layout)
    local hdr_h   = Screen:scaleBySize(22) * scale
    local row_h   = Screen:scaleBySize(38) * scale   -- 30pt values
    local spans   = (Size.padding.default * 2) * scale
    local content = hdr_h + row_h * 2 + spans
    local label_h = Config and Config.getScaledLabelH() or 0

    return math.floor(label_h + content)
end

-- ---------------------------------------------------------------------------
-- M.getMenuItems(ctx_menu) → table  (settings in the Arrange / module screen)
-- ---------------------------------------------------------------------------

function M.getMenuItems(ctx_menu)
    local Config = getConfig()
    if not Config then return nil end

    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._ or function(x) return x end
    local S       = getSettings()

    return {
        -- 1. Label visibility toggle
        Config.makeLabelToggleItem(M.id, M.name, refresh, _lc),

        -- 2. Scale slider
        Config.makeScaleItem({
            text_func    = function()
                local pct = Config.getModuleScalePct("recent_book_stats", pfx)
                return pct == 100
                    and _lc("Scale")
                    or  string.format("%s (%d%%)", _lc("Scale"), pct)
            end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module.\n100% is the default size."),
            get          = function()
                return Config.getModuleScalePct("recent_book_stats", pfx)
            end,
            set          = function(v)
                Config.setModuleScale(v, "recent_book_stats", pfx)
            end,
            refresh      = refresh,
        }),

        -- 3. Time format toggle (Nickel / XhYm)
        {
            text_func = function()
                local fmt = getTimeFmt(pfx)
                local lbl = (fmt == FMT_XHYM) and "XhYm" or _lc("Human")
                return string.format("%s \u{2014} %s", _lc("Time Format"), lbl)
            end,
            sub_item_table = {
                {
                    text           = _lc("Human (e.g. 3.5 hours)"),
                    radio          = true,
                    checked_func   = function() return getTimeFmt(pfx) ~= FMT_XHYM end,
                    keep_menu_open = true,
                    callback       = function()
                        if S then S:saveSetting(pfx .. SK_TIME_FMT, FMT_NICKEL) end
                        refresh()
                    end,
                },
                {
                    text           = "XhYm (e.g. 3h30m)",
                    radio          = true,
                    checked_func   = function() return getTimeFmt(pfx) == FMT_XHYM end,
                    keep_menu_open = true,
                    callback       = function()
                        if S then S:saveSetting(pfx .. SK_TIME_FMT, FMT_XHYM) end
                        refresh()
                    end,
                },
            },
        },

        -- 4. Tap to open book
        {
            text_func      = function() return _lc("Tap to Open Book") end,
            checked_func   = function() return isTappable(pfx) end,
            keep_menu_open = true,
            callback       = function()
                if S then
                    S:saveSetting(pfx .. SK_TAPPABLE, not isTappable(pfx))
                end
                refresh()
            end,
        },

        -- 5. Exclude paths from recent
        {
            text_func = function()
                local raw = S and S:readSetting(pfx .. SK_EXCLUDE_PATHS)
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
                local raw = (S and S:readSetting(pfx .. SK_EXCLUDE_PATHS)) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _lc("Exclude Paths from Recent"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss, instapaper",
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
                                if S then
                                    S:saveSetting(pfx .. SK_EXCLUDE_PATHS, val)
                                end
                                _cache = nil   -- show correct book immediately
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
