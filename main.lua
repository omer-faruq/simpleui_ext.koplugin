-- main.lua — SimpleUI Extra Modules
-- Plugin entry point.
--
-- HOW TO ADD A NEW MODULE
-- 1. Drop module_yourname.lua into simpleui_ext.koplugin/modules/
-- 2. Append its require path to MODULES below.
-- 3. Done. The module will appear in SimpleUI's homescreen arrange list
--    on next KOReader start (or after a hot-reload).

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")

-- List of module require-paths relative to this plugin's directory.
-- Each entry must resolve to a file with the standard SimpleUI module contract.
local MODULES = {
    "modules/module_hero_currently",
}

-- ---------------------------------------------------------------------------
local SimpleUIExtPlugin = WidgetContainer:new{
    name      = "simpleui_ext",
    _registry = nil,
    _mod_ids  = {},
}

function SimpleUIExtPlugin:init()
    -- Delay registration by one scheduler tick so that all plugins
    -- (including SimpleUI itself) have finished their own init().
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0, function()
        self:_register()
    end)
end

function SimpleUIExtPlugin:_register()
    local ok, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok or not Registry then
        logger.warn("simpleui_ext: SimpleUI moduleregistry not found. " ..
                    "Make sure SimpleUI is installed.")
        return
    end
    self._registry = Registry
    self._mod_ids  = {}

    for _, path in ipairs(MODULES) do
        local ok2, mod = pcall(require, path)
        if not ok2 or not mod then
            logger.warn("simpleui_ext: failed to load module '" .. path ..
                        "': " .. tostring(mod))
        elseif type(mod.id) ~= "string" then
            logger.warn("simpleui_ext: module '" .. path ..
                        "' has no id field — skipped.")
        else
            Registry.register(mod)
            self._mod_ids[#self._mod_ids + 1] = mod.id
            logger.info("simpleui_ext: registered module '" .. mod.id .. "'")
        end
    end
end

function SimpleUIExtPlugin:onClosePlugin()
    if self._registry then
        for _, id in ipairs(self._mod_ids) do
            self._registry.unregister(id)
            logger.info("simpleui_ext: unregistered module '" .. id .. "'")
        end
    end
    self._registry = nil
    self._mod_ids  = {}
end

return SimpleUIExtPlugin
