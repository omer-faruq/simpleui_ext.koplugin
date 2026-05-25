-- modules/module_reading_insights.lua — SimpleUI Extra Modules
-- Reading Insights card for SimpleUI homescreen.
--
-- Displays yearly reading statistics and monthly chart from statistics DB.
-- Tappable bars to show books read in that month.
--
-- Layout:
--   [Current Year]
--   [Days/Hours read] | [Pages read]
--   Monthly chart (6 bars per row)

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
local BottomContainer = require("ui/widget/container/bottomcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local Math = require("optmath")
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local SQ3 = require("lua-ljsqlite3/init")
local util = require("util")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")

-- Inline reading data provider (shared cache with 2-reading-insights-popup.lua)
local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local database_file = DataStorage:getDataDir() .. "/reading_insights_data.lua"
local ReadingInsightsDatabase = LuaSettings:open(database_file)

local insightsCache = ReadingInsightsDatabase:readSetting("readingInsights_cache") or {}
local cache_timestamps = ReadingInsightsDatabase:readSetting("readingInsights_cacheTimestamps") or {
    partialClear = 1262304000,
}

local MONTH_NAMES_SHORT = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}
local MONTH_NAMES_FULL = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

local function getDbModTime()
    local attr = lfs.attributes(db_path, "modification")
    return attr and attr or 0
end

local function clearYearCache(year)
    insightsCache.yearlyStats = insightsCache.yearlyStats or {}
    insightsCache.yearlyStats[year] = nil
    insightsCache.monthlyReadingDays = insightsCache.monthlyReadingDays or {}
    insightsCache.monthlyReadingDays[year] = nil
    insightsCache.monthlyReadingHours = insightsCache.monthlyReadingHours or {}
    insightsCache.monthlyReadingHours[year] = nil
    ReadingInsightsDatabase:saveSetting("readingInsights_cache", insightsCache)
    ReadingInsightsDatabase:flush()
end

local function clearCacheIfRequired()
    local latest_db_mod_timestamp = getDbModTime()
    if (latest_db_mod_timestamp > cache_timestamps.partialClear) then
        local current_year = tonumber(os.date("%Y"))
        clearYearCache(current_year)
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

local function getYearlyStats(year)
    local stats = { days = 0, pages = 0, duration = 0 }
    return withStatsDb(stats, function(conn)
        local year_str = tostring(year)
        
        withStatement(conn, string.format([[
            SELECT COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime'))
            FROM page_stat WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
        ]], year_str), function(stmt)
            for row in stmt:rows() do
                stats.days = tonumber(row[1]) or 0
            end
        end)
        
        withStatement(conn, string.format([[
            SELECT count(*) FROM (
                SELECT 1 FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book, page
            )
        ]], year_str), function(stmt)
            for row in stmt:rows() do
                stats.pages = tonumber(row[1]) or 0
            end
        end)
        
        withStatement(conn, string.format([[
            SELECT sum(duration) FROM page_stat
            WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
        ]], year_str), function(stmt)
            for row in stmt:rows() do
                stats.duration = tonumber(row[1]) or 0
            end
        end)
        
        insightsCache.yearlyStats = insightsCache.yearlyStats or {}
        insightsCache.yearlyStats[year] = stats
        ReadingInsightsDatabase:saveSetting("readingInsights_cache", insightsCache)
        ReadingInsightsDatabase:flush()
        return stats
    end)
end

local function getMonthlyReadingDays(year)
    local months = {}
    return withStatsDb(months, function(conn)
        local year_str = tostring(year)
        local results = {}
        withStatement(conn, string.format([[
            SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS month,
                   COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime')) AS days_read
            FROM page_stat WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
            GROUP BY month ORDER BY month ASC
        ]], year_str), function(stmt)
            for row in stmt:rows() do
                results[row[1]] = row[2]
            end
        end)
        
        for month_num = 1, 12 do
            local year_month = string.format("%04d-%02d", year, month_num)
            local days = tonumber(results[year_month]) or 0
            table.insert(months, {
                month = year_month,
                days = days,
                label = MONTH_NAMES_SHORT[month_num],
                label_full = MONTH_NAMES_FULL[month_num],
                month_num = month_num
            })
        end
        
        insightsCache.monthlyReadingDays = insightsCache.monthlyReadingDays or {}
        insightsCache.monthlyReadingDays[year] = months
        ReadingInsightsDatabase:saveSetting("readingInsights_cache", insightsCache)
        ReadingInsightsDatabase:flush()
        return months
    end)
