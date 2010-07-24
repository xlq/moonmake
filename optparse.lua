-- Command-line option parser.
-- See documentation optparse.html for details.

module(..., package.seeall)
util = require "moonmake.util"

local insert = table.insert

-- Pad a string with spaces to n chars
local function pad(s, n)
    return s .. string.rep(" ", n - s:len())
end

-- Wrap a string and put lines into 'out' list
local function wrap_string(out, str, indent, width, initindent)
    local len = str:len() -- length of str
    local strpos = 1 -- position in str
    local n = 1 -- line number
    local indentstr = string.rep(" ", indent)
    assert(indent < width)
    while strpos < len do
        -- find a good place to break the string
        -- XXX: can this search be done with built-ins?
        local breakp = strpos + (width - indent) - 1
        if breakp < len then
            -- move break point further back into string to find
            -- a space, but not too far!
            while breakp > (strpos + indent + 10)
              and str:sub(breakp, breakp) ~= " "
            do breakp = breakp - 1 end
        else
            -- no breaking needed
            breakp = len
        end
        -- output this bit of string
        if n == 1 and initindent then
            insert(out, pad(initindent, indent) .. str:sub(strpos, breakp))
        else
            insert(out, indentstr .. str:sub(strpos, breakp))
        end
        n = n + 1
        strpos = breakp + 1
        -- don't put whitespace on next line
        while str:sub(strpos, strpos) == " " do strpos = strpos + 1 end

    end
end

-- Format table items in 'lines' into nice columns.
-- Items in 'lines' will be either strings or 2-tuples of strings.
-- Return new table with just strings in
local function format_lines(lines)
    -- Calculate size of first column, within sensible limits.
    local maxcol1 = 23 -- 23 columns ought to be enough for anybody.
    local col1 = 0
    for i, v in ipairs(lines) do
        if type(v) == "table" then
            local l = v[1]:len()
            if l > col1 then col1 = l end
        end
    end
    col1 = col1 + 3 -- leave a comfortable 3-space padding
    if col1 > maxcol1 then col1 = maxcol1 end
    -- Make output table
    local out = {}
    for i, v in ipairs(lines) do
        if type(v) == "table" then
            local initindent
            if not v[2] or v[1]:len() + 1 > col1 then
                -- too large - put flags on a line on their own
                wrap_string(out, v[1], 0, 80)
            else
                initindent = v[1]
            end
            if v[2] then
                wrap_string(out, v[2] or "", col1, 80, initindent)
            end
        else
            --wrap_string(out, v, 0, 80)
            insert(out, v)
        end
    end
    return out
end


-- Guess an option's dest variable
local function guessdest(o)
    -- Find longest flag name
    local long, longlen = nil, 0
    for i,v in ipairs(o) do
        if #v > longlen then
            long, longlen = v, #v
        end
    end
    if long then
        -- Remove qualifiers
        return long:match("%a[%w%-_]*"):gsub("%-", "_")
    end
end

function parse(opts, args)
    args = args or arg

    -- process option table
    local flags = {}
    local function process_opts(opts)
        for _, o in ipairs(opts) do
            if o.group then process_opts(o)
            else
                local dest = o.dest or guessdest(o)
                for _, flag in ipairs(o) do
                    local flag, junk, lastchar = flag:match("^((.*)[^=:])([=:]?)$")
                    flags[flag] = {lastchar, dest}
                end
            end
        end
    end
    process_opts(opts)

    -- parse args
    args = args or arg
    -- parse args
    local result = {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        if util.startswith(arg, "-") then
            -- is an option
            local optname, eq, optvalue = arg:match("([^=]*)(=?)(.*)$")
            if eq == "=" then
                -- is a --name=value option
                local o = flags[optname]
                if o then
                    local mode, dest = unpack(o)
                    if mode ~= "=" then
                        return nil, string.format(
                            "Invalid argument to option: %s\n", arg)
                    end
                    result[dest] = optvalue
                else
                    return nil, string.format(
                        "Unrecognised option: %s", arg)
                end
            else
                -- is not a --name=value option
                repeat
                    local again = false
                    local o = flags[arg]
                    if o then
                        local mode, dest = unpack(o)
                        if mode ~= "" then
                            -- get another arg
                            i = i + 1
                            local optvalue = args[i]
                            if not optvalue then
                                return nil, string.format(
                                    "Missing argument to option: %s", arg)
                            end
                            result[dest] = optvalue
                        else
                            -- just a boolean switch
                            result[dest] = true
                        end
                    elseif arg:sub(2,2) ~= "-"
                    and flags[arg:sub(1,2)] then
                        -- Short option
                        local mode, dest = unpack(flags[arg:sub(1,2)])
                        if mode == "" then
                            -- Option doesn't take an argument
                            -- Process short options jammed together,
                            -- eg. -abcd
                            result[dest] = true
                            arg = "-" .. arg:sub(3)
                            again = true
                        else
                            result[dest] = arg:sub(3)
                        end
                    else
                        return nil, string.format(
                            "Unrecognised option: %s", arg)
                    end
                until not again
            end
        else
            -- positional argument
            result[#result + 1] = arg
        end
        i = i + 1
    end
    return result
end

local function do_help(opts, lines)
    local glines = {}
    for _, o in ipairs(opts) do
        if o.group then
            insert(glines, "")
            insert(glines, o.group..":")
            util.merge(glines, o.help)
            do_help(o, glines)
        else
            local flagstrbits = {}
            for _, flag in ipairs(o) do
                local flag, junk, lastchar = flag:match("^((.*)[^=:])([=:]?)$")
                if lastchar ~= "" then
                    -- XXX: don't re-calc metavar for every flag of o
                    local metavar = o.metavar
                    if not metavar then
                        metavar = o.dest or guessdest(o) or "XXX"
                        metavar = metavar:upper()
                    end
                    insert(flagstrbits, flag..(lastchar == "=" and lastchar or " ")..metavar)
                else
                    insert(flagstrbits, flag)
                end
            end
            insert(lines, ({"  "..table.concat(flagstrbits, ", "), o.help}))
        end
    end
    --lines:append("")
    util.merge(lines, glines)
end

function help(opts, file)
    file = file or io.stdout

    -- Make table for lines of text.
    -- Some entires here can be tables, for columnar formatting.
    local lines = {}
    if opts.help then
        insert(lines, (opts.help:gsub("%%prog", arg[0])))
    end
    -- lines:append("") too spaced out
    insert(lines, "Options:")
    do_help(opts, lines)
    lines = format_lines(lines)
    file:write(table.concat(lines, "\n"), "\n")
end
