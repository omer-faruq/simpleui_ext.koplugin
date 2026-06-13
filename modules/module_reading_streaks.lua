-- modules/module_reading_streaks.lua — SimpleUI Extra Modules
-- Reading Streaks card for SimpleUI homescreen.
--
-- Displays current and best weekly/daily reading streaks from statistics DB.
-- Tappable to show full Reading Insights popup (if patch is installed).
--
-- Layout:
--   CURRENT STREAK
--   [Weekly box] [Daily box]
--   BEST STREAK
--   [Weekly box] [Daily box]

local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local SQ3 = require("lua-ljsqlite3/init")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

-- Inline reading data provider (shared cache with 2-reading-insights-popup.lua)
local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local database_file = DataStorage:getDataDir() .. "/reading_insights_data.lua"
local ReadingInsightsDatabase = LuaSettings:open(database_file)

local insightsCache = ReadingInsightsDatabase:readSetting("readingInsights_cache") or {}
local cache_timestamps = ReadingInsightsDatabase:readSetting("readingInsights_cacheTimestamps") or {
    partialClear = 1262304000,
}

local function getDbModTime()
    local attr = lfs.attributes(db_path, "modification")
    return attr and attr or 0
end

local function clearStreaksCache()
    insightsCache.streaks = nil
    ReadingInsightsDatabase:saveSetting("readingInsights_cache", insightsCache)
    ReadingInsightsDatabase:flush()
end

local function clearCacheIfRequired()
    local latest_db_mod_timestamp = getDbModTime()
    if (latest_db_mod_timestamp > cache_timestamps.partialClear) then
        clearStreaksCache()
        cache_timestamps.partialClear = latest_db_mod_timestamp
        ReadingInsightsDatabase:saveSetting("readingInsights_cacheTimestamps", cache_timestamps)
        ReadingInsightsDatabase:flush()
    end
end

local function withStatsDb(fallback, fn)
    if lfs.attributes(db_path, "mode") ~= "file" then
        return fallback
    end
    local conn = SQ3.open(db_path)
    if not conn then return fallback end
    local ok, result = pcall(fn, conn)
    conn:close()
    if ok then return result end
    return fallback
end

local function withStatement(conn, sql, fn)
    local stmt = conn:prepare(sql)
    if not stmt then return end
    local ok, result = pcall(fn, stmt)
    stmt:close()
    if ok then return result end
end

local function parseDateYMD(date_str)
    if not date_str then return end
    local year = tonumber(date_str:sub(1, 4))
    local month = tonumber(date_str:sub(6, 7))
    local day = tonumber(date_str:sub(9, 10))
    if not year or not month or not day then return end
    return year, month, day
end

local function getTotalWeeksInYear(year)
    year = year or 2020
    local ts = os.time{year = year, month = 12, day = 28}
    return tonumber(os.date("%V", ts))
end

local function parseWeekYear(week_stamp)
    if not week_stamp then return end
    local yr, wk = os.date("%G", week_stamp), os.date("%V", week_stamp)
    return tonumber(yr), tonumber(wk)
end

local function computeStreaks(entries_desc, is_consecutive, is_current_start, weeksOrDays)
    local a = {current = 0, best = 0, best_start = 0, best_end = 0}
    if #entries_desc == 0 then return a
    elseif #entries_desc == 1 then
        a.best = 1
        if is_current_start(entries_desc[1][1]) then a.current = 1 end
        return a
    end
    
    local current = 0
    if is_current_start(entries_desc[1][1]) then
        current = 1
        for i = 2, #entries_desc do
            if is_consecutive(entries_desc[i - 1][1], entries_desc[i][1]) then
                current = current + 1
            else break end
        end
    end
    
    local best, run, best_start, best_end, best_end_temp = 1, 1, 1, 1, 0
    for i = 2, #entries_desc do
        if is_consecutive(entries_desc[i - 1][1], entries_desc[i][1]) then
            if run == 1 then best_end_temp = (i - 1) end
            run = run + 1
            if run > best then
                best, best_start, best_end = run, i, best_end_temp
            end
        else run = 1 end
    end
    
    best_end = entries_desc and entries_desc[best_end] and entries_desc[best_end][2] and tonumber(entries_desc[best_end][2]) or 0
    if weeksOrDays == 1 then
        best_start = entries_desc and entries_desc[best_start] and entries_desc[best_start][2] and tonumber(entries_desc[best_start][2]) or 0
    else
        best_start = entries_desc and entries_desc[best_start] and entries_desc[best_start][1] and tonumber(entries_desc[best_start][1]) or 0
    end
    
    return {current = current, best = best, best_start = best_start, best_end = best_end}
end

