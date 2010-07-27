module(..., package.seeall)
--require "luaconf"
require "subprocess"
make = require "moonmake.make"
util = require "moonmake.util"
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

function c:options(opts, envgroup)
    if not envgroup then
        envgroup = {
            group="Some influential environment variables",
        }
        insert(opts, envgroup)
    end
    local h = envgroup.help or {}
    envgroup.help = h
    insert(h, {"  "..self.name.."CC",     "C compiler command"})
    insert(h, {"  "..self.name.."CFLAGS", "C compiler flags"})
    return envgroup
end

-- Configuration
-- Returns table representing the configured compiler, or nil
function c:configure(conf)
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
    local info = {
        compiler = cc,
        objsuffix = suffix,
    }
    conf[self.name.."CC"] = info
    return info
end

local function make_incflags(cpppath)
    return util.totable(
      util.map(function(x) return "-I"..x end, cpppath))
end

-- Try a compilation
-- inf should contain the following fields:
--   CC, CFLAGS, CPPPATH (optional)
--   desc = description of test
--   link = true/false (whether to try linking or not)
--   content = program to compile
--   okstr = result string on success (default "ok")
--   failstr = result string on failure (default "no")
-- function try_compile(inf)
--     luaconf.start_test(inf.desc)
--     local content = inf.content or "int main(){ return 0; }"
--     local testfname, testf = luaconf.tmpname(
--         nil, nil, ".c")
--     testf:write(content .. "\n")
--     testf:close()
--     luaconf.log("Wrote `%s':\n%s", testfname, content)
--     local cc = inf.CC or CC or "cc"
--     local cflags = getruleopt(inf, "CFLAGS")
--     local ldflags = getruleopt(inf, "LDFLAGS")
--     local incflags = make_incflags(getruleopt(inf, "CPPPATH"))
--     local exitcode, msgs
--     local cmd
--     if inf.link then
--         cmd = table.join({cc}, cflags, incflags, ldflags, {util.basename(testfname)})
--     else
--         cmd = table.join({cc, "-c"}, cflags, incflags, {util.basename(testfname)})
--     end
--     local cmd = subprocess.form_cmdline(cmd)
--     luaconf.log("Running: %s", cmd)
--     exitcode, msgs = subprocess.execute_cap(
--         cmd, util.dirname(testfname))
--     os.remove(testfname)
--     if exitcode ~= 0 then
--         luaconf.end_test(inf.failstr or "no", false, msgs)
--         return false
--     else
--         luaconf.end_test(inf.okstr or "ok", true, msgs)
--         return true
--     end
-- end

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
    local info = bld.conf[self.name.."CC"]
    if not src then
        src = tgt
        assert(src, "source file not specified")
        tgt = kwargs.target or util.swapext(src, kwargs.OBJSUFFIX or info.objsuffix or ".o")
    end
    local cc = info.compiler or kwargs.CC or "cc"
    local cflags = kwargs.CFLAGS or {}
    local incflags = make_incflags(kwargs.CPPPATH or {})
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
    local info = bld.conf[self.name.."CC"]
    assert(tgt, "target file not specified")
    assert(srcs, "sources not specified")
    if type(srcs) == "string" then srcs = {srcs} end
    local ld = kwargs.LD or kwargs.CC or info.compiler or "cc"
    local ldflags = kwargs.LDFLAGS or {}
    local objsuffix = info.objsuffix or ".o"
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
        util.merge({ld}, ldflags, {"-o", tgt}, objects)}
end

-- c:shared_library {bld, dest, sources, options...}
-- Link a C shared library
-- TODO: less hard-coding please!
-- TODO: deal with suffixes and "lib" prefix conventions
function c:shared_library(kwargs)
    -- XXX: should I mutate kwargs?
    kwargs.CFLAGS = util.append(kwargs.CFLAGS or {}, "-fPIC")
    kwargs.LDFLAGS = util.append(kwargs.LDFLAGS or {}, "-shared", "-fPIC")
    return self:program(kwargs)
end
