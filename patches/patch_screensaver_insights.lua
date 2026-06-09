-- patches/patch_screensaver_insights.lua — SimpleUI Extra Modules
--
-- Adds a "Show Reading Insights on sleep screen" option to the Wallpaper
-- (sleep screen) settings.  When active, one of the three Reading Insights
-- pages is rendered as a static snapshot and shown as the screensaver.
-- Page 0 (default) picks a different page at random each sleep cycle.
--
-- CONTRACT (required by main.lua's patch discovery):
--   P.id              string  — unique identifier
--   P.apply           func()  — called once after SimpleUI has initialised
--   P.name            string  — display name
--   P.description     string  — help text
--   P.default_enabled bool    — first-run default (false = opt-in)
--
-- PAGES
--   1 — Today's Summary + Day Streak + Week Streak
--   2 — Last 7 Days / This Week / This Month
--   3 — All Time + Year Chart
--
-- SETTING KEYS
--   screensaver_type              "simpleui_insights"
--   screensaver_insights_page     0–3  (0 = random each time, default 0)

local logger = require("logger")
local _      = require("gettext")
local T      = require("ffi/util").template

local PATCH_ID   = "screensaver_insights"
local TYPE_VALUE = "simpleui_insights"
local SK_TYPE    = "screensaver_type"
local SK_PAGE    = "screensaver_insights_page"
local MAX_PAGE   = 3

local P = {}
P.id              = PATCH_ID
P.name            = "Sleep Screen: Reading Insights"
P.description     = "Adds a 'Show Reading Insights' option to the sleep screen Wallpaper settings"
P.default_enabled = false

local _applied = false

function P.apply()
    if _applied then return end
    _applied = true

    -- ── 1. screensaver_menu injection ─────────────────────────────────────
    local function _injectIntoMenuTable(tbl)
        if not (type(tbl) == "table"
                and type(tbl[1]) == "table"
                and type(tbl[1].sub_item_table) == "table") then
            logger.warn("screensaver_insights: unexpected screensaver_menu structure")
            return
        end
        local sub = tbl[1].sub_item_table
        local insert_before = #sub + 1
        for i, item in ipairs(sub) do
            if item.radio and item.separator then insert_before = i; break end
        end

        -- Radio item: activate this screensaver type.
        table.insert(sub, insert_before, {
            text = _("Show Reading Insights on sleep screen"),
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
                local page = G_reader_settings:readSetting(SK_PAGE) or 0
                if page == 0 then return _("Insights page: Random") end
                return T(_("Insights page: %1"), page)
            end,
            enabled_func = function()
                return G_reader_settings:readSetting(SK_TYPE) == TYPE_VALUE
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager2 = require("ui/uimanager")
                UIManager2:show(SpinWidget:new{
                    title_text      = _("Insights page"),
                    info_text       = _("Which Reading Insights page to show on the sleep screen.\n0 = a different random page each time."),
                    value           = G_reader_settings:readSetting(SK_PAGE) or 0,
                    value_min       = 0,
                    value_max       = MAX_PAGE,
                    value_step      = 1,
                    value_hold_step = 1,
                    default_value   = 0,
                    ok_text         = _("Set page"),
                    callback        = function(w)
                        G_reader_settings:saveSetting(SK_PAGE, w.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        })
    end

    -- ── 2. Widget & device dependencies (loaded once at apply time) ────────
    local Device          = require("device")
    local Screen          = Device.screen
    local bit             = require("bit")
    local UIManager       = require("ui/uimanager")
    local Blitbuffer      = require("ffi/blitbuffer")
    local SSWidget        = require("ui/widget/screensaverwidget")
    local ffiUtil         = require("ffi/util")
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")
    local VG              = require("ui/widget/verticalgroup")
    local VS              = require("ui/widget/verticalspan")
    local HG              = require("ui/widget/horizontalgroup")
    local HS              = require("ui/widget/horizontalspan")
    local FC              = require("ui/widget/container/framecontainer")
    local CC              = require("ui/widget/container/centercontainer")
    local LC              = require("ui/widget/container/leftcontainer")
    local RC              = require("ui/widget/container/rightcontainer")
    local BC              = require("ui/widget/container/bottomcontainer")
    local TW              = require("ui/widget/textwidget")
    local LW              = require("ui/widget/linewidget")
    local ImageWidget     = require("ui/widget/imagewidget")
    local Size            = require("ui/size")

    local ok_sty, SUIStyle = pcall(require, "sui_style")
    if not ok_sty or not SUIStyle then
        logger.warn("screensaver_insights: sui_style unavailable — aborting")
        return
    end
    local ok_cfg, Config = pcall(require, "sui_config")
    if not ok_cfg or not Config then
        logger.warn("screensaver_insights: sui_config unavailable — aborting")
        return
    end
    local ok_ui, UI = pcall(require, "sui_core")
    local SIDE_PAD  = (ok_ui and UI and UI.SIDE_PAD) or Screen:scaleBySize(16)

    local CLR_BLACK  = Blitbuffer.COLOR_BLACK
    local CLR_BORDER = Blitbuffer.gray(0.72)

    -- ── 3. DB helpers ──────────────────────────────────────────────────────
    local function _withStatsDb(fallback, fn)
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then return fallback end
        local db_path = Config.getStatsDbPath()
        if lfs.attributes(db_path, "mode") ~= "file" then return fallback end
        local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
        if not ok_sq3 or not SQ3 then return fallback end
        local ok_conn, conn = pcall(SQ3.open, db_path)
        if not ok_conn or not conn then return fallback end
        local ok_fn, result = pcall(fn, conn)
        pcall(conn.close, conn)
        return ok_fn and result or fallback
    end

    local function _withStmt(conn, sql, fn)
        local ok_prep, stmt = pcall(conn.prepare, conn, sql)
        if not ok_prep or not stmt then return end
        local ok_fn = pcall(fn, stmt)
        pcall(stmt.close, stmt)
        return ok_fn
    end

    -- ── 4. Formatters ──────────────────────────────────────────────────────
    local function fmtHours(secs)
        secs = math.floor(secs or 0)
        if secs < 60 then return "0h" end
        local h = math.floor(secs / 3600); local m = math.floor((secs % 3600) / 60)
        if h > 0 and m > 0 then return h.."h "..m.."m"
        elseif h > 0        then return h.."h"
        else                     return m.."m" end
    end

    local function fmtCount(n)
        n = math.floor(n or 0)
        return tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    end

    local function fmtDate(ts)
        if not ts or ts <= 0 then return "–" end
        return os.date("%d %b '%y", ts)
    end

    local function plural(n, sing, plur) return n == 1 and sing or plur end

    -- ── 5. Data fetchers ───────────────────────────────────────────────────

    local function getYearRange()
        local cur = tonumber(os.date("%Y"))
        return _withStatsDb({ min_year = cur, max_year = cur }, function(conn)
            local r = { min_year = cur, max_year = cur }
            _withStmt(conn, [[
                SELECT MIN(strftime('%Y',start_time,'unixepoch','localtime')),
                       MAX(strftime('%Y',start_time,'unixepoch','localtime'))
                FROM page_stat
            ]], function(stmt)
                for row in stmt:rows() do
                    if row[1] then r.min_year = tonumber(row[1]) or cur end
                    if row[2] then r.max_year = tonumber(row[2]) or cur end
                end
            end)
            return r
        end)
    end

    local function getTodayStats()
        return _withStatsDb({ seconds = 0, pages = 0 }, function(conn)
            local s   = { seconds = 0, pages = 0 }
            local now = os.time(); local t = os.date("*t")
            local mid = now - (t.hour * 3600 + t.min * 60 + t.sec)
            _withStmt(conn, string.format([[
                SELECT count(DISTINCT page||'@'||id_book), sum(duration)
                FROM page_stat_data WHERE start_time>=%d AND duration>0
            ]], mid), function(stmt)
                for row in stmt:rows() do
                    s.pages = tonumber(row[1]) or 0; s.seconds = tonumber(row[2]) or 0
                end
            end)
            return s
        end)
    end

    local function getLastWeekStats()
        return _withStatsDb({ avg_seconds = 0, avg_pages = 0 }, function(conn)
            local r  = { avg_seconds = 0, avg_pages = 0 }
            local now = os.time(); local t = os.date("*t")
            local mid = now - (t.hour * 3600 + t.min * 60 + t.sec)
            _withStmt(conn, string.format([[
                WITH d AS (
                    SELECT sum(duration) sd, count(DISTINCT page||'@'||id_book) pg
                    FROM page_stat_data WHERE start_time>=%d AND duration>0
                    GROUP BY date(start_time,'unixepoch','localtime')
                )
                SELECT sum(sd), sum(pg) FROM d
            ]], mid - 6 * 86400), function(stmt)
                for row in stmt:rows() do
                    r.avg_seconds = math.floor((tonumber(row[1]) or 0) / 7)
                    r.avg_pages   = math.floor((tonumber(row[2]) or 0) / 7)
                end
            end)
            return r
        end)
    end

    local function getThisWeekStats()
        return _withStatsDb({ seconds = 0, pages = 0 }, function(conn)
            local s   = { seconds = 0, pages = 0 }
            local now = os.time(); local t = os.date("*t")
            local mid = now - (t.hour * 3600 + t.min * 60 + t.sec)
            local ws  = mid - ((t.wday + 5) % 7) * 86400
            _withStmt(conn, string.format([[
                WITH d AS (
                    SELECT sum(duration) sd, count(DISTINCT page||'@'||id_book) pg
                    FROM page_stat_data WHERE start_time>=%d AND duration>0
                    GROUP BY date(start_time,'unixepoch','localtime')
                )
                SELECT COALESCE(sum(sd),0), COALESCE(sum(pg),0) FROM d
            ]], ws), function(stmt)
                for row in stmt:rows() do
                    s.seconds = tonumber(row[1]) or 0; s.pages = tonumber(row[2]) or 0
                end
            end)
            return s
        end)
    end

    local function getThisMonthStats()
        return _withStatsDb({ seconds = 0, pages = 0 }, function(conn)
            local s  = { seconds = 0, pages = 0 }
            local t  = os.date("*t")
            local ms = os.time{ year=t.year, month=t.month, day=1, hour=0, min=0, sec=0 }
            _withStmt(conn, string.format([[
                WITH d AS (
                    SELECT sum(duration) sd, count(DISTINCT page||'@'||id_book) pg
                    FROM page_stat_data WHERE start_time>=%d AND duration>0
                    GROUP BY date(start_time,'unixepoch','localtime')
                )
                SELECT COALESCE(sum(sd),0), COALESCE(sum(pg),0) FROM d
            ]], ms), function(stmt)
                for row in stmt:rows() do
                    s.seconds = tonumber(row[1]) or 0; s.pages = tonumber(row[2]) or 0
                end
            end)
            return s
        end)
    end

    local function getAllTimeStats()
        local r = { hours = 0, pages = 0, book_count = 0 }
        _withStatsDb(nil, function(conn)
            _withStmt(conn, [[
                SELECT COUNT(*) FROM (SELECT 1 FROM page_stat GROUP BY id_book,page)
            ]], function(stmt)
                for row in stmt:rows() do r.pages = tonumber(row[1]) or 0 end
            end)
            _withStmt(conn, [[
                SELECT SUM(s) FROM (
                    SELECT SUM(duration) s FROM page_stat
                    GROUP BY id_book,page,date(start_time,'unixepoch','localtime')
                )
            ]], function(stmt)
                for row in stmt:rows() do
                    r.hours = math.floor((tonumber(row[1]) or 0) / 3600)
                end
            end)
        end)
        local ok_sp, SP = pcall(require, "desktop_modules/module_stats_provider")
        if ok_sp and SP and SP.get then
            local s = SP.get(nil, os.date("%Y"), true)
            r.book_count = s and s.books_total or 0
        end
        return r
    end

    local function getYearlyStats(year)
        local yr  = tostring(year)
        local def = { days = 0, pages = 0, duration = 0 }
        return _withStatsDb(def, function(conn)
            local s = { days = 0, pages = 0, duration = 0 }
            _withStmt(conn, string.format([[
                SELECT COUNT(DISTINCT date(start_time,'unixepoch','localtime'))
                FROM page_stat
                WHERE strftime('%%Y',start_time,'unixepoch','localtime')='%s'
            ]], yr), function(stmt)
                for row in stmt:rows() do s.days = tonumber(row[1]) or 0 end
            end)
            _withStmt(conn, string.format([[
                SELECT count(*) FROM (
                    SELECT 1 FROM page_stat
                    WHERE strftime('%%Y',start_time,'unixepoch','localtime')='%s'
                    GROUP BY id_book,page
                )
            ]], yr), function(stmt)
                for row in stmt:rows() do s.pages = tonumber(row[1]) or 0 end
            end)
            _withStmt(conn, string.format([[
                SELECT sum(duration) FROM page_stat
                WHERE strftime('%%Y',start_time,'unixepoch','localtime')='%s'
            ]], yr), function(stmt)
                for row in stmt:rows() do s.duration = tonumber(row[1]) or 0 end
            end)
            return s
        end)
    end

    local _MONTH_SHORT = {
        "Jan","Feb","Mar","Apr","May","Jun",
        "Jul","Aug","Sep","Oct","Nov","Dec",
    }

    local function getMonthlyData(year)
        local yr  = tostring(year)
        local def = {}
        for m = 1, 12 do
            def[m] = { month = string.format("%04d-%02d", year, m),
                       days = 0, label = _MONTH_SHORT[m] }
        end
        return _withStatsDb(def, function(conn)
            local by_month = {}
            _withStmt(conn, string.format([[
                SELECT strftime('%%Y-%%m',start_time,'unixepoch','localtime') mo,
                       COUNT(DISTINCT date(start_time,'unixepoch','localtime'))
                FROM page_stat
                WHERE strftime('%%Y',start_time,'unixepoch','localtime')='%s'
                GROUP BY mo
            ]], yr), function(stmt)
                for row in stmt:rows() do by_month[row[1]] = tonumber(row[2]) or 0 end
            end)
            local result = {}
            for m = 1, 12 do
                local key = string.format("%04d-%02d", year, m)
                result[m] = { month = key, days = by_month[key] or 0,
                              label = _MONTH_SHORT[m] }
            end
            return result
        end)
    end

    local function getStreaks()
        local zero = { current=0, best=0, best_start=0, best_end=0 }
        return _withStatsDb({ days = zero, weeks = zero }, function(conn)
            -- Day streaks
            local dates = {}
            _withStmt(conn, [[
                SELECT date(start_time,'unixepoch','localtime') d, min(start_time)
                FROM page_stat GROUP BY d ORDER BY d DESC
            ]], function(stmt)
                for row in stmt:rows() do
                    dates[#dates+1] = { row[1], tonumber(row[2]) }
                end
            end)

            local function parseDMY(s)
                if not s then return end
                local y,m,d = tonumber(s:sub(1,4)),tonumber(s:sub(6,7)),tonumber(s:sub(9,10))
                if y and m and d then return y,m,d end
            end
            local function isConsecDay(prev, curr)
                local y,m,d = parseDMY(prev)
                if not y then return false end
                return curr == os.date("%Y-%m-%d", os.time{year=y,month=m,day=d} - 86400)
            end
            local function calcStreak(entries, isConsec, isCurrent)
                if #entries == 0 then return zero end
                local cur = 0
                if isCurrent(entries[1][1]) then
                    cur = 1
                    for i = 2, #entries do
                        if isConsec(entries[i-1][1], entries[i][1]) then cur = cur + 1
                        else break end
                    end
                end
                local best, run, bs, be, be_tmp = 1, 1, 1, 1, 0
                for i = 2, #entries do
                    if isConsec(entries[i-1][1], entries[i][1]) then
                        if run == 1 then be_tmp = i - 1 end
                        run = run + 1
                        if run > best then best=run; bs=i; be=be_tmp end
                    else run = 1 end
                end
                local ts_e = entries[be] and tonumber(entries[be][2]) or 0
                local ts_s = entries[bs] and tonumber(entries[bs][2]) or 0
                return { current=cur, best=best, best_start=ts_s, best_end=ts_e }
            end

            local today     = os.date("%Y-%m-%d")
            local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
            local day_str   = calcStreak(dates, isConsecDay,
                function(d) return d == today or d == yesterday end)

            -- Week streaks
            local weeks = {}
            _withStmt(conn, [[
                SELECT strftime('%G-%V',start_time,'unixepoch','localtime') wk,
                       MIN(start_time), MAX(start_time)
                FROM page_stat GROUP BY wk ORDER BY wk DESC
            ]], function(stmt)
                for row in stmt:rows() do
                    weeks[#weeks+1] = { tonumber(row[2]), tonumber(row[3]) }
                end
            end)

            local function pyear(ts) return tonumber(os.date("%G",ts)), tonumber(os.date("%V",ts)) end
            local function wksInYear(y)
                return tonumber(os.date("%V", os.time{year=y,month=12,day=28}))
            end
            local function isConsecWeek(p, c)
                local py,pw = pyear(p); local cy,cw = pyear(c)
                if not py then return false end
                if cy==py and pw==cw+1 then return true end
                if py==cy+1 and pw==1 and cw==wksInYear(cy) then return true end
                return false
            end
            local cur_wk  = os.date("%G-%V")
            local last_wk = os.date("%G-%V", os.time() - 7*86400)
            local function calcWeekStreak(entries)
                if #entries == 0 then return zero end
                local function isCur(ts) local w=os.date("%G-%V",ts); return w==cur_wk or w==last_wk end
                local cur = 0
                if isCur(entries[1][1]) then
                    cur = 1
                    for i = 2, #entries do
                        if isConsecWeek(entries[i-1][1], entries[i][1]) then cur = cur+1
                        else break end
                    end
                end
                local best, run, bs, be, be_tmp = 1, 1, 1, 1, 0
                for i = 2, #entries do
                    if isConsecWeek(entries[i-1][1], entries[i][1]) then
                        if run == 1 then be_tmp = i - 1 end
                        run = run + 1
                        if run > best then best=run; bs=i; be=be_tmp end
                    else run = 1 end
                end
                local ts_e = entries[be] and entries[be][2] or 0
                local ts_s = entries[bs] and entries[bs][1] or 0
                return { current=cur, best=best, best_start=ts_s, best_end=ts_e }
            end

            return { days = day_str, weeks = calcWeekStreak(weeks) }
        end)
    end

    -- ── 6. Shared widget helpers ───────────────────────────────────────────

    local function secLabel(text)
        return TW:new{
            text    = type(text) == "string" and text:upper() or text,
            face    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL),
            fgcolor = CLR_BLACK, bold = true,
        }
    end

    local function rowSep(inner_w)
        local ph = Size.padding.large
        return FC:new{
            bordersize = 0, padding = 0,
            padding_left = ph, padding_right = ph,
            LW:new{
                dimen      = Geom:new{ w = inner_w - 2*ph, h = SUIStyle.BORDER_SZ },
                background = CLR_BORDER,
            },
        }
    end

    -- Icon row: icon | label (+ optional sub) | value (right-aligned)
    local function iconRow(inner_w, icon, label, val_str, sub)
        local ROW_H  = Screen:scaleBySize(52)
        local ph     = Size.padding.large
        local icon_w = Screen:scaleBySize(36)
        local val_w  = Screen:scaleBySize(160)
        local lbl_w  = inner_w - 2*ph - icon_w - val_w
        local fi = Font:getFace(SUIStyle.FACE_ICONS,   SUIStyle.FS_BODY)
        local fl = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local fv = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local fs = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)

        local lbl_w2 = sub and VG:new{ align="left",
            TW:new{ text=label, face=fl, fgcolor=CLR_BLACK, max_width=lbl_w },
            TW:new{ text=sub,   face=fs, fgcolor=CLR_BLACK, max_width=lbl_w },
        } or TW:new{ text=label, face=fl, fgcolor=CLR_BLACK, max_width=lbl_w }

        return FC:new{
            bordersize=0, padding=0, padding_left=ph, padding_right=ph,
            dimen = Geom:new{ w=inner_w, h=ROW_H },
            HG:new{ align="center",
                CC:new{ dimen=Geom:new{w=icon_w,h=ROW_H},
                    TW:new{ text=icon, face=fi, fgcolor=CLR_BLACK } },
                LC:new{ dimen=Geom:new{w=lbl_w,h=ROW_H}, lbl_w2 },
                RC:new{ dimen=Geom:new{w=val_w,h=ROW_H},
                    TW:new{ text=tostring(val_str), face=fv, bold=true,
                            fgcolor=CLR_BLACK, max_width=val_w, alignment="right" } },
            },
        }
    end

    local function iconBlock(inner_w, rows)
        local vg = VG:new{ align="left" }
        for i, row in ipairs(rows) do
            if i > 1 then vg[#vg+1] = rowSep(inner_w) end
            vg[#vg+1] = row
        end
        return FC:new{
            bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER,
            radius = Screen:scaleBySize(12), padding = 0, margin = 0,
            vg,
        }
    end

    -- 3-column "All Time" block
    local function allTimeBlock(inner_w, alltime)
        local sep_w  = SUIStyle.BORDER_SZ
        local cell_w = math.floor((inner_w - 2*sep_w) / 3)
        local fl = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
        local fv = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)
        local fi = Font:getFace(SUIStyle.FACE_ICONS,   SUIStyle.FS_TITLE)
        local vpad = Screen:scaleBySize(16)
        local icon_h = Screen:scaleBySize(26)
        local lbl_h  = fl.size + Screen:scaleBySize(2)
        local val_h  = fv.size + Screen:scaleBySize(2)
        local cell_h = vpad*2 + icon_h + Screen:scaleBySize(6) + val_h + Screen:scaleBySize(2) + lbl_h

        local function mkCell(icon, val, lbl)
            return CC:new{ dimen=Geom:new{w=cell_w,h=cell_h},
                VG:new{ align="center",
                    CC:new{ dimen=Geom:new{w=cell_w,h=icon_h},
                        TW:new{text=icon,face=fi,fgcolor=CLR_BLACK,width=cell_w,alignment="center"} },
                    VS:new{width=Screen:scaleBySize(6)},
                    CC:new{ dimen=Geom:new{w=cell_w,h=val_h},
                        TW:new{text=tostring(val),face=fv,bold=true,
                               fgcolor=CLR_BLACK,width=cell_w,alignment="center"} },
                    VS:new{width=Screen:scaleBySize(2)},
                    CC:new{ dimen=Geom:new{w=cell_w,h=lbl_h},
                        TW:new{text=lbl,face=fl,fgcolor=CLR_BLACK,
                               width=cell_w,alignment="center"} },
                },
            }
        end
        local function mkSep()
            return CC:new{ dimen=Geom:new{w=sep_w,h=cell_h},
                LW:new{ dimen=Geom:new{w=sep_w,h=cell_h-Screen:scaleBySize(32)},
                        background=CLR_BORDER } }
        end
        return FC:new{
            bordersize=SUIStyle.BORDER_SZ, color=CLR_BORDER,
            radius=Screen:scaleBySize(12), padding=0, margin=0,
            HG:new{
                mkCell(SUIStyle.icon("clock"), fmtCount(alltime.hours),      _("hours read")),
                mkSep(),
                mkCell(SUIStyle.icon("page"),  fmtCount(alltime.pages),      _("pages read")),
                mkSep(),
                mkCell(SUIStyle.icon("book"),  fmtCount(alltime.book_count), _("books finished")),
            },
        }
    end

    local function yearlyRow(inner_w, yearly, avail_h)
        local fv   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)
        local fl   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
        local sepw = SUIStyle.BORDER_SZ
        local colw = math.floor((inner_w - sepw) / 2)
        local cH   = math.max(Screen:scaleBySize(48),
                         math.min(Screen:scaleBySize(90), math.floor(avail_h*0.12)))
        local function mkCol(val, lbl)
            return CC:new{ dimen=Geom:new{w=colw,h=cH},
                VG:new{ align="center",
                    TW:new{text=val,face=fv,bold=true,fgcolor=CLR_BLACK},
                    VS:new{width=Screen:scaleBySize(2)},
                    TW:new{text=lbl,face=fl,fgcolor=CLR_BLACK},
                },
            }
        end
        return HG:new{ align="center",
            mkCol(fmtCount(yearly.days),  plural(yearly.days,  "day read",  "days read")),
            CC:new{ dimen=Geom:new{w=sepw,h=cH},
                LW:new{ dimen=Geom:new{w=sepw,h=cH-Screen:scaleBySize(24)},
                        background=CLR_BLACK } },
            mkCol(fmtCount(yearly.pages), plural(yearly.pages, "page read", "pages read")),
        }
    end

    local function monthlyChart(inner_w, monthly, avail_h)
        if not monthly or #monthly == 0 then return VG:new{} end
        local cur_yr  = tonumber(os.date("%Y"))
        local cur_mo  = os.date("%Y-%m")
        local sel_yr  = getYearRange().max_year
        local max_val = 1
        for _, m in ipairs(monthly) do
            local v = tonumber(m.days) or 0; if v > max_val then max_val = v end
        end
        local bar_h  = math.max(Screen:scaleBySize(20),
                           math.min(Screen:scaleBySize(60), math.floor(avail_h*0.12)))
        local bar_w  = math.floor(inner_w/6) - Screen:scaleBySize(8)
        local bar_gap= math.floor((inner_w - bar_w*6) / 5)
        local fl     = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION - 2)
        local lbl_h  = fl.size + Screen:scaleBySize(2)
        local tot_h  = bar_h + lbl_h

        local function makeRow(slice)
            local bars = HG:new{ align="bottom" }; local lbls = HG:new{ align="top" }
            for i, m in ipairs(slice) do
                local v   = tonumber(m.days) or 0
                local bh  = math.floor((max_val>0 and v/max_val or 0)*bar_h + 0.5)
                if bh==0 and v>0 then bh=1 end
                local is_cur = (sel_yr==cur_yr) and (m.month==cur_mo)
                local clr    = is_cur and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_B
                local col    = VG:new{ align="center",
                    CC:new{ dimen=Geom:new{w=bar_w,h=lbl_h},
                        TW:new{ text=v>0 and tostring(v) or "", face=fl,
                                fgcolor=Blitbuffer.COLOR_BLACK } },
                }
                if bh > 0 then
                    col[#col+1] = LW:new{ dimen=Geom:new{w=bar_w,h=bh}, background=clr }
                end
                col[#col+1] = LW:new{ dimen=Geom:new{w=bar_w,h=Screen:scaleBySize(2)}, background=clr }
                bars[#bars+1] = BC:new{ dimen=Geom:new{w=bar_w,h=tot_h}, col }
                lbls[#lbls+1] = CC:new{ dimen=Geom:new{w=bar_w,h=lbl_h},
                    TW:new{ text=m.label:lower(), face=fl, fgcolor=Blitbuffer.COLOR_BLACK } }
                if i < #slice then
                    bars[#bars+1] = HS:new{width=bar_gap}
                    lbls[#lbls+1] = HS:new{width=bar_gap}
                end
            end
            return VG:new{ align="center", bars, VS:new{width=Screen:scaleBySize(2)}, lbls }
        end

        local r1, r2 = {}, {}
        for i = 1,  6 do r1[#r1+1] = monthly[i] end
        for i = 7, 12 do r2[#r2+1] = monthly[i] end
        return VG:new{ align="center",
            makeRow(r1), VS:new{width=Screen:scaleBySize(8)}, makeRow(r2) }
    end

    -- ── 7. Main page builder ───────────────────────────────────────────────
    local function buildPage(page_num, inner_w, avail_h)
        local ok, result = pcall(function()
            local gap = math.max(Screen:scaleBySize(6), math.floor(avail_h * 0.02))

            if page_num == 1 then
                local today   = getTodayStats()
                local streaks = getStreaks()

                local time_str  = fmtHours(today.seconds)
                if today.seconds < 60 then time_str = "0m" end
                local pages_str = fmtCount(today.pages)

                local today_gap  = Screen:scaleBySize(12)
                local card_w     = math.floor((inner_w - today_gap) / 2)
                local cH         = math.max(Screen:scaleBySize(70),
                                       math.min(Screen:scaleBySize(110), math.floor(avail_h*0.16)))
                local card_h     = cH + Screen:scaleBySize(24)
                local fv = Font:getFace(SUIStyle.FACE_REGULAR, math.floor(SUIStyle.FS_TITLE*1.6))
                local fl = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
                local fi = Font:getFace(SUIStyle.FACE_ICONS,   math.floor(SUIStyle.FS_TITLE*1.6))

                local function mkCard(icon, val, lbl)
                    return FC:new{
                        bordersize=SUIStyle.BORDER_SZ, color=CLR_BORDER,
                        radius=Screen:scaleBySize(12), padding=0, margin=0,
                        CC:new{ dimen=Geom:new{w=card_w,h=card_h},
                            HG:new{ align="center",
                                TW:new{text=icon,face=fi,fgcolor=CLR_BLACK},
                                HS:new{width=Screen:scaleBySize(12)},
                                VG:new{ align="left",
                                    TW:new{text=val,face=fv,bold=true,fgcolor=CLR_BLACK},
                                    VS:new{width=Screen:scaleBySize(2)},
                                    TW:new{text=lbl,face=fl,fgcolor=CLR_BLACK},
                                },
                            },
                        },
                    }
                end

                local sd = streaks.days;  local sw = streaks.weeks
                local cur_d  = string.format(plural(sd.current, "%d day",  "%d days"),  sd.current)
                local best_d = string.format(plural(sd.best,    "%d day",  "%d days"),  sd.best)
                local best_d_sub = (sd.best > 1 and sd.best_start > 0)
                    and (fmtDate(sd.best_start) .. " – " .. fmtDate(sd.best_end)) or nil
                local cur_w  = string.format(plural(sw.current, "%d week", "%d weeks"), sw.current)
                local best_w = string.format(plural(sw.best,    "%d week", "%d weeks"), sw.best)
                local best_w_sub = (sw.best > 1 and sw.best_start > 0)
                    and (fmtDate(sw.best_start) .. " – " .. fmtDate(sw.best_end)) or nil

                local streak_row  = iconBlock(inner_w, {
                    iconRow(inner_w, SUIStyle.icon("calendar"), _("Current streak"), cur_d),
                    iconRow(inner_w, SUIStyle.icon("trophy"),   _("Best streak"),    best_d, best_d_sub),
                })
                local wstreak_row = iconBlock(inner_w, {
                    iconRow(inner_w, SUIStyle.icon("calendar"), _("Current streak"), cur_w),
                    iconRow(inner_w, SUIStyle.icon("trophy"),   _("Best streak"),    best_w, best_w_sub),
                })

                return VG:new{ align="left",
                    VS:new{width=Screen:scaleBySize(16)},
                    secLabel(_("TODAY'S SUMMARY")),
                    VS:new{width=Screen:scaleBySize(8)},
                    HG:new{ align="center",
                        mkCard(SUIStyle.icon("clock"), time_str,  _("reading time")),
                        HS:new{width=today_gap},
                        mkCard(SUIStyle.icon("page"),  pages_str, _("pages read")),
                    },
                    VS:new{width=gap},
                    secLabel(_("DAY STREAK")),
                    VS:new{width=Screen:scaleBySize(8)},
                    streak_row,
                    VS:new{width=gap},
                    secLabel(_("WEEK STREAK")),
                    VS:new{width=Screen:scaleBySize(8)},
                    wstreak_row,
                }

            elseif page_num == 2 then
                local lw  = getLastWeekStats()
                local tw  = getThisWeekStats()
                local tm  = getThisMonthStats()

                local avg_t  = fmtHours(lw.avg_seconds)
                if lw.avg_seconds < 60 then avg_t = "0m" end
                local avg_p  = fmtCount(math.floor(lw.avg_pages + 0.5))
                local wtm    = fmtHours(tw.seconds)
                if tw.seconds < 60 then wtm = "0m" end
                local wtp    = fmtCount(tw.pages)
                local mtm    = fmtHours(tm.seconds)
                local mtp    = fmtCount(tm.pages)

                return VG:new{ align="left",
                    VS:new{width=Screen:scaleBySize(16)},
                    secLabel(_("LAST 7 DAYS")),
                    VS:new{width=Screen:scaleBySize(8)},
                    iconBlock(inner_w, {
                        iconRow(inner_w, SUIStyle.icon("clock"), _("Average per day"), avg_t),
                        iconRow(inner_w, SUIStyle.icon("page"),  _("Pages per day"),   avg_p),
                    }),
                    VS:new{width=gap},
                    secLabel(_("THIS WEEK")),
                    VS:new{width=Screen:scaleBySize(8)},
                    iconBlock(inner_w, {
                        iconRow(inner_w, SUIStyle.icon("clock"), _("Total time"),  wtm),
                        iconRow(inner_w, SUIStyle.icon("page"),  _("Pages read"),  wtp),
                    }),
                    VS:new{width=gap},
                    secLabel(_("THIS MONTH")),
                    VS:new{width=Screen:scaleBySize(8)},
                    iconBlock(inner_w, {
                        iconRow(inner_w, SUIStyle.icon("clock"), _("Total time"),  mtm),
                        iconRow(inner_w, SUIStyle.icon("page"),  _("Pages read"),  mtp),
                    }),
                }

            else  -- page 3
                local alltime  = getAllTimeStats()
                local yr_range = getYearRange()
                local sel_yr   = yr_range.max_year
                local ystats   = getYearlyStats(sel_yr)
                local monthly  = getMonthlyData(sel_yr)

                local face_yr = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_SUBTITLE)
                local yr_h    = face_yr.size + Screen:scaleBySize(4)
                local yr_lbl  = CC:new{ dimen=Geom:new{w=inner_w,h=yr_h},
                    TW:new{ text=tostring(sel_yr), face=face_yr,
                            fgcolor=CLR_BLACK, bold=true } }

                return VG:new{ align="left",
                    VS:new{width=Screen:scaleBySize(16)},
                    secLabel(_("ALL TIME")),
                    VS:new{width=Screen:scaleBySize(8)},
                    allTimeBlock(inner_w, alltime),
                    VS:new{width=gap + Screen:scaleBySize(24)},
                    yr_lbl,
                    VS:new{width=Screen:scaleBySize(4)},
                    yearlyRow(inner_w, ystats, avail_h),
                    VS:new{width=gap + Screen:scaleBySize(16)},
                    monthlyChart(inner_w, monthly, avail_h),
                }
            end
        end)

        if ok and type(result) == "table" then return result end
        logger.warn("screensaver_insights: buildPage page=" .. tostring(page_num)
                    .. " error: " .. tostring(result))
        return VG:new{}
    end

    -- ── 8. Wallpaper helper ────────────────────────────────────────────────
    local _last_wp_widget   = nil
    local _last_snap_widget = nil

    local function getBgWidget(sw, sh)
        if _last_wp_widget then
            pcall(function() _last_wp_widget:free() end); _last_wp_widget = nil
        end
        local HS2 = package.loaded["sui_homescreen"]
        if not HS2 then return nil end
        if not (HS2.styleGetWallpaperEnabled and HS2.styleGetWallpaperEnabled()) then return nil end
        local path = HS2.styleGetWallpaper and HS2.styleGetWallpaper()
        if not path then return nil end
        local ok, w = pcall(ImageWidget.new, ImageWidget, {
            file=path, width=sw, height=sh, scale_factor=0, file_do_cache=false, alpha=true,
        })
        if ok and w then _last_wp_widget = w; return w end
        return nil
    end

    -- ── 9. Full-screen insights widget ────────────────────────────────────
    local function buildInsightsWidget(screen_w, screen_h, target_page)
        local function white()
            return FC:new{ bordersize=0, padding=0,
                dimen=Geom:new{w=screen_w,h=screen_h},
                background=Blitbuffer.COLOR_WHITE, VG:new{} }
        end

        local page_num
        if not target_page or target_page <= 0 then
            math.randomseed(os.time())
            page_num = math.random(1, MAX_PAGE)
        else
            page_num = math.max(1, math.min(target_page, MAX_PAGE))
        end

        local wp   = getBgWidget(screen_w, screen_h)
        local iw   = screen_w - SIDE_PAD * 2

        local ok_pg, vg = pcall(buildPage, page_num, iw, screen_h)
        if not ok_pg or not vg then
            logger.warn("screensaver_insights: buildPage threw: " .. tostring(vg))
            return white()
        end

        local content = FC:new{
            bordersize=0, padding=0,
            padding_left=SIDE_PAD, padding_right=SIDE_PAD,
            dimen=Geom:new{w=screen_w, h=screen_h},
            vg,
        }

        if wp then
            local orig_pt = content.paintTo
            local _bg     = wp
            local ok_st, SUIStore = pcall(require, "sui_store")
            local opacity = (ok_st and SUIStore
                and SUIStore:readSetting("simpleui_style_wallpaper_opacity", 0)) or 0
            function content:paintTo(bb, x, y)
                _bg:paintTo(bb, x, 0)
                if opacity > 0 then bb:lightenRect(x, 0, screen_w, screen_h, opacity/100) end
                orig_pt(self, bb, x, y)
            end
        end

        return content
    end

    -- ── 10. Screensaver.show() patch ──────────────────────────────────────
    local _show_patched        = false
    local _orig_req_for_ss     = _G.require

    local function _patchShow(Screensaver)
        if _show_patched then return true end
        if type(Screensaver) ~= "table" then return false end
        local orig_show = Screensaver.show
        if type(orig_show) ~= "function" then
            local mt = type(orig_show) == "table" and getmetatable(orig_show)
            if not (mt and mt.__call) then
                logger.warn("screensaver_insights: show not callable — cannot patch")
                return false
            end
        end
        _show_patched = true

        Screensaver.show = function(self)
            if self.screensaver_type ~= TYPE_VALUE then return orig_show(self) end
            if not self.ui then
                logger.warn("screensaver_insights: show() aborting — self.ui nil"); return
            end

            Device.screen_saver_mode = true
            local with_gl = Device:isTouchDevice()
                and G_reader_settings:readSetting("screensaver_delay") == "gesture"
            local sw = Screen:getWidth(); local sh = Screen:getHeight()
            local rot = Screen:getRotationMode(); local orig_dimen
            Device.orig_rotation_mode = rot
            if bit.band(rot, 1) == 1 then
                Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
                if with_gl then orig_dimen = { w=sw, h=sh } end
                sw, sh = sh, sw
            else
                Device.orig_rotation_mode = nil
            end

            if Device:hasEinkScreen() then
                Screen:clear(); Screen:refreshFull(0, 0, sw, sh)
                if Device:isKobo() and Device:isSunxi() then ffiUtil.usleep(150*1000) end
            end

            local target_page = G_reader_settings:readSetting(SK_PAGE) or 0
            local ok_b, hs = pcall(buildInsightsWidget, sw, sh, target_page)
            if not ok_b then
                logger.warn("screensaver_insights: buildInsightsWidget: " .. tostring(hs)); hs = nil
            end

            local snap
            if hs then
                local ok_bb, bb = pcall(Blitbuffer.new, sw, sh, Screen.bb:getType())
                if ok_bb and bb then
                    pcall(function() bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_WHITE) end)
                    local ok_pt = pcall(function() hs:paintTo(bb, 0, 0) end)
                    pcall(function() if hs.free then hs:free() end end); hs = nil
                    if ok_pt then
                        local _bb = bb; local _w, _h = sw, sh
                        snap = FC:new{ bordersize=0, padding=0,
                            dimen=Geom:new{w=_w,h=_h},
                            background=Blitbuffer.COLOR_WHITE, VG:new{} }
                        function snap:paintTo(dst, x, y)
                            if _bb then dst:blitFrom(_bb, x, y, 0, 0, _w, _h) end
                        end
                        function snap:free()
                            if _bb then pcall(function() _bb:free() end); _bb = nil end
                        end
                    else
                        logger.warn("screensaver_insights: paintTo failed")
                        pcall(function() bb:free() end)
                    end
                else
                    logger.warn("screensaver_insights: Blitbuffer.new failed")
                    pcall(function() if hs and hs.free then hs:free() end end)
                end
            end

            if _last_snap_widget then
                pcall(function() if _last_snap_widget.free then _last_snap_widget:free() end end)
                _last_snap_widget = nil
            end

            if not snap then
                snap = FC:new{ bordersize=0, padding=0,
                    dimen=Geom:new{w=sw,h=sh},
                    background=Blitbuffer.COLOR_WHITE, VG:new{} }
            end
            _last_snap_widget = snap

            UIManager:setIgnoreTouchInput(false)

            local ok_sw2, sw2 = pcall(SSWidget.new, SSWidget, {
                widget=snap, background=Blitbuffer.COLOR_WHITE, covers_fullscreen=true,
            })
            if not ok_sw2 then
                logger.err("screensaver_insights: SSWidget:new failed: " .. tostring(sw2))
                Device.screen_saver_mode = false; Device.orig_rotation_mode = nil
                return orig_show(self)
            end
            self.screensaver_widget = sw2
            self.screensaver_widget.modal    = true
            self.screensaver_widget.dithered = true
            local ok_us, ue = pcall(UIManager.show, UIManager, self.screensaver_widget, "full")
            if not ok_us then
                logger.err("screensaver_insights: UIManager:show failed: " .. tostring(ue))
                Device.screen_saver_mode = false; Device.orig_rotation_mode = nil
                return orig_show(self)
            end

            if with_gl then
                local SSLW = require("ui/widget/screensaverlockwidget")
                self.screensaver_lock_widget = SSLW:new{ ui=self.ui, orig_dimen=orig_dimen }
                UIManager:show(self.screensaver_lock_widget)
            end
        end

        return true
    end

    -- Patch if screensaver already loaded.
    local cached_ss = package.loaded["ui/screensaver"]
    if type(cached_ss) == "table" and cached_ss.show ~= nil then
        _patchShow(cached_ss)
    end

    -- Intercept future require("ui/screensaver").
    if not _show_patched then
        _G.require = function(modname, ...)
            local result = _orig_req_for_ss(modname, ...)
            if modname == "ui/screensaver" then
                if not _show_patched then
                    if type(result) == "table" then
                        if _patchShow(result) then
                            _G.require = _orig_req_for_ss
                        else
                            logger.warn("screensaver_insights: require patch of show() failed")
                        end
                    end
                else
                    _G.require = _orig_req_for_ss
                end
            end
            return result
        end
    end

    -- Intercept dofile() to inject menu items and re-check show() patching.
    -- _patchShow has a _show_patched guard so it never double-wraps, which
    -- means it is safe to call here even when patch_screensaver_homescreen
    -- is also active and runs its own re-check.
    local _orig_dofile = _G.dofile
    _G.dofile = function(path, ...)
        local result = _orig_dofile(path, ...)
        if type(path) == "string" and path:find("screensaver_menu%.lua$") then
            _injectIntoMenuTable(result)
            local ss = package.loaded["ui/screensaver"]
            if ss then _patchShow(ss) end
        end
        return result
    end
end

return P