local function calculateStreaks()
    local streaks = {
        days = {current = 0, best = 0, best_start = 0, best_end = 0},
        weeks = {current = 0, best = 0, best_start = 0, best_end = 0},
    }
    
    return withStatsDb(streaks, function(conn)
        local dates = {}
        withStatement(conn, [[
            SELECT date(start_time, 'unixepoch', 'localtime') as d, min(start_time) as timestamp
            FROM page_stat GROUP BY d ORDER BY d DESC
        ]], function(stmt)
            for row in stmt:rows() do
                table.insert(dates, { row[1], tonumber(row[2]) })
            end
        end)
        
        local today = os.date("%Y-%m-%d")
        local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
        
        local function isCurrentDayStart(first_date)
            return first_date == today or first_date == yesterday
        end
        
        local function isConsecutiveDay(prev_date, curr_date)
            local year, month, day = parseDateYMD(prev_date)
            if not year then return false end
            local prev_time = os.time({year = year, month = month, day = day})
            local expected_prev = os.date("%Y-%m-%d", prev_time - 86400)
            return curr_date == expected_prev
        end
        
        streaks.days = computeStreaks(dates, isConsecutiveDay, isCurrentDayStart, 1)
        
        local weeks = {}
        withStatement(conn, [[
            SELECT strftime('%G-%V', start_time, 'unixepoch', 'localtime') as week,
                   MIN(start_time) as first_timestamp, MAX(start_time) as last_timestamp
            FROM page_stat GROUP BY week ORDER BY week DESC
        ]], function(stmt_weeks)
            for row in stmt_weeks:rows() do
                table.insert(weeks, {tonumber(row[2]), tonumber(row[3])})
            end
        end)
        
        local current_week = os.date("%G-%V")
        local last_week = os.date("%G-%V", os.time() - 7 * 86400)
        
        local function isCurrentWeekStart(first_week_stamp)
            local first_week = os.date("%G-%V", first_week_stamp)
            return first_week == current_week or first_week == last_week
        end
        
        local function isConsecutiveWeek(prev_week_stamp, curr_week_stamp)
            local prev_year, prev_wk = parseWeekYear(prev_week_stamp)
            local curr_year, curr_wk = parseWeekYear(curr_week_stamp)
            if not prev_year or not prev_wk or not curr_year or not curr_wk then return false end
            
            if curr_year == prev_year and prev_wk == curr_wk + 1 then return true
            elseif prev_year == curr_year + 1 and prev_wk == 1 and curr_wk == getTotalWeeksInYear(curr_year) then return true
            else return false end
        end
        
        streaks.weeks = computeStreaks(weeks, isConsecutiveWeek, isCurrentWeekStart, 0)
        
        insightsCache.streaks = streaks
        ReadingInsightsDatabase:saveSetting("readingInsights_cache", insightsCache)
        ReadingInsightsDatabase:flush()
        return streaks
    end)
end

local function getStreaksData()
    clearCacheIfRequired()
    return insightsCache.streaks or calculateStreaks()
end

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

local function getStyle()
    if not _SUIStyle then
        local ok, m = pcall(require, "sui_style")
        if ok and m then _SUIStyle = m end
    end
    return _SUIStyle
end

local SK_TAPPABLE = "rstreaks_tappable"

local function isTappable(pfx)
    local S = getSettings()
    if not S then return true end
    local v = S:readSetting(pfx .. SK_TAPPABLE)
    return v ~= false
end

local function formatCount(value)
    if value == nil then return "" end
    local util = require("util")
    return util.getFormattedSize(value)
end

local function mkSectionHeader(face, text, full_w, bg_color, left_pad, transparent)
    left_pad = left_pad or Size.padding.default
    local tw = TextWidget:new{ text = text, face = face }
    if transparent then
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ height = Size.padding.small },
            CenterContainer:new{
                dimen = Geom:new{ w = full_w, h = tw:getSize().h },
                tw,
            },
            VerticalSpan:new{ height = Size.padding.small },
            LineWidget:new{
                dimen = Geom:new{ w = full_w, h = Size.line.thick },
                background = Blitbuffer.COLOR_BLACK,
            },
        }
    end
    return FrameContainer:new{
        background = bg_color or Blitbuffer.COLOR_GRAY_E,
        bordersize = 0,
        padding_top = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left = 0,
        padding_right = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = full_w, h = tw:getSize().h },
            tw,
        },
    }
end

