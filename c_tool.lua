---------- C LANGUAGE SUPPORT ----------

-- C source scanner
function c_scanner(node)
    local csource = node.depends[1]
    -- TODO: compiler options
    if not c_scanner_outfname then
        c_scanner_outfname = os.tmpname()
        atexit.atexit(function()
            os.remove(c_scanner_outfname)
        end)
    end
    local cc = node.command[1]
    local cmdline = string.format("%s -M -MT %s %s > %s",
        quote(cc), quote(node.target), quote(csource.target),
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
        if m_targ ~= node.target then
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
-- Eg.  c_compile {"foo.c", CFLAGS = {...}}
function c_compile(inf)
    local tgt, src
    if inf[2] then
        tgt = inf[1]
        src = inf[2]
    else
        src = inf[1] or inf.source
        assert(src, "source file not specified")
        tgt = inf.target or swapext(src, inf.OBJSUFFIX or OBJSUFFIX or ".o")
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
        scanner = c_scanner
    }
end

-- Link a C program
function c_program(inf)
    local tgt = inf[1] or inf.target
    local srcs = inf[2] or inf.sources
    assert(tgt, "target file not specified")
    assert(srcs, "sources not specified")
    if type(srcs) == "string" then srcs = {srcs} end
    local ld = inf.LD or LD or "cc"
    local ldflags = getruleopt(inf, "LDFLAGS")
    local objsuffix = inf.OBJSUFFIX or OBJSUFFIX or ".o"
    local objects = {}
    for _,src in ipairs(srcs) do
        local base, ext = splitext(src)
        local obj
        if table.search({".c", ".i"}, ext) then
            obj = base .. objsuffix
            c_compile(util.tabrepli(inf, obj, src))
        else
            obj = src
        end
        objects[#objects+1] = obj
    end
    return target {tgt, objects,
        table.join({ld}, ldflags, {"-o", tgt}, objects)
    }
end

