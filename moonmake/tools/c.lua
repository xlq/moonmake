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
    cc = conf:findprogram(cc and {cc} or {"cl", "gcc", "cc", "tcc", "cl", "CL"})
    if not cc then return nil end
    
    -- See what it says if we run it on its own (is this a bit risky?)
    conf:test("Checking type of compiler")
    local cc_basename = util.basename(cc)
    local exitcode, output = subprocess.call_capture {
      cc, stderr=subprocess.STDOUT, cwd=conf:dir()}
    if output:find("Microsoft (R)", 1, true)
    and output:find("Compiler", 1, true) then
        -- Microsoft Visual C compiler
        conf.CC_type = "msvc"
        conf.CC_compile_only = "/c"
        --conf:endtest(output:match "[^%\n]+", true)
        conf:endtest("Microsoft", true)
    elseif util.startswith(cc_basename, "gcc")
    or util.startswith(cc_basename, "cc")
    or util.startswith(cc_basename, "tcc") then
        -- GCC-like compiler
        conf.CC_type = "gcc"
        conf.CC_compile_only = "-c"
        conf:endtest("gcc-like", true)
    else
        -- Unknown sort of compiler
        conf:endtest("unknown compiler type", false, output)
        return false
    end


    conf:test("Checking for suffix of object files")
    local testdir = util.path(conf:dir(), "objsuffixtest")
    assert(lfs.mkdir(testdir))
    local f, err = io.open(util.path(testdir, "test.c"), "w")
    if not f then
        print(lfs.rmdir(testdir))
        conf:endtest("failed", false, "Cannot create "..testdir..": "..err)
        return false
    end
    f:write("int main(){ return 0; }\n")
    f:close()
    local exitcode, msgs = subprocess.call_capture {
        cc, conf.CC_compile_only, "test.c",
        stderr = subprocess.STDOUT,
        cwd = testdir
    }
    if exitcode ~= 0 then
        os.remove(util.path(testdir, "test.c"))
        lfs.rmdir(testdir)
        conf:endtest("failed", false, msgs)
        return false
    end
    local suffix = nil
    local diriter, dirobj = lfs.dir(testdir)
    for f in diriter, dirobj do
        local f_root, f_ext = util.splitext(f)
        if f ~= "test.c" and f_root == "test" then
            suffix = f_ext
            os.remove(util.path(testdir, f))
            conf:endtest(suffix, true)
            break
        end
    end
    dirobj:close()  -- closing this allows us to delete the directory
    os.remove(util.path(testdir, "test.c"))
    lfs.rmdir(testdir)
    if not suffix then
        conf:endtest("failed", false, "No object found.")
        return false
    end

    --[[
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
    ]]--
    
    conf.CC = cc
    conf.OBJSUFFIX = suffix
    --conf:comment("OBJSUFFIX", "Suffix for object file names")

    -- Find a way to scan dependencies
    local testfname, testf = conf:tmpname(nil, ".c")
    testf:write("int main(){ return 0; }\n")
    testf:close()
    local scan_method
    if conf.CC_type == "gcc" then
        conf:test("Checking for -M")
        local exitcode, msgs = subprocess.call_capture {
            cc, "-M", testfname,
            stderr = subprocess.STDOUT}
        if exitcode == 0 then
            conf:endtest("yes", true)
            scan_method = "compiler"
        else
            conf:endtest("no", false, msgs)
        end
    end
    os.remove(testfname)
    if not scan_method then
        -- Try to find makedepend
        local makedepend = conf.MAKEDEPEND or conf:findprogram {"makedepend"}
        if makedepend then
            scan_method = "makedepend"
            conf.MAKEDEPEND = makedepend
        end
    end
    if not scan_method then
        print "Not doing any dependency scanning."
        scan_method = "none"
    end
    conf.CC_scan_method = scan_method
    conf:comment("CC_scan_method", [[
The method for scanning C sources for dependencies.
This can be "compiler" to use the -M compiler option,
"makedepend" to use the makedepend program, or
"none" to do no dependency scanning and always build all sources.]])

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

