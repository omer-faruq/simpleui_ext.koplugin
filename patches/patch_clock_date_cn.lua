-- patches/patch_clock_date_cn.lua — SimpleUI Extra Modules
-- Replaces module_clock's _localDate() with a Chinese-format date.
--
-- Original: "Wednesday, 3 June"
-- CN:       "6月3日 星期三"
--
-- IMPLEMENTATION
-- The patch works by hotfix, it replace function by debug.setupvalue.
--

local logger = require "logger"
local hotfix = require "utils/hotfix"


local P        = {
    id              = "clock_date_cn",
    name            = "Clock: Chinese Date Format",
    description     = [[Shows the homescreen clock date as "6月3日 星期三" instead of "Wednesday, 3 June"]],
    default_enabled = false,
}

local _CN_WDAY = { "日", "一", "二", "三", "四", "五", "六" }

local function _localDateCN()
    local t = os.date("*t", os.time())
    if not t or not t.day then return os.date "%m月%d日" end
    local w = _CN_WDAY[t.wday] or "??"
    return string.format("%d月%d日 周%s", t.month, t.day, w)
end

-- ---------------------------------------------------------------------------
-- apply()
-- ---------------------------------------------------------------------------
local _applied = false

function P.apply()
    if _applied then return end
    _applied = true

    local ok, ClockMod = pcall(require, "desktop_modules/module_clock")
    if not ok then
        logger.warn "simpleui_ext/patch_clock_date_cn: failed to load module_clock"
        return
    end

    local err = hotfix(_localDateCN, ClockMod.build, "build -> _localDate")
    if err then
        logger.warn("simpleui_ext/patch_clock_date_cn: failed to apply hotfix: " .. err)
        return
    end

    local _build = ClockMod.build
    ---@diagnostic disable-next-line: duplicate-set-field
    ClockMod.build = function(...)
        logger.warn "simpleui_ext/patch_clock_date_cn: hooked build"
        return _build(...)
    end

    logger.info "simpleui_ext/patch_clock_date_cn: applied patch"
end

return P
