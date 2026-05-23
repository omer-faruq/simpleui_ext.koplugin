-- main.lua — SimpleUI Extra Modules
-- Plugin entry point.
--
-- HOW TO ADD A NEW MODULE
--   Drop module_yourname.lua into simpleui_ext.koplugin/modules/
--   It will be auto-registered with SimpleUI on the next KOReader start.
--
-- HOW TO ADD A NEW PATCH
--   Drop patch_yourname.lua into simpleui_ext.koplugin/patches/
--   The file must return a table with:
--     patch.id     string   — unique identifier used in log messages
--     patch.apply  func()   — called once after SimpleUI has initialised
--   Patches are applied in alphabetical order after modules are registered.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")

-- ---------------------------------------------------------------------------
-- discover_patches — scans patches/ for patch_*.lua files.
-- Returns a sorted list of require-paths (e.g. "patches/patch_foo").
-- Mirrors discover_modules; runs once at startup.
-- ---------------------------------------------------------------------------
local function discover_patches(plugin_dir)
    if not plugin_dir then return {} end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return {} end
    local patches = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin_dir .. "/patches")
    if not ok then return patches end
    for entry in iter, dir_obj do
        local stem = entry:match("^(patch_%a[%w_]*)%.lua$")
        if stem then
            patches[#patches + 1] = "patches/" .. stem
        end
    end
    table.sort(patches)   -- deterministic, alphabetical order
    return patches
end

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
    name        = "simpleui_ext",
    is_doc_only = false,   -- must be false so onCloseDocument fires in Reader context
    _registry   = nil,
    _mod_ids    = {},
    _mods       = {},      -- module objects, for event forwarding
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
    self._mods     = {}

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
            self._mods[#self._mods + 1]       = mod
            logger.info("simpleui_ext: registered module '" .. mod.id .. "'")
        end
    end

    -- Apply patches from patches/.  Each patch file is required once;
    -- patch.apply() is called immediately.  Errors are caught so a broken
    -- patch never prevents modules from loading.
    for _, path in ipairs(discover_patches(self.path)) do
        local ok3, patch = pcall(require, path)
        if not ok3 or type(patch) ~= "table" then
            logger.warn("simpleui_ext: failed to load patch '" .. path ..
                        "': " .. tostring(patch))
        elseif type(patch.apply) ~= "function" then
            logger.warn("simpleui_ext: patch '" .. path ..
                        "' has no apply() function — skipped")
        else
            local ok4, err = pcall(patch.apply)
            if not ok4 then
                logger.warn("simpleui_ext: patch '" .. (patch.id or path) ..
                            "' apply() failed: " .. tostring(err))
            else
                logger.info("simpleui_ext: applied patch '" ..
                            (patch.id or path) .. "'")
            end
        end
    end
end

-- Forwarded from ReaderUI when the user closes a book.
-- Invalidates any module caches so the homescreen shows fresh data
-- the moment the user returns (instead of waiting for the TTL to expire).
function SimpleUIExtPlugin:onCloseDocument()
    for _, mod in ipairs(self._mods) do
        if type(mod.invalidateCache) == "function" then
            mod.invalidateCache()
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
    self._mods     = {}
end

return SimpleUIExtPlugin
