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

-- gather_options(name, ...)
-- Assemble table of options from a configuration.
-- ... contains options tables to look for options in.
-- This function handles the 'use' list.
-- name is "CFLAGS", "LDFLAGS" etc.
local function gather_options(name, options, conf)
    local flags = util.copy(options[name] or conf[name] or {})
    local use = options.use or conf.use or {}
    -- Process "use" setting (list of package names to get options from)
    for _, pkgname in ipairs(use) do
        local pkg = options[pkgname] or conf[pkgname]
        if pkg then
            util.merge(flags, pkg[name])
        end
    end
    return flags
end

-- configure(conf, [cc])
-- Configure the C compiler.
-- cc is the path of the C compiler to use.
-- Returns true on success, false/nil on failure.
function configure(conf, cc)
    -- TODO: support more compilers!
    cc = conf:findprogram(cc and {cc} or {"cl", "CL", "gcc", "cc", "tcc"})
    if not cc then return false end
    
    -- Find out what sort of compiler it is, by its name
    conf:test("Checking type of compiler")
    local patterns = {
        {type="gcc", "[gt]?cc.*"},
        {type="msvc", "[Cc][Ll].*"},
    }
    local cc_type
    for _, x in ipairs(patterns) do
        for _, ptn in ipairs(x) do
            if cc:match(ptn) then
                cc_type = x.type
                break
            end
        end
        if cc_type then break end
    end    
    if not cc_type then
        -- Didn't match any patterns
        -- TODO: allow user to specify compiler type to handle unusual names
        conf:endtest("unknown compiler type", false)
        return false
    end
    conf:endtest(cc_type, true)
    --------------------
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
        cc, ({msvc="/c"})[cc_type] or "-c", "test.c",
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
    --------------------
    if cc_type == "msvc" then
        -- TODO: override from environment
        local link = conf:findprogram({"link", "LINK"}, "Checking for linker")
        if not link then return false end
        conf.LINK = link
    end
    --------------------
    conf.CC = cc
    conf.CC_type = cc_type
    conf.OBJSUFFIX = suffix
    --conf:comment("OBJSUFFIX", "Suffix for object file names")
    
    --------------------
    -- Find a way to scan dependencies
    local scan_method
    if cc_type == "gcc" then
        -- Try using GCC's -M option
        conf:test("Checking for -M")
        local testfname, testf = conf:tmpname(nil, ".c")
        testf:write("int main(){ return 0; }\n")
        testf:close()
        local exitcode, msgs = subprocess.call_capture {
            cc, "-M", testfname,
            stderr = subprocess.STDOUT}
        if exitcode == 0 then
            conf:endtest("yes", true)
            scan_method = "compiler"
        else
            conf:endtest("no", false, msgs)
        end
        os.remove(testfname)
    end
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

    --------------------
    if cc_type == "msvc" then
        -- Parse LIB environment variable and add to LIBPATH
        local libpath = conf.LIBPATH or {}
        conf.LIBPATH = libpath
        conf.LIBPATH = util.merge(conf.LIBPATH or {},
            util.split(os.getenv "LIB" or "", ";"))
    end

    --------------------
    -- Get library suffix based on platform
    local libsuffix
    if platform.platform == "windows" then libsuffix = ".dll"
    else libsuffix = ".so" end

    conf.LIBSUFFIX = libsuffix
    --conf:comment("LIBSUFFIX", "Suffix for shared library file names")

    return true
end