local function mkStreakColumn(value, header_text, col_w, face_val, has_wp, UI)
    local value_widget = TextWidget:new{
        text = formatCount(value),
        face = face_val,
    }
    
    local content = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = value_widget:getSize().h },
            value_widget,
        },
    }
    
    return VerticalGroup:new{
        align = "left",
        mkSectionHeader(Font:getFace("x_smallinfofont"), header_text, col_w, Blitbuffer.COLOR_GRAY_D, Size.padding.default, has_wp),
        VerticalSpan:new{ height = Size.padding.default },
        content,
        VerticalSpan:new{ height = Size.padding.default },
    }
end

local function buildStreaksWidget(w, ctx, data)
    local streaks = data.streaks or { days = {current = 0, best = 0}, weeks = {current = 0, best = 0} }
    
    local Config = getConfig()
    local UI = getUI()
    local scale = Config and Config.getModuleScale("reading_streaks", ctx.pfx) or 1.0
    local has_wp = ctx and ctx.has_wallpaper
    
    local PAD = UI and UI.PAD or Size.padding.large
    local gap = Screen:scaleBySize(10)
    local sep_w = Size.line.medium
    local total_gaps = 3 * (gap * 2 + sep_w)
    local col_w = math.floor((w - total_gaps) / 4)
    
    local base_val_fs = 32
    local val_fs = math.max(16, math.floor(base_val_fs * scale))
    local face_val = Font:getFace("NotoSerif-Bold.ttf", val_fs) or Font:getFace("tfont", val_fs)
    
    local col1 = mkStreakColumn(streaks.weeks.current, "CURR. WEEKS", col_w, face_val, has_wp, UI)
    local col2 = mkStreakColumn(streaks.days.current, "CURR. DAYS", col_w, face_val, has_wp, UI)
    local col3 = mkStreakColumn(streaks.weeks.best, "BEST WEEKS", col_w, face_val, has_wp, UI)
    local col4 = mkStreakColumn(streaks.days.best, "BEST DAYS", col_w, face_val, has_wp, UI)
    
    local cols_h = math.max(col1:getSize().h, col2:getSize().h, col3:getSize().h, col4:getSize().h)
    
    local card = HorizontalGroup:new{
        align = "top",
        col1,
        HorizontalSpan:new{ width = gap },
        LineWidget:new{
            dimen = Geom:new{ w = Size.line.medium, h = cols_h },
            background = Blitbuffer.COLOR_GRAY,
        },
        HorizontalSpan:new{ width = gap },
        col2,
        HorizontalSpan:new{ width = gap },
        LineWidget:new{
            dimen = Geom:new{ w = Size.line.medium, h = cols_h },
            background = Blitbuffer.COLOR_GRAY,
        },
        HorizontalSpan:new{ width = gap },
        col3,
        HorizontalSpan:new{ width = gap },
        LineWidget:new{
            dimen = Geom:new{ w = Size.line.medium, h = cols_h },
            background = Blitbuffer.COLOR_GRAY,
        },
        HorizontalSpan:new{ width = gap },
        col4,
    }
    
    return card
end

-- Kept separate from module.label: applyLabelToggle() mutates module.label to
-- nil when the section label is hidden, so it can't also serve as its own default.
local _DEFAULT_LABEL = "Reading Streaks"

local module = {
    id = "reading_streaks",
    name = "Reading Streaks",
    description = "Current and best reading streaks (days and weeks)",
    default_enabled = true,   -- Loaded by simpleui_ext by default
    label = _DEFAULT_LABEL,
    enabled_key = "reading_streaks",
    default_on = false,
}

function module.build(w, ctx)
    local ok_config, Config = pcall(require, "sui_config")
    if ok_config and Config then
        Config.applyLabelToggle(module, _DEFAULT_LABEL)
    end
    
    local ok, streaks = pcall(getStreaksData)
    if not ok or not streaks then
        return nil
    end
    
    return buildStreaksWidget(w, ctx, {streaks = streaks})
end

function module.invalidateCache()
    clearStreaksCache()
end

function module.getMenuItems(ctx_menu)
    local ok, Config = pcall(require, "sui_config")
    if not ok or not Config then return nil end
    
    local pfx = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc = ctx_menu._ or function(x) return x end
    
    return {
        Config.makeLabelToggleItem(module.id, module.name, refresh, _lc),
        Config.makeScaleItem({
            text_func = function()
                local pct = Config.getModuleScalePct("reading_streaks", pfx)
                return pct == 100
                    and _lc("Scale")
                    or string.format("%s (%d%%)", _lc("Scale"), pct)
            end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title = _lc("Scale"),
            info = _lc("Scale for this module.\n100% is the default size."),
            get = function() return Config.getModuleScalePct("reading_streaks", pfx) end,
            set = function(v) Config.setModuleScale(v, "reading_streaks", pfx) end,
            refresh = refresh,
        }),
    }
end

return module