-- Collect include flags and return list of include directories
local function get_incpaths(flags)
    local dirs = {}
    for _, x in ipairs(flags) do
        if util.startswith(x, "-I") or util.startswith(x, "/I") then
            insert(dirs, x:sub(3))
        end
    end
    return dirs
end

-- Collect include paths for MSVC
-- These arestored in an environment variable called INCLUDE.
function get_msvc_stdincludes()
    local envstr = os.getenv "INCLUDE"
    if envstr then return util.split(envstr, ";")
    else return {} end
end

-- C source scanner
function scanner(bld, node)
    local conf, options = node.cc_conf, node.cc_options
    local scan_method = conf.CC_scan_method
    local newline_delim = false
    if scan_method == "compiler" or scan_method == "makedepend" then
        local csource = node.depends[1]
        local node_target = node.target
        local node_target_base = util.basename(node_target)

        local cmdline
        if scan_method == "compiler" then
            local cc = node.command[1]
            cmdline = util.merge({cc}, node.CFLAGS, {"-M", csource.target,
              stdout=subprocess.PIPE})
        else
            local function addI(x) return "-I"..x end
            local flags = util.totable(util.map(addI, get_incpaths(node.CFLAGS)))
            if conf.CC_type == "msvc" then
                -- We need a few more things for makedepend
                util.merge(flags, util.map(addI, get_msvc_stdincludes()))
                util.append(flags, "-D_WIN32")
            end
            -- Use -w0 to make sure each dependency gets its own line.
            -- This way, we can actually handle spaces in file names.
            -- TODO: use something that isn't as rubbish as makedepend!
            newline_delim = true
            cmdline = util.merge(
                {options.MAKEDEPEND or conf.MAKEDEPEND or "makedepend", "-w0", "-f-",
                    "-o"..(options.OBJSUFFIX or conf.OBJSUFFIX or ".o")},
                flags, {csource.target, stdout=subprocess.PIPE}
            )
        end

        if not bld.opts.quiet then
            print(make.cmdlinestr(cmdline))
        end
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
            -- remove comment, if present
            local line = line:gsub("%s*%#.*", "")
            if line ~= "" then
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
                if newline_delim then
                    deps[#deps+1] = line:match("[^%s].*")
                else
                    for dep in line:gmatch("[^ ]+") do
                        deps[#deps+1] = dep
                    end
                end
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
    elseif scan_method == "makedepend" then
        
    end
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
    local cmd = util.merge({options.CC or conf.CC or "cc"}, cflags)
    if conf.CC_type == "gcc" then
        util.append(cmd, "-c", "-o", dest, source)
    elseif conf.CC_type == "msvc" then
        util.append(cmd, "/c", "/Fo"..dest, source)
    end
    local node = bld:target(dest, source, cmd, scanner)
    -- Save information that scanner will need
    -- TODO: either document this or allow bld:target to specify
    -- an arbitrary object to store
    node.CFLAGS = cflags
    node.cc_options = options
    node.cc_conf = conf
    if conf.CC_scan_method == "none" then
        bld:always_make(node)
    end
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
    local outflag = ({
        msvc = {"/Fe"..dest},
        gcc = {"-o", dest},
    })[conf.CC_type]
    return bld:target(
        dest,
        objects,
        (util.merge(
            {options.CC or conf.CC or "cc"},
            gather_flags(bld, options, "CFLAGS"),
            gather_flags(bld, options, "LDFLAGS"),
            outflag,
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
    if conf.CC_type == "gcc" then
        options.CFLAGS = util.append(
            util.copy(options.CFLAGS or conf.CFLAGS or {}),
            "-fPIC"
        )
        options.LDFLAGS = util.append(
            util.copy(options.LDFLAGS or conf.LDFLAGS or {}),
            "-shared"
        )
    elseif conf.CC_type == "msvc" then
        options.LDFLAGS = util.append(
            util.copy(options.LDFLAGS or conf.LDFLAGS or {}),
            "/LD"
        )
    end
    return program(bld, dest, sources, options)
end
