-- Miscellaneous general-purpose utility functions for Lua

module(..., package.seeall)
--util = require "moonmake.functional"

-- Return true if k is an integer key
local function isikey(k)
    return type(k) == "number" and k >= 1 and k % 1 == 0
end

----- ITERATORS -----
--
--  The following functions provide iterators.
--  The iterators provided here are closures that can be called
--  repeatedly until they return nil.
--  Lua's pairs and ipairs functions are not compatible with these
--  sorts of iterators, but the for..in statement works with them.
--

-- Get an iterator for x
-- If x is:
--     table with __iter metatable field - __iter(x) is returned
--     table - ivalues(x) is returned
--     string - chars(x) is returned
--     otherwise - returns x
function iter(x)
    local t = type(x)
    if t == "table" then
        local mt = getmetatable(x)
        if mt then
            local __iter = mt.__iter
            if __iter then return __iter(x) end
        end
        return ivalues(x)
    elseif t == "string" then
        return chars(x)
    else
        return x
    end
end

-- Iterate over a table's key/value pairs
-- This differs from Lua's pairs because it closes its state.
function pairs(t)
    local k = nil
    return function()
        local v
        k, v = next(t, k)
        return k, v
    end
end

-- Iterate over a table's array index/value pairs
function ipairs(t)
    local i = 0
    return function()
        i = i + 1
        local v = t[i]
        if v == nil then return nil
        else return i, v end
    end
end

-- Iterate over just a table's values
function values(t)
    local k = nil
    return function()
        local v
        k, v = next(t, k)
        return v
    end
end

-- Iterate over a table's array values
function ivalues(t)
    local i = 0
    return function()
        i = i + 1
        return t[i]
    end
end

-- Iterate over a string's characters
function chars(s)
    local i, len = 0, #s
    return function()
        i = i + 1
        if i <= len then return s:sub(i,i) end
    end
end

-- Make a table from an iterable
function totable(x)
    local x = iter(x)
    local t = {}
    local i = 0
    for v in x do
        i = i + 1
        t[i] = v
    end
    return t
end

-- Like table.concat but better :D
function concat(iterable, delim)
    return table.concat(totable(iterable), delim)
end

----- FUNCTIONAL -----

function map(f, iterable)
    iterable = iter(iterable)
    return function()
        local x = iterable()
        if x ~= nil then return f(x) end
    end
end

-- Iterate over an iterable, skipping elements for which the
-- predicate f evaluates to false.
function filter(f, iterable)
    iterable = iter(iterable)
    return function()
        local x
        repeat x = iterable()
        until not x or f(x)
        return x
    end
end

-- Return number of items from an iterator
function count(iterable)
    iterable = iter(iterable)
    local i = 0
    for junk in iterable do i = i + 1 end
    return i
end

-- Return true if any item evaluates to true
-- May not exhaust iterable
function any(iterable)
    iterable = iter(iterable)
    for x in iterable do if x then return true end end
    return false
end

-- Return true if all items evaluate to true
-- May not exhaust iterable
function all(iterable)
    iterable = iter(iterable)
    for x in iterable do if not x then return false end end
    return true
end

-- range(a,b): Return iterator for a range of numbers [a,b]
-- range(n): Return iterator for a range of numbers [1,n]
function range(a,b)
    local i
    if b then i = a - 1
    else i, b = 0, a end
    return function()
        i = i + 1
        if i <= b then return i end
    end
end

-- Return a function f(x) -> x[k]
-- Useful with map
function getter(k)
    return function(x)
        return x[k]
    end
end

----- TABLES -----
--
--  These functions provide functionality for tables that
--  isn't present in Lua.
--

-- Linear search
-- Return key for a value in the given table, or nil if not found
function search(t, value)
    for k, v in pairs(t) do
        if v == value then
            return k
        end
    end
end

-- Same as search but only for ipairs
function isearch(t, value)
    for i, v in ipairs(t) do
        if v == value then
            return i
        end
    end
end

-- Make a shallow copy of a table
function copy(t)
    local t2 = {}
    for k, v in pairs(t) do
        t2[k] = v
    end
    return setmetatable(t2, getmetatable(t))
end

-- Make a shallow copy of a table (integer keys only)
function icopy(t)
    local t2 = {}
    for i, v in ipairs(t) do
        t2[k] = v
    end
    return setmetatable(t2, getmetatable(t))
end

-- Make a shallow copy of a table (non-integer keys only)
function hcopy(t)
    local t2 = {}
    for k, v in pairs(t) do
        if not isikey(k) then t2[k] = v end
    end
    return setmetatable(t2, getmetatable(t))
end

-- Compare keys and values of a table (shallow)
function compare(t1, t2)
    for k, v in pairs(t1) do
        if t2[k] ~= v then return false end
    end
    for k, v in pairs(t2) do
        if t1[k] ~= v then return false end
    end
    return true
end

-- tabrepli(t, [a, b, ...])
-- Copy a table t and replace its integer items with a, b, ...
--function tabrepli(t, ...)
--    local t2 = {...}
--    for k,v in pairs(t) do
--        if t2[k] == nil then
--            t2[k] = v
--        end
--    end
--    return t2
--end

