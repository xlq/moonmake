module(..., package.seeall)
--require "luaconf"
require "subprocess"
make = require "moonmake.make"
util = require "moonmake.util"
platform = require "moonmake.platform"
--functional = require "moonmake.functional"
--atexit = require "moonmake.atexit"
--flexilist = require "moonmake.flexilist"

local insert = table.insert

local c = {}
c.__index = c

function new(name)
    name = (name or ""):gsub("CC$", "")
    return setmetatable({
        name = name,
    }, c)
end

---------- C LANGUAGE SUPPORT ----------

-- -- Get options from arguments or 
-- -- name is the name of the option to get.
-- local function getruleopt(kwargs, name)
--     local v = inf[name:upper()] or _G[name] or {}
--     if type(v) == "string" then v = {v} end
--     local v2 = inf[name:lower()]
--     if v2 then
--         if type(v2) == "string" then v2 = {v2} end
--         return util.join(v, v2)
--     else
--         return v
--     end
-- end

-- Get a variable from kwargs or the configuration
function c:getvar(name, conf, kwargs, default)
    return kwargs[name] or conf[self.name..name] or default
end

-- Add items to optparse option table
function c:options(opts, envgroup)
    if not envgroup then
        envgroup = {
            group="Some influential environment variables",
        }
        insert(opts, envgroup)
    end
    local h = envgroup.help or {}
    envgroup.help = h
    insert(h, {"  "..self.name.."CC",      "C compiler command"})
    insert(h, {"  "..self.name.."CPPPATH", "Paths to search for C headers"})
    insert(h, {"  "..self.name.."CFLAGS",  "C compiler flags"})
    insert(h, {"  "..self.name.."LDFLAGS", "C linker flags"})
    insert(h, {"  "..self.name.."LIBS",    "Names of libraries to link to"})
    return envgroup
end

-- Get configuration info
function c:getvars(conf)
    local vars = conf[self.name.."CC"]
    if not vars then error(self.name.."CC has not been configured") end
    return vars
end

-- Set configuration info
function c:setvars(conf, vars)
    conf[self.name.."CC"] = vars
end

