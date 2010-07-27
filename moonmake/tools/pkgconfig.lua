module(..., package.seeall)
require "subprocess"
util = require "moonmake.util"

-- Find pkg-config program
function configure(conf)
    assert(type(conf) == "table" and conf.test, "expected conf object as first argument")
    conf.PKGCONFIG = conf:findprogram{"pkg-config"}
    return conf.PKGCONFIG
end

-- Check configuration for package 'pkg'
-- Return CFLAGS, LDFLAGS
-- or nil if package not found.
function getflags(conf, pkg)
    assert(type(conf) == "table" and conf.test, "expected conf object as first argument")
    assert(type(pkg) == "string", "expected package name as second argument")
    conf:test("Checking for package "..pkg)
    local cflags, ldflags
    local exitcode, output = subprocess.call_capture {
        conf.PKGCONFIG, "--cflags", pkg,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT }
    if exitcode ~= 0 then
        conf:endtest("not found", false, output)
        return nil
    end
    cflags = util.totable(output:gmatch("[^ \n]+"))
    local exitcode, output = subprocess.call_capture {
        conf.PKGCONFIG, "--libs", pkg,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT }
    if exitcode ~= 0 then
        conf:endtest("failed", false, output)
        return nil
    end
    conf:endtest("ok", true)
    ldflags = util.totable(output:gmatch("[^ \n]+"))
    return cflags, ldflags
end
