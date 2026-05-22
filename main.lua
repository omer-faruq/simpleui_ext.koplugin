-- main.lua — SimpleUI Extra Modules
-- Plugin entry point.
--
-- HOW TO ADD A NEW MODULE
-- 1. Drop module_yourname.lua into simpleui_ext.koplugin/modules/
-- 2. Done. The module will appear in SimpleUI's homescreen arrange list
--    on next KOReader start (or after a hot-reload).
--    (No need to edit this file.)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")

-- Auto-discover all module_*.lua files inside the modules/ subdirectory.
-- Runs once at startup; with a handful of files the overhead is negligible.
-- plugin_dir is self.path, set automatically by KOReader's pluginloader.
local function discover_modules(plugin_dir)
    if not plugin_dir then
        logger.warn("simpleui_ext: could not resolve plugin directory, skipping auto-discovery")
        return {}
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.warn("simpleui_ext: lfs unavailable, skipping auto-discovery")
        return {}
    end

    local modules = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin_dir .. "/modules")
    if not ok then
        logger.warn("simpleui_ext: cannot scan modules/ dir: " .. tostring(iter))
        return modules
    end
    for entry in iter, dir_obj do
        -- Only pick up files like  module_foo.lua  (prefix required, no sub-dirs)
        local stem = entry:match("^(module_%a[%w_]*)%.lua$")
        if stem then
            modules[#modules + 1] = "modules/" .. stem
        end
    end
    table.sort(modules)   -- deterministic load order
    return modules
end

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

    for _, path in ipairs(discover_modules(self.path)) do
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
