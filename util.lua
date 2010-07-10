module(..., package.seeall)

-- Return key for a value in the given table, or nil if not found
function table.search(t, value)
    for k, v in pairs(t) do
        if v == value then
            return k
        end
    end
end

-- Make a shallow copy of a table
function table.copy(t)
    local t2 = {}
    for k, v in pairs(t) do
        t2[k] = v
    end
    return t2
end

-- Concatenate multiple tables
function table.join(...)
    local dest = {}
    local sources = {...}
    local i = 1
    for _, t in ipairs(sources) do
        for _, v in ipairs(t) do
            dest[i] = v
            i = i + 1
        end
        for k, v in pairs(t) do
            if not dest[k] then
                dest[k] = v
            end
        end
    end
    return dest
end

-- tabrepli(t, [a, b, ...])
-- Copy a table t and replace its integer items with a, b, ...
function tabrepli(t, ...)
    local t2 = {...}
    for k,v in pairs(t) do
        if t2[k] == nil then
            t2[k] = v
        end
    end
    return t2
end