end

local function getMonthlyReadingHours(year)
    local months = {}
    return withStatsDb(months, function(conn)
        local year_str = tostring(year)
        local results = {}
        withStatement(conn, string.format([[
            SELECT dates AS month, SUM(sum_duration) / 3600.0 AS hours_read
            FROM (
                SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS dates,
                       sum(duration) AS sum_duration
                FROM page_stat WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book, page, dates
            )
            GROUP BY dates ORDER BY dates ASC
        ]], year_str), function(stmt)
            for row in stmt:rows() do
                results[row[1]] = row[2]
            end
        end)
        
        for month_num = 1, 12 do
            local year_month = string.format("%04d-%02d", year, month_num)
            local hours = tonumber(results[year_month]) or 0
            if hours >= 1 then
                hours = math.floor(hours)
            elseif hours > 0 then
                hours = (math.floor(hours * 10)) / 10
            end
            table.insert(months, {
                month = year_month,
                hours = hours,
                label = MONTH_NAMES_SHORT[month_num],
                label_full = MONTH_NAMES_FULL[month_num],
                month_num = month_num
            })
        end
        
        insightsCache.monthlyReadingHours = insightsCache.monthlyReadingHours or {}
        insightsCache.monthlyReadingHours[year] = months
        ReadingInsightsDatabase:saveSetting("readingInsights_cache", insightsCache)
        ReadingInsightsDatabase:flush()
        return months
    end)
end

local function getSelectedYear(pfx)
    local Settings = ReadingInsightsDatabase
    local key = (pfx or "") .. "reading_insights_selected_year"
    return Settings:readSetting(key) or tonumber(os.date("%Y"))
end

local function setSelectedYear(pfx, year)
    local Settings = ReadingInsightsDatabase
    local key = (pfx or "") .. "reading_insights_selected_year"
    Settings:saveSetting(key, year)
    Settings:flush()
end

local function getInsightsData(pfx)
    clearCacheIfRequired()
    local selected_year = getSelectedYear(pfx)
    
    local yearlyStats = (insightsCache.yearlyStats and insightsCache.yearlyStats[selected_year])
        or getYearlyStats(selected_year)
    local monthlyDays = (insightsCache.monthlyReadingDays and insightsCache.monthlyReadingDays[selected_year])
        or getMonthlyReadingDays(selected_year)
    local monthlyHours = (insightsCache.monthlyReadingHours and insightsCache.monthlyReadingHours[selected_year])
        or getMonthlyReadingHours(selected_year)
    
    return {
        year = selected_year,
        yearlyStats = yearlyStats,
        monthlyReadingDays = monthlyDays,
        monthlyReadingHours = monthlyHours,
    }
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

local SK_MODE = "rinsights_mode"
local SK_TAPPABLE = "rinsights_tappable"
local MODE_DAYS = "days"
local MODE_HOURS = "hours"

local function getMode(pfx)
    local S = getSettings()
    local v = S and S:readSetting(pfx .. SK_MODE)
    return (v == MODE_HOURS) and MODE_HOURS or MODE_DAYS
end

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

local function formatNumber(value)
    if value == nil then return "" end
    if type(value) == "number" and value % 1 ~= 0 then
        return string.format("%.1f", value)
    end
    return formatCount(value)
end

local function formatHoursRead(seconds)
    if (not seconds) or (seconds < 60) then
        return 0, "hours read"
    end

    local h = math.floor(seconds / 3600)
    if h == 0 then
        h = math.floor((seconds / 3600) * 10) / 10
        return h, "hours read"
    end

    local h_unit = h == 1 and "hour read" or "hours read"
    return h, h_unit
end

