--[[
  optparse(opts, [args])
  Parse command-line arguments
  opts:
      This is a list of {flag, flag, ..., dest} groups, where
      each flag is a flag name (eg. --help).
      The suffix of each flag is:
        (no suffix)   boolean flag
        :             option takes an argument, eg. -b: takes -bARG or -b ARG
        =             long option takes an argument, eg. --file= takes --file=ARG or --file ARG
      dest is the vairable name to store the result in.
  args:
      Specifies a list of arguments to parse. By default it is the global
      arg (the process's arguments).
  Return value:
      Returns a table of positional and optional arguments.
      Positional arguments are keyed by 1, 2, ... and
      the optional arguments are keyed by the name given in 
      the opts table.
      On error, returns nil, msg
  Example:
      optparse {
        {"-h",  "--help",  "help"},
        {"-f:", "--file=", "file"},
      }
--]]

module(..., package.seeall)

function optparse(opts, args)
    args = args or arg
    local flags = {}
    -- process opts
    for _,o in ipairs(opts) do
        local dest = o[#o]
        for i = 1,#o-1 do
            local flag = o[i]
            local lastchar = flag:sub(-1)
            if lastchar == ":" or lastchar == "=" then
                flag = flag:sub(0, -2)
            else
                lastchar = ""
            end
            flags[flag] = {lastchar, dest}
        end
    end
    -- parse args
    local result = {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg:sub(1, 1) == "-" then
            -- is an option
            local eq_idx = arg:find("=", 1, true)
            if eq_idx then
                -- is a --name=value option
                local optname = arg:sub(1, eq_idx - 1)
                local optvalue = arg:sub(eq_idx + 1)
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
