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

-- MUST come first: installs the loader that maps this plugin's
-- pre-2.5 SimpleUI require paths ("sui_config", "desktop_modules/…")
-- onto SimpleUI 2.5's foldered layout ("infra/sui_config",
-- "modules/…"). Without it every SimpleUI require below — and in
-- every module/ and patch/ file — fails and _register() bails out.
require("utils/sui_compat")

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings     = require("luasettings")
local logger          = require("logger")
local _ = require("sui_ext_i18n").translate

-- Settings file path helper - computed at runtime to ensure consistency
local function getSettingsFilePath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/simpleui_ext.lua"
end

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
        logger.dbg("simpleui_ext: could not resolve plugin directory, skipping auto-discovery")
        return {}
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.dbg("simpleui_ext: lfs unavailable, skipping auto-discovery")
        return {}
    end

    local modules = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin_dir .. "/modules")
    if not ok then
        logger.dbg("simpleui_ext: cannot scan modules/ dir: " .. tostring(iter))
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
    name           = "simpleui_ext",
    is_doc_only    = false,   -- must be false so onCloseDocument fires in Reader context
    _settings      = nil,     -- LuaSettings instance (lazy-loaded)
    _registry      = nil,
    _mod_ids       = {},
    _mods          = {},      -- module objects, for event forwarding
    _patches_meta  = {},      -- all discovered patch tables (for menu)
    _diag          = nil,     -- per-run report, see _buildDiagText()
    _modules_meta  = {},      -- all discovered module tables (for menu)
}

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:_getSettings()
    if not self._settings then
        self._settings = LuaSettings:open(getSettingsFilePath())
    end
    return self._settings
end

function SimpleUIExtPlugin:_isPatchEnabled(patch_id, default_enabled)
    local states = self:_getSettings():readSetting("patch_states") or {}
    local enabled = states[patch_id]
    if enabled == nil then
        -- Patches default to false (opt-in) unless explicitly set to true
        return default_enabled == true
    end
    return enabled == true
end

function SimpleUIExtPlugin:_setPatchEnabled(patch_id, enabled)
    local states = self:_getSettings():readSetting("patch_states") or {}
    states[patch_id] = enabled
    self:_getSettings():saveSetting("patch_states", states)
    self:_getSettings():flush()
end

function SimpleUIExtPlugin:_isModuleEnabled(module_id, default_enabled)
    local states = self:_getSettings():readSetting("module_states") or {}
    local enabled = states[module_id]
    if enabled == nil then
        -- Modules default to true unless explicitly set to false
        return default_enabled ~= false
    end
    return enabled == true
end

function SimpleUIExtPlugin:_setModuleEnabled(module_id, enabled)
    local states = self:_getSettings():readSetting("module_states") or {}
    states[module_id] = enabled
    self:_getSettings():saveSetting("module_states", states)
    self:_getSettings():flush()
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:init()
    -- Register menu (must be before _register for menu to appear)
    self.ui.menu:registerToMainMenu(self)

    -- Delay registration by one scheduler tick so that all plugins
    -- (including SimpleUI itself) have finished their own init().
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0, function()
        self:_register()
        -- Synchronous on purpose: by the time the user reaches the home
        -- screen (separate code path, after file manager etc. close) the
        -- stats cache is already warm.
        self:_prewarmBookModuleCaches()
    end)

    -- Deferred repair, once SimpleUI's own init and our patches have settled.
    UIManager:scheduleIn(5, function()
        -- If the live engine holds a foreign registry instance, copy our
        -- modules into it so the rebuild that follows can resolve them.
        pcall(function() self:_healEngineRegistry() end)
        -- The check at the end of _register() runs a scheduler tick after
        -- startup, when the home screen has often not rendered yet and there is
        -- no module table to inspect; by now it has.
        pcall(function() self:_refreshStaleScreens() end)
    end)
end

-- ---------------------------------------------------------------------------
-- _hydrateCtx(ctx)
--
-- Fills in the book fields SimpleUI's engine leaves empty for us.
--
-- ScreenWidget:_buildCtx only calls SH.prefetchBooks() when SimpleUI's OWN
-- "currently", "recent" or "coverdeck" module is enabled:
--
--     local show_c = mod_c and Registry.isEnabled(mod_c, self._pfx)
--     ...
--     if show_c or show_r then self._cached_books_state = SH.prefetchBooks(...)
--     else self._cached_books_state = { current_fp = nil, recent_fps = {}, ... }
--
-- There is no way for an external module to opt in: M.needs.books exists, but
-- it is read further down and only reaches the stats provider, not this gate.
-- (SimpleUI 3.0 replaced that gate with M.needs.recent / Registry.getRecentDemand,
-- but current_fp still depends on its own "currently" module alone.)
-- So a home screen page built out of OUR book modules -- with SimpleUI's own
-- ones switched off, which is exactly what replacing them means -- hands every
-- module a ctx with no current book and an empty recent list, and a module
-- that has nothing to show returns nil and paints nothing.
--
-- Done here, once per ctx, rather than in each module: all six share the one
-- prefetch, and their build() code stays unchanged.
--
-- ctx.db_conn is deliberately NOT filled in: every one of our modules already
-- falls back to opening its own connection and closing it, and a connection
-- opened here would have no owner to close it.
-- ---------------------------------------------------------------------------
-- Module id of a layout page entry. SimpleUI 3.0 layouts may still hold
-- legacy { id = ..., width = ... } tables (normalized to plain ids on the
-- next Layout Editor load); 2.6 and earlier hold plain id strings only.
local function _entryId(entry)
    if type(entry) == "table" then return entry.id end
    return entry
end

