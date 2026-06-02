-- module_currently_yanllsama.lua — Enhanced Currently Reading (SimpleUI Dashboard Module)
--
-- Enhanced Currently Reading is a completely redesigned, highly detailed, and fully dynamic
-- reading statistics dashboard module for KOReader's SimpleUI plugin.
--
-- While maintaining the solid foundation of the original module, it offers enriched data,
-- brand new progress bar designs, dynamic grid management, and flexible interface options.
--
-- Features:
-- • Fully Dynamic Grid System: Freely determine layout with Number of Columns (1-4) and Rows (1-6)
-- • 4 Customizable Category Headers: Change header text, thickness, or hide them completely
-- • Rich Statistics: Time Left/Spent, Pages Read/Left, Days Reading/To Go, Daily Average,
--   Pages/Minute Speed, Last Session Pages
-- • Advanced Progress Bars: Simple, With percentage, Bold, Minimal, Outline, Segmented
-- • Full Control (Edit Items): Show/hide any statistic, rearrange display order
-- • Smart Info Screen: Tap Book/Author name to view book description
--
-- Developed by Yanllsama, based on the original open-source codes.
-- https://github.com/yanllsama/koreader-enhanced-currently-reading

local Device  = require("device")
local Screen  = Device.screen
local _       = require("sui_i18n").translate
local N_      = require("sui_i18n").ngettext
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local DataStorage     = require("datastorage")
local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Math            = require("optmath")
local Size            = require("ui/size")
local util            = require("util")

local Config       = require("sui_config")
local UI           = require("sui_core")
local SUISettings  = require("sui_store")
local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m else logger.warn("simpleui: cannot load module_books_shared") end
    end
    return _SH
end

local _SUIStyle = nil
local function getSUIStyle()
    if not _SUIStyle then
        local ok, m = pcall(require, "sui_style")
        if ok and m then _SUIStyle = m end
    end
    return _SUIStyle
end

local _CLR_DARK   = Blitbuffer.COLOR_BLACK
local _CLR_BAR_BG = Blitbuffer.gray(0.15)
local _CLR_BAR_FG = Blitbuffer.gray(0.75)

local _BASE_COVER_GAP      = Screen:scaleBySize(16)
local _BASE_BAR_GAP_BEFORE = Screen:scaleBySize(6)
local _BASE_BAR_H          = Screen:scaleBySize(7)
local _BASE_BAR_PCT_GAP    = Screen:scaleBySize(6)
local _BASE_PCT_W          = Screen:scaleBySize(32)
local _BASE_INLINEPCT_FS   = Screen:scaleBySize(11)
local _BASE_AUTHOR_GAP     = Screen:scaleBySize(6)

local BAR_STYLE_KEY     = "yanllsama_bar_style"
local COVER_GAP_KEY     = "yanllsama_cover_gap"
local SK_TIME_FMT       = "yanllsama_time_format"
local SK_EXCLUDE_PATHS  = "yanllsama_exclude_paths"
local FMT_NICKEL        = "nickel"
local FMT_XHYM          = "xhym"

local GRID_COLS_KEY     = "yanllsama_grid_cols"
local GRID_ROWS_KEY     = "yanllsama_grid_rows"
local STAT_ORDER_KEY    = "yanllsama_stat_order"
local ACTIVE_STATS_KEY  = "yanllsama_active_stats"

local VAL_FS_KEY        = "yanllsama_val_fs"
local LBL_FS_KEY        = "yanllsama_lbl_fs"
local TITLE_FS_KEY      = "yanllsama_title_fs"
local AUTHOR_FS_KEY     = "yanllsama_author_fs"

local VAL_FONT_KEY      = "yanllsama_val_font"
local LBL_FONT_KEY      = "yanllsama_lbl_font"
local TITLE_FONT_KEY    = "yanllsama_title_font"
local AUTHOR_FONT_KEY   = "yanllsama_author_font"

local VAL_BOLD_KEY      = "yanllsama_val_bold"
local LBL_BOLD_KEY      = "yanllsama_lbl_bold"

local SHOW_HEADERS_KEY  = "yanllsama_show_headers"
local HEADER_TXT_PFX    = "yanllsama_header_txt_"
local HEADER_WEIGHT_KEY = "yanllsama_header_weight"

local _STAT_LABELS = {
    book_time_left     = _("Time Left"),
    book_pages_read    = _("Pages Read"),
    book_time_spent    = _("Time Spent"),
    pages_left         = _("Pages Left"),
    days_reading       = _("Days Reading"),
    days_to_go         = _("Days to Go"),
    avg_time_per_day   = _("Daily Average"),
    pages_per_minute   = _("Pages/Minute"),
    mins_per_session   = _("Mins/Session"),
    pages_last_session = _("Last Session Pages"),
}

local _DEFAULT_STAT_ORDER = {
    "book_time_left", "book_pages_read",
    "book_time_spent", "pages_left",
    "days_reading", "days_to_go",
    "avg_time_per_day", "pages_per_minute",
    "mins_per_session", "pages_last_session"
}

local function getBarStyle(pfx) return SUISettings:readSetting(pfx .. BAR_STYLE_KEY) or "with_pct" end
local function getCoverGapPct(pfx)
    local v = SUISettings:readSetting(pfx .. COVER_GAP_KEY)
    local n = tonumber(v)
    return n and math.max(0, math.min(300, math.floor(n))) or 100
end
local function getTimeFmt(pfx) return SUISettings:readSetting(pfx .. SK_TIME_FMT) == FMT_XHYM and FMT_XHYM or FMT_NICKEL end
local function getGridCols(pfx) return tonumber(SUISettings:readSetting(pfx .. GRID_COLS_KEY)) or 2 end
local function getGridRows(pfx) return tonumber(SUISettings:readSetting(pfx .. GRID_ROWS_KEY)) or 4 end
local function getValFs(pfx) return tonumber(SUISettings:readSetting(pfx .. VAL_FS_KEY)) or 30 end
local function getLblFs(pfx) return tonumber(SUISettings:readSetting(pfx .. LBL_FS_KEY)) or 16 end
local function getTitleFs(pfx) return tonumber(SUISettings:readSetting(pfx .. TITLE_FS_KEY)) or 24 end
local function getAuthorFs(pfx) return tonumber(SUISettings:readSetting(pfx .. AUTHOR_FS_KEY)) or 20 end
local function getValFont(pfx) return SUISettings:readSetting(pfx .. VAL_FONT_KEY) or "NotoSerif" end
local function getLblFont(pfx) return SUISettings:readSetting(pfx .. LBL_FONT_KEY) or "x_smallinfofont" end
local function getTitleFont(pfx) return SUISettings:readSetting(pfx .. TITLE_FONT_KEY) or "NotoSerif" end
local function getAuthorFont(pfx) return SUISettings:readSetting(pfx .. AUTHOR_FONT_KEY) or "NotoSerif" end
local function getValBold(pfx) local v = SUISettings:readSetting(pfx .. VAL_BOLD_KEY); if v == nil then return true else return v end end
local function getLblBold(pfx) return SUISettings:readSetting(pfx .. LBL_BOLD_KEY) or false end
local function getShowHeaders(pfx) local v = SUISettings:readSetting(pfx .. SHOW_HEADERS_KEY); if v == nil then return true else return v end end
local function getHeaderTxt(pfx, col_idx) 
    local defaults = { _("THIS BOOK"), _("SPEED"), _("EXTRA 1"), _("EXTRA 2") }
    return SUISettings:readSetting(pfx .. HEADER_TXT_PFX .. tostring(col_idx)) or defaults[col_idx] or _("INFO")
