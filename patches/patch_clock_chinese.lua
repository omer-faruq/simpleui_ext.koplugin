-- patches/patch_clock_chinese.lua — SimpleUI Extra Modules
--
-- Clock Chinese Extension Patch
-- Injects Chinese time display into the SimpleUI clock module
-- (desktop_modules/module_clock) by replacing two upvalues inside the build
-- function via utils/hotfix, and wrapping M.build:
--
--   * _localDate  → Style-aware date formatting
--       - word: Chinese lunar calendar "Bingwu (Horse) 7th Mo. 11th Day"
--         (Ganzhi, zodiac, leap month, and Chinese month/day notation)
--       - digital / analogue: Chinese Gregorian date "2026年 1月23日 星期五"
--       - Falls back to "MM月DD日" if os.date fails
--   * timeToWords → Traditional 12-Shichen & 4 Da Ke system
--       (Visible only in "word" style)
--       HourWord: Shichen (e.g. "巳正")
--       MinuteWord: Da Ke (e.g. "初刻")
--       Rendered as two lines split by '\n'.

local logger = require "logger"
local hotfix = require "utils/hotfix"
local _      = require("sui_ext_i18n").translate

local P = {
    id              = "clock_chinese",
    name            = _("Clock: Chinese Extension"),
    description     = _("Add Chinese date & time style extension support to SimpleUI Clock module"),
    default_enabled = false,
}

-- Public tables
local _GAN = { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" }
local _ZHI = { "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" }
local _SX  = { "鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪" }
local _NUM = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二" }
local _WK  = { "日", "一", "二", "三", "四", "五", "六" }
local _KE  = { "初刻", "一刻", "二刻", "三刻" }

-- --------------------------------------------------------------
-- 1) Chinese date string (unchanged)
-- --------------------------------------------------------------
-- Build a localized Chinese date string (e.g. "2026年 1月23日 星期五").
-- Uses os.date("*t") to fetch the full time table. Falls back to a
-- simplified "MM月DD日" format if the time table is incomplete.

local function _localDateGregorian()
    local t = os.date("*t", os.time())
    if not t or not t.day then return os.date "%m月%d日" end
    local w = _WK[t.wday] or "??"
    return string.format("%d年 %d月%d日 星期%s", t.year, t.month, t.day, w)
end

-- --------------------------------------------------------------
-- 2) Chinese 12-Shichen & 96-Ke System (word style only)
-- --------------------------------------------------------------
-- Proxy function: Preserves the 3-argument signature timeToWords(hour, min, is_12h)
-- Returns a "line1\nline2" string; _buildWordClockWidget splits it by '\n' for dual-line rendering.
-- This matches the original timeToWords return shape of "HourWord\nMinuteWord":
--   HourWord   = Shichen  (e.g. "巳正")
--   MinuteWord = ke       (e.g. "初刻")
-- The ancient 12-Shichen system has no 12h/24h distinction; line1/line2 ignores is_12h.

local function _shiChen(hour)
    return _ZHI[(math.floor((hour + 1) / 2) % 12) + 1]
         .. ((hour % 2 == 1) and "初" or "正")
end

local function _shiChenKe(min)
    if     min < 15 then return _KE[1]
    elseif min < 30 then return _KE[2]
    elseif min < 45 then return _KE[3]
    else                 return _KE[4]
    end
end

local function _shiChenWords(hour, min, is_12h)
    return _shiChen(hour) .. "\n" .. _shiChenKe(min)
end

-- --------------------------------------------------------------
-- 3) Lunar Calendar Subsystem (1900–2100, hex table)
-- --------------------------------------------------------------
-- Each entry encodes one Gregorian year. Month sizes and leap-month data
-- are extracted via bitwise operations.
-- Reference epoch: 1900-01-31 (Gregorian) = Lunar 1900-01-01.

local _LUNAR = {
    0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,
    0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,
    0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,
    0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,
    0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,
    0x06ca0,0x0b550,0x15355,0x04da0,0x0a5b0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0,
    0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,
    0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6,
    0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,
    0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0,
    0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,
    0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,
    0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,
    0x05aa0,0x076a3,0x096d0,0x04afb,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,
    0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,
    0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0,
    0x0a2e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4,
    0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0,
    0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160,
    0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252,
    0x0d520,
}

local function _leapMonth(y) return _LUNAR[y - 1899] % 16 end

local function _leapDays(y)
    if _leapMonth(y) == 0 then return 0 end
    return (math.floor(_LUNAR[y - 1899] / 65536) % 2 == 1) and 30 or 29
end

local function _monthDays(y, m)
    -- m=1 reads bit 15; m=12 reads bit 4
    return (math.floor(_LUNAR[y - 1899] / (2 ^ (16 - m))) % 2 == 1) and 30 or 29
end

local function _lunarYearDays(y)
    local sum = 348  -- 12 * 29 baseline
    for i = 15, 4, -1 do
        if math.floor(_LUNAR[y - 1899] / (2 ^ i)) % 2 == 1 then
            sum = sum + 1
        end
    end
    return sum + _leapDays(y)
end

