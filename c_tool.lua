module(..., package.seeall)
require "luaconf"
require "subprocess"

---------- C LANGUAGE SUPPORT ----------

-- Configuration
function configure(varprefix)
    -- TODO: support more compilers!
    varprefix = varprefix or ""
    local cc = os.getenv(varprefix.."CC")
    if not cc then
        cc = luaconf.find_program({"gcc", "cc", "tcc"}, "Finding C compiler")
    end
    if not cc then return nil end
    luaconf.set(varprefix.."CC", cc)
    
    luaconf.start_test("Checking for suffix of object files")
    local confdir = luaconf.confdir()
    local testfname, testf = luaconf.tmpname(
        confdir, nil, ".c")
    testf:write("int main(){ return 0; }\n")
    testf:close()
    local exitcode, msgs = subprocess.execute_cap(
        {cc, "-c", util.basename(testfname)}, confdir)
    if exitcode ~= 0 then
        os.remove(testfname)
        luaconf.end_test("failed", false, msgs)
        return nil
    end
    local testfname_basename = util.basename(testfname)
    local testfname_root = util.splitext(testfname_basename)
    local suffix = nil
    for f in lfs.dir(confdir) do
        if f ~= testfname_basename
        and f:sub(1, #testfname_root) == testfname_root then
            suffix = f:sub(#testfname_root + 1)
            luaconf.end_test(suffix, true)
            break
        end
    end
    if not suffix then
        os.remove(testfname)
        luaconf.end_test("failed", false, "no object found")
        return nil
    end
    luaconf.set(varprefix.."OBJSUFFIX", suffix)

    --local testf_obj = util.swapext(testfname, suffix)
    luaconf.start_test("Checking for -M")
    local exitcode, msgs = subprocess.execute_cap(
        {cc, "-M", testfname})
    if exitcode ~= 0 then
        os.remove(testfname)
        luaconf.end_test("no", false, msgs)
        return nil
    end
    luaconf.end_test("yes", true)
    os.remove(testfname)
    return true
end

-- C source scanner
function scanner(node)
    local csource = node.depends[1]
    local node_target = node.target
    local node_target_base = util.basename(node_target)
    -- TODO: compiler options
    if not c_scanner_outfname then
        c_scanner_outfname = os.tmpname()
        atexit.atexit(function()
            os.remove(c_scanner_outfname)
        end)
    end
    local cc = node.command[1]
    local quote = subprocess.quote
    local cmdline = string.format("%s -M %s > %s",
        quote(cc), quote(csource.target),
        quote(c_scanner_outfname))
    if not opts.quiet then
        print(cmdline)
    end
    local retval = os.execute(cmdline)
    if retval ~= 0 then
        error(string.format(
            "%s failed with return code %d while scanning `%s'",
            cc, retval, csource))
    end
    local f = io.open(c_scanner_outfname, "r")
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
                csource))
        end
        if m_targ ~= node_target 
        and m_targ ~= node_target_base then
            error(string.format(
                "%s produced dependencies for target `%s', how strange",
                cc, csource))
        end
        line = line:sub(b + 1)
        for dep in line:gmatch("[^ ]+") do
            deps[#deps+1] = dep
        end
    end
    f:close()
    return deps
end

-- Compile a C source
-- Eg.  compile {"foo.c", CFLAGS = {...}}
function compile(inf)
    local tgt, src
    if inf[2] then
        tgt = inf[1]
        src = inf[2]
    else
        src = inf[1] or inf.source
        assert(src, "source file not specified")
        tgt = inf.target or util.swapext(src, inf.OBJSUFFIX or OBJSUFFIX or ".o")
    end
    local cc = inf.CC or CC or "cc"
    local cflags = getruleopt(inf, "CFLAGS")
    local cpppath = getruleopt(inf, "CPPPATH")
    local incflags = {}
    for _, v in ipairs(cpppath) do
        incflags[#incflags+1] = "-I" .. v
    end
    return target {tgt, src,
        table.join({cc}, cflags, incflags, {"-c", "-o", tgt, src}),
        scanner = scanner
    }
end

-- Link a C program
function program(inf)
    local tgt = inf[1] or inf.target
    local srcs = inf[2] or inf.sources
    assert(tgt, "target file not specified")
    assert(srcs, "sources not specified")
    if type(srcs) == "string" then srcs = {srcs} end
    local ld = inf.LD or LD or inf.CC or CC or "cc"
    local ldflags = getruleopt(inf, "LDFLAGS")
    local objsuffix = inf.OBJSUFFIX or OBJSUFFIX or ".o"
    local objects = {}
    for _,src in ipairs(srcs) do
        local base, ext = util.splitext(src)
        local obj
        if table.search({".c", ".i"}, ext) then
            obj = base .. objsuffix
            compile(util.tabrepli(inf, obj, src))
        else
            obj = src
        end
        objects[#objects+1] = obj
    end
    return target {tgt, objects,
        table.join({ld}, ldflags, {"-o", tgt}, objects)
    }
end