end
local function getHeaderWeight(pfx) return SUISettings:readSetting(pfx .. HEADER_WEIGHT_KEY) or "bold" end

local function getActiveStatsDict(pfx)
    local d = SUISettings:readSetting(pfx .. ACTIVE_STATS_KEY)
    if type(d) ~= "table" then
        d = {}
        for k, _ in pairs(_STAT_LABELS) do d[k] = true end
    end
    return d
end

local function _resolveStatOrder(saved)
    if type(saved) ~= "table" or #saved == 0 then return _DEFAULT_STAT_ORDER end
    local seen, result = {}, {}
    for _, v in ipairs(saved) do
        if _STAT_LABELS[v] and not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    for _, v in ipairs(_DEFAULT_STAT_ORDER) do
        if not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Text Formatting & Translation Normalizers
-- ---------------------------------------------------------------------------
local function fmtCount(n)
    if n == nil then return "" end
    return util.getFormattedSize(n)
end

local function emptyVal() return { value = "", unit = "" } end
local function fmtFraction(a, b) return string.format("%s/%s", fmtCount(a), fmtCount(b)) end

local function fmtTimeHuman(secs)
    if not secs or secs ~= secs then return emptyVal() end
    if secs <= 0 then return { value = fmtCount(0), unit = _("min") } end
    local mins = Math.round(secs / 60)
    if mins <= 0 then return { value = fmtCount(0), unit = _("min") }
    elseif mins < 60 then return { value = fmtCount(mins), unit = _("min") } end
    local h = mins / 60
    local val = (h < 100) and string.format("%.1f", h) or string.format("%.0f", h)
    return { value = val, unit = _("hours") }
end

local function fmtTimeXhym(secs)
    if not secs or secs ~= secs then return emptyVal() end
    local mins = Math.round(secs / 60)
    if mins <= 0 then return { value = _("0 min"), unit = "" } end
    local h = math.floor(mins / 60)
    local m = mins % 60
    return { value = (h > 0) and string.format(_("%dh %02d min"), h, m) or string.format(_("%d min"), m), unit = "" }
end

local function pickFormatter(pfx) return (getTimeFmt(pfx) == FMT_XHYM) and fmtTimeXhym or fmtTimeHuman end

local function humanDayCount(days, kind)
    local n = math.max(0, tonumber(days) or 0)
    local unit = "day"
    if n >= 60 then unit = "month"; n = math.floor((n + 15) / 30)
    elseif n >= 14 then unit = "week"; n = math.floor((n + 3) / 7) end
    local labels = {
        reading = { day = { _("days read") }, week = { _("weeks read") }, month = { _("months read") } },
        to_go   = { day = { _("days left") }, week = { _("weeks left") }, month = { _("months left") } },
    }
    local group = labels[kind] or labels.to_go
    local pair  = group[unit]  or group.day
    return { value = fmtCount(n), unit = pair[1] }
end

local function resolveFontFace(fam, is_bold)
    if fam == "NotoSerif" then return is_bold and "NotoSerif-Bold.ttf" or "NotoSerif-Regular.ttf" end
    if fam == "NotoSans" then return is_bold and "NotoSans-Bold.ttf" or "NotoSans-Regular.ttf" end
    if fam == "LinLibertine" then return is_bold and "LinLibertine_RB.ttf" or "LinLibertine_R.ttf" end
    if fam == "tfont" then return "tfont" end
    if fam == "x_smallinfofont" then return "x_smallinfofont" end
    return is_bold and "NotoSerif-Bold.ttf" or "NotoSerif-Regular.ttf"
end

local function truncateTitle(title)
    if not title then return title end
    local count, i = 0, 1
    while i <= #title do
        local byte    = title:byte(i)
        local charLen = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        count = count + 1
        if count > 60 then return title:sub(1, i - 1) .. "…" end
        i = i + charLen
    end
    return title
end

-- ---------------------------------------------------------------------------
-- SQLite Statistics Database Connection & Engine
-- ---------------------------------------------------------------------------
local function getMaxSec()
    local ok, max = pcall(function() return tonumber(G_reader_settings:readSetting("statistics").max_sec) end)
    return (ok and max and max > 0) and max or 120
end

local function openStatsDB()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn
    pcall(function() conn = SQ3.open(path) end)
    return conn
end

local function dbGetBookId(conn, md5)
    if not md5 then return nil end
    local id
    pcall(function() id = conn:rowexec(string.format("SELECT id FROM book WHERE md5 = %q LIMIT 1;", md5)) end)
    return id and tonumber(id) or nil
end

