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

-- Extend one table with another (positional elements only)
function table.extend(dest, src)
    for i, v in ipairs(src) do dest[i] = v end
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

-- Iterates over pieces of a split string
function string.split(str, sep, nmax)
    sep = sep or " "
    local pos = 1
    return function (sep, nmatch)
        if pos == -1 then return nil
        elseif nmatch == nmax then
            local r = str:sub(pos)
            pos = -1
            return nmatch + 1, r
        else
            local a, b = str:find(sep, pos, true)
            if a then
                local r = str:sub(pos, a - 1)
                pos = b + 1
                return nmatch + 1, r
            else
                local r = str:sub(pos)
                pos = -1
                return nmatch + 1, r
            end
        end
    end, sep, 0
end

---------- Functions for file names and paths ----------

-- Return base, ext from a filename
function splitext(fname)
    return fname:match("^(.*)(%.[^%.]+)$")
end

-- Swap file extensions
function swapext(fname, newext)
    return splitext(fname) .. newext
end

-- Parse a path into pieces
-- Return pieces, depth, absolute
local function parse_path(...)
    local bits = {}
    local depth = 0
    local absolute = false
    for _, x in ipairs({...}) do
        if x ~= "" then
            for _, elem in string.split(x, "/") do
                if elem == "" then depth = 0; absolute = true
                elseif elem == "." then
                elseif elem == ".." then depth = depth - 1
                else depth = depth + 1; bits[depth] = elem end
            end
        end
    end
    return bits, depth, absolute
end

-- Return just the file portion of a path
function basename(...)
    local bits, depth, absolute = parse_path(...)
    return bits[depth]
end

-- Join bits of pathname (like Python's os.path.join)
function path(...)
    local bits, depth, absolute = parse_path(...)
    if absolute then str = "/"
    elseif depth < 0 then str = string.rep("../", -depth-1) .. ".."
    else str = "" end
    return str .. table.concat(bits, "/", 1, depth)
end