-- Convert Gregorian (y, m, d) to lunar. Epoch: 1900-01-31 = lunar 1900-01-01 (offset 0).
local function _solarToLunar(y, m, d)
    local function _offsetFromEpoch(yr, mo, dy)
        -- Julian Day Number (Gregorian) for yr-mo-dy
        local a  = math.floor((14 - mo) / 12)
        local y2 = yr + 4800 - a
        local m2 = mo + 12 * a - 3
        local jd = dy + math.floor((153 * m2 + 2) / 5) + 365 * y2
                  + math.floor(y2 / 4) - math.floor(y2 / 100) + math.floor(y2 / 400) - 32045
        -- 1900-01-31 JDN = 2415051 (1900-01-01 JDN 2415021 + 30 days)
        return jd - 2415051
    end

    local offset = _offsetFromEpoch(y, m, d)
    local i      = 1900
    while i < 2100 and offset >= 0 do
        local yd = _lunarYearDays(i)
        if offset < yd then break end
        offset = offset - yd
        i      = i + 1
    end

    local ly      = i
    local leap    = _leapMonth(ly)
    local isLeap  = false
    local temp    = 0
    local lmonth  = 0
    for i2 = 1, 12 do
        local mlen
        if leap > 0 and i2 == (leap + 1) and not isLeap then
            i2   = i2 - 1
            isLeap = true
            mlen  = _leapDays(ly)
        else
            mlen = _monthDays(ly, i2)
        end
        if isLeap and i2 == (leap + 1) then isLeap = false end
        if offset < mlen then
            lmonth = i2
            return { year = ly, month = lmonth, day = offset + 1, isLeap = isLeap }
        end
        offset = offset - mlen
    end
    -- Defensive fallback (should not reach for valid dates in 1900-2100)
    return { year = ly, month = 12, day = 29, isLeap = false }
end

-- 1864 = 甲子年 (60-cycle reference); cycle repeats every 60 years.
local function _ganZhi(y)
    local idx = ((y - 1864) % 60 + 60) % 60
    return _GAN[idx % 10 + 1] .. _ZHI[idx % 12 + 1]
end

local function _shuXiang(y)
    return _SX[(((y - 4) % 12) + 12) % 12 + 1]
end

local function _lunarDay(d)
    if d == 10 then return "初十" end
    if d == 20 then return "二十" end
    if d == 30 then return "三十" end
    local u = d % 10
    if d < 10 then return "初" .. _NUM[d] end
    if d < 20 then return "十" .. _NUM[u] end
    return "廿" .. _NUM[u]
end

local function _localDateLunar()
    local t = os.date("*t", os.time())
    if not t or not t.year or not t.month or not t.day then return _localDateGregorian() end
    local r = _solarToLunar(t.year, t.month, t.day)
    if not r or not r.year or not r.month or not r.day then return _localDateGregorian() end
    local leap_prefix = r.isLeap and "闰" or ""
    return string.format("%s年（%s） %s%s月%s",
        _ganZhi(r.year), _shuXiang(r.year),
        leap_prefix, _NUM[r.month], _lunarDay(r.day))
end

-- --------------------------------------------------------------
-- 4) Shared style state — read by M.build wrapper before each build
-- --------------------------------------------------------------
local _currentStyle = "digital"  -- default; updated in M.build wrapper

-- Mirror module_clock.getClockStyle (line 149-151): reads pfx .. "clock_style"
-- via infra/sui_store (the SUISettings module_clock uses internally).
local function _readClockStyle(pfx)
    local key = (pfx or "") .. "clock_style"
    local ok, SUISettings = pcall(require, "infra/sui_store")
    if ok and SUISettings then
        local ok2, v = pcall(function() return SUISettings:readSetting(key) end)
        if ok2 and (v == "word" or v == "digital" or v == "analogue") then
            return v
        end
    end
    return "digital"
end

-- Style-aware date proxy: word → lunar; otherwise → Chinese public date.
-- pcall wraps the lunar path so any internal boundary (os.date incomplete,
-- lunar algo overrun, etc.) degrades to the public-date formatter without
-- crashing the build path.
local function _localDateStyleAware()
    if _currentStyle == "word" then
        local ok, v = pcall(_localDateLunar)
        if ok then return v end
        logger.dbg("simpleui_ext/patch_clock_chinese.lua: _localDateLunar failed: " .. tostring(v))
    end
    return _localDateGregorian()
end

-- --------------------------------------------------------------
-- 5) apply
-- --------------------------------------------------------------
local _applied = false

function P.apply()
    if _applied then return end
    _applied = true

    local ok, ClockMod = pcall(require, "desktop_modules/module_clock")
    if not ok then
        logger.dbg "simpleui_ext/patch_clock_chinese.lua: failed to load module_clock"
        return
    end

    -- Hotfix #1: _localDate → style-aware (word → lunar; otherwise → Chinese date)
    local err1 = hotfix(_localDateStyleAware, ClockMod.build, "build -> _localDate")
    if err1 then
        logger.dbg("simpleui_ext/patch_clock_chinese.lua: failed to hotfix _localDate: " .. err1)
    end

    -- Hotfix #2: timeToWords → traditional 12-Shichen (visible only in "word" style)
    local err2 = hotfix(_shiChenWords, ClockMod.build, "build -> timeToWords")
    if err2 then
        logger.dbg("simpleui_ext/patch_clock_chinese.lua: failed to hotfix timeToWords: " .. err2)
    end

    -- Wrap M.build: read clock_style into _currentStyle BEFORE each build so that
    -- the _localDate upvalue inside `local build` can pick the right formatter.
    local _build = ClockMod.build
    ---@diagnostic disable-next-line: duplicate-set-field
    ClockMod.build = function(w, ctx, ...)
        _currentStyle = _readClockStyle(ctx and ctx.pfx or "")
        logger.dbg "simpleui_ext/patch_clock_chinese.lua: hooked build"
        return _build(w, ctx, ...)
    end

    logger.dbg "simpleui_ext/patch_clock_chinese.lua: applied patch"
end

return P