local function gatherStats(book, pfx, conn_ext)
    local fmt  = pickFormatter(pfx)
    local zero = fmt(0)
    local s = {
        book_progress      = emptyVal(),
        book_pages_read    = emptyVal(),
        book_time_spent    = zero,
        book_time_left     = zero,
        avg_time_per_day   = zero,
        pages_per_minute   = { value = fmtCount(0), unit = _("pages/min") },
        days_reading       = humanDayCount(0, "reading"),
        days_to_go         = humanDayCount(0, "to_go"),
        mins_per_session   = { value = "-", unit = _("mins/session") },
        pages_last_session = { value = "-", unit = _("pages (last)") }
    }
    
    if not book or not book.md5 then return s end

    local pct      = book.percent or 0
    local pages    = book.pages   or 0
    local cur_page = (pages > 0) and math.max(1, math.floor(pct * pages)) or 0

    if pct > 0 then s.book_progress = { value = string.format("%%%.0f", pct * 100), unit = "" } end
    if pages > 0 then s.book_pages_read = { value = fmtFraction(cur_page, pages), unit = _("read") } end

    local conn = conn_ext or openStatsDB()
    if not conn then return s end

    local book_id = dbGetBookId(conn, book.md5)
    if not book_id then
        if not conn_ext then pcall(function() conn:close() end) end
        return s
    end

    local max_sec = getMaxSec()
    local ts = nil
    local total_days = nil
    local session_cnt = 0
    local last_session_pages = nil

    pcall(function()
        local rows = conn:exec(string.format([[
            WITH ps AS (SELECT page, sum(duration) AS pd FROM page_stat WHERE id_book = %d GROUP BY page)
            SELECT sum(min(pd, %d)), count(*) FROM ps;
        ]], book_id, max_sec))
        
        if rows and rows[1] and rows[1][1] then
            local tt = tonumber(rows[1][1]) or 0
            local rp = tonumber(rows[2] and rows[2][1]) or 0
            ts = { total_time = tt, read_pages = rp, avg_time = (rp > 0 and tt > 0) and (tt / rp) or nil }
        end

        local ndays = conn:rowexec(string.format("SELECT count(*) FROM (SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') FROM page_stat WHERE id_book = %d GROUP BY 1);", book_id))
        total_days = ndays and tonumber(ndays) or nil

        local nses = conn:rowexec(string.format("SELECT count(DISTINCT round(start_time / 3600)) FROM page_stat WHERE id_book = %d", book_id))
        session_cnt = tonumber(nses) or 0

        local q_last = string.format([[
            SELECT count(DISTINCT page) FROM page_stat 
            WHERE id_book = %d AND strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') = 
                (SELECT strftime('%%Y-%%m-%%d', max(start_time), 'unixepoch', 'localtime') FROM page_stat WHERE id_book = %d)
        ]], book_id, book_id)
        last_session_pages = conn:rowexec(q_last)
    end)

    if not conn_ext then pcall(function() conn:close() end) end

    if ts and ts.total_time and ts.total_time > 0 then
        s.book_time_spent = fmt(ts.total_time)
        if session_cnt > 0 then
            s.mins_per_session.value = fmtCount(math.floor(ts.total_time / 60 / session_cnt))
        end
    end

    if last_session_pages then
        s.pages_last_session.value = fmtCount(tonumber(last_session_pages))
    end

    local avg_time   = ts and ts.avg_time
    local pages_left = (pages > 0) and (pages - cur_page) or nil

    if avg_time and avg_time > 0 and pages_left and pages_left > 0 then
        s.book_time_left = fmt(pages_left * avg_time)
    end

    if avg_time and avg_time > 0 then
        local ppm = 60 / avg_time
        s.pages_per_minute = {
            value = (ppm >= 1) and string.format("%.1f", ppm) or string.format("%.2f", ppm),
            unit  = _("pages/min"),
        }
    end

    if total_days and total_days > 0 then
        s.days_reading = humanDayCount(total_days, "reading")
        s.avg_time_per_day = fmt(ts.total_time / total_days)

        if avg_time and avg_time > 0 and pages_left and pages_left > 0 and ts.total_time > 0 then
            local avg_per_day = ts.total_time / total_days
            if avg_per_day > 0 then
                local days_to_finish = math.ceil((pages_left * avg_time) / avg_per_day)
                s.days_to_go = humanDayCount(days_to_finish, "to_go")
            end
        end
    end

    return s
end

local _cache = nil
local _CACHE_TTL = 300 

local function cacheGet(fp, pfx)
    if not _cache then return nil end
    if _cache.fp  ~= fp  then return nil end
    if _cache.pfx ~= pfx then return nil end
    if (os.time() - _cache.ts) > _CACHE_TTL then return nil end
    return _cache.stats
end

local function cachePut(fp, pfx, stats)
    _cache = { fp = fp, pfx = pfx, ts = os.time(), stats = stats }
end

