module(..., package.seeall)
require "lfs"
--tostring2 = require "moonmake.tostring2"
util = require "moonmake.util"
optparse = require "moonmake.optparse"
platform = require "moonmake.platform"
--functional = require "moonmake.functional"
--list = require "moonmake.flexilist".list

local insert = table.insert

-- Configuration context
local conf = { __tostring = util.repr }

conf.__index = conf

function conf:__newindex(k, v)
    insert(self.__order, k)
    rawset(self, k, v)
end

-- Create a configuration context
function newconf(parent, t)
    t = t or {}
    t.__comments = {}       -- [varname] = comment list
    t.__order = {}          -- list of variable names (the order they were created)
    t.__usermsgs = {}       -- list of messages to print after configuration has finished
    return setmetatable(t, conf)
end

conf.newconf = newconf

-- Load configuration variables from file
-- This executes the log file, so you must trust the file.
function load(filename)
    if lfs.attributes(filename, "mode") then
        -- Load configuration as Lua code
        local func = loadfile(filename)

        -- Create configuration context
        local conf = newconf()

        -- Create environment for the function
        local env = {
            conf = conf
        }
        setfenv(func, env)

        -- Run!
        func()

        -- Return the configuration context
        return conf
    else
        util.errorf("configuration state `%s' does not exist", filename)
    end
end

-- Save a configuration state
function conf:save(filename)
    local f

    local function keyrepr(k)
        if type(k) == "string" then
            if k:match "^[%a_][%w_]*$" then
                return "." .. k
            else
                return "[" .. util.repr(k) .. "]"
            end
        end
    end

    local function doctx(ctx, name)
        local comments = ctx.__comments
        for _, k in ipairs(ctx.__order) do
            local v = ctx[k]
            local comment = comments[k]
            if comment then
                for _, line in ipairs(comment) do
                    f:write("-- ", line, "\n")
                end
            end
            if type(v) == "table" and getmetatable(v) == conf then
                -- sub-context
                f:write(name, keyrepr(k), " = ", name, ":newconf()\n")
                doctx(v, name .. keyrepr(k))
            else
                f:write(name, keyrepr(k), " = ", util.repr(v), "\n")
            end
        end
    end

    -- Write code to reproduce variables
    f = io.open(filename, "w")
    --f:write("local conf = getfenv()\n")

    doctx(self, "conf")

    f:close()
end

-- Set a comment for a configuration variable.
-- This makes the configuration state more readable.
function conf:comment(k, text)
    local lines = self.__comments[k] or {}
    self.__comments[k] = lines
    util.merge(lines, util.xsplit(text, "\n"))
end

-- Get flags from the environment (with defaults)
function conf:getflags(name, default)
    local env = os.getenv(name)
    if env then return util.split(env)
    else return default or {} end
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
        g_path_bits = util.totable((os.getenv("PATH") or ""):
          gmatch("[^"..platform.pathenvsep.."]+"))
    end
    return g_path_bits
end

-- start a test
function conf:test(desc)
    io.stdout:write(desc or "Unknown test", ": ")
    io.stdout:flush()
end

-- finish a test
function conf:endtest(result, success, diagnostics)
    if success then io.stdout:write(result, "\n")
    else io.stdout:write(result, "\n") end
    if not success and self.opts.verbose and diagnostics then print(diagnostics) end
end

-- present a message to the user.
-- Usually, this is printed once configuration has finished.
function conf:usermesage(...)
    util.append(self.__usermsgs, ...)
end

-- finish configuration successfully
function conf:finish()
    print "Configuration finished."
    util.count(util.map(print, self.__usermsgs))
end

-- abort configuration
function conf:abort()
    print("Configuration failed.")
    if not self.opts.verbose then
        print "Consider using --verbose for more details."
    end
    os.exit(1)
end

if platform.platform == "windows" then
    exesuffixes = {"", ".exe"}
else
    exesuffixes = {""}
end

-- conf:findprogram({cmd1, cmd2, ...}, [desc])
-- Find a program named cmd1 or cmd2 or ...
-- Desc is a description of the test (optional).
-- Return filename, fullpath
function conf:findprogram(cmds, desc)
    self:test(desc or "Checking for " .. table.concat(cmds, ","))
    local path = split_path()
    for prog in util.iter(cmds) do
        for _, exesuffix in ipairs(exesuffixes) do
            local prog2 = prog..exesuffix
            if util.isabs(prog2) then
                if lfs.attributes(prog2, "mode") then
                    self:endtest(prog2, true)
                    return prog2, prog2
                end
            else
                for _, dir in ipairs(path) do
                    local try_path = util.path(dir, prog2)
                    if lfs.attributes(try_path, "mode") then
                        self:endtest(try_path, true)
                        --return try_path
                        return prog2, try_path
                    end
                end
            end
        end
    end
    self:endtest("not found", false)
end

-- conf:findfile({file1, file2, ...}, {dir1, dir2, ..}, desc)
-- Find a file named file1 or file2 or ... in dir1 or dir 2 or ...
-- Return its filename
function conf:findfile(files, dirs, desc)
    self:test(desc or "Checking for " .. table.concat(files, ","))
    for _, file in ipairs(files) do
        if util.isabs(file) then
            if lfs.attributes(file, "mode") then
                self:endtest(file, true)
                return file
            end
        else
            for _, dir in ipairs(dirs) do
                local try_path = util.path(dir, file)
                if lfs.attributes(try_path, "mode") then
                    self:endtest(try_path, true)
                    return try_path
                end
            end
        end
    end
    self:endtest("not found", false)
end