local function buildYearlyStatsRow(ctx, stats, mode, content_width, has_wp, UI)
    local value_font = Font:getFace("NotoSans-Bold.ttf", 28)
    local label_font_name = has_wp and "NotoSans-Bold.ttf" or "NotoSans-Regular.ttf"
    local label_font = Font:getFace(label_font_name, 16)
    
    local col_width = math.floor((content_width - Size.padding.default) / 2)
    
    local left_value, left_unit
    if mode == MODE_HOURS then
        left_value, left_unit = formatHoursRead(stats.duration)
    else
        left_value = formatCount(stats.days)
        left_unit = stats.days == 1 and "day read" or "days read"
    end
    
    local left_val_widget = TextWidget:new{
        text = tostring(left_value),
        face = value_font,
    }
    local left_unit_widget = TextWidget:new{
        text = left_unit,
        face = label_font,
    }
    local left_content = HorizontalGroup:new{
        left_val_widget,
        HorizontalSpan:new{ width = Size.padding.default },
        left_unit_widget,
    }
    
    local right_val_widget = TextWidget:new{
        text = formatCount(stats.pages),
        face = value_font,
    }
    local right_unit_widget = TextWidget:new{
        text = stats.pages == 1 and "page read" or "pages read",
        face = label_font,
    }
    local right_content = HorizontalGroup:new{
        right_val_widget,
        HorizontalSpan:new{ width = Size.padding.default },
        right_unit_widget,
    }
    
    local left_cell = LeftContainer:new{
        dimen = Geom:new{ w = col_width, h = left_val_widget:getSize().h },
        left_content,
    }
    
    local right_cell = LeftContainer:new{
        dimen = Geom:new{ w = col_width, h = right_val_widget:getSize().h },
        right_content,
    }
    
    return HorizontalGroup:new{
        left_cell,
        HorizontalSpan:new{ width = Size.padding.default },
        right_cell,
    }
end