local function buildCustomProgressBar(w, pct, bar_h, scale, lbl_scale, face_inline, fg_color, style)
    local PCT_W   = math.max(16, math.floor(_BASE_PCT_W * scale * lbl_scale))
    local GAP     = math.max(2,  math.floor(_BASE_BAR_PCT_GAP * scale))
    local pct_str = string.format("%.0f%%", (pct or 0) * 100)
    local _face   = face_inline
    local _fg     = fg_color or _CLR_DARK

    local eff_h = bar_h
    if style == "bold" then eff_h = math.floor(bar_h * 1.8) end
    if style == "outline" then eff_h = math.floor(bar_h * 1.5) end
    if style == "segmented" then eff_h = math.floor(bar_h * 1.2) end
    if style == "minimal" then eff_h = math.max(1, math.floor(bar_h * 0.4)) end

    local needs_pct = (style == "with_pct" or style == "bold" or style == "outline" or style == "segmented")
    local bar_w = math.max(10, w - (needs_pct and (GAP + PCT_W) or 0))
    local fw    = math.max(0, math.floor(bar_w * math.min(pct or 0, 1.0)))

    local bar_widget
    if style == "minimal" then
        local dot_r = math.max(3, math.floor(eff_h * 3.5))
        bar_widget = OverlapGroup:new{
            dimen = Geom:new{ w = bar_w, h = dot_r },
            LineWidget:new{ dimen = Geom:new{ w = bar_w, h = eff_h }, background = _CLR_BAR_BG, overlap_offset = {0, math.floor((dot_r - eff_h) / 2)} },
            LineWidget:new{ dimen = Geom:new{ w = dot_r, h = dot_r }, background = _CLR_BAR_FG, overlap_offset = {math.max(0, fw - math.floor(dot_r/2)), 0} },
        }
    elseif style == "outline" then
        bar_widget = OverlapGroup:new{
            dimen = Geom:new{ w = bar_w, h = eff_h },
            LineWidget:new{ dimen = Geom:new{ w = bar_w, h = eff_h }, background = _CLR_BAR_FG },
            LineWidget:new{ dimen = Geom:new{ w = math.max(0, bar_w - 2), h = math.max(0, eff_h - 2) }, background = _CLR_BAR_BG, overlap_offset = {1, 1} },
            LineWidget:new{ dimen = Geom:new{ w = math.max(0, fw - 2), h = math.max(0, eff_h - 2) }, background = _CLR_BAR_FG, overlap_offset = {1, 1} },
        }
    elseif style == "segmented" then
        local segs = {
            dimen = Geom:new{ w = bar_w, h = eff_h },
            LineWidget:new{ dimen = Geom:new{ w = bar_w, h = eff_h }, background = _CLR_BAR_BG },
            LineWidget:new{ dimen = Geom:new{ w = fw, h = eff_h }, background = _CLR_BAR_FG },
        }
        local sc = 10
        local sw = math.max(1, math.floor(2 * scale))
        for i=1, sc-1 do
            segs[#segs+1] = LineWidget:new{ dimen = Geom:new{ w = sw, h = eff_h }, background = Blitbuffer.COLOR_WHITE, overlap_offset = {math.floor((bar_w/sc)*i), 0} }
        end
        bar_widget = OverlapGroup:new(segs)
    else
        bar_widget = (fw <= 0) and LineWidget:new{ dimen = Geom:new{ w = bar_w, h = eff_h }, background = _CLR_BAR_BG }
                    or OverlapGroup:new{
                        dimen = Geom:new{ w = bar_w, h = eff_h },
                        LineWidget:new{ dimen = Geom:new{ w = bar_w, h = eff_h }, background = _CLR_BAR_BG },
                        LineWidget:new{ dimen = Geom:new{ w = fw,    h = eff_h }, background = _CLR_BAR_FG },
                    }
    end

    if needs_pct then
        return HorizontalGroup:new{
            align = "center", bar_widget, HorizontalSpan:new{ width = GAP },
            UI.makeColoredText{ text = pct_str, face = _face, bold = true, fgcolor = _fg, width = PCT_W }
        }
    end
    return HorizontalGroup:new{ align = "center", bar_widget }
end

local function mkSectionHeader(face, text, full_w, bg_color, left_pad, transparent)
    left_pad = left_pad or Size.padding.large
    local tw = TextWidget:new{ text = text, face = face }
    if transparent then
        return VerticalGroup:new{
            align = "left", VerticalSpan:new{ height = Size.padding.small },
            HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = left_pad }, tw },
            VerticalSpan:new{ height = Size.padding.small },
            LineWidget:new{ dimen = Geom:new{ w = full_w, h = Size.line.thick }, background = Blitbuffer.COLOR_BLACK },
        }
    end
    return FrameContainer:new{
        background = bg_color or Blitbuffer.COLOR_GRAY_E, bordersize = 0,
        padding_top = Size.padding.small, padding_bottom = Size.padding.small, padding_left = left_pad, padding_right = 0,
        LeftContainer:new{ dimen = Geom:new{ w = full_w - left_pad, h = tw:getSize().h }, tw },
    }
end

local M = {}

M.id              = "currently_yanllsama"
M.name            = _("Currently Reading (Yanllsama)")
M.label           = _("Currently Reading")
M.description     = _("Enhanced reading dashboard with dynamic grid (1-4 cols, 1-6 rows), customizable headers, rich statistics (10 metrics), and 6 progress bar styles. Tap book/author for description.")
M.default_enabled = false
M.enabled_key     = "currently_yanllsama"
M.default_on      = false
M.has_covers      = true   
M.is_book_mod     = true   
M.needs           = { db = true } 

