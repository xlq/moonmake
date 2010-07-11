module(..., package.seeall)
require "atexit"

-- Quote a command line argument, for the shell
-- (os.execute invokes the shell, unfortunately).
function quote(arg)
    local needs_quoting = arg:find("[ \t%!%$%^%&%*%(%)%~%[%]%\\%|%{%}%'%\"%;%<%>%?]")
    if needs_quoting then
        arg = "'" .. arg:gsub("%\\", "\\\\") .. "'"
    end
    return arg
end

-- Construct a command-line string from a table, ready to execute.
function form_cmdline(cmd)
    if type(cmd) ~= "string" then
        local s = ""
        for i = 1,#cmd do
            s = s .. quote(cmd[i]) .. " "
        end
        return s:sub(1,-2)
    else
        return cmd
    end
end

-- Run a command (cmd can be a table or a string)
function execute(cmd, cwd)
    cmd = form_cmdline(cmd)
    if cwd then
        cmd = "cd " .. quote(cwd) .. " && " .. cmd
    end
    return os.execute(cmd)
end

-- Run a command and capture its output (stdout/stderr)
-- Returns exitcode, content
--   content is the entire output, in a string.
-- Not thread-safe!
function execute_cap(cmd, cwd)
    cmd = form_cmdline(cmd)
    if cwd then
        cmd = "cd " .. quote(cwd) .. " && " .. cmd
    end
    if not execute_cap_tmpfile then
        execute_cap_tmpfile = os.tmpname()
        atexit.atexit(function()
            os.remove(execute_cap_tmpfile)
        end)
    end
    cmd = cmd .. " >" .. quote(execute_cap_tmpfile) .. " 2>&1"
    local exitcode = os.execute(cmd)
    local f = io.open(execute_cap_tmpfile, "r")
    local content = f:read("*a")
    f:close()
    return exitcode, content
end
