-- utils/hotfix.lua — SimpleUI Extra Utils
-- A simple hotfix utility to get or replace upvalue by name.
-- The main use case is to patch a function in a module without modifying the module's code.
--
-- Path is composed of `arrow` separation
-- The following are valid examples:
--   "name1 -> name2"
--   "name1 >> name2" (if you like to use)
--   "name1 -- name2" (if you like to use)
--   [[name1 -> name2
--           -> name3
--           -> ...]] (if you want to searching a deep nested upvalue)
--
-- Example usage:
--     # replace a function or table
--     # use `hotfix.set` or simply call `hotfix` directly, they are the same.
--     local err = hotfix(_myProxy, Mod.method, "name1 -> name2")
--     if err then
--         logger.warn("failed to hotfix: " .. err)
--     end
--
--     # get a function or table
--     local err, val = hotfix.get(Mod.method, "name1 -> name2")
--     if err then
--         logger.warn("failed to get upvalue: " .. err)
--     end
--     # call the function or change the table
---@overload fun(proxy: any, root: function, path: string): string?
local hotfix = {}

local function split(path)
    local names = {}
    path:gsub("[^->%s]+", function(s)
        names[#names + 1] = s
    end)
    return names
end

---@param root function
---@param names string[]
---@param start integer?
---@param stop integer?
---@return string?, function?, integer?
local function scan(root, names, start, stop)
    start = start or 1
    stop = stop or #names

    local max_saved = 4
    local dbg_saved = { [max_saved + 1] = "..." }
    local fn, up = root, 0
    for i = start, stop do
        local name = names[i]
        for j = 1, 65536 do
            local n, v = debug.getupvalue(fn, j)
            -- return error massage if no more upvalue to check
            if not n then
                local info = debug.getinfo(fn, 'S')
                local file = info.short_src or "unknown"
                local saved_names = table.concat(dbg_saved, ", ")
                local err_msg = string.format(
                    "failed to find upvalue `%s`: in lua file %s, checked upvalues: [ %s ]",
                    name, file, saved_names)
                return err_msg
            end
            -- return value if name matched
            if n == name then
                fn, up = v, j
                break
            end
            -- save checked upvalues for debug
            if j <= max_saved then
                dbg_saved[j] = n
            end
        end
        dbg_saved = { [max_saved + 1] = "..." }
    end
    return nil, fn, up
end

-- hotfixes a function's upvalue by name.
-- return error message on failure.
-- Example usage:
--     local err = hotfix(_myProxy, Mod.method, "name1 -> name2")
---@param proxy any the new value to replace the target with
---@param root function the root function to start searching from (often a module's public function)
---@param path string the path to the target function, e.g. "name1 -> name2"
---@return string?
function hotfix.set(proxy, root, path)
    local names = split(path)

    local err, val, _ = scan(root, names, 1, #names - 1)
    if err then
        return err
    end

    local err, _, up = scan(val, names, #names, #names)
    if err then
        return err
    end
    debug.setupvalue(val, up, proxy)
end

-- get the value of a function's upvalue by path.
-- return error message on failure, or nil and the value on success.
---@param root function the root function to start searching from (often a module's public function)
---@param path string  the path to the target function, e.g. "name1 -> name2"
---@return string?, any?
function hotfix.get(root, path)
    local names = split(path)
    local err, val, _ = scan(root, names)
    if err then
        return err
    end

    return nil, val
end

-- Compatibility with older versions and simplification of the most used scenarios
setmetatable(hotfix, {
    __call = function(_, ...)
        return hotfix.set(...)
    end,
})

return hotfix