local function _hydrateCtx(ctx)
    if type(ctx) ~= "table" or ctx._sui_ext_hydrated then return end
    ctx._sui_ext_hydrated = true

    -- SimpleUI 3.0 prefetches recent books whenever ANY enabled module asks
    -- for them (M.needs.recent: coverdeck, recent, tab_grid, ...), but only
    -- fills current_fp when its own "currently" module is on. A recent list
    -- prefetched without a current book starts with the book on top of the
    -- history -- exactly what current_fp would have been -- so reuse it
    -- instead of leaving our currently-reading modules empty.
    if not ctx.current_fp and not ctx._show_c
       and type(ctx.recent_fps) == "table" and ctx.recent_fps[1] then
        ctx.current_fp = ctx.recent_fps[1]
    end

    local has_books = ctx.current_fp or (ctx.recent_fps and #ctx.recent_fps > 0)
    if has_books then return end

    local ok, SH = pcall(require, "desktop_modules/module_books_shared")
    if not ok or not SH or type(SH.prefetchBooks) ~= "function" then return end

    -- 15 matches what _buildCtx asks for, so modules that filter finished
    -- books still have enough entries left to fill a row.
    local ok2, bs = pcall(SH.prefetchBooks, true, true, 15)
    if not ok2 or not bs then return end

    ctx.current_fp = ctx.current_fp or bs.current_fp
    if not ctx.recent_fps or #ctx.recent_fps == 0 then
        ctx.recent_fps = bs.recent_fps or {}
    end
    if not ctx.prefetched or next(ctx.prefetched) == nil then
        ctx.prefetched = bs.prefetched_data or ctx.prefetched
    end
end

function SimpleUIExtPlugin:_register()
    -- Everything below is pcall-wrapped, so a module or patch that fails to
    -- load is skipped silently and simply never appears anywhere. _diag
    -- records what actually happened to each one so the "Diagnostics" menu
    -- entry can show it instead of leaving an unexplained empty list.
    self._diag = { modules = {}, patches = {}, registry = nil, sui_version = nil }

    -- MUST run before the first SimpleUI require below. SimpleUI evicts its
    -- own modules from package.loaded on every teardown (i.e. every
    -- FileManager <-> Reader switch) and rebuilds them; without this, our
    -- compat aliases keep pointing at the discarded tables and every module
    -- we register lands in a registry SimpleUI no longer reads. See
    -- utils/sui_compat.lua's syncAliases() for the full story.
    local ok_c, Compat = pcall(require, "utils/sui_compat")
    if not ok_c then Compat = nil end
    if Compat then
        pcall(function() self._diag.stale_aliases = Compat.syncAliases() end)
        -- The chunk-load attempt ran inside PluginLoader:_load(), when
        -- package.path did not yet hold SimpleUI's root — retry now that the
        -- full path is in place (no-op when already installed).
        pcall(function() self._diag.preload_name = Compat.installRegistryPreload() end)
        -- Pre-2.5 files left behind by an in-place upgrade. The alias loader
        -- now outranks the path searcher so they can no longer hijack our
        -- requires, but they are still dead weight worth deleting.
        pcall(function()
            local remnants = Compat.staleRemnants()
            self._diag.stale_remnants = remnants
            for _i, r in ipairs(remnants) do
                logger.dbg(("simpleui_ext: STALE pre-2.5 SimpleUI file on disk: %s "
                             .. "(current layout provides '%s') -- safe to delete")
                            :format(tostring(r.stale_file), tostring(r.real)))
            end
        end)
    end

    local ok, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok or not Registry then
        self._diag.registry = "NOT FOUND: " .. tostring(Registry)
        logger.dbg("simpleui_ext: SimpleUI moduleregistry not found. " ..
                    "Make sure SimpleUI is installed.")
        return
    end
    self._diag.registry = "ok"
    -- Which file each legacy SimpleUI name actually resolved to. This is the
    -- single most useful line when something stops appearing after a SimpleUI
    -- upgrade: it says whether utils/sui_compat found the new layout, and
    -- where.
    pcall(function()
        self._diag.resolved = require("utils/sui_compat").report({
            "desktop_modules/moduleregistry", "sui_config", "sui_core",
            "sui_store", "sui_homescreen", "sui_style",
        })
    end)
    self._registry     = Registry
    self._mod_ids      = {}
    self._mods         = {}
    self._modules_meta = {}

    -- Load modules: Hybrid approach (same as patches)
    -- - New modules (not in settings): require() once to get metadata, store in settings
    -- - Known modules: check enabled state, skip require() if disabled
    -- This ensures all modules appear in menu while maximizing performance.
    local module_states = self:_getSettings():readSetting("module_states") or {}
    local existing_modules = {}  -- Track which modules exist (for cleanup later)

    -- Recorded separately from the per-module results below so the log can
    -- tell "no module_*.lua found under <path>/modules" (folder missing or
    -- not copied to the device) apart from "found them, then skipped them".
    local discovered_modules = discover_modules(self.path)
    self._diag.plugin_path = self.path
    self._diag.n_module_files = #discovered_modules

    for _i, path in ipairs(discovered_modules) do
        -- Extract module_id from path (e.g., "modules/module_hero_currently" -> "hero_currently")
        -- Note: [%w_]+ matches alphanumeric + underscore (not just %w which excludes underscore)
        local module_id = path:match("module_([%w_]+)$")
        local function _rec(st, extra)
            self._diag.modules[#self._diag.modules + 1] =
                { id = module_id or path, status = st, detail = extra }
        end
        if not module_id then
            logger.dbg("simpleui_ext: could not extract module_id from path '" .. path .. "'")
            _rec("bad file name")
            goto continue_module
        end
        existing_modules[module_id] = true  -- Mark as existing
        
        -- Check if this module is known (exists in settings)
        local is_known = module_states[module_id] ~= nil
        
        if is_known then
            -- Known module: check enabled state BEFORE require (performance optimization)
            if not self:_isModuleEnabled(module_id, true) then
                -- Still need to add minimal metadata for menu (without requiring)
                self._modules_meta[#self._modules_meta + 1] = {
                    id = module_id,
                    name = module_id:gsub("_", " "):gsub("(%a)([%w_']*)", function(first, rest)
                        return first:upper() .. rest:lower()
                    end),
                    description = _("Disabled module (enable to load)"),
                    default_enabled = true,
                }
                if Compat and Compat.untrackModule then pcall(Compat.untrackModule, module_id) end
                _rec("off (this plugin's Modules menu)")
                goto continue_module
            end
        end
        
        -- New module OR enabled module: require() to get full metadata
        local ok2, mod = pcall(require, path)
        if not ok2 or not mod then
            logger.dbg("simpleui_ext: failed to load module '" .. path ..
                        "': " .. tostring(mod))
            _rec("LOAD ERROR", tostring(mod))
            goto continue_module
        elseif type(mod.id) ~= "string" then
            logger.dbg("simpleui_ext: module '" .. path ..
                        "' has no id field — skipped.")
            _rec("no id field")
            goto continue_module
        end
        
        -- Validate: mod.id MUST match filename-based module_id
        if mod.id ~= module_id then
            logger.err("simpleui_ext: module '" .. path .. "' has mismatched ID — SKIPPED")
            logger.err("  Expected (from filename): '" .. module_id .. "'")
            logger.err("  Actual (from mod.id):  '" .. mod.id .. "'")
            logger.err("  Fix: Rename file to 'module_" .. mod.id .. ".lua' OR change M.id to '" .. module_id .. "'")
            _rec("id mismatch", "M.id = " .. tostring(mod.id))
            goto continue_module
        end
        
        -- Store full metadata
        self._modules_meta[#self._modules_meta + 1] = mod
        
        -- If this is a new module, register it in settings with its default state
        if not is_known then
            local default_state = mod.default_enabled ~= false
            module_states[mod.id] = default_state
            self:_getSettings():saveSetting("module_states", module_states)
            self:_getSettings():flush()
        end
        
        -- Register module with SimpleUI if enabled
        if self:_isModuleEnabled(mod.id, mod.default_enabled) then
            -- Wrap build() so the ctx is topped up before the module sees it.
            -- Idempotent: re-registering the same table (context switch) must
            -- not stack wrappers.
            if type(mod.build) == "function" and not mod._sui_ext_build_wrapped then
                local orig_build = mod.build
                mod._sui_ext_orig_build = orig_build
                mod.build = function(w, ctx)
                    _hydrateCtx(ctx)
                    return orig_build(w, ctx)
                end
                mod._sui_ext_build_wrapped = true
            end
            Registry.register(mod)
            -- Track it in sui_compat so its registry preload hook injects the
            -- module into EVERY registry instance created from now on --
            -- SimpleUI's teardown evicts the registry from package.loaded on
            -- each context switch, and any instance built after this register()
            -- call would otherwise start with an empty _external list.
            if Compat and Compat.trackModule then pcall(Compat.trackModule, mod) end
            -- ...and into the table the live engine holds, when that is a
            -- different one. See _engineRegistry() for why it can be.
            local ER = self:_engineRegistry()
            if ER and ER ~= Registry then
                if not self._diag.engine_registry_differs then
                    self._diag.engine_registry_differs = true
                end
                pcall(ER.register, mod)
            end
            self._mod_ids[#self._mod_ids + 1] = mod.id
            self._mods[#self._mods + 1]       = mod
            -- Registered != visible on a screen: SimpleUI only paints a
            -- module once it has been added to a page in Arrange Modules.
            _rec("registered with SimpleUI")
        else
            if Compat and Compat.untrackModule then pcall(Compat.untrackModule, mod.id) end
            _rec("off (this plugin's Modules menu)")
        end
        ::continue_module::
    end

    -- Verify the registrations actually stuck.
    --
    -- Registry.register() only appends to the registry's _external list; the
    -- module does not become visible until the next Registry.list()/_load().
    -- Anything that runs Registry.invalidate() or unregister() in between --
    -- including this plugin's own onClosePlugin() on the FileManager<->Reader
    -- context switch -- can undo it, and that failure is otherwise completely
    -- silent: no error, the module simply never shows up in Arrange Modules.
    --
    -- Costs one Registry.list(), which force-loads SimpleUI's built-in modules
    -- a little earlier than their designed lazy first-paint. Bounded, once per
    -- context, and SimpleUI calls list() on its first render anyway.
    if #self._mod_ids > 0 then
        local ok_l, live = pcall(Registry.list)
        if ok_l and type(live) == "table" then
            local seen = {}
            for _i, m in ipairs(live) do
                if type(m) == "table" and m.id then seen[m.id] = true end
            end
            for _i, r in ipairs(self._diag.modules) do
                if r.status == "registered with SimpleUI" and not seen[r.id] then
                    r.status = "REGISTERED BUT MISSING from Registry.list()"
                end
            end
            self._diag.registry_size = #live
        else
            self._diag.registry_size = "Registry.list() failed: " .. tostring(live)
        end
    end

    -- Apply patches from patches/.
    -- Hybrid approach: First-time discovery + subsequent skip for disabled patches.
    -- - New patches (not in settings): require() once to get metadata, store in settings
    -- - Known patches: check enabled state, skip require() if disabled
    -- This ensures all patches appear in menu while maximizing performance.
    self._patches_meta = {}
    local patch_states = self:_getSettings():readSetting("patch_states") or {}
    local existing_patches = {}  -- Track which patches exist (for cleanup later)

    local discovered_patches = discover_patches(self.path)
    self._diag.n_patch_files = #discovered_patches

    for _i, path in ipairs(discovered_patches) do
        -- Extract patch_id from path (e.g., "patches/patch_coverdeck_exclude" -> "coverdeck_exclude")
        -- Note: [%w_]+ matches alphanumeric + underscore (not just %w which excludes underscore)
        local patch_id = path:match("patch_([%w_]+)$")
        local function _prec(st, extra)
            self._diag.patches[#self._diag.patches + 1] =
                { id = patch_id or path, status = st, detail = extra }
        end
        if not patch_id then
            logger.dbg("simpleui_ext: could not extract patch_id from path '" .. path .. "'")
            _prec("bad file name")
            goto continue_patch
        end
        existing_patches[patch_id] = true  -- Mark as existing
        
        -- Check if this patch is known (exists in settings)
        -- IMPORTANT: We assume patch.id == filename-based patch_id for performance
        -- If they differ, the patch must be loaded to get the real ID
        local is_known = patch_states[patch_id] ~= nil
        
        if is_known then
            -- Known patch: check enabled state BEFORE require (performance optimization)
            if not self:_isPatchEnabled(patch_id, false) then
                -- Still need to add minimal metadata for menu (without requiring)
                self._patches_meta[#self._patches_meta + 1] = {
                    id = patch_id,
                    name = patch_id:gsub("_", " "):gsub("(%a)([%w_']*)", function(first, rest)
                        return first:upper() .. rest:lower()
                    end),
                    description = _("Disabled patch (enable to load)"),
                    default_enabled = false,
                }
                _prec("off (this plugin's Patches menu)")
                goto continue_patch
            end
        end
        
        -- New patch OR enabled patch: require() to get full metadata
        local ok3, patch = pcall(require, path)
        if not ok3 or type(patch) ~= "table" then
            logger.dbg("simpleui_ext: failed to load patch '" .. path ..
                        "': " .. tostring(patch))
            _prec("LOAD ERROR", tostring(patch))
            goto continue_patch
        elseif type(patch.apply) ~= "function" then
            logger.dbg("simpleui_ext: patch '" .. path ..
                        "' has no apply() function — skipped")
            _prec("no apply() function")
            goto continue_patch
        end
        
        -- Validate: patch.id MUST match filename-based patch_id
        if patch.id ~= patch_id then
            logger.err("simpleui_ext: patch '" .. path .. "' has mismatched ID — SKIPPED")
            logger.err("  Expected (from filename): '" .. patch_id .. "'")
            logger.err("  Actual (from patch.id):  '" .. patch.id .. "'")
            logger.err("  Fix: Rename file to 'patch_" .. patch.id .. ".lua' OR change P.id to '" .. patch_id .. "'")
            _prec("id mismatch", "P.id = " .. tostring(patch.id))
            goto continue_patch
        end
        
        if is_known then
            -- Already known, check if enabled
            if not self:_isPatchEnabled(patch.id, false) then
                -- Still need to add minimal metadata for menu (without requiring)
                self._patches_meta[#self._patches_meta + 1] = {
                    id = patch_id,
                    name = patch_id:gsub("_", " "):gsub("(%a)([%w_']*)", function(first, rest)
                        return first:upper() .. rest:lower()
                    end),
                    description = _("Disabled patch (enable to load)"),
                    default_enabled = false,
                }
                _prec("off (this plugin's Patches menu)")
                goto continue_patch
            end
        end
        
        -- Store full metadata (patch already loaded above)
        self._patches_meta[#self._patches_meta + 1] = patch
        
        -- If this is a new patch, register it in settings with its default state
        if not is_known then
            local default_state = patch.default_enabled == true
            patch_states[patch.id] = default_state
            self:_getSettings():saveSetting("patch_states", patch_states)
            self:_getSettings():flush()
        end
        
        -- Apply patch if enabled
        if self:_isPatchEnabled(patch.id, patch.default_enabled) then
            local ok4, err = pcall(patch.apply)
            if ok4 then
                _prec("applied")
            else
                logger.dbg("simpleui_ext: patch '" .. (patch.id or path) ..
                            "' apply() failed: " .. tostring(err))
                _prec("APPLY ERROR", tostring(err))
            end
        else
            _prec("off (this plugin's Patches menu)")
        end
        ::continue_patch::
    end
    
    -- Cleanup: Remove deleted files from settings
    -- This prevents "ghost" entries in the menu for files that no longer exist
    local module_states_cleaned = false
    for module_id in pairs(module_states) do
        if not existing_modules[module_id] then
            module_states[module_id] = nil
            module_states_cleaned = true
        end
    end
    if module_states_cleaned then
        self:_getSettings():saveSetting("module_states", module_states)
        self:_getSettings():flush()
    end
    
    local patch_states_cleaned = false
    for patch_id in pairs(patch_states) do
        if not existing_patches[patch_id] then
            patch_states[patch_id] = nil
            patch_states_cleaned = true
        end
    end
    if patch_states_cleaned then
        self:_getSettings():saveSetting("patch_states", patch_states)
        self:_getSettings():flush()
    end

    -- After the modules are registered AND the patches have run, so the screen
    -- rebuilds against the final set.
    pcall(function() self._diag.rebuilt_screens = self:_refreshStaleScreens() end)

end

-- ---------------------------------------------------------------------------
-- _refreshStaleScreens()
--
-- Forces a live screen to re-resolve its module table when it was built
-- before our modules existed.
--
-- ScreenWidget caches the walk from layout.pages to module objects in
-- self._enabled_mods_cache, and only redoes it when the layout FINGERPRINT
-- changes -- and that fingerprint is built from the module ids in the layout,
-- not from what the registry can actually resolve:
--
--     if not self._enabled_mods_cache
--        or self._enabled_mods_cache.layout_fingerprint ~= layout_fingerprint then
--
-- So when the home screen renders before this plugin has registered (our
-- _register runs on a scheduler tick, after SimpleUI's own init), every one of
-- our ids resolves through Registry.get() to nil, the pages holding them come
-- out empty, and the fingerprint is unchanged forever after -- the table is
-- never rebuilt, however many times we register afterwards. Registry.register()
-- calls Registry.invalidate(), but that clears the REGISTRY's cache, not the
-- screen widget's.
--
-- SimpleUI's own _rebuildScreenLayout() clears exactly this cache, so ask for
-- it -- but only when there is really a gap: an id that the screen's layout
-- references and its cache does not hold. Rebuilding unconditionally would
-- mean a full relayout on every FileManager <-> Reader switch.
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:_refreshStaleScreens()
    if #(self._mod_ids or {}) == 0 then return false end

    local Engine = self:_engine()
    if type(Engine) ~= "table" or type(Engine.rebuildLayout) ~= "function" then
        return false
    end

    local ok_s, S = pcall(require, "sui_store")
    if not ok_s or not S then return false end

    local ours = {}
    for _i, id in ipairs(self._mod_ids) do ours[id] = true end

    local stale = false
    for _i, sc in ipairs(self:_screens()) do
        local inst = nil
        if sc.id == "hs" then inst = Engine._instance
        elseif type(Engine.getInstance) == "function" then
            inst = select(2, pcall(Engine.getInstance, sc.id))
        end
        local cache = type(inst) == "table" and inst._enabled_mods_cache
        -- No cache yet means the screen has not rendered; it will resolve us
        -- correctly on its first render, so there is nothing to fix.
        if type(cache) == "table" and type(cache.pages_of_mods) == "table" then
            local resolved = {}
            for _j, page in ipairs(cache.pages_of_mods) do
                for _k, m in ipairs(page) do
                    if type(m) == "table" and m.id then resolved[m.id] = true end
                end
            end
            for _j, page in ipairs(sc.pages) do
                for _k, id in ipairs(page) do
                    if ours[id] and not resolved[id] then
                        stale = true
                        break
                    end
                end
                if stale then break end
            end
        end
        if stale then break end
    end

    if not stale then
        return false
    end

    -- Before rebuilding, make sure the engine's registry can resolve us at
    -- all -- a rebuild against a registry that lacks our modules just walks
    -- the same empty pages again.
    pcall(function() self:_healEngineRegistry() end)

    -- Before rebuilding, make sure the engine will re-read the SAME layout we
    -- see. The live engine can hold an orphaned sui_store instance (see
    -- _engineStore); a rebuild through it re-reads a stale in-memory layout
    -- and resolves the same empty pages again. Push the current layouts into
    -- the engine's store first, so the rebuild works from current data.
    pcall(function()
        local ES = self:_engineStore()
        if not ES then
            return
        end
        if ES == S then
            return
        end
        for _i, sc in ipairs(self:_screens()) do
            ES:saveSetting(sc.layout_key, S:readSetting(sc.layout_key))
            ES:saveSetting(sc.pfx .. "module_order", S:readSetting(sc.pfx .. "module_order"))
        end
    end)

    local ok_r, err = pcall(Engine.rebuildLayout)
    if not ok_r then
        logger.dbg("simpleui_ext: rebuildLayout failed: " .. tostring(err))
        return false
    end
    return true
end

-- Runs once after _register. Opens the stats DB, pulls the current +
-- recent books from the shared prefetcher, and hands the result to every
-- module that exposes a `prewarm` hook. Without this, the home screen's
-- first paint runs under _defer_stats=true (db_conn=nil) and stats render
-- empty; with this, the SQL has already run and the first paint has data.
-- Every step is pcall-wrapped — a bad DB or any module's prewarm throwing
-- does not abort registration.
function SimpleUIExtPlugin:_prewarmBookModuleCaches()
    if not self._mods or #self._mods == 0 then return end

    -- Skip the DB connection + prefetchBooks() cost entirely when nothing
    -- registered actually consumes it (e.g. Hero Currently Reading disabled).
    local has_prewarm = false
    for _i, mod in ipairs(self._mods) do
        if type(mod.prewarm) == "function" then
            has_prewarm = true
            break
        end
    end
    if not has_prewarm then return end

    pcall(function()
        local ok_cfg, Config = pcall(require, "sui_config")
        if not ok_cfg or not Config or type(Config.openStatsDB) ~= "function" then
            return
        end

        local db_conn = Config.openStatsDB()
        if not db_conn then return end

        local ok_sh, SH = pcall(require, "desktop_modules/module_books_shared")
        if not ok_sh or not SH or type(SH.prefetchBooks) ~= "function" then
            pcall(function() db_conn:close() end)
            return
        end

        local books_state
        pcall(function()
            -- 5 books: current + 4 most recent. Matches the typical
            -- "Recently read" rail width and keeps prewarm well under
            -- a frame even on cold cache.
            books_state = SH.prefetchBooks(true, true, 5)
        end)
        if not books_state then
            pcall(function() db_conn:close() end)
            return
        end

        for _i, mod in ipairs(self._mods) do
            if type(mod.prewarm) == "function" then
                pcall(function() mod.prewarm(books_state, db_conn) end)
            end
        end

        pcall(function() db_conn:close() end)
    end)
end

-- Flags a deferred refresh; _runDeferredStatsRefresh() does the actual
-- SQL re-query + repaint after the 2-second settle window.
function SimpleUIExtPlugin:onCloseDocument()
    for _i, mod in ipairs(self._mods) do
        if type(mod.invalidateCache) == "function" then
            mod.invalidateCache()
        end
    end

    -- Settle window: ReaderUI flushes page_stat rows synchronously on
    -- close, but a brief defer avoids racing with whatever else KOReader
    -- may still be writing (highlights, time-on-page). 2s gives the DB
    -- a comfortable margin without making the stats feel stale.
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(2, function()
        -- Bail if the reader reopened during the settle window.
        local ok_r, RUI = pcall(require, "apps/reader/readerui")
        if not ok_r or (RUI and RUI.instance) then return end

        -- Before requiring anything of SimpleUI's: the 2s settle window is
        -- long enough for a teardown to have swapped its modules out.
        -- Skip if the homescreen is not on screen — there is nothing to
        -- repaint, and the next HS open pulls fresh data on its own.
        -- Via _engine() like every other lookup: see its doc comment for why
        -- resolving the engine two ways gives two different answers.
        local HS = self:_engine()
        if not HS or not HS._instance then return end

        self:_runDeferredStatsRefresh(HS._instance)
    end)
end

-- Single-shot: open a stats DB connection, run refreshStats on every
-- module that exposes it, close the connection, then trigger an HS
-- rebuild so the freshly-cached values appear in the next render.
--
-- Why _updatePage(false) and not setDirty("ui"): setDirty only repaints
-- existing widgets — fetchStatsFromDB lives inside the build path, so
-- the new cache values would never be read unless we force a rebuild.
-- _updatePage(false) clears _ctx_cache, so the next paint runs _buildCtx
-- and every module's build() sees the new cache.
function SimpleUIExtPlugin:_runDeferredStatsRefresh(hs_instance)
    -- Aliases were synced by the caller (onCloseDocument) right before it
    -- resolved hs_instance, so the requires below already see live modules.
    local ok_cfg, Config = pcall(require, "sui_config")
    if not ok_cfg or not Config or type(Config.openStatsDB) ~= "function" then return end
    local db_conn = Config.openStatsDB()
    if not db_conn then return end

    for _i, mod in ipairs(self._mods) do
        if type(mod.refreshStats) == "function" then
            pcall(function() mod.refreshStats(nil, db_conn) end)
        end
    end
    pcall(function() db_conn:close() end)

    -- pcall-wrapped: _updatePage drives a full module rebuild and can
    -- throw if the homescreen is mid-teardown. UIManager:setDirty after
    -- a successful rebuild nudges E-ink to repaint immediately.
    pcall(function()
        hs_instance:_updatePage(false)
        local UIManager = require("ui/uimanager")
        UIManager:setDirty(hs_instance, "ui")
    end)
end

-- Fires when the UI this plugin instance belongs to goes away — notably on
-- every FileManager <-> Reader context switch, which creates a fresh instance
-- and tears the old one down.
--
-- Deliberately does NOT unregister our modules any more. KOReader creates the
-- incoming context's plugins BEFORE tearing the outgoing one down, so this
-- teardown can land AFTER the incoming instance's _register() — unregistering
-- here then silently undid a registration that had already been reported as
-- successful, and the modules vanished with no error anywhere. Leaving them
-- registered is safe: Registry.register() replaces an entry with the same id,
-- so the incoming instance's re-registration never stacks duplicates, and the
-- module tables are process-wide singletons anyway. A module the user disables
-- in our menu is dropped on the next _register() (it is skipped and untracked
-- there), which matches the existing "restart to apply" UX.
function SimpleUIExtPlugin:onClosePlugin()
    self._registry     = nil
    self._mod_ids      = {}
    self._mods         = {}
    self._patches_meta = {}
    self._modules_meta = {}
end

-- ---------------------------------------------------------------------------
-- Menu Integration
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:addToMainMenu(menu_list)
    menu_list["simpleui_ext"] = {
        text = _("SimpleUI Extra"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Patches"),
                sub_item_table_func = function() return self:_buildPatchMenu() end,
            },
            {
                text = _("Modules"),
                sub_item_table_func = function() return self:_buildModuleMenu() end,
            },
            -- "Add my modules to the Home Screen" is deliberately not listed
            -- here. _addModulesToHomescreen() is kept below and still works;
            -- re-add an entry pointing at it to expose the action again.
            {
                text = _("Diagnostics"),
                separator = true,
                keep_menu_open = true,
                callback = function() self:_showDiagnostics() end,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Diagnostics
--
-- Module and patch loading is pcall-wrapped end to end, so anything that
-- fails is skipped silently and simply never shows up — in SimpleUI's Arrange
-- Modules list, in a module's settings, or anywhere else. That is fine at
-- runtime (one broken patch must not take the plugin down) but leaves no
-- way to tell "disabled" apart from "crashed on load" or "SimpleUI moved the
-- file". This dumps what _register() recorded for the current session.
-- ---------------------------------------------------------------------------
-- Every module id placed on a page of any SimpleUI screen (the built-in
-- Homescreen plus every Custom Screen), read straight from SimpleUI's own
-- settings. Registering a module only makes SimpleUI aware of it; since
-- SimpleUI 2.x nothing is painted until the id is also placed on a page via
-- Arrange Modules, and those are two very different reasons for a module to
-- be missing from the screen.
function SimpleUIExtPlugin:_placedModuleIds()
    local placed, ok_any = {}, false

    local ok_s, S = pcall(require, "sui_store")
    if not ok_s or not S then return placed, false end

    local function collect(layout)
        if type(layout) == "table" and type(layout.pages) == "table" then
            ok_any = true
            for _i, page in ipairs(layout.pages) do
                for _j, entry in ipairs(page.modules or {}) do
                    local id = _entryId(entry)
                    if id then placed[id] = true end
                end
            end
        end
    end

    pcall(function() collect(S:readSetting("simpleui_layout")) end)
    pcall(function()
        local CS = require("infra/sui_custom_screens")
        for _i, screen in ipairs(CS.list()) do
            collect(S:readSetting(screen.layout_key))
        end
    end)

    return placed, ok_any
end

-- ---------------------------------------------------------------------------
-- _probeRegistry() -> { lines }
--
-- Re-runs, verbatim, the test SimpleUI's "Add Module" screen uses to decide
-- what to offer (screens/sui_settings_window.lua, buildModulePicker):
--
--     for _, mod in ipairs(Registry.list()) do
--         local is_instance = mod.id:match("_row_") ~= nil  -- 3.0: Registry.isInstance(mod.id)
--         if not active_set[mod.id] and not is_instance then  -- offer it
--
-- Deliberately called late -- from the Diagnostics screen, and from a delayed
-- log -- rather than during _register(). The check inside _register() runs
-- BEFORE the patches, so it sees the raw Registry.list; the picker sees
-- whatever patch_module_copies wrapped it with. Measuring at the same point
-- the picker does is the only way to tell those two apart.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- _addModulesToHomescreen()
--
-- Appends this plugin's registered modules to SimpleUI's Home Screen layout,
-- on a new page at the end, skipping any that are already placed somewhere.
--
-- Why this exists: SimpleUI 2.5 builds its new "simpleui_layout" once, by
-- filtering the old flat module order through Registry.get(). Any module not
-- registered at that moment is dropped from the layout permanently -- which is
-- what happened to this plugin's modules during the upgrade. They are still
-- offered in SimpleUI's own Add Module picker, but that list is paginated and
-- ours sort last, so re-adding six modules by hand is a chore.
--
-- Mirrors LayoutService.save()'s three effects (settings_window.lua) rather
-- than only writing the layout, because SimpleUI reads all three: the layout,
-- the flat module order, and each module's own enabled flag.
--
-- Additive and explicit: only ever appends, never reorders or removes, and
-- only runs when the user taps the menu entry and confirms.
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:_addModulesToHomescreen()
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    -- Every exit path logs. The action writes to SimpleUI's settings on a
    -- single user tap, so "I pressed it and nothing happened" has to be
    -- answerable from the log alone.
    local function fail(msg)
        self._last_add_result = msg
        UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
    end


    pcall(function() require("utils/sui_compat").syncAliases() end)

    local ok_s, S = pcall(require, "sui_store")
    local ok_r, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok_s or not S or not ok_r or not Registry then
        return fail(_("SimpleUI is not available."))
    end

    -- Target the screen that is actually on display, not always the built-in
    -- Homescreen. A Custom Screen is a separate home screen with its own
    -- layout key and settings prefix, so writing to "simpleui_layout" while
    -- the user is looking at a Custom Screen adds the modules to a screen they
    -- never see -- and the engine, reading the other layout, never even builds
    -- them. Falls back to the built-in Homescreen when nothing is open.
    local target = nil
    for _i, sc in ipairs(self:_screens()) do
        if sc.live then target = sc; break end
    end
    target = target or { id = "hs", pfx = "simpleui_hs_", layout_key = "simpleui_layout" }
    local pfx = target.pfx

    local layout = S:readSetting(target.layout_key)
    if type(layout) ~= "table" or type(layout.pages) ~= "table" or #layout.pages == 0 then
        return fail(_("No layout found for the screen on display. Open its "
                      .. "Layout Editor once, then try again."))
    end

    local placed = {}
    for _i, page in ipairs(layout.pages) do
        for _j, entry in ipairs(page.modules or {}) do
            local id = _entryId(entry)
            if id then placed[id] = true end
        end
    end
    local was_placed = 0
    for _i, id in ipairs(self._mod_ids or {}) do
        if placed[id] then was_placed = was_placed + 1 end
    end

    -- Normally self._mod_ids. If this instance never registered (e.g. the menu
    -- belongs to a different plugin instance than the one that ran _register),
    -- fall back to matching our discovered module ids against the live
    -- registry, so the action still does the right thing instead of silently
    -- reporting "nothing to add".
    local candidates = {}
    for _i, id in ipairs(self._mod_ids or {}) do candidates[#candidates + 1] = id end
    if #candidates == 0 then
        local ok_l0, live = pcall(Registry.list)
        if ok_l0 and type(live) == "table" then
            local live_ids = {}
            for _i, m in ipairs(live) do
                if type(m) == "table" and type(m.id) == "string" then live_ids[m.id] = true end
            end
            for _i, meta in ipairs(self._modules_meta or {}) do
                if meta.id and live_ids[meta.id] then candidates[#candidates + 1] = meta.id end
            end
        end
    end

    if #candidates == 0 then
        return fail(_("No registered modules found to add. Open Diagnostics for details."))
    end

    -- Re-place rather than only add. A module of ours that is already on a page
    -- is first lifted off it, so running this again re-packs a page that is
    -- overflowing instead of reporting "nothing to do" and leaving it broken.
    -- Only our own ids are ever moved; every other module keeps its slot.
    local ours = {}
    for _i, id in ipairs(candidates) do ours[id] = true end

    local lifted = 0
    for _i, page in ipairs(layout.pages) do
        local kept = {}
        for _j, entry in ipairs(page.modules or {}) do
            if ours[_entryId(entry)] then lifted = lifted + 1 else kept[#kept + 1] = entry end
        end
        page.modules = kept
    end
    -- Drop pages our removal emptied; a page left with nothing on it is just a
    -- blank swipe. Pages that were already empty are left alone.
    if lifted > 0 then
        local kept_pages = {}
        for _i, page in ipairs(layout.pages) do
            if #(page.modules or {}) > 0 then kept_pages[#kept_pages + 1] = page end
        end
        if #kept_pages == 0 then kept_pages[1] = { id = 1, modules = {} } end
        for i, page in ipairs(kept_pages) do page.id = i end
        layout.pages = kept_pages
    end

    local to_add = candidates

    -- New pages rather than appending to an existing one: that cannot overflow
    -- someone's carefully arranged page, and the modules are trivial to move or
    -- delete from there in SimpleUI's Layout Editor.
    --
    -- Plural, because these modules are big. Building all six measured 2606px
    -- of content -- two to three screens' worth. Putting them on one page
    -- guarantees a page that runs far past the bottom, which SimpleUI can only
    -- answer with its "Modules exceed the visible area" warning. So measure
    -- each one and pack them into as many pages as they actually need.
    local avail_h = 0
    pcall(function() avail_h = require("sui_core").getContentHeight() end)
    if type(avail_h) ~= "number" or avail_h <= 0 then
        avail_h = require("device").screen:getHeight()
    end

    local probe_ctx, cleanup = self:_makeProbeCtx(pfx)
    local heights = {}
    for _i, id in ipairs(to_add) do
        local h
        local mod = select(2, pcall(Registry.get, id))
        if type(mod) == "table" and type(mod.build) == "function" then
            local ok_b, w = pcall(mod.build, probe_ctx._w, probe_ctx)
            if ok_b and w then
                local ok_sz, sz = pcall(function() return w:getSize() end)
                if ok_sz and sz then h = sz.h end
            end
        end
        -- Unknown height: assume a third of a screen, so it still gets packed
        -- conservatively instead of being treated as costing nothing.
        heights[id] = h or math.floor(avail_h / 3)
    end
    if cleanup then pcall(cleanup) end

    local pages_added, cur, cur_h = 0, nil, 0
    for _i, id in ipairs(to_add) do
        local h = heights[id]
        if not cur or (cur_h > 0 and cur_h + h > avail_h) then
            cur = { id = #layout.pages + 1, modules = {} }
            layout.pages[#layout.pages + 1] = cur
            pages_added = pages_added + 1
            cur_h = 0
        end
        cur.modules[#cur.modules + 1] = id
        cur_h = cur_h + h
        placed[id] = true
    end
    S:saveSetting(target.layout_key, layout)

    -- LayoutService.save() effect 2: the flat order (placed first, then the rest).
    local flat_order = {}
    for _i, page in ipairs(layout.pages) do
        for _j, entry in ipairs(page.modules or {}) do
            local id = _entryId(entry)
            if id then flat_order[#flat_order + 1] = id end
        end
    end
    local ok_l, mods = pcall(Registry.list)
    if ok_l and type(mods) == "table" then
        for _i, m in ipairs(mods) do
            if type(m) == "table" and type(m.id) == "string" and not placed[m.id] then
                flat_order[#flat_order + 1] = m.id
            end
        end
    end
    S:saveSetting(pfx .. "module_order", flat_order)

    -- LayoutService.save() effect 3: each module's own enabled flag.
    if ok_l and type(mods) == "table" then
        for _i, m in ipairs(mods) do
            if type(m) == "table" and type(m.id) == "string" then
                local on = placed[m.id] == true
                if type(m.setEnabled) == "function" then
                    pcall(m.setEnabled, pfx, on)
                elseif m.enabled_key then
                    S:saveSetting(pfx .. m.enabled_key, on)
                end
            end
        end
    end
    pcall(function() S:flush() end)

    -- If the live engine reads through a different (orphaned) sui_store
    -- instance, mirror what we just saved into it, or the repaint below
    -- re-reads the old layout and paints the same screen again.
    pcall(function()
        local ES = self:_engineStore()
        if ES and ES ~= S then
            ES:saveSetting(target.layout_key, layout)
            ES:saveSetting(pfx .. "module_order", flat_order)
        end
    end)

    -- Repaint the Home Screen if it happens to be open.
    pcall(function()
        local HS = self:_engine()
        if not HS then return end
        if target.id ~= "hs" and type(HS.refreshScreen) == "function" then
            HS.refreshScreen(target.id, false)
        elseif HS._instance and HS.refresh then
            HS.refresh(false)
        end
    end)

    self._last_add_result = ("added %d module(s) across %d new page(s): %s")
                            :format(#to_add, pages_added, table.concat(to_add, ", "))
    UIManager:show(InfoMessage:new{
        text = string.format(
            _("Added %d module(s) across %d new Home Screen page(s):\n\n%s\n\n"
              .. "They are split by measured height so no page overflows. Move "
              .. "them where you want in Simple UI Settings > Home Screen > "
              .. "Layout Editor."),
            #to_add, pages_added, table.concat(to_add, ", ")),
    })
end

-- ---------------------------------------------------------------------------
-- _screens() -> { { id, pfx, layout_key, live, pages = { {ids}, ... } }, ... }
--
-- Every SimpleUI screen and the layout each one reads.
--
-- SimpleUI 2.5 added "Extra Custom Screens": each is a full home screen with
-- its OWN settings prefix and layout key ("simpleui_cs_<id>_" /
-- "simpleui_layout_cs_<id>", see infra/sui_custom_screens.lua), separate from
-- the built-in Homescreen's "simpleui_hs_" / "simpleui_layout". Placing a
-- module in one of them says nothing about the others -- and the Layout Editor
-- opens the built-in Homescreen by default, so "I added it and the settings
-- show it" can be true of a screen you are not the one looking at.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- _engine() -> ScreenEngine | nil
--
-- The one way this plugin resolves SimpleUI's screen engine.
--
-- It must be one way, because the engine table is not a stable singleton:
-- "screens/sui_homescreen" is in SimpleUI's _PLUGIN_MODULES eviction list, so
-- a teardown drops it from package.loaded and the next require builds a FRESH
-- ScreenEngine -- and the live home screen widget lives in a FIELD of that
-- table (ScreenEngine._instance). Resolve it two different ways and you get
-- two different answers to "is the home screen open": that is exactly what
-- happened here, with the diagnostics probe reading package.loaded and the
-- staleness check requiring through our compat alias, one line apart in the
-- log, one saying LIVE and the other saying not open.
--
-- package.loaded["screens/sui_homescreen"] first, because that is the entry
-- SimpleUI itself uses; the alias require is only a fallback for a layout
-- where the foldered name does not exist.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- _engineRegistry() -> Registry | nil
--
-- The module registry the LIVE screen engine actually uses, which is not
-- necessarily the one require() hands us.
--
-- engines/sui_screen_engine.lua captures it once, at file scope:
--
--     local Registry = require("modules/moduleregistry")
--
-- That is an upvalue of every function in the chunk. SimpleUI's teardown
-- evicts "modules/moduleregistry" from package.loaded, so the next require
-- builds a BRAND NEW registry table -- but the screen widget already running
-- keeps the old one in its upvalue for the rest of its life. Register into the
-- new table and the live engine never sees the modules: Registry.get() returns
-- nil inside its page walk, the pages holding our modules resolve empty, and
-- no amount of rebuilding fixes it, because the rebuild re-runs the same walk
-- against the same stale table. That is exactly the state observed here --
-- our probe resolving all six while the engine, one second later, resolved
-- none.
--
-- So ask the engine which table it holds, instead of assuming. Identified
-- structurally (register/unregister/get/list/invalidate) rather than by
-- identity, since we have nothing to compare against.
-- ---------------------------------------------------------------------------
local function _looksLikeRegistry(v)
    return type(v) == "table"
       and type(v.register)   == "function"
       and type(v.unregister) == "function"
       and type(v.get)        == "function"
       and type(v.list)       == "function"
end

local function _looksLikeStore(v)
    return type(v) == "table"
       and type(v.readSetting) == "function"
       and type(v.saveSetting) == "function"
end

-- Walks the upvalues of the live engine's own functions and returns the first
-- one `pred(name, value)` accepts. Lua binds a function only the upvalues it
-- ACTUALLY references, so it is not enough to grab any function off the engine
-- table: ScreenEngine.show and .rebuildLayout are defined in
-- screens/sui_homescreen.lua (a chunk with no Registry at all), and
-- .getInstance only touches _sget. The functions that do reference Registry
-- and SUISettings are the ScreenWidget methods in engines/sui_screen_engine.lua
-- -- _buildCtx and _updatePage use both directly -- so go through the live
-- instance first, and keep the module-level ones as a fallback.
function SimpleUIExtPlugin:_engineUpvalue(pred)
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
    local Engine = self:_engine()
    if type(Engine) ~= "table" then return nil end

    local inst = Engine._instance
    local probes = {}
    if type(inst) == "table" then
        probes[#probes + 1] = inst._updatePage
        probes[#probes + 1] = inst._buildCtx
        probes[#probes + 1] = inst._prefetchBooks   -- 3.0 (references Registry)
        probes[#probes + 1] = inst._getCtxMenu      -- <= 2.6; removed in 3.0
        probes[#probes + 1] = inst._openModuleSettingsFor
        probes[#probes + 1] = inst._showBookHoldDialog
    end
    probes[#probes + 1] = Engine._open
    probes[#probes + 1] = Engine.refreshScreen
    probes[#probes + 1] = Engine.showCustomScreen
    probes[#probes + 1] = Engine.show
    probes[#probes + 1] = Engine.rebuildLayout
    for _i, fn in ipairs(probes) do
        if type(fn) == "function" then
            local i = 1
            while true do
                local ok, name, val = pcall(debug.getupvalue, fn, i)
                if not ok or name == nil then break end
                if pred(name, val) then return val end
                i = i + 1
            end
        end
    end
    return nil
end

function SimpleUIExtPlugin:_engineRegistry()
    return self:_engineUpvalue(function(_name, val) return _looksLikeRegistry(val) end)
end

-- ---------------------------------------------------------------------------
-- _healEngineRegistry()
--
-- When the LIVE engine holds a registry instance different from the one our
-- registrations landed in, copy our modules into the engine's instance and
-- invalidate it so its next _load() surfaces them. Belt and braces for
-- instances born before our hooks were in place (first install, hot reload);
-- with the preload hook and the front-positioned alias loader active, the two
-- registries should simply be the same table and this is a no-op.
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:_healEngineRegistry()
    if #(self._mods or {}) == 0 then return false end
    local ER = self:_engineRegistry()
    if not ER or ER == self._registry then return false end
    local n = 0
    for _i, mod in ipairs(self._mods) do
        if pcall(ER.register, mod) then n = n + 1 end
    end
    return n > 0
end

-- The sui_store instance the LIVE engine reads its layout through. Like the
-- registry, "infra/sui_store" is on SimpleUI's eviction list, so the live
-- engine chunk can hold an ORPHANED store whose in-memory settings no longer
-- match what a fresh require("sui_store") (and the file on disk) says -- a
-- layout we write through the fresh store is then invisible to the engine's
-- own SUISettings:readSetting(self._layout_key) walk, which reads pages
-- 2..n as empty exactly like a missing registry entry would.
function SimpleUIExtPlugin:_engineStore()
    -- Matched by the chunk-local's name first ("SUISettings" in
    -- engines/sui_screen_engine.lua); the shape check keeps a renamed local
    -- from slipping through as a miss, and keeps Config (which shares no API)
    -- from matching.
    return self:_engineUpvalue(function(name, val)
        return _looksLikeStore(val) and (name == "SUISettings" or name == "S" or
                                         name:match("[Ss]ettings") ~= nil or
                                         name:match("[Ss]tore") ~= nil)
    end)
end

function SimpleUIExtPlugin:_engine()
    pcall(function() require("utils/sui_compat").syncAliases() end)
    local E = package.loaded["screens/sui_homescreen"]
    if type(E) == "table" then return E end
    local ok, m = pcall(require, "sui_homescreen")
    if ok and type(m) == "table" then return m end
    return nil
end

-- ---------------------------------------------------------------------------
-- _enginePagesLines() -> { line, ... }
--
-- The engine's own resolved page table, read off the live screen widget.
-- ScreenWidget caches the walk from layout.pages to module objects in
-- self._enabled_mods_cache and only redoes it when the layout fingerprint
-- changes, so this is the difference between "the layout lists our module"
-- and "the engine knows about it".
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:_enginePagesLines()
    local out = {}
    local Engine = self:_engine()
    local inst = type(Engine) == "table" and Engine._instance or nil
    if not inst then
        out[1] = "home screen is not open right now"
        return out
    end
    out[#out + 1] = ("page %s of %s, layout_key=%s pfx=%s")
                    :format(tostring(inst._current_page), tostring(inst._total_pages),
                            tostring(inst._layout_key), tostring(inst._pfx))
    local cache = inst._enabled_mods_cache
    if type(cache) ~= "table" or type(cache.pages_of_mods) ~= "table" then
        out[#out + 1] = "  no _enabled_mods_cache yet (screen has not rendered)"
        return out
    end
    for i, page in ipairs(cache.pages_of_mods) do
        local ids = {}
        for _j, m in ipairs(page) do
            ids[#ids + 1] = (type(m) == "table" and m.id) or "?"
        end
        out[#out + 1] = ("  engine page %d: %s")
                        :format(i, #ids > 0 and table.concat(ids, ", ") or "(empty)")
    end
    return out
end

function SimpleUIExtPlugin:_screens()
    local out = {}
    local ok_s, S = pcall(require, "sui_store")
    if not ok_s or not S then return out end

    local Engine = self:_engine()

    local function pages_of(layout_key)
        local pages = {}
        local layout = S:readSetting(layout_key)
        if type(layout) == "table" and type(layout.pages) == "table" then
            for _i, page in ipairs(layout.pages) do
                local ids = {}
                for _j, entry in ipairs(page.modules or {}) do
                    local id = _entryId(entry)
                    if id then ids[#ids + 1] = id end
                end
                pages[#pages + 1] = ids
            end
        end
        return pages
    end

    local function live(id)
        if type(Engine) ~= "table" then return false end
        if type(Engine.getInstance) == "function" then
            return select(2, pcall(Engine.getInstance, id)) ~= nil
        end
        return id == "hs" and Engine._instance ~= nil
    end

    out[#out + 1] = { id = "hs", pfx = "simpleui_hs_", layout_key = "simpleui_layout",
                      live = live("hs"), pages = pages_of("simpleui_layout") }

    pcall(function()
        local CS = require("infra/sui_custom_screens")
        for _i, sc in ipairs(CS.list()) do
            out[#out + 1] = { id = sc.id, pfx = sc.pfx, layout_key = sc.layout_key,
                              live = live(sc.id), pages = pages_of(sc.layout_key) }
        end
    end)

    return out
end

function SimpleUIExtPlugin:_probeRegistry()
    local out = {}
    local function add(l) out[#out + 1] = l end


    pcall(function() require("utils/sui_compat").syncAliases() end)

    local ok_r, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok_r or not Registry then
        add("Registry unavailable: " .. tostring(Registry))
        return out
    end

    local ok_l, mods = pcall(Registry.list)
    if not ok_l or type(mods) ~= "table" then
        add("Registry.list() failed: " .. tostring(mods))
        return out
    end

    -- The picker builds active_set from the screen's own layout only.
    local active = {}
    pcall(function()
        local S = require("sui_store")
        local layout = S:readSetting("simpleui_layout")
        if type(layout) == "table" and type(layout.pages) == "table" then
            for _i, page in ipairs(layout.pages) do
                for _j, entry in ipairs(page.modules or {}) do
                    local id = _entryId(entry)
                    if id then active[id] = true end
                end
            end
        end
    end)

    local ours, offered = {}, 0
    for _i, id in ipairs(self._mod_ids or {}) do ours[id] = true end

    -- SimpleUI 3.0's picker asks Registry.isInstance(); <= 2.6 matched "_row_".
    local function isInstance(id)
        if type(Registry.isInstance) == "function" then
            local ok_i, r = pcall(Registry.isInstance, id)
            if ok_i then return r == true end
        end
        return id:match("_row_") ~= nil
    end

    add(("Registry.list() now returns %d module(s)"):format(#mods))
    local seen_idx = {}
    for i, m in ipairs(mods) do
        local id = type(m) == "table" and m.id
        if type(id) == "string" then
            if ours[id] then seen_idx[id] = i end
            if not active[id] and not isInstance(id) then offered = offered + 1 end
        end
    end
    add(("Add Module would offer %d entr(ies)"):format(offered))

    for _i, id in ipairs(self._mod_ids or {}) do
        if seen_idx[id] then
            local why = active[id] and "already placed -- picker hides it"
                        or (isInstance(id) and "treated as an instance -- picker hides it"
                            or "SHOULD BE OFFERED")
            add(("  %s: in list at #%d, %s"):format(id, seen_idx[id], why))
        else
            add(("  %s: NOT IN Registry.list()"):format(id))
        end
    end

    -- Render gate. A module that IS placed on a page still paints nothing
    -- unless it clears every check the screen engine makes before calling
    -- build() (engines/sui_screen_engine.lua's page loop):
    --
    --     local mod = Registry.get(mod_id)
    --     if mod and Registry.isEnabled(mod, self._pfx) then ...
    --
    -- Registry.isEnabled reads pfx..mod.enabled_key, which is a DIFFERENT
    -- setting from "is it in the layout" -- a module can be on a page and
    -- still be switched off. Past that, build() returning nil paints nothing
    -- either, and that is silent by design.
    local pfx = "simpleui_hs_"
    local ok_s2, S2 = pcall(require, "sui_store")
    add("Render gate (pfx " .. pfx .. ")")
    for _i, id in ipairs(self._mod_ids or {}) do
        local mod = select(2, pcall(Registry.get, id))
        if type(mod) ~= "table" then
            add(("  %s: Registry.get() -> nil, engine skips it"):format(id))
        else
            local raw = ok_s2 and S2 and mod.enabled_key
                        and S2:readSetting(pfx .. mod.enabled_key)
            local ok_e, enabled = pcall(Registry.isEnabled, mod, pfx)
            add(("  %s: enabled_key=%s setting=%s isEnabled=%s build=%s getHeight=%s needs=%s")
                :format(id, tostring(mod.enabled_key), tostring(raw),
                        ok_e and tostring(enabled) or ("ERR " .. tostring(enabled)),
                        type(mod.build), type(mod.getHeight),
                        mod.needs and "yes" or "no"))
        end
    end

    do
        local ER = self:_engineRegistry()
        if not ER then
            add("Engine registry: could not be read from the engine's upvalues")
        elseif ER == Registry then
            add("Engine registry: same instance we register into")
        else
            local n = select(2, pcall(function() return #ER.list() end))
            add(("Engine registry: DIFFERENT instance -- it holds %s module(s)")
                :format(tostring(n)))
        end
    end

    do
        local ok_s3, S3 = pcall(require, "sui_store")
        local ES = self:_engineStore()
        if not ES then
            add("Engine store: could not be read from the engine's upvalues")
        elseif ok_s3 and ES == S3 then
            add("Engine store: same instance require(\"sui_store\") returns")
        else
            -- A stale store makes the engine read an OLD layout: its page walk
            -- then never even asks the registry for our ids.
            local pages = "?"
            pcall(function()
                local lay = ES:readSetting("simpleui_layout")
                if type(lay) == "table" and type(lay.pages) == "table" then
                    local counts = {}
                    for _j, pg in ipairs(lay.pages) do
                        counts[#counts + 1] = tostring(#(pg.modules or {}))
                    end
                    pages = #lay.pages .. " page(s), module counts: " .. table.concat(counts, "/")
                end
            end)
            add("Engine store: DIFFERENT instance -- its simpleui_layout has " .. pages)
        end
    end

    -- Which screen holds our modules, and which screen is on display. These
    -- are not the same question, and the answer to the second one is what
    -- decides whether the engine ever asks for them.
    local ours_set = {}
    for _i, id in ipairs(self._mod_ids or {}) do ours_set[id] = true end
    add("Screens")
    for _i, sc in ipairs(self:_screens()) do
        local mine, total = 0, 0
        for _j, page in ipairs(sc.pages) do
            for _k, id in ipairs(page) do
                total = total + 1
                if ours_set[id] then mine = mine + 1 end
            end
        end
        add(("  %s%s: layout=%s pfx=%s -- %d page(s), %d module(s), %d of ours")
            :format(sc.id, sc.live and " [LIVE, on display]" or "",
                    sc.layout_key, sc.pfx, #sc.pages, total, mine))
    end

    -- The engine's OWN resolved page table, read off the live screen widget
    -- instead of re-derived from settings. Everything above says the layout is
    -- right; this says what the engine made of it. ScreenWidget caches the
    -- result of walking layout.pages through Registry.get + Registry.isEnabled
    -- in self._enabled_mods_cache, and paints only
    -- pages_of_mods[self._current_page] -- so if our modules are in the layout
    -- but missing from this table, the gap is in that walk, and if they are
    -- present here while build() is never called, the gap is after it.
    do
        local lines = self:_enginePagesLines()
        add("Engine state: " .. (lines[1] or ""))
        for i = 2, #lines do add(lines[i]) end
    end

    -- What the engine will actually put in ctx. _buildCtx only runs
    -- SH.prefetchBooks() when SimpleUI's OWN currently/recent/coverdeck module
    -- is enabled -- an external module cannot ask for it (M.needs.books only
    -- reaches the stats provider). Replacing those built-ins with ours
    -- therefore leaves ctx.current_fp nil and ctx.recent_fps empty for every
    -- module on the page, which is a very different ctx from the one probed
    -- below.
    do
        local mc  = select(2, pcall(Registry.get, "currently"))
        local mr  = select(2, pcall(Registry.get, "recent"))
        local mcd = select(2, pcall(Registry.get, "coverdeck"))
        local function en(m)
            if type(m) ~= "table" then return false end
            return select(2, pcall(Registry.isEnabled, m, pfx)) == true
        end
        local show_c = en(mc)
        local show_r = en(mr) or en(mcd)
        -- 3.0: any module may ask for recent books through M.needs.recent.
        if type(Registry.getRecentDemand) == "function" then
            local ok_d, demand = pcall(Registry.getRecentDemand, pfx)
            if ok_d and type(demand) == "number" then show_r = demand > 0 end
        end
        add(("Engine ctx: currently=%s recent=%s coverdeck=%s -> prefetchBooks %s")
            :format(tostring(en(mc)), tostring(en(mr)), tostring(en(mcd)),
                    (show_c or show_r) and "RUNS (ctx gets books)"
                                        or "SKIPPED (ctx.current_fp = nil, recent_fps = {})"))
    end

    -- The last gate, and the silent one: a module that clears everything above
    -- still paints nothing if build() returns nil. Call it here with a ctx
    -- shaped like the engine's (_buildCtx) so the answer is "returned nil" or
    -- "threw <error>" instead of a blank page.
    local probe_ctx, cleanup = self:_makeProbeCtx(pfx)
    add("build() with an engine-shaped ctx" ..
        (probe_ctx.current_fp and "" or " (note: no current book found)"))
    for _i, id in ipairs(self._mod_ids or {}) do
        local mod = select(2, pcall(Registry.get, id))
        if type(mod) == "table" and type(mod.build) == "function" then
            local ok_b, w = pcall(mod.build, probe_ctx._w, probe_ctx)
            if not ok_b then
                add(("  %s: build() THREW %s"):format(id, tostring(w)))
            elseif w == nil then
                add(("  %s: build() returned nil -- nothing is painted"):format(id))
            else
                local ok_sz, sz = pcall(function() return w:getSize() end)
                add(("  %s: build() ok, %s"):format(id,
                    ok_sz and sz and ("%dx%d"):format(sz.w or 0, sz.h or 0) or "size unknown"))
            end
        end
    end
    if cleanup then pcall(cleanup) end

    -- Second pass with the ctx the engine actually hands over when SimpleUI's
    -- own book modules are off: no books, no shared DB connection. If a module
    -- builds with the rich ctx above but not with this one, that gap is the
    -- reason its page paints blank.
    local bare = {
        pfx = pfx, recent_fps = {}, prefetched = {},
        open_fn = function() end, hold_fn = function() end,
        refresh_fn = function() end, on_qa_tap = function() end,
        on_goal_tap = function() end, sectionLabel = function() return nil end,
        vspan_pool = {},
    }
    -- Deliberately the UNWRAPPED build: mod.build is our wrapper, which tops
    -- the ctx up before calling through, so going via it would hide exactly
    -- the difference this pass exists to measure.
    add("build() with a bare ctx (no books, no db), bypassing our ctx top-up")
    for _i, id in ipairs(self._mod_ids or {}) do
        local mod = select(2, pcall(Registry.get, id))
        local raw = type(mod) == "table" and (mod._sui_ext_orig_build or mod.build)
        if type(raw) == "function" then
            local ok_b, w = pcall(raw, probe_ctx._w, bare)
            if not ok_b then
                add(("  %s: build() THREW %s"):format(id, tostring(w)))
            elseif w == nil then
                add(("  %s: build() returned nil -- THIS is the blank page"):format(id))
            else
                local ok_sz, sz = pcall(function() return w:getSize() end)
                add(("  %s: build() ok, %s"):format(id,
                    ok_sz and sz and ("%dx%d"):format(sz.w or 0, sz.h or 0) or "size unknown"))
            end
        end
    end

    return out
end

-- Builds a context resembling the one ScreenWidget:_buildCtx hands to
-- modules: prefix, the current/recent books, and a stats DB connection.
-- Returns the ctx plus a cleanup function that closes the connection.
function SimpleUIExtPlugin:_makeProbeCtx(pfx)
    local Screen = require("device").screen
    local ctx = {
        pfx          = pfx,
        recent_fps   = {},
        prefetched   = {},
        open_fn      = function() end,
        hold_fn      = function() end,
        refresh_fn   = function() end,
        on_qa_tap    = function() end,
        on_goal_tap  = function() end,
        sectionLabel = function() return nil end,
        vspan_pool   = {},
        -- SimpleUI 3.0 ctx fields modules may read unguarded.
        landscape_factor = 1,
        cfg          = {},
        _w           = math.max(200, Screen:getWidth() - 28),
    }

    pcall(function()
        local SH = require("desktop_modules/module_books_shared")
        local bs = SH.prefetchBooks(true, true, 5)
        if bs then
            ctx.current_fp = bs.current_fp
            ctx.recent_fps = bs.recent_fps or {}
            ctx.prefetched = bs.prefetched_data or {}
        end
    end)

    local conn
    pcall(function()
        local Config = require("sui_config")
        conn = Config.openStatsDB()
        ctx.db_conn = conn
    end)

    return ctx, function() if conn then conn:close() end end
end

function SimpleUIExtPlugin:_buildDiagText()
    local d = self._diag
    if not d then
        return _("Registration has not run yet. Reopen this menu in a moment.")
    end

    local NL  = "\n"
    local out = {}
    local function add(line) out[#out + 1] = line or "" end

    add(_("SimpleUI module registry: ") .. tostring(d.registry))
    if d.registry ~= "ok" then
        add("")
        add(_("Nothing else could run: without the registry no module can be "
              .. "registered and no patch is applied. Check that the SimpleUI "
              .. "plugin is installed and enabled."))
        return table.concat(out, NL)
    end

    if self._last_add_result then
        add("")
        add(_("Last 'Add my modules' result: ") .. tostring(self._last_add_result))
    end

    add("")
    add(_("What the Add Module screen sees, right now"))
    for _i, l in ipairs(self:_probeRegistry()) do add("  " .. l) end

    add("")
    add(_("Plugin path: ") .. tostring(d.plugin_path))
    add(_("Files on disk: ") .. ("%s module(s), %s patch(es)")
        :format(tostring(d.n_module_files), tostring(d.n_patch_files)))

    if d.registry_size ~= nil then
        add(_("Modules SimpleUI's registry reports: ") .. tostring(d.registry_size))
    end

    add("")
    add(_("Resolved SimpleUI paths"))
    for _i, r in ipairs(d.resolved or {}) do
        if r.real then
            add(("  %s -> %s"):format(r.name, r.real))
        else
            add(("  %s -> NOT FOUND"):format(r.name))
        end
    end

    local placed, know_layout = self:_placedModuleIds()

    local function section(title, rows, with_placement)
        add("")
        add(title .. (" (%d)"):format(#rows))
        if #rows == 0 then add("  " .. _("none discovered")) end
        for _i, r in ipairs(rows) do
            local line = ("  %s: %s"):format(r.id, r.status)
            if with_placement and know_layout and r.status == "registered with SimpleUI" then
                line = line .. (placed[r.id] and _(", placed on a screen")
                                             or _(", NOT placed on any screen"))
            end
            add(line)
            if r.detail then add("      " .. tostring(r.detail)) end
        end
    end
    section(_("Modules"), d.modules, true)
    section(_("Patches"), d.patches, false)

    add("")
    add(_("A module has to clear two separate bars to show up: registered "
          .. "here, and then placed on a page in SimpleUI's Arrange Modules. "
          .. "A module that is registered but not placed was dropped from the "
          .. "layout at some point — add it back from Arrange Modules."))
    return table.concat(out, NL)
end

function SimpleUIExtPlugin:_showDiagnostics()
    local UIManager  = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("SimpleUI Extra diagnostics"),
        text  = self:_buildDiagText(),
    })
end

function SimpleUIExtPlugin:_buildPatchMenu()
    local Blitbuffer = require("ffi/blitbuffer")
    local UIManager  = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    
    local menu = {}
    for _i, patch in ipairs(self._patches_meta) do
        table.insert(menu, {
            text = patch.name or patch.id,
            help_text = patch.description,
            checked_func = function()
                return self:_isPatchEnabled(patch.id, patch.default_enabled)
            end,
            callback = function()
                local currently_enabled = self:_isPatchEnabled(patch.id, patch.default_enabled)
                self:_setPatchEnabled(patch.id, not currently_enabled)
                
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Patch '%s' %s.\n\nPlease restart KOReader for changes to take effect."),
                            patch.name or patch.id, currently_enabled and _("disabled") or _("enabled")),
                    timeout = 3,
                })
            end,
        })
    end
    
    if #menu == 0 then
        table.insert(menu, {
            text = _("No patches available"),
            enabled = false,
        })
    end
    
    return menu
end

function SimpleUIExtPlugin:_buildModuleMenu()
    local Blitbuffer = require("ffi/blitbuffer")
    local UIManager  = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    
    local menu = {}
    for _i, mod in ipairs(self._modules_meta) do
        table.insert(menu, {
            text = mod.name or mod.id,
            help_text = mod.description,
            checked_func = function()
                return self:_isModuleEnabled(mod.id, mod.default_enabled)
            end,
            callback = function()
                local currently_enabled = self:_isModuleEnabled(mod.id, mod.default_enabled)
                self:_setModuleEnabled(mod.id, not currently_enabled)
                
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Module '%s' %s.\n\nPlease restart KOReader for changes to take effect."),
                            mod.name or mod.id, currently_enabled and _("disabled") or _("enabled")),
                    timeout = 3,
                })
            end,
        })
    end
    
    if #menu == 0 then
        table.insert(menu, {
            text = _("No modules available"),
            enabled = false,
        })
    end
    
    return menu
end

return SimpleUIExtPlugin
