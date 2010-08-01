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

-- configure(conf, [cc])
-- Configure the C compiler.
-- cc is the path of the C compiler to use.
-- Returns true on success, false/nil on failure.
function configure(conf, cc)
    -- TODO: support more compilers!
    cc = conf:findprogram(cc and {cc} or {"gcc", "cc", "tcc"})
    if not cc then return nil end
    conf.CC = cc
    
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
    conf.OBJSUFFIX = suffix
    --conf:comment("OBJSUFFIX", "Suffix for object file names")

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

    conf.LIBSUFFIX = libsuffix
    --conf:comment("LIBSUFFIX", "Suffix for shared library file names")

    return true
end

-- try_compile {conf, [options...]}
-- Try a compilation.
-- options should contain the following:
--   CC, CFLAGS, CPPPATH (optional)
--   desc = description of test
--   link = true/false (whether to try linking or not)
--   content = program to compile
--   okstr = result string on success (default "ok")
--   failstr = result string on failure (default "no")
-- Return value: true if compilation succeeded, false/nil if not.

function try_compile(kwargs)
    assert(type(kwargs) == "table", "expected a single table argument")
    local conf = kwargs[1]
    assert(type(conf) == "table" and conf.test, "expected configure object as first argument")
    conf:test(kwargs.desc)
    local content = kwargs.content or "int main(){ return 0; }"
    local testfname, testf = conf:tmpname(nil, ".c")
    testf:write(content, "\n")
    testf:close()
    --conf:log("Wrote `%s':\n%s", testfname, content)
    local cc = kwargs.CC or conf.CC or "cc"
    local cflags = kwargs.CFLAGS or conf.CFLAGS or {}
    local ldflags = kwargs.LDFLAGS or conf.LDFLAGS or {}
    local libs = kwargs.LIBS or conf.LIBS or {}
    local cmd
    if kwargs.link then
        cmd = util.merge({cc}, cflags, ldflags, {util.basename(testfname)}, libs)
    else
        cmd = util.merge({cc, "-c"}, cflags, {util.basename(testfname)})
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

-- gather_flags(bld, conf, name, use)
-- Assemble flags
-- name is "CFLAGS", "LDFLAGS" etc.
local function gather_flags(bld, options, name)
    local conf = options.conf or bld.conf
    local flags = util.copy(options[name] or conf[name] or {})
    for _, pkgname in ipairs(options.use or {}) do
        local pkg = options[pkgname] or conf[pkgname]
        if pkg then
            util.merge(flags, pkg[name])
        end
    end
    return flags
end

-- compile(bld, dest, source, [options])
-- Compile a C source file.
-- Options is a table with:
--     CFLAGS  - usual meanings (overriding)
--     conf - compiler configuration to use
--     use - list of packages to use
function compile(bld, dest, source, options)
    assert(make.is_builder(bld), "expected builder as first argument")
    assert(source, "source file not specified")
    options = options or {}
    local conf = options.conf or bld.conf
    if not dest then
        dest = util.swapext(source, options.OBJSUFFIX or conf.OBJSUFFIX or ".o")
    end
    local cflags = gather_flags(bld, options, "CFLAGS")
    local node = bld:target(
        dest,
        source,
        util.merge(
            {options.CC or conf.CC or "cc"},
            cflags,
            {"-c", "-o", dest, source}
        ),
        scanner
    )
    node.CFLAGS = cflags
    return node
end

-- program(bld, dest, sources, [options])
-- Link a C program.
-- Options is a table with:
--     CFLAGS, LDFLAGS, LIBS - usual meanings (overriding)
--     conf - compiler configuration to use
--     use - list of packages to use
function program(bld, dest, sources, options)
    assert(make.is_builder(bld), "expected builder as first argument")
    assert(dest, "target file not specified")
    assert(sources, "sources not specified")
    options = options or {}
    local conf = options.conf or bld.conf
    local objects = {}
    if type(sources) == "string" then sources = {sources} end
    for _, src in ipairs(sources) do
        local base, ext = util.splitext(src)
        local obj
        -- TODO: more suffixes!
        if util.search({".c", ".i"}, ext) then
            -- Compile this source
            obj = base .. (options.OBJSUFFIX or conf.OBJSUFFIX or ".o")
            compile(bld, obj, src, options)
        else
            -- This is already an object
            obj = src
        end
        insert(objects, obj)
    end
    -- Link the program
    return bld:target(
        dest,
        objects,
        (util.merge(
            {options.CC or conf.CC or "cc"},
            gather_flags(bld, options, "CFLAGS"),
            gather_flags(bld, options, "LDFLAGS"),
            {"-o", dest},
            objects,
            gather_flags(bld, options, "LIBS")
        ))
    )
end

-- shared_library(bld, dest, sources, [options])
-- Link a C shared library
-- TODO: deal with "lib" prefix conventions
function shared_library(bld, dest, sources, options)
    options = options or {}
    local conf = options.conf or bld.conf
    if not select(2, util.splitext(dest)) then
        -- Append library suffix
        dest = dest .. (options.LIBSUFFIX or conf.LIBSUFFIX or ".so")
    end
    -- TODO: is mutating options a good idea?
    options.CFLAGS = util.append(
        util.copy(options.CFLAGS or conf.CFLAGS or {}),
        "-fPIC"
    )
    options.LDFLAGS = util.append(
        util.copy(options.LDFLAGS or conf.LDFLAGS or {}),
        "-shared"
    )
    return program(bld, dest, sources, options)
end
