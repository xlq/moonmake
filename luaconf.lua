module(..., package.seeall)
require "tostring2"
require "util"
require "lfs"
require "optparse"

_log = {}

-- Set a global variable and log it
function set(k, v)
    _G[k] = v
    _log[#_log + 1] = "set(" .. tostring2.tostring2(k) .. ", " .. tostring2.tostring2(v) .. ")"
end

-- Load a configuration state from a file
-- This executes the log file, so you must trust the file.
function loadconf(filename)
    if lfs.attributes(filename, "mode") then
        local f = io.open(filename, "r")
        local func = load(
            function() return f:read(4096) end,
            "@" .. filename)
        f:close()
        setfenv(func, {set = set})
        func()
    else
        error(string.format(
            "configuration state `%s' does not exist",
            filename))
    end
end

-- Save a configuration state
function saveconf(filename)
    -- Write code to replay log
    local f = io.open(filename, "w")
    for _, x in ipairs(_log) do
        f:write(x .. "\n")
    end
    --f:write("return " .. tostring2.tostring2(self) .. "\n")
    f:close()
end

-- Make a directory for configuration tests
-- Return the directory's name
confdir_name = ".conftest"
function confdir()
    if not confdir_created then
        if not lfs.attributes(confdir_name, "mode") then
            local x, err = lfs.mkdir(confdir_name)
            if not x then error(string.format(
                "Could not create configuration directory `%s': %s",
                confdir_name, err))
            end
        end
        confdir_created = true
    end
    return confdir_name
end

-- An improved os.tmpname
-- Returns name, fileobj
function tmpname(tmpdir, name_base, suffix)
    tmpdir = tmpdir or confdir()
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
            if not f then error(string.format(
                "Unable to create temporary file `%s': %s",
                fname, err))
            end
            return fname, f
        end
    end
    error(string.format(
        "Failed to create temporary file `%s*%s' in `%s'",
        name_base, suffix, tmpdir))
end

-- Get and split PATH variable
function split_path()
    if g_path_bits then
        return g_path_bits
    else
        local bits = {}
        local path = os.getenv("PATH")
        for bit in path:gmatch("[^:]+") do
            bits[#bits + 1] = bit
        end
        g_path_bits = bits
        return bits
    end
end

-- log something
function log(fmt, ...)
    local l = _log
    local indent = 0
    for _, x in string.format(fmt, ...):split("\n") do
        l[#l + 1] = "-- " .. string.rep(" ", indent) .. x
        indent = 4
    end
end

-- start a test
function start_test(desc)
    log("Starting test: %s", desc)
    io.stdout:write(desc .. ": ")
    io.stdout:flush()
end

-- finish a test
function end_test(result, success, diagnostics)
    if success then
        log("Test succeeded: %s", result)
        if diagnostics then log("Diagnostics:\n%s", diagnostics) end
        io.stdout:write(result .. "\n")
    else
        log("Test failed: %s", result)
        if diagnostics then log("Diagnostics:\n%s", diagnostics) end
        io.stdout:write("[0;31m" .. result .. "[0m\n")
        if diagnostics then print(diagnostics) end
    end
end

-- abort configuration
function abort()
    print("Configuration failed.")
    os.exit(1)
end

-- conf:find_program({cmd1, cmd2, ...}, [desc])
-- Find a program named cmd1 or cmd2 or ...
-- Desc is a description of the test (optional).
-- Return its filename.
function find_program(cmds, desc)
    start_test(desc or "Checking for " .. table.concat(cmds, ","))
    local path = split_path()
    for _, prog in ipairs(cmds) do
        for _, dir in ipairs(path) do
            local try_path = util.path(dir, prog)
            if lfs.attributes(try_path, "mode") then
                end_test(try_path, true)
                return try_path
            end
        end
    end
    end_test("not found", false)
end
