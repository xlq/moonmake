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

-- Check configuration for package 'pkg'.
-- Store a table at conf[pkg] with configuration variables.
-- Return boolean.
function getflags(conf, pkg)
    assert(type(conf) == "table" and conf.test, "expected conf object as first argument")
    assert(type(pkg) == "string", "expected package name as second argument")
    assert(conf.PKGCONFIG, "pkg-config not configured")
    conf:test("Checking for package "..pkg)
    local cflags, ldflags
    local exitcode, output = subprocess.call_capture {
        conf.PKGCONFIG, "--cflags", pkg,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT }
    if exitcode ~= 0 then
        conf:endtest("not found", false, output)
        return false
    end
    cflags = util.totable(output:gmatch("[^ \n]+"))
    local exitcode, output = subprocess.call_capture {
        conf.PKGCONFIG, "--libs", pkg,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT }
    if exitcode ~= 0 then
        conf:endtest("failed", false, output)
        return false
    end
    conf:endtest("ok", true)
    libs = util.totable(output:gmatch("[^ \n]+"))
    conf[pkg] = {CFLAGS=cflags, LIBS=libs}
    --conf:comment(pkg, "Settings for package "..pkg)
    return true
end