function M.reset()
    _SH = nil; _SUIStyle = nil; _cache = nil
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Currently Reading"))
    if not ctx.current_fp then return nil end

    local SH = getSH()
    if not SH then return nil end

    local c     = ctx.cfg and ctx.cfg.currently_yanllsama
    local pfx   = ctx.pfx or ""
    local scale = c and c.scale or Config.getModuleScale("currently_yanllsama", pfx)
    local thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently_yanllsama", pfx)
    local lbl_scale   = c and c.lbl_scale   or Config.getItemLabelScale("currently_yanllsama", pfx)
    local bar_style   = c and c.bar_style   or getBarStyle(pfx)
    
    local cols = getGridCols(pfx)
    local rows = getGridRows(pfx)

    local D = SH.getDims(scale, thumb_scale)
    
    local cover_gap      = math.max(0, math.floor(_BASE_COVER_GAP      * scale * (getCoverGapPct(pfx) / 100)))
    local bar_gap_before = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_h          = math.max(1, math.floor(_BASE_BAR_H          * scale))
    local author_gap     = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))

    local prefetched_entry = ctx.prefetched and ctx.prefetched[ctx.current_fp]
    local bd    = SH.getBookData(ctx.current_fp, prefetched_entry)
    local cover = SH.getBookCover(ctx.current_fp, D.COVER_W, D.COVER_H, nil, 0.10)
                  or SH.coverPlaceholder(bd.title, bd.authors, D.COVER_W, D.COVER_H)

    local stats = cacheGet(ctx.current_fp, pfx)
    if not stats then
        local book_meta = {
            fp = ctx.current_fp, title = bd.title or "", md5 = prefetched_entry and prefetched_entry.partial_md5_checksum, percent = bd.percent or 0, pages = bd.pages or 0
        }
        stats = gatherStats(book_meta, pfx, ctx.db_conn)
        cachePut(ctx.current_fp, pfx, stats)
    end

    local _CLR_DARK_EFF = _CLR_DARK
    local CLR_TEXT_SUB_EFF = CLR_TEXT_SUB

    local SS = getSUIStyle()
    if SS then
        _CLR_DARK_EFF = SS.getThemeColor("fg") or _CLR_DARK_EFF
        CLR_TEXT_SUB_EFF = SS.getThemeColor("text_secondary") or _CLR_DARK_EFF
    end

    local val_fg_color = _CLR_DARK_EFF
    local lbl_fg_color = CLR_TEXT_SUB_EFF

    local face_inlinepct = Font:getFace("smallinfofont", math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))
    
    local title_fs = math.max(12, math.floor(getTitleFs(pfx) * scale))
    local author_fs = math.max(10, math.floor(getAuthorFs(pfx) * scale))
    local face_title = Font:getFace(resolveFontFace(getTitleFont(pfx), true), title_fs) or Font:getFace("tfont", title_fs)
    local face_author = Font:getFace(resolveFontFace(getAuthorFont(pfx), false), author_fs) or Font:getFace("tfont", author_fs)

    local val_fs = math.max(12, math.floor(getValFs(pfx) * scale))
    local lbl_fs = math.max(10, math.floor(getLblFs(pfx) * scale))
    local face_v = Font:getFace(resolveFontFace(getValFont(pfx), getValBold(pfx)), val_fs) or Font:getFace("tfont", val_fs)
    local face_l = Font:getFace(resolveFontFace(getLblFont(pfx), getLblBold(pfx)), lbl_fs) or Font:getFace("x_smallinfofont", lbl_fs)

    local left_frame = FrameContainer:new{ bordersize = 0, padding = 0, padding_right = cover_gap, [1] = cover }

    local tw = w - PAD - D.COVER_W - cover_gap - PAD
    
    local ip     = Size.padding.default
    local ig     = Screen:scaleBySize(10)
    local total_isep_w = (ig * 2 + Size.line.medium) * (cols - 1)
    local icol_w   = math.max(1, math.floor((tw - 2 * ip - total_isep_w) / cols))

    local has_wp = ctx.has_wallpaper
    local function make_tbw(args)
        args.fgcolor = args.fgcolor or _CLR_DARK_EFF
        if has_wp and UI and UI.makeAlphaTextBox then return UI.makeAlphaTextBox(args) end
        return TextBoxWidget:new(args)
    end

    local function fitValFace(text, max_w)
        if not text or text == "" then return face_v end
        local fs, min_fs = val_fs, math.max(9, val_fs - 12)
        local face = face_v
        local p_tw = TextWidget:new{ text = text, face = face }
        while p_tw:getSize().w > max_w and fs > min_fs do
            fs = fs - 1
            face = Font:getFace(resolveFontFace(getValFont(pfx), getValBold(pfx)), fs) or Font:getFace("tfont", fs)
            p_tw = TextWidget:new{ text = text, face = face }
        end
        return face
    end

    local function pvline(data, extra)
        if not data or data.value == "" then
            return HorizontalGroup:new{ align = "left", make_tbw({ text = "", face = face_l, width = icol_w }) } 
        end
        local desc = data.unit or ""
        if extra and extra ~= "" then desc = (desc ~= "") and (desc .. " " .. extra) or extra end
        local max_val_w = (desc ~= "") and math.max(1, math.floor(icol_w * 0.55)) or math.max(1, icol_w - Size.padding.small)
        
        local vw = TextWidget:new{ text = data.value, face = fitValFace(data.value, max_val_w), fgcolor = val_fg_color }
        local lbl_w = math.max(1, icol_w - vw:getSize().w - Size.padding.large)
        return HorizontalGroup:new{
            align = "center", vw, HorizontalSpan:new{ width = Size.padding.large },
            make_tbw({ text = desc, face = face_l, width = lbl_w, alignment = "left", fgcolor = lbl_fg_color }),
        }
    end

    local hdr_weight = getHeaderWeight(pfx)
    local hdr_base_fs = math.max(12, math.floor(14 * scale))
    local sec_fs
    if hdr_weight == "thin" then sec_fs = Font:getFace("NotoSerif-Regular.ttf", hdr_base_fs)
    elseif hdr_weight == "medium" then sec_fs = Font:getFace("NotoSans-Regular.ttf", hdr_base_fs)
    else sec_fs = Font:getFace("NotoSans-Bold.ttf", hdr_base_fs) end

    local CLR_HDR_BG = SS and (SS.getThemeColor("muted") or SS.getThemeColor("divider")) or Blitbuffer.COLOR_GRAY_D
    
    local function mkDynamicGrid(items)
        local grid_args = { align = "left" }
        local show_h = getShowHeaders(pfx)

        local col_groups = {}
        for c=1, cols do col_groups[c] = { align = "left" } end
        
        if show_h then
            for c=1, cols do
                local h_txt = getHeaderTxt(pfx, c)
                table.insert(col_groups[c], mkSectionHeader(sec_fs, h_txt, icol_w, CLR_HDR_BG, Size.padding.large, has_wp))
                table.insert(col_groups[c], VerticalSpan:new{ height = Size.padding.default })
            end
        end
        
        for r=1, rows do
            for c=1, cols do
                local idx = (c - 1) * rows + r
                if items[idx] then table.insert(col_groups[c], items[idx]) end
                if r < rows then table.insert(col_groups[c], VerticalSpan:new{ height = Size.padding.default }) end
            end
        end
        
        local hg_args = { align = "top" }
        local rendered_cols = {}
        local max_h = 0
        for c=1, cols do 
            rendered_cols[c] = VerticalGroup:new(col_groups[c])
            max_h = math.max(max_h, rendered_cols[c]:getSize().h)
        end
        
        for c=1, cols do
            table.insert(hg_args, rendered_cols[c])
            if c < cols then
                table.insert(hg_args, HorizontalSpan:new{ width = ig })
                table.insert(hg_args, LineWidget:new{ dimen = Geom:new{ w = Size.line.medium, h = max_h }, background = Blitbuffer.COLOR_GRAY })
                table.insert(hg_args, HorizontalSpan:new{ width = ig })
            end
        end
        table.insert(grid_args, HorizontalGroup:new(hg_args))
        return VerticalGroup:new(grid_args)
    end

    local right_top = VerticalGroup:new{ align = "left" }

    local title_wid = make_tbw({
        text      = truncateTitle(bd.title) or "?", face      = face_title,
        bold      = true, width     = tw, max_lines = 2, fgcolor   = _CLR_DARK_EFF,
    })

    local ta_group_items = { align = "left", [1] = title_wid }

    if bd.authors and bd.authors ~= "" then
        table.insert(ta_group_items, VerticalSpan:new{ height = author_gap })
        local auth_wid = UI.makeColoredText{
            text = bd.authors, face = face_author, fgcolor = CLR_TEXT_SUB_EFF,
            width = tw, max_width = tw, truncation_char = "…",
        }
        table.insert(ta_group_items, auth_wid)
    end

    local ta_group = VerticalGroup:new(ta_group_items)

    local info_tap_container = InputContainer:new{
        dimen = Geom:new{ w = tw, h = ta_group:getSize().h },
        [1] = ta_group
    }
    info_tap_container.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return info_tap_container.dimen end } }
    }
    function info_tap_container:onTap()
        local InfoMessage = require("ui/widget/infomessage")
        local desc = (bd.description and bd.description ~= "") and bd.description or _("Bu kitap hakkında ek açıklama bulunmamaktadır.")
        UIManager:show(InfoMessage:new{ text = desc })
        return true
    end

    table.insert(right_top, info_tap_container)
    table.insert(right_top, VerticalSpan:new{ height = Size.padding.large })

    local pages_left_data = { value = "", unit = "" }
    local total_p = bd.pages or 0
    if total_p > 0 then
        local cur_p = math.max(1, math.floor((bd.percent or 0) * total_p))
        local rem_p = math.max(0, total_p - cur_p)
        pages_left_data = { value = tostring(rem_p), unit = _("pages") }
    end

    local stat_defs = {
        book_time_spent    = { data = stats.book_time_spent, extra = _("read") },
        book_pages_read    = { data = stats.book_pages_read, extra = "" },
        book_time_left     = { data = stats.book_time_left,  extra = _("left") },
        pages_left         = { data = pages_left_data,       extra = _("left") },
        days_reading       = { data = stats.days_reading,    extra = "" },
        days_to_go         = { data = stats.days_to_go,      extra = "" },
        avg_time_per_day   = { data = stats.avg_time_per_day,extra = _("a day") },
        pages_per_minute   = { data = stats.pages_per_minute,extra = "" },
        mins_per_session   = { data = stats.mins_per_session,extra = "" },
        pages_last_session = { data = stats.pages_last_session, extra = "" },
    }

    local active_items = {}
    local active_dict = getActiveStatsDict(pfx)
    local max_items = cols * rows
    for _, key in ipairs(_resolveStatOrder(SUISettings:readSetting(pfx .. STAT_ORDER_KEY))) do
        if stat_defs[key] and active_dict[key] and #active_items < max_items then
            table.insert(active_items, pvline(stat_defs[key].data, stat_defs[key].extra))
        end
    end

    table.insert(right_top, mkDynamicGrid(active_items))

    local current_right_h = right_top:getSize().h
    local safe_min_gap = math.max(bar_gap_before * 3, Size.padding.large * 2) 
    local dynamic_bottom_gap = math.max(safe_min_gap, D.COVER_H - current_right_h - bar_h)

    local bar_widget
    if bar_style == "simple" then
        bar_widget = SH.progressBar(tw, bd.percent, bar_h)
    else
        bar_widget = buildCustomProgressBar(tw, bd.percent, bar_h, scale, lbl_scale, face_inlinepct, _CLR_DARK_EFF, bar_style)
    end

    local right_col = VerticalGroup:new{
        align = "left", [1] = right_top, [2] = VerticalSpan:new{ height = dynamic_bottom_gap }, [3] = bar_widget
    }

    local left_h = D.COVER_H
    local content_h = math.max(left_h, right_col:getSize().h)

    local left_wrapper  = LeftContainer:new{ dimen = Geom:new{ w = D.COVER_W + cover_gap, h = content_h }, [1] = left_frame }
    local right_wrapper = LeftContainer:new{ dimen = Geom:new{ w = tw, h = content_h }, [1] = right_col }

    local row = HorizontalGroup:new{ align = "top", [1] = left_wrapper, [2] = right_wrapper }
    
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = content_h }, _fp = ctx.current_fp, _open_fn = ctx.open_fn,
        [1] = FrameContainer:new{ bordersize = 0, padding = 0, padding_left = PAD, padding_right = PAD, [1] = row },
    }
    tappable.ges_events = { TapBook = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } } }
    
    tappable._cover_slots = { { container = left_frame, idx = 1, fp = ctx.current_fp, w = D.COVER_W, h = D.COVER_H, align = nil, stretch = 0.10 } }
    
    function tappable:onTapBook()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    if ctx.kb_currently_focused then
        local bw = Screen:scaleBySize(3)
        return OverlapGroup:new{
            dimen = Geom:new{ w = w, h = content_h }, tappable,
            LineWidget:new{ dimen = Geom:new{ w = w, h = bw }, background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = w, h = bw }, background = _CLR_DARK_EFF, overlap_offset = {0, content_h - bw} },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = content_h }, background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = content_h }, background = _CLR_DARK_EFF, overlap_offset = {w - bw, 0} },
        }
    end

    return tappable
