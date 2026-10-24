-- utils/sui_compat.lua — SimpleUI module-path compatibility shim.
--
-- WHY THIS EXISTS
--   SimpleUI 2.5 moved every internal file out of the plugin root into
--   topic folders:
--
--       sui_config                     → infra/sui_config
--       sui_core / sui_store           → infra/sui_*
--       sui_style                      → features/sui_style
--       sui_homescreen                 → screens/sui_homescreen
--       desktop_modules/moduleregistry → modules/moduleregistry
--       desktop_modules/module_*       → modules/module_*
--
--   Every require() in this plugin still used the pre-2.5 names, so on 2.5
--   they all failed. main.lua's _register() gives up on the very first one
--   ("desktop_modules/moduleregistry") and returns early — which is why
--   nothing showed up anywhere after the upgrade: no extra modules on the
--   homescreen, no patches applied, and empty "Modules"/"Patches" lists in
--   this plugin's own menu (_modules_meta / _patches_meta stayed empty).
--
-- HOW IT WORKS
--   Instead of hard-coding the 2.5 layout at ~15 call sites (and redoing
--   that on the next reshuffle), we append one loader to package.loaders.
--   Lua only consults it AFTER the normal package.path search has already
--   failed, so it costs nothing while SimpleUI's layout matches what a
--   caller asked for. On a miss it retries the same basename under each
--   known SimpleUI folder.
--
--   The alias is resolved through require(real_name), never loadfile — so
--   the old and the new name share ONE module instance. That matters:
--   sui_store, sui_core and moduleregistry all hold process-wide state, and
--   a second copy would silently desync from SimpleUI's own.
--
--   Loading this file installs the loader; requiring it twice is a no-op.

local logger = require("logger")

-- Folders SimpleUI 2.5 spreads its internals over, most likely first.
-- "" keeps a flat (≤2.4) layout working for "desktop_modules/x" style names.
-- 3.0 added features/dialogs/, modules/reading_stats/ (module_reading_stats
-- moved there) and screens/insights/.
local SUI_DIRS = {
    "infra/", "screens/", "modules/", "features/",
    "engines/", "features/library/", "features/dialogs/",
    "modules/reading_stats/", "screens/insights/", "",
}

-- Only names that can only ever be SimpleUI's. Anything else is left to the
-- stock loaders untouched.
local function isSuiName(name)
    return name:match("^sui_[%w_]+$") ~= nil
        or name:match("^desktop_modules/[%w_]+$") ~= nil
end

-- Resolves `mod` to the file that backs it through package.path, nil if none.
local function findFile(mod)
    if package.searchpath then
        return package.searchpath(mod, package.path)
    end
    for tmpl in package.path:gmatch("[^;]+") do
        local path = tmpl:gsub("%?", mod)
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

-- True when `mod` is already loaded or resolvable through package.path.
local function isResolvable(mod)
    if package.loaded[mod] then return true end
    return findFile(mod) ~= nil
end

-- alias name -> real module name, for every alias this loader has served.
local _served = {}

local function suiLoader(name)
    if type(name) ~= "string" or not isSuiName(name) then return nil end

    local base = name:match("([^/]+)$")
    for _, dir in ipairs(SUI_DIRS) do
        local real = dir .. base
        if real ~= name and isResolvable(real) then
            return function()
                logger.dbg("simpleui_ext: sui_compat: '" .. name .. "' -> '" .. real .. "'")
                -- Remember the pairing so syncAliases() can spot a stale
                -- alias later. See its doc comment for why that matters.
                _served[name] = real
                -- require(), not loadfile(): one shared instance.
                return require(real)
            end
        end
    end

    return "\n\tno SimpleUI module named '" .. base .. "' in any of its folders"
end

local M = {}

-- package.loaders on LuaJIT/5.1, package.searchers on 5.2+.
--
-- POSITION MATTERS: inserted at index 2, right after the package.preload
-- searcher and BEFORE the package.path searcher. An in-place SimpleUI
-- upgrade (its updater unzips over the old folder) leaves the pre-2.5
-- files behind — "desktop_modules/moduleregistry.lua", a flat
-- "sui_store.lua", etc. With this loader appended at the END, the path
-- searcher finds those STALE files first and every legacy-name require in
-- this plugin silently loads dead 2.1.1 code: modules get registered into
-- a registry no live SimpleUI code reads, patches patch module tables no
-- menu shows, and nothing errors. Sitting in front of the path searcher,
-- this loader resolves legacy names against the CURRENT layout first
-- (SUI_DIRS tries the foldered names before the flat one), so remnants can
-- never be picked up. Names it does not recognise fall through untouched,
-- and on a genuinely flat (≤2.4) install every candidate misses, so the
-- path searcher still loads the real flat file.
local loaders = package.loaders or package.searchers
if loaders then
    for i = #loaders, 1, -1 do
        if loaders[i] == suiLoader then table.remove(loaders, i) end
    end
    table.insert(loaders, 2, suiLoader)
