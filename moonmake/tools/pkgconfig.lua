module(..., package.seeall)
require "subprocess"
util = require "moonmake.util"

-- Find pkg-config program
function configure(conf)
    assert(type(conf) == "table" and conf.test, "expected conf object as first argument")
    conf.PKGCONFIG = conf:findprogram{"pkg-config"}
    conf:comment("PKGCONFIG", "Location of pkg-config executable")
    return conf.PKGCONFIG
end

-- Set entries in CPPPATH, LIBPATH and CPPDEFINES from some C/linker flags.
-- Return a table containing only the entries in 'flags' that were not used.
function extract_flags(pkg, flags)
    local other = {}
    local cpppath = pkg.CPPPATH or {}
    local cppdefines = pkg.CPPDEFINES or {}
    local libpath = pkg.LIBPATH or {}
    for _, x in ipairs(flags) do
        if util.startswith(x, "-I") then
            table.insert(cpppath, x:sub(3))
        elseif util.startswith(x, "-L") then
            table.insert(libpath, x:sub(3))
        elseif util.startswith(x, "-D") then
            local k, v = x:match("-D([^=]+)=?(.*)")
            cppdefines[k] = v or true
        else
            table.insert(other, x)
        end
    end
    pkg.CPPPATH = cpppath
    pkg.CPPDEFINES = cppdefines
    pkg.LIBPATH = libpath
    return other
end

-- Check configuration for package 'pkgname'.
-- Store a table at conf[pkgname] with configuration variables.
-- Return boolean.
function getflags(conf, pkgname)
    assert(type(conf) == "table" and conf.test, "expected conf object as first argument")
    assert(type(pkgname) == "string", "expected package name as second argument")
    assert(conf.PKGCONFIG, "pkg-config not configured")
    conf:test("Checking for package "..pkgname)
    local pkg = {}
    local exitcode, output = subprocess.call_capture {
        conf.PKGCONFIG, "--cflags", pkgname,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT }
    if exitcode ~= 0 then
        conf:endtest("not found", false, output)
        return false
    end
    pkg.CFLAGS = extract_flags(pkg, util.totable(output:gmatch("[^ \n]+")))
    local exitcode, output = subprocess.call_capture {
        conf.PKGCONFIG, "--libs", pkgname,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT }
    if exitcode ~= 0 then
        conf:endtest("failed", false, output)
        return false
    end
    conf:endtest("ok", true)
    pkg.LIBS = extract_flags(pkg, util.totable(output:gmatch("[^ \n]+")))
    conf[pkgname] = pkg
    --conf:comment(pkgname, "Settings for package "..pkgname)
    return true
end