end

function M.updateCovers(widget, _ctx)
    local tappable = (widget._cover_slots) and widget or (widget[1] and widget[1]._cover_slots and widget[1])
    if not tappable or not tappable._cover_slots then return true end

    local SH = getSH()
    if not SH then return true end

    local all_done = true
    for _, slot in ipairs(tappable._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then all_done = false end
    end
    return all_done
end

function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH() end
    local pfx   = _ctx and _ctx.pfx or ""
    local scale = Config.getModuleScale("currently_yanllsama", pfx)
    local thumb_scale = Config.getThumbScale("currently_yanllsama", pfx)
    local cols = getGridCols(pfx)
    local rows = getGridRows(pfx)
    local show_h = getShowHeaders(pfx)
    local D     = SH.getDims(scale, thumb_scale)
    
    local title_approx  = ((getTitleFs(pfx) or 24) * scale) * 2.5
    local author_approx = ((getAuthorFs(pfx) or 20) * scale) * 1.5
    local max_fs = math.max(getValFs(pfx), getLblFs(pfx))
    local row_h = Screen:scaleBySize(max_fs + 8) * scale
    
    local spans = (Size.padding.default * rows) * scale
    
    local header_approx = 0
    if show_h then
        header_approx = (Screen:scaleBySize(22) * scale) + (Size.padding.default * scale)
    end
    
    local safe_min_gap = math.max(math.floor(_BASE_BAR_GAP_BEFORE * scale) * 3, math.floor(Size.padding.large * scale) * 2)
    local bar_approx = safe_min_gap + math.floor(_BASE_BAR_H * scale)
    
    local right_h = title_approx + author_approx + header_approx + (row_h * rows) + spans + bar_approx
    local left_h  = D.COVER_H

    return Config.getScaledLabelH() + math.max(left_h, right_h)
end

local function moveItem(list, item, dir)
    local idx = nil
    for i, v in ipairs(list) do 
        if v == item then idx = i; break end 
    end
    if not idx then return list end
    if dir == "up" and idx > 1 then list[idx], list[idx-1] = list[idx-1], list[idx]
    elseif dir == "down" and idx < #list then list[idx], list[idx+1] = list[idx+1], list[idx] end
    return list
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx or ""
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local SortWidget = require("ui/widget/sortwidget")
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")

    local font_options = {
        { name = "NotoSerif", label = "Noto Serif" },
        { name = "NotoSans", label = "Noto Sans" },
        { name = "LinLibertine", label = "Linux Libertine" },
        { name = "tfont", label = _lc("System UI Font") }
    }
    
    local function makeFontMenu(key_name, default_val)
        local sub = {}
        for _, opt in ipairs(font_options) do
            table.insert(sub, {
                text = opt.label, radio = true, keep_menu_open = true,
                checked_func = function() return (SUISettings:readSetting(pfx .. key_name) or default_val) == opt.name end,
                callback = function() SUISettings:saveSetting(pfx .. key_name, opt.name) refresh() end,
            })
        end
        return sub
    end

    local function makeSizeMenu(key_name, default_val, max_val, step)
        local sub = {}
        for fs = 12, (max_val or 44), (step or 2) do
            table.insert(sub, {
                text = tostring(fs) .. (fs == default_val and _lc(" (Default)") or ""), radio = true, keep_menu_open = true,
                checked_func = function() return (tonumber(SUISettings:readSetting(pfx .. key_name)) or default_val) == fs end,
                callback = function() SUISettings:saveSetting(pfx .. key_name, fs) refresh() end,
            })
        end
        return sub
    end

    local function makeCountMenu(key_name, min_val, max_val, default_val)
        local sub = {}
        for n = min_val, max_val do
            table.insert(sub, {
                text = tostring(n) .. (n == default_val and _lc(" (Default)") or ""), radio = true, keep_menu_open = true,
                checked_func = function() return (tonumber(SUISettings:readSetting(pfx .. key_name)) or default_val) == n end,
                callback = function() SUISettings:saveSetting(pfx .. key_name, n) refresh() end,
            })
        end
        return sub
    end

    local toggle_items = {}
    local active_dict = getActiveStatsDict(pfx)
    for _, key in ipairs(_resolveStatOrder(SUISettings:readSetting(pfx .. STAT_ORDER_KEY))) do
        table.insert(toggle_items, {
            text_func = function()
                local d = getActiveStatsDict(pfx)
                return (d[key] and "[✔] " or "[✗] ") .. (_STAT_LABELS[key] or key)
            end,
            keep_menu_open = true,
            callback = function()
                local d = getActiveStatsDict(pfx)
                d[key] = not d[key]
                SUISettings:saveSetting(pfx .. ACTIVE_STATS_KEY, d)
                refresh()
            end
        })
    end

    return {
        Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end, enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"), info = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct("currently_yanllsama", pfx) end, set = function(v) Config.setModuleScale(v, "currently_yanllsama", pfx) end, refresh = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() return _lc("Cover size") end, title = _lc("Cover size"), info = _lc("Scale for the cover thumbnail only.\n100% is the default size."),
            get       = function() return Config.getThumbScalePct("currently_yanllsama", pfx) end, set = function(v) Config.setThumbScale(v, "currently_yanllsama", pfx) end, refresh   = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() local pct = getCoverGapPct(pfx); return pct == 100 and _lc("Cover Spacing") or string.format("%s (%d%%)", _lc("Cover Spacing"), pct) end,
            separator = true, title = _lc("Cover Spacing"), info = _lc("Horizontal space between the cover and the text.\n100% is the default spacing."),
            get       = function() return getCoverGapPct(pfx) end, set = function(v) SUISettings:saveSetting(pfx .. COVER_GAP_KEY, v) end, refresh   = refresh, value_min = 0, value_max = 300, value_step = 10, default_value = 100,
        }),
        Config.makeLabelToggleItem("currently_yanllsama", _("Currently Reading"), refresh, _lc),
        
        {
            text = _lc("Statistics Layout & Appearance"),
            sub_item_table = {
                {
                    text = _lc("Progress bar style"),
                    sub_item_table = {
                        { text = _lc("Simple"), radio = true, keep_menu_open = true, checked_func = function() return getBarStyle(pfx) == "simple" end, callback = function() SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "simple") refresh() end },
                        { text = _lc("With percentage"), radio = true, keep_menu_open = true, checked_func = function() return getBarStyle(pfx) == "with_pct" end, callback = function() SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "with_pct") refresh() end },
                        { text = _lc("Bold"), radio = true, keep_menu_open = true, checked_func = function() return getBarStyle(pfx) == "bold" end, callback = function() SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "bold") refresh() end },
                        { text = _lc("Minimal"), radio = true, keep_menu_open = true, checked_func = function() return getBarStyle(pfx) == "minimal" end, callback = function() SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "minimal") refresh() end },
                        { text = _lc("Outline"), radio = true, keep_menu_open = true, checked_func = function() return getBarStyle(pfx) == "outline" end, callback = function() SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "outline") refresh() end },
                        { text = _lc("Segmented"), radio = true, keep_menu_open = true, checked_func = function() return getBarStyle(pfx) == "segmented" end, callback = function() SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "segmented") refresh() end },
                    },
                },
                {
                    text_func = function() local fmt = getTimeFmt(pfx); local lbl = (fmt == FMT_XHYM) and "XhYm" or _lc("Readable"); return string.format("%s \u{2014} %s", _lc("Time Format"), lbl) end,
                    sub_item_table = {
                        { text = _lc("Readable (e.g., 3.5 hours)"), radio = true, keep_menu_open = true, checked_func = function() return getTimeFmt(pfx) ~= FMT_XHYM end, callback = function() SUISettings:saveSetting(pfx .. SK_TIME_FMT, FMT_NICKEL) refresh() end },
                        { text = _lc("XhYm (e.g., 3h 30 min)"), radio = true, keep_menu_open = true, checked_func = function() return getTimeFmt(pfx) == FMT_XHYM end, callback = function() SUISettings:saveSetting(pfx .. SK_TIME_FMT, FMT_XHYM) refresh() end },
                    },
                },
                {
                    text = _lc("Edit Items"),
                    sub_item_table = {
                        { text = _lc("Toggle Visibility"), sub_item_table = toggle_items },
                        {
                            text = _lc("Sort Items"), keep_menu_open = true,
                            callback = function()
                                local sort_items = {}
                                for _, key in ipairs(_resolveStatOrder(SUISettings:readSetting(pfx .. STAT_ORDER_KEY))) do
                                    table.insert(sort_items, { text = _STAT_LABELS[key] or key, orig_item = key })
                                end
                                UIManager:show(SortWidget:new{
                                    title = _lc("Sort Statistics"), item_table = sort_items, covers_fullscreen = true,
                                    callback = function()
                                        local new_order = {}
                                        for _, item in ipairs(sort_items) do table.insert(new_order, item.orig_item) end
                                        SUISettings:saveSetting(pfx .. STAT_ORDER_KEY, new_order) refresh()
                                    end,
                                })
                            end,
                        }
                    }
                },
                {
                    text = _lc("Category Headers"),
                    sub_item_table = {
                        {
                            text_func = function() return getShowHeaders(pfx) and _lc("Show Headers: On") or _lc("Show Headers: Off") end,
                            keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. SHOW_HEADERS_KEY, not getShowHeaders(pfx)) refresh() end,
                        },
                        {
                            text = _lc("Header Thickness"),
                            sub_item_table = {
                                { text = _lc("Thin"), radio = true, keep_menu_open = true, checked_func = function() return getHeaderWeight(pfx) == "thin" end, callback = function() SUISettings:saveSetting(pfx .. HEADER_WEIGHT_KEY, "thin") refresh() end },
                                { text = _lc("Medium"), radio = true, keep_menu_open = true, checked_func = function() return getHeaderWeight(pfx) == "medium" end, callback = function() SUISettings:saveSetting(pfx .. HEADER_WEIGHT_KEY, "medium") refresh() end },
                                { text = _lc("Bold"), radio = true, keep_menu_open = true, checked_func = function() return getHeaderWeight(pfx) == "bold" end, callback = function() SUISettings:saveSetting(pfx .. HEADER_WEIGHT_KEY, "bold") refresh() end },
                            }
                        },
                        {
                            text = _lc("Change Column 1 Header"),
                            callback = function()
                                local dlg
                                dlg = InputDialog:new{
                                    title = _lc("Column 1 Header"), input = getHeaderTxt(pfx, 1),
                                    buttons = {{
                                        { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
                                        { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. HEADER_TXT_PFX .. "1", dlg:getInputText()); UIManager:close(dlg); refresh() end },
                                    }},
                                }
                                UIManager:show(dlg)
                                dlg:onShowKeyboard()
                            end,
                        },
                        {
                            text = _lc("Change Column 2 Header"),
                            callback = function()
                                local dlg
                                dlg = InputDialog:new{
                                    title = _lc("Column 2 Header"), input = getHeaderTxt(pfx, 2),
                                    buttons = {{
                                        { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
                                        { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. HEADER_TXT_PFX .. "2", dlg:getInputText()); UIManager:close(dlg); refresh() end },
                                    }},
                                }
                                UIManager:show(dlg)
                                dlg:onShowKeyboard()
                            end,
                        },
                        {
                            text = _lc("Change Column 3 Header"),
                            callback = function()
                                local dlg
                                dlg = InputDialog:new{
                                    title = _lc("Column 3 Header"), input = getHeaderTxt(pfx, 3),
                                    buttons = {{
                                        { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
                                        { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. HEADER_TXT_PFX .. "3", dlg:getInputText()); UIManager:close(dlg); refresh() end },
                                    }},
                                }
                                UIManager:show(dlg)
                                dlg:onShowKeyboard()
                            end,
                        },
                        {
                            text = _lc("Change Column 4 Header"),
                            callback = function()
                                local dlg
                                dlg = InputDialog:new{
                                    title = _lc("Column 4 Header"), input = getHeaderTxt(pfx, 4),
                                    buttons = {{
                                        { text = _lc("Cancel"), callback = function() UIManager:close(dlg) end },
                                        { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. HEADER_TXT_PFX .. "4", dlg:getInputText()); UIManager:close(dlg); refresh() end },
                                    }},
                                }
                                UIManager:show(dlg)
                                dlg:onShowKeyboard()
                            end,
                        },
                    }
                },
                {
                    text = _lc("Grid Dimensions"),
                    sub_item_table = {
                        { text = _lc("Columns"), sub_item_table = makeCountMenu(GRID_COLS_KEY, 1, 4, 2) },
                        { text = _lc("Rows"), sub_item_table = makeCountMenu(GRID_ROWS_KEY, 1, 6, 4) },
                    },
                },
                {
                    text = _lc("Book and Author Settings"), separator = true,
                    sub_item_table = {
                        { text = _lc("Book Title Font"), sub_item_table = makeFontMenu(TITLE_FONT_KEY, "NotoSerif") },
                        { text = _lc("Book Title Size"), sub_item_table = makeSizeMenu(TITLE_FS_KEY, 24, 60, 2) },
                        { text = _lc("Author Name Font"), sub_item_table = makeFontMenu(AUTHOR_FONT_KEY, "NotoSerif") },
                        { text = _lc("Author Name Size"), sub_item_table = makeSizeMenu(AUTHOR_FS_KEY, 20, 60, 2) },
                    }
                },
                {
                    text = _lc("Number (Data) Settings"),
                    sub_item_table = {
                        { text = _lc("Number Font"), sub_item_table = makeFontMenu(VAL_FONT_KEY, "NotoSerif") },
                        { text = _lc("Number Size"), sub_item_table = makeSizeMenu(VAL_FS_KEY, 30, 60, 2) },
                        { text_func = function() return getValBold(pfx) and _lc("Weight: Bold") or _lc("Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. VAL_BOLD_KEY, not getValBold(pfx)) refresh() end },
                    }
                },
                {
                    text = _lc("Label (Text) Settings"),
                    sub_item_table = {
                        { text = _lc("Label Font"), sub_item_table = makeFontMenu(LBL_FONT_KEY, "x_smallinfofont") },
                        { text = _lc("Label Size"), sub_item_table = makeSizeMenu(LBL_FS_KEY, 16, 60, 2) },
                        { text_func = function() return getLblBold(pfx) and _lc("Weight: Bold") or _lc("Weight: Normal") end, keep_menu_open = true, callback = function() SUISettings:saveSetting(pfx .. LBL_BOLD_KEY, not getLblBold(pfx)) refresh() end },
                    }
                }
            }
        },
        {
            text_func = function()
                local raw = SUISettings:readSetting(pfx .. SK_EXCLUDE_PATHS) or ""
                if raw == "" then return _lc("Exclude Paths from Recents") end
                local n = 0; for _ in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _lc("Exclude Paths from Recents"), n)
            end,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local raw = SUISettings:readSetting(pfx .. SK_EXCLUDE_PATHS) or ""
                local dlg; dlg = InputDialog:new{
                    title       = _lc("Exclude Paths from Recents"), input       = raw, input_hint  = "/mnt/onboard/rss, instapaper", description = _lc("Comma separated path fragments.\nBooks containing any of these fragments in their path will be skipped."), allow_newline = false,
                    buttons = {{ text = _lc("Cancel"), callback = function() UIManager:close(dlg) end }, { text = _lc("Save"), is_enter_default = true, callback = function() SUISettings:saveSetting(pfx .. SK_EXCLUDE_PATHS, dlg:getInputText()); _cache = nil; UIManager:close(dlg); refresh() end }},
                }
                UIManager:show(dlg) dlg:onShowKeyboard()
            end,
        },
    }
end

return M