else
    logger.dbg("simpleui_ext: sui_compat: no package.loaders table — "
                .. "SimpleUI 2.5 paths will not resolve")
end

-- ---------------------------------------------------------------------------
-- Module-registry preload hook
--
-- THE PROBLEM THIS SOLVES (the "modules registered, pages empty" bug)
--   SimpleUI's teardown evicts "modules/moduleregistry" from package.loaded
--   on every FileManager <-> Reader context switch (main.lua's
--   _PLUGIN_MODULES). Every require() after an eviction builds a BRAND NEW
--   registry table with an empty _external list. KOReader creates the new
--   context's plugins BEFORE tearing the old context down, so our _register()
--   and the screen engine's own `local Registry = require(...)` capture can
--   land on opposite sides of an eviction: we register six modules into one
--   registry instance, the engine walks its pages against another, and
--   Registry.get() returns nil for every one of our ids — no error anywhere,
--   the pages simply resolve empty.
--
-- THE FIX
--   package.preload is consulted by require() BEFORE package.path, and
--   SimpleUI's eviction only clears package.loaded — the preload entry
--   survives. So we own the registry's construction: whenever ANY caller
--   (SimpleUI's engine included) requires the registry after an eviction, our
--   preload loads SimpleUI's real file and injects every tracked module into
--   the newborn instance before handing it over. However many registry
--   instances get created over a session, every one of them knows our
--   modules from birth — there is no wrong side of an eviction any more.
--
--   Registry.register() replaces an existing entry with the same id, and
--   moduleregistry's _load() skips duplicate ids, so injecting on top of a
--   later explicit register() (or vice versa) is harmless.
-- ---------------------------------------------------------------------------

-- module id -> module table; what _injectTracked() feeds newborn registries.
local _tracked = {}

-- The registry's require-name per SimpleUI layout, most likely first.
local _REGISTRY_NAMES = { "modules/moduleregistry", "desktop_modules/moduleregistry" }

local function _injectTracked(reg)
    if type(reg) ~= "table" or type(reg.register) ~= "function" then return end
    for _id, mod in pairs(_tracked) do
        pcall(reg.register, mod)
    end
end

-- Keep `mod` registered in every registry instance created from now on.
function M.trackModule(mod)
    if type(mod) == "table" and type(mod.id) == "string" then
        _tracked[mod.id] = mod
        -- A registry that already exists was born before this call: catch it up.
        for _i, name in ipairs(_REGISTRY_NAMES) do
            local reg = package.loaded[name]
            if reg then _injectTracked(reg) end
        end
    end
end

function M.untrackModule(id)
    if id ~= nil then _tracked[id] = nil end
end

-- The name the hook is currently installed under, nil while not installed.
local _preload_name = nil

-- RE-CALLABLE ON PURPOSE. This file is first loaded from the plugin's main
-- chunk, which runs inside PluginLoader:_load() — at that point package.path
-- holds ONLY this plugin's root (other plugin roots are appended later, in
-- PluginLoader:loadPlugins()), so findFile() cannot see SimpleUI's files yet
-- and the install attempt below quietly misses. _register() therefore calls
-- this again once the full path is in place.
function M.installRegistryPreload()
    if _preload_name and package.preload[_preload_name] then
        return _preload_name
    end
    for _i, name in ipairs(_REGISTRY_NAMES) do
        if findFile(name) then
            package.preload[name] = function()
                local file = findFile(name)
                if not file then
                    -- SimpleUI's layout changed since install: step aside and
                    -- let the stock loaders (and the alias loader above) have
                    -- another go at the name.
                    package.preload[name] = nil
                    return require(name)
                end
                local chunk, err = loadfile(file)
                if not chunk then
                    error(("simpleui_ext: sui_compat: cannot load '%s': %s")
                          :format(file, tostring(err)))
                end
                local reg = chunk()
                _injectTracked(reg)
                return reg
            end
            _preload_name = name
            return name
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- M.staleRemnants() -> { { name, stale_file, real }, ... }
--
-- Detects pre-2.5 SimpleUI files left behind by an in-place upgrade: a legacy
-- name (flat "sui_*" / "desktop_modules/*") that is DIRECTLY backed by a file
-- on package.path while the current layout also provides it under a foldered
-- name. Before the alias loader moved in front of the path searcher, such a
-- remnant hijacked every legacy require in this plugin — two parallel
-- SimpleUI code universes, no error anywhere. Reported so Diagnostics and the
-- log can tell the user exactly which files to delete.
-- ---------------------------------------------------------------------------
local _LEGACY_NAMES = {
    "desktop_modules/moduleregistry", "desktop_modules/module_books_shared",
    "desktop_modules/module_currently", "desktop_modules/module_recent",
    "sui_store", "sui_config", "sui_core", "sui_homescreen", "sui_style",
    "sui_patches", "sui_screen_engine",
}

