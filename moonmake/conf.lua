module(..., package.seeall)
require "lfs"
--tostring2 = require "moonmake.tostring2"
util = require "moonmake.util"
optparse = require "moonmake.optparse"
--functional = require "moonmake.functional"
--list = require "moonmake.flexilist".list

-- Configuration context
local conf = { __tostring = util.repr }
conf.__index = conf

function conf:__newindex(k, v)
    self._vars[k] = true
    rawset(self, k, v)
end

function newconf()
    return setmetatable({
        _vars = {}, -- set of variable names to write to conf state
    }, conf)
end

-- Load configuration variables from file
-- This executes the log file, so you must trust the file.
function conf:load(filename)
    if lfs.attributes(filename, "mode") then
        -- Load configuration as Lua code
        local func = loadfile(filename)
        --local f = io.open(filename, "r")
        --local func = load(
        --    function() return f:read(4096) end,
        --    "@" .. filename)
        --f:close()
        -- Reset configuration variables
        self._vars = {}
        setfenv(func, setmetatable({}, {
            __index = function(_, k)
                return self[k] or _G[k]
            end,
            __newindex = function(_, k, v)
                self[k] = v
            end
        }))
        func()
    else
        util.errorf("configuration state `%s' does not exist", filename)
    end
end

-- Save a configuration state
function conf:save(filename)
    -- Write code to replay log
    local f = io.open(filename, "w")
    f:write("local conf = getfenv()\n")
    for k, _ in pairs(self._vars) do
        local v = self[k]
        if k:match("^[%a_][%w_]*$") then
            f:write(k, " = ", util.repr(v), "\n")
        else
            f:write("conf[", util.repr(k), "] = ", util.repr(v), "\n")
        end
    end
    f:close()
end

-- Make a directory for configuration tests
-- Return the directory's name
confdir_name = ".conftest"
function conf:dir()
    if not confdir_created then
        if not lfs.attributes(confdir_name, "mode") then
            local x, err = lfs.mkdir(confdir_name)
            if not x then util.errorf(
                "Could not create configuration directory `%s': %s",
                confdir_name, err)
            end
        end
        confdir_created = true
    end
    return confdir_name
end

-- An improved os.tmpname
-- Returns name, fileobj
function tmpname(tmpdir, name_base, suffix)
    name_base = name_base or ""
    suffix = suffix or ""
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    for i = 1, 10 do
        local name = name_base
        while #name < 8 do
            local n = math.random(1, #chars)
            name = name .. chars:sub(n, n)
        end
        local fname = util.path(tmpdir, name) .. suffix
        -- TODO: more secure!
        if not lfs.attributes(fname, "mode") then
            -- doesn't exist: good
            local f, err = io.open(fname, "w")
            if not f then util.errorf(
                "Unable to create temporary file `%s': %s",
                fname, err)
            end
            return fname, f
        end
    end
    util.errorf(
        "Failed to create temporary file `%s*%s' in `%s'",
        name_base, suffix, tmpdir)
end

function conf:tmpname(...)
    return tmpname(self:dir(), ...)
end

-- Get and split PATH variable
function split_path()
    if not g_path_bits then
        g_path_bits = util.totable((os.getenv("PATH") or ""):gmatch("[^:]+"))
    end
    return g_path_bits
end

-- start a test
function conf:test(desc)
    io.stdout:write(desc, ": ")
    io.stdout:flush()
end

-- finish a test
function conf:endtest(result, success, diagnostics)
    if success then io.stdout:write(result, "\n")
    else io.stdout:write("\27[0;31m", result, "\27[0m\n") end
    if not success and diagnostics then print(diagnostics) end
end

-- abort configuration
function conf:abort()
    print("Configuration failed.")
    os.exit(1)
end

-- conf:findprogram({cmd1, cmd2, ...}, [desc])
-- Find a program named cmd1 or cmd2 or ...
-- Desc is a description of the test (optional).
-- Return its filename.
function conf:findprogram(cmds, desc)
    self:test(desc or "Checking for " .. table.concat(cmds, ","))
    local path = split_path()
    for prog in util.iter(cmds) do
        if util.isabs(prog) then
            if lfs.attributes(prog, "mode") then
                self:endtest(prog, true)
                return prog
            end
        else
            for _, dir in ipairs(path) do
                local try_path = util.path(dir, prog)
                if lfs.attributes(try_path, "mode") then
                    self:endtest(try_path, true)
                    return try_path
                end
            end
        end
    end
    self:endtest("not found", false)
end