-- Search for a library
-- Return its path, or nil, tried
--    where tried is a table of the paths that were tried.
local function findlib(libpath, libname)
    local tried = {}
    for _, p in ipairs(libpath) do
        -- NOTE: findlib only used for MSVC so we can assume .lib suffix
        local try_path = util.path(p, libname..".lib")
        if lfs.attributes(try_path, "mode") then
            return try_path
        else
            tried[#tried+1] = try_path
        end
    end
    return nil, tried
end

-- make_cmdline(options, conf, output, inputs, link)
-- Return a command line table.
--   link - true if linker is to be run, false for compiler
function make_cmdline(options, conf, output, inputs, link)
    local cc_type = options.CC_type or conf.CC_type
    local cmd
    if cc_type == "msvc" and link then cmd = {options.LINK or conf.LINK or "LINK.EXE"} -- use separate linker program
    else
        cmd = {options.CC or conf.CC or "cc"}
        if not link then util.append(cmd, ({msvc="/c"})[cc_type] or "-c") end
    end
    if cc_type == "msvc" then util.append(cmd, "/nologo") end -- don't show useless logo
    if output then
        if cc_type == "gcc" then util.append(cmd, "-o", output)
        else
            if link then util.append(cmd, "/OUT:"..output)
            else util.append(cmd, "/Fo"..output) end
        end
    end
    if not link or cc_type == "gcc" then
        -- CFLAGS should be given to gcc even during linking, according to
        -- the GNU make manual.
        util.merge(cmd, gather_options("CFLAGS", options, conf))
    end
    if not link then
        -- C preprocessor search path options
        local incopt = ({msvc="/I"})[cc_type] or "-I"
        local defopt = ({msvc="/D"})[cc_type] or "-D"
        util.merge(cmd,
            util.map(
                function(x) return incopt..x end,
                gather_options("CPPPATH", options, conf)),
            util.mapm(
                function(k,v)
                    if v == true then return defopt..k
                    else return defopt..k.."="..tostring(v) end
                end,
                util.pairs(gather_options("CPPDEFINES", options, conf)))
        )
    else -- link
        -- linker options
        util.merge(cmd, gather_options("LDFLAGS", options, conf))
        if cc_type == "gcc" then
            util.merge(cmd, util.map(function(x) return "-L"..x end,
                gather_options("LIBPATH", options, conf)))
        end
    end
    -- Add sources
    util.merge(cmd, inputs)
    -- Add libraries
    if link then
        local libs = gather_options("LIBS", options, conf)
        if cc_type == "gcc" then util.merge(cmd, libs)
        else
            local libpath = gather_options("LIBPATH", options, conf)
            for _, lib in ipairs(gather_options("LIBS", options, conf)) do
                if util.startswith(lib, "-l") then
                    -- Well LINK.EXE doesn't understand the concept of searching for libraries.
                    -- We'll have to do our own searching.
                    local libfile, tried = findlib(libpath, lib:sub(3))
                    if not libfile then
                        -- Couldn't find it. This is bad.
                        if util.isempty(tried) then
                            return util.errorf("%s not found (no library paths to search!)", lib)
                        else
                            return util.errorf("%s not found. Tried:\n\t%s", lib,
                                table.concat(tried, "\n\t"))
                        end
                    end
                    util.append(cmd, libfile)
                else
                    util.append(cmd, lib)
                end
            end
        end
    end
    return cmd
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
    
    local sourcename, sourcef = conf:tmpname(nil, ".c")
    sourcef:write(content, "\n")
    sourcef:close()
    local objname = util.swapext(sourcename, kwargs.OBJSUFFIX or conf.OBJSUFFIX or ".o")
    local cmd = make_cmdline(conf, kwargs, objname, sourcename, false)
    cmd.stderr = subprocess.STDOUT
    local exitcode, msgs = subprocess.call_capture(cmd)
    os.remove(sourcename)
    if exitcode ~= 0 then
        os.remove(objname)
        conf:endtest(kwargs.failstr or "no", false, msgs)
        return false
    end
    
    if kwargs.link then
        local cmd = make_cmdline(conf, kwargs, nil, util.basename(objname), true)
        cmd.cwd = util.dirname(objname)
        cmd.stderr = subprocess.STDOUT
        exitcode, msgs = subprocess.call_capture(cmd)
        os.remove(objname)
        if exitcode ~= 0 then
            conf:endtest(kwargs.failstr or "no", false, msgs)
            return false
        end
    else
        os.remove(objname)
    end
    
    conf:endtest(kwargs.okstr or "ok", true, msgs)
    return true
end

-- Collect flags needed for using makedepend
local function get_m_flags(options, conf)
    local flags = util.totable(
        util.map(function(x) return "-I"..x end,
            gather_options("CPPPATH", options, conf)))
    for k, v in pairs(gather_options("CPPDEFINES", options, conf)) do
        if v == true then util.append(flags, "-D"..k)
        else util.append(flags, "-D"..k.."="..tostring(v)) end
    end
    return flags
end

-- Collect include path flags from a table.
-- Returns table of "-I<foo>" strings.
-- NOTE: not all include flags will come from CPPPATH,
-- eg. some include flags might come from CFLAGS from pkgconfig.
-- So this function finds all the include path flags.
function get_incflags(cmd)
    local flags = {}
    for _, x in ipairs(cmd) do
        if util.startswith(x, "-I")
        or util.startswith(x, "/I") then
            util.append(flags, "-I"..x:sub(3))
        end
    end
    return flags
end

-- Collect include paths for MSVC
-- These are stored in an environment variable called INCLUDE.
local function get_msvc_stdincludes()
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
        -- Decide which command to use to scan for dependencies
        local cmdline
        if scan_method == "compiler" then
            local cc = node.command[1]
            cmdline = util.merge(
                {cc},
                gather_options("CFLAGS", options, conf),
                util.map(function(x) return "-I"..x end,
                    gather_options("CPPPATH", options, conf)),
                 {"-M", csource.target,
                    stdout=subprocess.PIPE})
        else
            local flags = get_m_flags(options, conf)
            if conf.CC_type == "msvc" then
                -- We need a few more things for makedepend
                util.merge(flags, util.map(function(x) return "-I"..x end,
                    get_msvc_stdincludes()))
                -- Define some things to satisfy the Windows headers.
                -- These macros are usually defined by CL.EXE.
                -- It doesn't matter if these flags are wrong, because we only
                -- need to check header dependencies.
                util.append(flags, "-D_WIN32", "-D_M_IX86")
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

        local default_obj = util.swapext(csource.target,
           select(2, util.splitext(node_target)))  -- object filename that compiler will use
        local default_obj_base = util.basename(default_obj)
        -- local f = io.open(c_scanner_outfname, "r")
        
        -- Start the scanner
        if not bld.opts.quiet then
            if not bld.opts.verbose and bld.echo_func and bld.echo_func({
                depends = {csource},
                type = "c.scanner",
            }) then --OK
            else print(make.cmdlinestr(cmdline)) end
        end
        local proc = subprocess.popen(cmdline)
        local f = proc.stdout
        local deps = {}
        
        -- Parse the Makefile rules it outputs
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
    local cmd = make_cmdline(conf, options, dest, source, false)
    local node = bld:target(dest, source, cmd, scanner)
    -- Save information that scanner will need
    -- TODO: either document this or allow bld:target to specify
    -- an arbitrary object to store
    node.cc_options = options
    node.cc_conf = conf
    if conf.CC_scan_method == "none" then
        bld:always_make(node)
    end
    bld:type(node, "c.compile")
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
        if util.search({".o", ".obj", ".ld"}, ext:lower()) then
            -- Already an object
            obj = src
        else
            -- Compile this source
            obj = base .. (options.OBJSUFFIX or conf.OBJSUFFIX or ".o")
            compile(bld, obj, src, options)
        end
        insert(objects, obj)
    end
    -- Link the program
    local cmd = make_cmdline(options, conf, dest, objects, true)
    return bld:type(
        bld:target(dest, objects, cmd),
        "c.program"
    )
end

-- shared_library(bld, dest, sources, [options])
-- Link a C shared library
-- TODO: deal with "lib" prefix conventions
-- TODO: deal with Windows export definitions
function shared_library(bld, dest, sources, options)
    options = options or {}
    local conf = options.conf or bld.conf
    if not select(2, util.splitext(dest)) then -- dest has no suffix
        -- Append library suffix
        dest = dest .. (options.LIBSUFFIX or conf.LIBSUFFIX or ".so")
    end
    -- TODO: is mutating options a good idea?
    if conf.CC_type == "gcc" then
        -- XXX: don't use -fPIC if not needed (eg. MinGW)
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
            "/DLL"
        )
    end
    return bld:type(
        program(bld, dest, sources, options),
        "c.shared_library"
    )
end
