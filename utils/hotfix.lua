-- hotfixes a function's upvalue by name.
-- returns true on success, false and an error message on failure.
-- Example usage:
--     local ok, err = hotfix(_localDateProxy, ClockMod.build, "build -> _localDate")
---@param proxy function the new function to replace the target with
---@param root function the root function to start searching from (often a module's public function)
---@param path string the path to the target function, e.g. "build -> _localDate"
---@return boolean, string?
local function hotfix(proxy, root, path)
    local names = {}
    path:gsub("[^-> ]+", function(s)
        names[#names + 1] = s
    end)

    local fn = root
    local owner, up = root, 0
    for _, name in ipairs(names) do
        for i = 1, 65536 do
            local n, v = debug.getupvalue(fn, i)
            if not n then
                return false, "failed to find upvalue: `" .. name .. "`"
            end
            if n == name then
                owner = fn
                fn, up = v, i
                break
            end
        end
    end

    debug.setupvalue(owner, up, proxy)
    return true
end

return hotfix