-- split_flags(flags, [strip_prefix])
-- Split flags from an environment variable.
-- Remove prefix strip_prefix, if present, from each option.
-- If flags is a table, it is returned immediately.
function split_flags(flags, strip_prefix)
    if type(flags) == "table" then return table end
    local tab = util.split(flags)
    for i = 1, #tab do
        if strip_prefix and util.startswith(tab[i], strip_prefix) then
            tab[i] = tab[i]:sub(#strip_prefix + 1)
        end
    end
    return tab
end

-- c:configure {conf, [options...]}
-- Configuration
-- Options can include CFLAGS, LDFLAGS. These are used as the defaults.
-- Returns table representing the configured compiler, or nil
function c:configure(kwargs)
    local conf = kwargs[1]
    -- TODO: support more compilers!
    local cc = os.getenv(self.name.."CC")
    cc = conf:findprogram(cc and {cc} or {"gcc", "cc", "tcc"})
    if not cc then return nil end
    
    conf:test("Checking for suffix of object files")
    local testfname, testf = conf:tmpname(nil, ".c")
    local testf_base = util.basename(testfname)
    local testf_dir = util.dirname(testfname)
    testf:write("int main(){ return 0; }\n")
    testf:close()
    local exitcode, msgs = subprocess.call_capture {
        cc, "-c", testf_base,
        stderr = subprocess.STDOUT,
        cwd = testf_dir}
    if exitcode ~= 0 then
        os.remove(testfname)
        conf:endtest("failed", false, msgs)
        return nil
    end
    local testf_root = util.splitext(testf_base) -- filename without suffix
    local suffix = nil
    for f in lfs.dir(testf_dir) do
        local f_root, f_ext = util.splitext(f)
        if f ~= testf_base and f_root == testf_root then
            suffix = f_ext
            conf:endtest(suffix, true)
            break
        end
    end
    if not suffix then
        os.remove(testfname)
        conf:endtest("failed", false, "no object found")
        return nil
    end

    conf:test("Checking for -M")
    local exitcode, msgs = subprocess.call_capture {
        cc, "-M", testfname,
        stderr = subprocess.STDOUT}
    if exitcode ~= 0 then
        os.remove(testfname)
        conf:endtest("no", false, msgs)
        return nil
    end
    conf:endtest("yes", true)
    os.remove(testfname)

    local libsuffix
    if platform.platform == "windows" then libsuffix = ".dll"
    else libsuffix = ".so" end

    local vars = {
        compiler = cc,
        objsuffix = suffix,
        libsuffix = libsuffix,
    }
    
    -- Read environment variables
    vars.CPPPATH = split_flags(os.getenv(self.name.."CPPPATH") or kwargs.CPPPATH, "-I")
    vars.CFLAGS = split_flags(os.getenv(self.name.."CFLAGS") or kwargs.CFLAGS)
    vars.LDFLAGS = split_flags(os.getenv(self.name.."LDFLAGS") or kwargs.LDFLAGS)
    vars.LIBS = split_flags(os.getenv(self.name.."LIBS") or kwargs.LIBS, "-l")

    self:setvars(conf, vars)
    return vars
end

-- Construct compiler flags from list of include paths
local function make_incflags(cpppath)
    return util.totable(
      util.map(function(x) return "-I"..x end, cpppath))
end

-- Construct linker flags from list of libraries
local function make_libflags(libs)
    return util.totable(
      util.map(function(x) return "-l"..x end, libs))
end

-- c:try_compile {conf, [options...]}
-- Try a compilation.
-- options should contain the following:
--   CC, CFLAGS, CPPPATH (optional)
--   desc = description of test
--   link = true/false (whether to try linking or not)
--   content = program to compile
--   okstr = result string on success (default "ok")
--   failstr = result string on failure (default "no")
-- Return value: true if compilation succeeded, false/nil if not.

function c:try_compile(kwargs)
    assert(type(self) == "table" and self.name, "expected C compiler object as self")
    local conf = kwargs[1]
    assert(type(conf) == "table" and conf.test, "expected configure object as first argument")
    local vars = self:getvars(conf)
    conf:test(kwargs.desc)
    local content = kwargs.content or "int main(){ return 0; }"
    local testfname, testf = conf:tmpname(nil, ".c")
    testf:write(content, "\n")
    testf:close()
    --conf:log("Wrote `%s':\n%s", testfname, content)
    local cc = kwargs.CC or vars.compiler or "cc"
    local cflags = self:getvar("CFLAGS", conf, kwargs, {})
    local incflags = make_incflags(self:getvar("CPPPATH", conf, kwargs, {}))
    local ldflags = self:getvar("LDFLAGS", conf, kwargs, {})
    local libflags = make_libflags(self:getvar("LIBS", conf, kwargs, {}))
    local cmd
    if kwargs.link then
        cmd = util.merge({cc}, cflags, incflags, ldflags, {util.basename(testfname)}, libflags)
    else
        cmd = util.merge({cc, "-c"}, cflags, incflags, {util.basename(testfname)})
    end
    -- local cmd = subprocess.form_cmdline(cmd) -- ???
    --conf:log("Running: %s", cmd)
    util.merge(cmd, {cwd=util.dirname(testfname), stderr=subprocess.STDOUT})
    local exitcode, msgs = subprocess.call_capture(cmd)
    os.remove(testfname)
    if exitcode ~= 0 then
        conf:endtest(kwargs.failstr or "no", false, msgs)
        return false
    else
        conf:endtest(kwargs.okstr or "ok", true, msgs)
        return true
    end
end

-- C source scanner
function scanner(bld, node)
    local csource = node.depends[1]
    local node_target = node.target
    local node_target_base = util.basename(node_target)
    -- TODO: compiler options
  --if not c_scanner_outfname then
  --    -- Create a temporary file for depends output
  --    c_scanner_outfname = os.tmpname()
  --    atexit.atexit(function()
  --        os.remove(c_scanner_outfname)
  --    end)
  --end
    local cc = node.command[1]
    --local quote = subprocess.quote
    
    -- local cmdline = string.format("%s -M %s > %s",
    --     quote(cc), quote(csource.target),
    --     quote(c_scanner_outfname))
    local cmdline = util.merge({cc}, node.CFLAGS, {"-M", csource.target,
      stdout=subprocess.PIPE})
    if not bld.opts.quiet then
        print(make.cmdlinestr(cmdline))
    end
    --local retval = os.execute(cmdline)
    --local retval = os.execute(cmdline)
    -- if retval ~= 0 then
    --     error(string.format(
    --         "%s failed with return code %d while scanning `%s'",
    --         cc, retval, csource.target))
    -- end
    local default_obj = util.swapext(csource.target,
       select(2, util.splitext(node_target)))  -- object filename that compiler will use
    local default_obj_base = util.basename(default_obj)
    -- local f = io.open(c_scanner_outfname, "r")
    local proc = subprocess.popen(cmdline)
    local f = proc.stdout
    local deps = {}
    while true do
        local line = f:read()
        if not line then
            break
        end
        while line:sub(-1) == "\\" do
            -- escaped newline: merge with next line
            local line2 = f:read() or ""
            line = line:sub(0,-2) .. line2
        end
        -- throw a regular expression at it!
        local a, b, m_targ = line:find("^([^%:]*):")
        if not a then
            error(string.format(
                "failed to parse dependency info while scanning `%s'",
                csource.target))
        end
        if m_targ ~= default_obj
        and m_targ ~= default_obj_base then
            error(string.format(
                "%s produced dependencies for `%s', how strange",
                cc, m_targ))
        end
        line = line:sub(b + 1)
        for dep in line:gmatch("[^ ]+") do
            deps[#deps+1] = dep
        end
    end
    f:close()
    local exitcode = proc:wait()
    if exitcode ~= 0 then
        error(string.format(
            "%s failed with exit code %d while scanning `%s'",
            cc, exitcode, csource.target))
    end
    return deps
end

-- c:compile {bld, [dest,] source, options...}
-- Compile a C source file
function c:compile(kwargs)
    local bld, tgt, src = unpack(kwargs)
    assert(type(bld) == "table" and bld.target, "expected builder object as first argument")
    local vars = self:getvars(bld.conf)
    if not src then
        src = tgt
        assert(src, "source file not specified")
        tgt = kwargs.target or util.swapext(src, kwargs.OBJSUFFIX or vars.objsuffix or ".o")
    end
    local cc = kwargs.CC or vars.compiler or "cc"
    local cflags = self:getvar("CFLAGS", bld.conf, kwargs, {})
    local incflags = make_incflags(self:getvar("CPPPATH", bld.conf, kwargs, {}))
    --print(util.repr(cflags), util.repr(incflags))
    local node = bld:target{tgt, src,
        util.merge({cc}, cflags, incflags, {"-c", "-o", tgt, src}),
        scanner = scanner,
    }
    node.CFLAGS = util.merge({}, cflags, incflags)
    return node
end

-- c:program {bld, dest, sources, options...}
-- Link a C program
function c:program(kwargs)
    local bld, tgt, srcs = unpack(kwargs)
    assert(type(bld) == "table" and bld.target, "expected builder object as first argument")
    local vars = self:getvars(bld.conf)
    assert(tgt, "target file not specified")
    assert(srcs, "sources not specified")
    if type(srcs) == "string" then srcs = {srcs} end
    local ld = kwargs.LD or kwargs.CC or vars.compiler or "cc"
    local ldflags = self:getvar("LDFLAGS", bld.conf, kwargs, {})
    local objsuffix = vars.objsuffix or ".o"
    local objects = {}
    for _,src in ipairs(srcs) do
        local base, ext = util.splitext(src)
        local obj
        if util.search({".c", ".i"}, ext) then
            obj = base .. objsuffix
            self:compile(
              util.append(
                util.hcopy(kwargs),
                bld, obj, src))
        else
            obj = src
        end
        insert(objects, obj)
    end
    return bld:target{tgt, objects,
        util.merge({ld}, ldflags, {"-o", tgt}, objects,
        make_libflags(self:getvar("LIBS", bld.conf, kwargs, {})))}
end

-- c:shared_library {bld, dest, sources, options...}
-- Link a C shared library
-- TODO: less hard-coding please!
-- TODO: deal with suffixes and "lib" prefix conventions
function c:shared_library(kwargs)
    -- XXX: should I mutate kwargs?
    local bld, dest = unpack(kwargs)
    local vars = self:getvars(bld.conf)
    if not select(2, util.splitext(dest)) then
        -- Append library suffix
        dest = dest..vars.libsuffix or ".so"
    end
    kwargs[2] = dest
    kwargs.CFLAGS = util.append(
        util.copy(self:getvar("CFLAGS", bld.conf, kwargs, {})),
        "-fPIC")
    kwargs.LDFLAGS = util.append(
        util.copy(self:getvar("LDFLAGS", bld.conf, kwargs, {})),
        "-shared", "-fPIC")
    return self:program(kwargs)
end