local function showBooksForMonth(year_month, month_label)
    local SQ3 = require("lua-ljsqlite3/init")
    local DataStorage = require("datastorage")
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(db_path, "mode") ~= "file" then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = "Statistics database not found",
            timeout = 2,
        })
        return
    end
    
    local conn = SQ3.open(db_path)
    if not conn then return end
    
    local books = {}
    local pages_total = 0
    
    local sql = string.format([[
        SELECT book.title, book.authors, COUNT(DISTINCT page_stat.page) as pages_read
        FROM page_stat
        JOIN book ON page_stat.id_book = book.id
        WHERE strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
        GROUP BY page_stat.id_book
        ORDER BY pages_read DESC
    ]], year_month)
    
    local stmt = conn:prepare(sql)
    if stmt then
        for row in stmt:rows() do
            local pages_curr = tonumber(row[3]) or 0
            table.insert(books, {
                title = row[1] or "Unknown",
                authors = row[2] or "",
                pages = pages_curr,
            })
            pages_total = pages_total + pages_curr
        end
        stmt:close()
    end
    conn:close()
    
    if #books == 0 then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = "No books read in " .. month_label,
            timeout = 2,
        })
        return
    end
    
    local Menu = require("ui/widget/menu")
    local item_table = {}
    for i, book in ipairs(books) do
        local pages_text = book.pages == 1 and "page" or "pages"
        local display_text = book.title
        if book.authors and book.authors ~= "" then
            display_text = display_text .. " (" .. book.authors .. ")"
        end
        table.insert(item_table, {
            text = display_text,
            mandatory = formatCount(book.pages) .. " " .. pages_text,
            bold = true,
        })
    end
    
    local book_count = #books
    local book_text = book_count == 1 and "book" or "books"
    local page_text = pages_total == 1 and "page" or "pages"
    local title = string.format("%s - %s %s (%s %s)",
        month_label, formatCount(book_count), book_text,
        formatCount(pages_total), page_text)
    
    local menu
    menu = Menu:new{
        title = title,
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        modal = true,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

local function buildMonthlyChart(ctx, monthly_data, mode, content_width, scale, has_wp, UI)
    if #monthly_data == 0 then
        return nil
    end
    
    local value_key = mode == MODE_HOURS and "hours" or "days"
    local max_value = 1
    for _, m in ipairs(monthly_data) do
        local v = tonumber(m[value_key]) or 0
        if v > max_value then max_value = v end
    end
    
    local bar_height = Screen:scaleBySize(50 * scale)
    local bar_width = math.floor(content_width / 6) - Screen:scaleBySize(6)
    local bar_gap = math.floor((content_width - bar_width * 6) / 5)
    
    local font_small_name = has_wp and "NotoSans-Bold.ttf" or "NotoSans-Regular.ttf"
    local font_small = Font:getFace(font_small_name, 14)
    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()
    
    local current_year = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")
    
    local function createBarRow(data_slice)
        local bars_row = HorizontalGroup:new{ align = "bottom" }
        local month_labels_row = HorizontalGroup:new{ align = "top" }
        local baseline_h = Size.line.medium
        local total_bar_height = bar_height + label_height
        
        for i, m in ipairs(data_slice) do
            local value = tonumber(m[value_key]) or 0
            local ratio = max_value > 0 and (value / max_value) or 0
            local bar_h = math.floor(ratio * bar_height + 0.5)
            if bar_h == 0 and value > 0 then bar_h = 1 end
            
            local is_current = (m.month == current_month)
            local bar_color = is_current and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
            
            local value_label = TextWidget:new{
                text = formatNumber(value),
                face = font_small,
            }
            local centered_label = CenterContainer:new{
                dimen = Geom:new{ w = bar_width, h = label_height },
                value_label,
            }
            
            local bar_column = VerticalGroup:new{
                align = "center",
            }
            table.insert(bar_column, centered_label)
            if bar_h > 0 then
                table.insert(bar_column, LineWidget:new{
                    dimen = Geom:new{ w = bar_width, h = bar_h },
                    background = bar_color,
                })
            end
            table.insert(bar_column, LineWidget:new{
                dimen = Geom:new{ w = bar_width, h = baseline_h },
                background = bar_color,
            })
            
            local bar_container = BottomContainer:new{
                dimen = Geom:new{ w = bar_width, h = total_bar_height },
                bar_column,
            }
            
            if isTappable(ctx.pfx) then
                local tappable_bar = InputContainer:new{
                    dimen = Geom:new{ w = bar_width, h = total_bar_height },
                    bar_container,
                }
                local month_data = m
                local month_year_label = m.label_full .. " " .. current_year
                tappable_bar.ges_events = {
                    Tap = {
                        GestureRange:new{
                            ges = "tap",
                            range = function() return tappable_bar.dimen end,
                        }
                    },
                }
                function tappable_bar:onTap()
                    showBooksForMonth(month_data.month, month_year_label)
                    return true
                end
                table.insert(bars_row, tappable_bar)
            else
                table.insert(bars_row, bar_container)
            end
            
            local month_label_widget = TextWidget:new{
                text = string.lower(m.label),
                face = font_small,
            }
            table.insert(month_labels_row, CenterContainer:new{
                dimen = Geom:new{ w = bar_width, h = month_label_widget:getSize().h },
                month_label_widget,
            })
            
            if i < #data_slice then
                table.insert(bars_row, HorizontalSpan:new{ width = bar_gap })
                table.insert(month_labels_row, HorizontalSpan:new{ width = bar_gap })
            end
        end
        
        return VerticalGroup:new{
            align = "center",
            bars_row,
            VerticalSpan:new{ height = Size.padding.small },
            month_labels_row,
        }
    end
    
    local chart = VerticalGroup:new{
        align = "center",
    }
    local row_index = 0
    for i = 1, #monthly_data, 6 do
        local row_data = {}
        for j = i, math.min(i + 5, #monthly_data) do
            table.insert(row_data, monthly_data[j])
        end
        if #row_data > 0 then
            if row_index > 0 then
                table.insert(chart, VerticalSpan:new{ height = Size.padding.default })
            end
            local bar_row = createBarRow(row_data)
            table.insert(chart, bar_row)
            row_index = row_index + 1
        end
    end
    
    return chart
end

local function buildInsightsWidget(w, ctx, data)
    local selected_year = data.year or tonumber(os.date("%Y"))
    local stats = data.yearlyStats or { days = 0, pages = 0, duration = 0 }
    local mode = getMode(ctx.pfx)
    local monthly_data = mode == MODE_HOURS and data.monthlyReadingHours or data.monthlyReadingDays
    
    local Config = getConfig()
    local UI = getUI()
    local scale = Config and Config.getModuleScale("reading_insights", ctx.pfx) or 1.0
    local has_wp = ctx and ctx.has_wallpaper
    
    local PAD = UI and UI.PAD or Size.padding.large
    local content_width = w - 2 * PAD
    
    local year_font_size = has_wp and 22 or 20
    local year_font = Font:getFace("NotoSans-Bold.ttf", year_font_size)
    
    local current_year = tonumber(os.date("%Y"))
    
    local year_text = TextWidget:new{
        text = tostring(selected_year),
        face = year_font,
        bold = true,
    }
    
    local year_display
    if selected_year == current_year and current_year > 2010 then
        local prev_year_text = TextWidget:new{
            text = "◀ " .. tostring(current_year - 1),
            face = year_font,
            bold = true,
        }
        
        local prev_w = prev_year_text:getSize().w
        local year_w = year_text:getSize().w
        local total_w = prev_w + year_w
        local left_gap = math.floor((content_width - total_w) / 2)
        local right_gap = content_width - total_w - left_gap
        
        year_display = HorizontalGroup:new{
            align = "center",
            prev_year_text,
            HorizontalSpan:new{ width = left_gap },
            year_text,
            HorizontalSpan:new{ width = right_gap },
        }
    else
        year_display = LeftContainer:new{
            dimen = Geom:new{ w = content_width, h = year_text:getSize().h },
            year_text,
        }
    end
    
    local year_widget
    if selected_year == current_year and current_year > 2010 then
        local year_h = year_display:getSize().h
        local tappable_overlay = InputContainer:new{
            dimen = Geom:new{ w = content_width, h = year_h },
            year_display,
        }
        tappable_overlay.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return tappable_overlay.dimen end,
                }
            },
        }
        function tappable_overlay:onTap()
            local ReaderUI = require("apps/reader/readerui")
            local FileManager = require("apps/filemanager/filemanager")
            
            local ui_instance = ReaderUI.instance or FileManager.instance
            if ui_instance and ui_instance.onShowReadingInsightsPopup then
                ui_instance:onShowReadingInsightsPopup()
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("Reading Insights popup not available.\n\nWith the patch installed, you could view detailed statistics for previous years."),
                    timeout = 3,
                })
            end
            return true
        end
        year_widget = tappable_overlay
    else
        year_widget = year_display
    end
    
    local stats_row = buildYearlyStatsRow(ctx, stats, mode, content_width, has_wp, UI)
    local chart = buildMonthlyChart(ctx, monthly_data, mode, content_width, scale, has_wp, UI)
    
    local inner_content = VerticalGroup:new{
        align = "left",
        year_widget,
        VerticalSpan:new{ height = Size.padding.default },
        stats_row,
        VerticalSpan:new{ height = Size.padding.large },
        chart,
    }
    
    local content = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = PAD },
        inner_content,
    }
    
    if not has_wp then
        return content
    end
    
    return FrameContainer:new{
        padding = Size.padding.large,
        bordersize = Size.border.default,
        background = Blitbuffer.COLOR_TRANSPARENT,
        content,
    }