function isempty(table)
    return next(table) == nil
end

-- merge(t, src, [src2, [src3 ...]] )
-- Mutate table t with values from src
-- If src is:
--   table: concatenate positional items to the end of t and
--          copy the other items, with values from src replacing
--          values in t.
--   function: concatenate items from iterator src to end of t
--   anything else: src is appended to table
-- This function doesn't work very well with holey tables.
-- Repeats for src2, src3 ...
-- Returns t, #t
function merge(t, ...)
    local args = {...}
    local n = #t
    for _, src in ipairs(args) do
        local typ = type(src)
        if typ == "table" then
            for k, v in pairs(src) do
                if isikey(k) then t[n+k] = v
                else t[k] = v end
            end
            n = #t
        elseif typ == "function" then
            for x in src do
                n = n + 1
                t[n] = x
            end
        else
            n = n + 1
            t[n] = src
        end
    end
    return t, n
end

-- append(t, x1, [x2, ...] )
-- Mutate table t by appending each item x1, x2, ...
-- Return t
function append(t, ...)
    local args = {...}
    local n = #t
    for k, v in ipairs(args) do
        t[n+k] = v
    end
    return t
end

----- STRINGS -----
--
--  These functions provide extra string functionality
--

-- xsplit(str, [sep=" "], [nmax])
-- Break a string into pieces, Python-style (returns iterator)
function xsplit(str, sep, nmax)
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

-- split(str, [sep=" "], [nmax])
-- Break a string into pieces, Python-style (returns table)
function split(str, sep, nmax)
    return totable(xsplit(str, sep, nmax))
end

-- True if s starts with s2
function startswith(s, s2)
    return s:sub(1, #s2) == s2
end

-- True if s ends with s2
function endswith(s, s2)
    return s:sub(-#s2) == s2
end

----- IO -----

function printf(fmt, ...)
    return fprintf(io.stdout, fmt, ...)
end

function printfln(fmt, ...)
    return fprintf(io.stdout, fmt.."\n", ...)
end

function fprintf(f, fmt, ...)
    f:write(string.format(fmt, ...))
end

function errorf(fmt, ...)
    return error(string.format(fmt, ...))
end

----- FILESYSTEM PATH MANIPULATIONS -----

pathsep = "/"

-- Return base, ext from a filename
function splitext(fname)
    return fname:match("^(.*)(%.[^%.]+)$")
end

-- Return fname with extension swapped for newext
-- eg. swapext("foo.c", ".o") == "foo.o"
-- eg. swapext("foo", ".o") == "foo.o"
function swapext(fname, newext)
    return splitext(fname) .. newext
end

-- Return just the file portion of a path
-- eg. basename("a/b/foo.o") == "foo.o"
function basename(path)
    return path:match("[^/]*$")
end

-- Return just the directory portion of a path
-- eg. dirname("a/b/foo.o") == "a/b"
function dirname(path)
    return path:match("^(.*)/[^/]*$")
end

-- Join bits of pathname (like Python's os.path.join)
-- eg. path("a", "b/c") == "a/b/c"
-- eg. path("a", "/b") == "/b"
function path(...)
    local s = ""
    for _, v in ipairs({...}) do
        if v:sub(1,1) == "/" then s = v
        else
            if #s > 0 and s:sub(-1) ~= "/" then s = s .. "/" end
            s = s .. v
        end
    end
    return s
end

-- Return true if path is absolute
function isabs(path)
    return startswith(path, "/")
end

----- STRING REPRESENTATION --

-- repr(obj)
-- Return string representation of a Lua object obj.
-- This string representation should be valid Lua code where possible.
-- Exceptions include functions.
function repr(obj)
    local stack = {}
    local tostring = tostring
    local function visit(obj, doiter, key)
        local typ = type(obj)
        if typ == "table" and not key then
            if stack[obj] then return tostring(obj)
            else
                stack[obj] = true
                local bits = {}
                local highest_ikey = 0
                for k,v in ipairs(obj) do
                    bits[#bits+1] = visit(v, false, false)
                    highest_ikey = k
                end
                for k,v in pairs(obj) do
                    if type(k) == "number"
                      and math.floor(k) == k
                      and k >= 1
                      and k <= highest_ikey
                    then
                        -- Already done this item in loop above
                    else
                        local keystr
                        if type(k) == "string" and k:match("^[_%a][_%w]*$") then
                            -- valid identifier
                            keystr = k
                        else
                            keystr = "[" .. visit(k, false, true) .. "]"
                        end
                        bits[#bits+1] = keystr .. " = " .. visit(v, false, false)
                    end
                end
                stack[obj] = nil
                return "{" .. table.concat(bits, ", ") .. "}"
            end
        elseif typ == "string" then
            return "\"" .. obj:gsub("\"", "\\\"") .. "\""
        elseif doiter and typ == "function" then
            return "{" .. concat(obj, ", ") .. "}"
        else
            return tostring(obj)
        end
    end
    return visit(obj, true, false)
end