function M.staleRemnants()
    local out = {}
    for _i, name in ipairs(_LEGACY_NAMES) do
        local stale_file = findFile(name)
        if stale_file then
            local base = name:match("([^/]+)$")
            for _j, dir in ipairs(SUI_DIRS) do
                local real = dir .. base
                if real ~= name and findFile(real) then
                    out[#out + 1] = { name = name, stale_file = stale_file, real = real }
                    break
                end
            end
        end
    end
    return out
end

-- Attempted at load time too: costs nothing, and on layouts where the path
-- already resolves (e.g. a hot ext reload at runtime) it installs early.
M.installRegistryPreload()

-- ---------------------------------------------------------------------------
-- M.wallpaperAPI() -> table | nil
--
-- The wallpaper / bar-transparency getters (styleGetWallpaperEnabled,
-- styleGetWallpaper, …) used to live on sui_homescreen. SimpleUI 2.5 moved
-- them to features/sui_wallpaper.lua, so a plain require("sui_homescreen")
-- now resolves fine (via the loader above) but no longer carries them.
--
-- Returns whichever table actually owns them, or nil when neither does.
-- Resolved per call rather than cached: the screensaver patches re-read
-- these across context switches, when the module tables can have been
-- re-required.
-- ---------------------------------------------------------------------------
local function hasWallpaper(t)
    return type(t) == "table" and type(t.styleGetWallpaperEnabled) == "function"
end

function M.wallpaperAPI()
    -- ≤2.4: the getters sit on the homescreen module itself.
    local hs = package.loaded["sui_homescreen"] or package.loaded["screens/sui_homescreen"]
    if hasWallpaper(hs) then return hs end

    -- 2.5+: features/sui_wallpaper.lua.
    local wp = package.loaded["features/sui_wallpaper"]
    if hasWallpaper(wp) then return wp end

    local ok, m = pcall(require, "features/sui_wallpaper")
    if ok and hasWallpaper(m) then return m end

    return nil
end

-- ---------------------------------------------------------------------------
-- M.themeColor(role) -> Blitbuffer color | nil
--
-- SimpleUI <= 2.5 exposed a user-themable palette through
-- sui_style.getThemeColor(role). It returned nil for every role the user had
-- not overridden, so each caller fell back to its own hard-coded default --
-- which is why almost every call site in this plugin reads
--     local c = SUIStyle.getThemeColor("fg") or Blitbuffer.COLOR_BLACK
--
-- SimpleUI 2.6 dropped the theming feature outright: getThemeColor,
-- setThemeColor, resetTheme and makeThemeMenuItems are gone, replaced by the
-- fixed SUIStyle.COLOR catalog (text_primary / text_secondary / surface /
-- gray / ...).
--
-- Every one of those call sites guarded the REQUIRE ("ok_ss and SUIStyle")
-- but not the FUNCTION, so on 2.6 they all raise
--     attempt to call field 'getThemeColor' (a nil value)
-- from inside build(). sui_screen_engine pcalls mod.build(), so this never
-- surfaced as a crash: the module just silently painted nothing. The same
-- throw inside patch_coverdeck_description -- which runs within SimpleUI's
-- OWN module_coverdeck build -- took the built-in coverdeck down with it,
-- while modules that never touched sui_style (reading_insights,
-- reading_streaks) kept working. That is the whole "modules vanished after
-- the 2.6 upgrade" bug.
--
-- This resolves a role against whichever mechanism the installed SimpleUI
-- actually has:
--   <= 2.5  the live getThemeColor, so user themes keep working unchanged;
--   >= 2.6  nil for every role -- there is no theming to honour any more.
--
-- WHY 2.6 RETURNS nil RATHER THAN THE NEAREST SUIStyle.COLOR ENTRY
--   Mapping roles onto the new catalog looks like the faithful translation,
--   but it silently REPAINTS text these modules never asked to be repainted.
--   The clearest case is "text_secondary": on <= 2.5 an unthemed install
--   returned nil there, so every call site fell through to its own default,
--   which is UI.CLR_TEXT_SUB -- black on 2.5 AND on 2.6, where SimpleUI's own
--   modules still paint their secondary text with it. Handing back
--   SUIStyle.COLOR.text_secondary (COLOR_DARK_GRAY, 0x88) instead turns that
--   text mid-grey: washed out on e-ink, and lighter than the built-in
--   modules sitting right next to it. "separator" does the same to
--   module_recent_book_stats' rules, black by default, 0x48 via COLOR.gray.
--
--   nil is what an unthemed <= 2.5 install returned for EVERY role, so it is
--   also what reproduces the colours these modules actually shipped with.
--   The <= 2.5 branch stays intact, so a user theme on an older SimpleUI is
--   still honoured; only 2.6+, which has no theme to read, goes plain.
-- ---------------------------------------------------------------------------

local function _styleModule()
    local ss = package.loaded["sui_style"] or package.loaded["features/sui_style"]
    if type(ss) == "table" then return ss end
    local ok, m = pcall(require, "features/sui_style")
    if ok and type(m) == "table" then return m end
    return nil
end

function M.themeColor(role)
    local SS = _styleModule()
    if not SS then return nil end

    -- <= 2.5: honour the user's own theme.
    if type(SS.getThemeColor) == "function" then
        local ok, c = pcall(SS.getThemeColor, role)
        if ok then return c end
        return nil
    end

    -- >= 2.6: no theming exists; the caller keeps its own default. See the
    -- "WHY 2.6 RETURNS nil" note above before adding a COLOR mapping here.
    return nil
end

-- ---------------------------------------------------------------------------
-- M.applyLabel(mod, default_label)
--
-- SimpleUI <= 2.6 had Config.applyLabelToggle(mod, label), which set
-- mod.label to nil while the user's "Show section label" toggle was off.
-- SimpleUI 3.0 removed it: the label descriptor
-- (engines/sui_section_label.lua) now checks Config.isLabelHidden itself and
-- M.label must stay set. Calling the missing function threw inside each
-- module's getHeight/build, which the engine swallowed -- the module simply
-- vanished. Use the old toggle where it exists, otherwise just set the label.
-- ---------------------------------------------------------------------------
function M.applyLabel(mod, default_label)
    if type(mod) ~= "table" then return end
    local Config = package.loaded["infra/sui_config"] or package.loaded["sui_config"]
    if not Config then
        local ok, m = pcall(require, "infra/sui_config")
        if ok then Config = m end
    end
    if type(Config) == "table" and type(Config.applyLabelToggle) == "function" then
        Config.applyLabelToggle(mod, default_label)
    else
        mod.label = default_label
    end
end

-- ---------------------------------------------------------------------------
-- M.syncAliases()
--
-- Drops any alias entry from package.loaded that no longer points at the same
-- table as the module it aliases, so the next require() re-resolves it.
--
-- WHY THIS IS NEEDED
--   SimpleUI clears its own modules out of package.loaded on every teardown
--   (main.lua's _PLUGIN_MODULES loop, which runs on each FileManager <->
--   Reader context switch, so a hot plugin update is picked up without a
--   restart). The next require() therefore builds a BRAND NEW module table.
--
--   Before SimpleUI 2.5 that list held exactly the names this plugin
--   requires ("desktop_modules/moduleregistry", "sui_config", ...), so both
--   plugins always shared one cache entry and were reset together. 2.5
--   renamed the list to the foldered paths — and require() caches an alias
--   under its OWN name too, so "desktop_modules/moduleregistry" survives an
--   eviction that clears "modules/moduleregistry".
--
--   The result is two live registries: SimpleUI reads the fresh one, this
--   plugin keeps registering its modules into the orphaned one. Everything
--   reports success and nothing shows up — no error, because nothing failed.
--
--   Call this before any batch of SimpleUI requires (see _register()) to put
--   both plugins back on the same instance.
-- ---------------------------------------------------------------------------
function M.syncAliases()
    local dropped = 0
    for alias, real in pairs(_served) do
        if package.loaded[alias] ~= nil and package.loaded[alias] ~= package.loaded[real] then
            package.loaded[alias] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end

-- ---------------------------------------------------------------------------
-- M.report(names) -> { { name, real, file }, ... }
--
-- For each legacy name, the module name it resolves to today and the file
-- backing it. Used by the plugin's Diagnostics menu: after a SimpleUI
-- upgrade this is what tells you whether the loader above found the new
-- layout, and where it looked.
-- ---------------------------------------------------------------------------
function M.report(names)
    local out = {}
    for _, name in ipairs(names or {}) do
        local base = name:match("([^/]+)$")
        local row  = { name = name }
        for _, dir in ipairs(SUI_DIRS) do
            local cand = dir .. base
            local file = package.searchpath and package.searchpath(cand, package.path)
            if not file and isResolvable(cand) then file = "(found)" end
            if file then
                row.real, row.file = cand, file
                break
            end
        end
        out[#out + 1] = row
    end
    return out
end

M.dirs = SUI_DIRS
return M