end

local module = {
    id = "reading_insights",
    name = "Reading Insights",
    label = "Reading Insights",
    description = "Yearly reading statistics and monthly chart",
    enabled_key = "reading_insights",
    default_on = false,
}

function module.build(w, ctx)
    local ok_config, Config = pcall(require, "sui_config")
    if ok_config and Config then
        Config.applyLabelToggle(module, module.label)
    end
    
    local ok, data = pcall(getInsightsData, ctx.pfx)
    if not ok or not data or not data.yearlyStats then
        return nil
    end
    
    return buildInsightsWidget(w, ctx, data)
end

function module.invalidateCache()
    local current_year = tonumber(os.date("%Y"))
    clearYearCache(current_year)
end

function module.getMenuItems(ctx_menu)
    local ok, Config = pcall(require, "sui_config")
    if not ok or not Config then return nil end
    
    local pfx = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc = ctx_menu._ or function(x) return x end
    local S = getSettings()
    
    return {
        Config.makeLabelToggleItem(module.id, module.name, refresh, _lc),
        Config.makeScaleItem({
            text_func = function()
                local pct = Config.getModuleScalePct("reading_insights", pfx)
                return pct == 100
                    and _lc("Scale")
                    or string.format("%s (%d%%)", _lc("Scale"), pct)
            end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title = _lc("Scale"),
            info = _lc("Scale for this module.\n100% is the default size."),
            get = function() return Config.getModuleScalePct("reading_insights", pfx) end,
            set = function(v) Config.setModuleScale(v, "reading_insights", pfx) end,
            refresh = refresh,
        }),
        {
            text = _lc("Display Mode"),
            sub_item_table = {
                {
                    text = _lc("Days read per month"),
                    checked_func = function() return getMode(pfx) == MODE_DAYS end,
                    callback = function()
                        if S then S:saveSetting(pfx .. SK_MODE, MODE_DAYS) S:flush() end
                        refresh()
                    end,
                },
                {
                    text = _lc("Hours read per month"),
                    checked_func = function() return getMode(pfx) == MODE_HOURS end,
                    callback = function()
                        if S then S:saveSetting(pfx .. SK_MODE, MODE_HOURS) S:flush() end
                        refresh()
                    end,
                },
            },
        },
    }
end

return module
