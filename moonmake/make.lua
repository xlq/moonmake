#!/usr/bin/env lua
--package.path = debug.getinfo(1,"S").short_src:gsub("/[^/]*$", "") .. "/?.lua;" .. package.path
module(..., package.seeall)
require "lfs"
require "subprocess"
--tostring2 = require "moonmake.tostring2"
util = require "moonmake.util"
--functional = require "moonmake.functional"
--atexit = require "moonmake.atexit"
--list = require "moonmake.flexilist".list
--require "profiler"

local insert, remove = table.insert, table.remove
local isempty = util.isempty

argv0 = arg[0]  -- name of luamake executable

-- Quote a command line argument, for the shell
function quote(arg)
    assert(type(arg) == "string", "expected string as first argument")
    local needs_quoting = arg:find("[ \t%!%$%^%&%*%(%)%~%[%]%\\%|%{%}%'%\"%;%<%>%?]")
    if needs_quoting then
        arg = "'" .. arg:gsub("%'", "'\\''") .. "'"
    end
    return arg
end

-- Return string representation of a command, with shell-like quoting
function cmdlinestr(cmd)
    if type(cmd) ~= "string" then
        return util.concat(
            util.map(quote, cmd),
            " ")
    else
        return cmd
    end
end


---- Information about node data structure
-- A node is a table with the following fields:
--     target - name of the file the node represents.
--     depends - list of static dependencies for the node. May be empty but
--         this field is always present. Each entry is another node reference.
--     _succ - list of nodes that depend on this one
-- Sometimes present:
--     command - the command used to update the node. This is a table of
--         arguments, eg. {"gcc", "-c", "-o", "main.o", "main.c"}
--     _proc - object representing the running process
--     _mtime - the modification time of the file, or false if the file
--         does not exist.
--     _visited - set to true during dependency traversal when the node has
--         been visited.
--     _updated - set to true after the node has been updated (updating a node
--         involves running the command, unless --dry-run is being used)
--     _always_make - set to true if the node should always be rebuilt.

---- Builder class
builder = {}
builder.__index = builder

function builder.new()
    return setmetatable({
        -- Options (from command line)
        opts = nil,
        -- State table
        state = nil,
        -- Table of [node.target] = node
        table = {},
        -- Table of [alias name] = node
        aliases = {},
        running_jobs = {},
        finished_jobs = {},
    }, builder)
end

function is_builder(x)
    return type(x) == "table" and getmetatable(x) == builder
end

-- Print debugging message.
function builder:debug(fmt, ...)
    if self.opts.debug then
        print(string.format(fmt, ...))
    end
end

-- Get a node's target's mtime (cached).
-- Returns the mtime, or false if file does not exist.
function builder:get_mtime(node)
    local t = node._mtime
    t = (t == nil) and t or lfs.attributes(node.target, "modification") or false
    node._mtime = t
    return t
end

-- Invalidate all mtime cache records.
function builder:inval_all_mtime()
    for _, node in pairs(self.table) do
        node._mtime = nil
    end
end

-- Turn x into a node (x can be a node already, or a filename)
function builder:node(x)
    if type(x) == "table" then return x
    elseif type(x) == "string" then
        local node = self.table[x] or {
            target = x,
            depends = {},
            _succ = {}}
        self.table[x] = node
        return node
    else
        util.errorf("Unexpected argument for builder:node: %s", type(x))
    end
end

function validate_command(cmd)
    for _, x in ipairs(cmd) do
        if type(x) ~= "string" then
            error("command table cannot contain items of type "..type(x))
        end
    end
    return cmd
end

-- bld:target(target, depends, command, scanner)
function builder:target(target_name, depends_names, command, scanner)
    assert(target_name, "no target specified")
    local node = self:node(target_name)
    if command and node.command then
        util.errorf("command for target `%s' already defined", target_name)
    end
    assert(not command or type(command) == "table", "command must be a table")
    if type(depends_names) == "string" then depends_names = {depends_names} end
    -- convert list of depends names to table references
    local depends = node.depends
    for _, dep_name in ipairs(depends_names) do
        local dep = self:node(dep_name)
        insert(dep._succ, node)
        insert(depends, dep)
    end
    node.command = validate_command(command)
    if scanner then
        assert(type(scanner) == "function", "function expected for argument 4")
        node.scanner = scanner
    end
    return node
end

-- Add extra dependencies for a target
function builder:depends(tgt, dep_names)
    return self:target{tgt, dep_names}
end

-- Always build a node
function builder:always_make(node)
    node = self:node(node)
    node._always_make = true
    return node
end

-- Declare an alias node
-- The alias 'default' is built by default.
function builder:alias(name, target_names)
    local targets = self.aliases[name] or {}
    self.aliases[name] = targets
    if type(target_names) == "string" then target_names = {target_names} end
    for _, tgt in ipairs(target_names) do
        insert(targets, self:node(tgt))
    end
end

-- Load or create new state table.
function builder:loadstate()
    self.state = lfs.attributes(".moonmake.state", "mode")
      and dofile(".moonmake.state")
      or {
        depends = {},
        commands = {},
      }
end

-- Write state to file.
function builder:savestate()
    local f = io.open(".moonmake.state", "w")
    f:write("return " .. util.repr(self.state) .. "\n")
    f:close()
end

-- Run the dependency scanner for a node
-- Returns new dependency list
function builder:run_scanner(node)
    local dyn_deps = node.scanner(self, node)
    self.state.depends[node.target] = dyn_deps
    return dyn_deps
end

-- Handle dynamic dependencies.
-- Returns new need_update value
function builder:do_dyn_deps(node, need_update)
    local dyn_deps = self.state.depends[node.target]
    local scanner_run = false
    -- NOTE: do_dyn_deps won't be called if target doesn't exist
    local node_mtime = node._mtime
    -- Run the dependency scanner if:
    --  - there is one, but there's no old dependency information
    --  - not up-to-date
    if need_update or not dyn_deps then
        self:debug("Running scanner (needupdate=%s)", tostring(need_update))
        scanner_run = true
        dyn_deps = self:run_scanner(node) or {}
    end
    if not need_update then
        -- Check dynamic dependencies
        for _, dep_name in ipairs(dyn_deps) do
            local dep = self:node(dep_name)
            -- If dep is not a source node (i.e. it has a rule to generate it)
            -- and it is not in the normal dependencies list, we could've run
            -- things in the wrong order before dependency scanning. This is
            -- bad. If dep *is* in normal dependencies list, it will have been
            -- visited by now, so we can check dep._visited to catch *some* cases.
            if dep.command and not dep._visited then
                util.fprintf(io.stderr,
                    "%s: warning: `%s' depends on generated target `%s', "
                    .. "but `%s' is not in the dependencies list\n",
                    argv0, node.target, dep_name, node.target)
            end
            local dep_mtime = self:get_mtime(dep)
            if not dep_mtime or dep_mtime > node_mtime then
                need_update = true
                -- A dynamic dep has changed, so if we haven't run the scanner
                -- already, we'll need to, to maintain consistency.
                if not scanner_run then
                    scanner_run = true
                    self:run_scanner(node)
                end
                -- We don't need to check the dynamic deps any further
                break
            end
        end
    end
    return need_update
end
    
-- Actually start a job
function builder:startjob(node)
    self:wait_for_free_slot()
    node._proc = subprocess.popen(node.command)
    insert(self.running_jobs, node)
end

-- Check up-to-date-ness and start a job, if needed.
function builder:examine(node)
    local node_name = node.target
    local node_command = node.command
    if node_command then
        local node_mtime = self:get_mtime(node)
        local need_update = self.opts.always_make or node._always_make

        if not node_mtime then
            -- target does not exist
            self:debug("Target `%s' does not exist", node_name)
            need_update = true
        end

        -- Check dependency times
        for _, dep in ipairs(node.depends) do
            local dep_mtime = self:get_mtime(dep)
            if not dep_mtime then
                -- dep doesn't exist
                self:debug("Dep `%s' does not exist", dep.target)
                need_update = true
            elseif node_mtime and dep_mtime > node_mtime then
                -- dep is newer
                self:debug("Dep `%s' newer than `%s'", dep.target, node_name)
                need_update = true
            end
        end

        -- Has command changed?
        local old_command = self.state.commands[node_name]
        if old_command and not util.compare(old_command, node_command) then
            self:debug("Command for `%s' has changed", node_name)
            need_update = true
        end
        self.state.commands[node_name] = node_command
        -- Handle dynamic dependencies
        if node.scanner then
            need_update = self:do_dyn_deps(node, need_update)
        end
        if need_update then
            -- TODO: after questioning, save state?
            if self.opts.question then os.exit(1) end
            if not self.opts.quiet then print(cmdlinestr(node_command)) end
            if not self.opts.dry_run then
                -- Start the job
                self:startjob(node)
                --self:wait_for_free_slot()
                --local proc = subprocess.popen(node.command)
                --node._proc = proc
                --insert(self.running_jobs, node)
            end
        else
            insert(self.finished_jobs, node)
        end
    else
        insert(self.finished_jobs, node)
    end
end

-- Wait until the number of running jobs is below maximum
function builder:wait_for_free_slot()
    local max_jobs = tonumber(self.opts.jobs) or 1
    if #self.running_jobs == max_jobs then
        self.debug("%d jobs running: waiting for free slot", max_jobs)
        self:waitfor()
    end
end

-- Wait for a job to finish
function builder:waitfor()
    local running_jobs = self.running_jobs
    local function finish(i, job)
        table.remove(running_jobs, i)
        job._mtime = nil -- invalidate cached mtime
        insert(self.finished_jobs, job)
        return
    end
    if #running_jobs > 0 then
        -- see if a subprocess has already finished
        for i, job in ipairs(running_jobs) do
            if job._proc:poll() then
                return finish(i, job)
            end
        end
        -- Now might be a good time to collect garbage
        --collectgarbage("collect")
        -- Wait for child process
        self:debug("Waiting for child processes")
        local proc, exitcode = assert(subprocess.wait())
        for i, job in ipairs(running_jobs) do
            if job._proc == proc then
                return finish(i, job)
            end
        end
        error("subprocess.wait returned unknown process: no clue what to do now!")
    end
end

-- Return list of root nodes based on options on command line
function builder:roots()
    local atable = self.aliases
    local dtable = self.table
    --print(tostring2.tostring2(dtable))
    
    local roots
    if #self.opts > 0 then
        -- Build the targets specified on the command line
        roots = {}
        for _, tgt in ipairs(self.opts) do
            local nodes = atable[tgt]
            if nodes then
                -- is an alias
                roots:merge(nodes)
            else
                local node = dtable[tgt]
                if node then
                    insert(roots, node)
                else
                    util.fprintf(io.stderr,
                        "%s: *** No rule to make target `%s'. Stop.\n",
                        argv0, tgt)
                    os.exit(2)
                end
            end
        end
    else
        -- No targets specified on command line
        -- Try using "default" alias
        roots = atable.default
        if not S then
            roots = {}
            -- Doesn't exist. Find all nodes that nothing depends on
            for _, node in pairs(dtable) do
                if isempty(node._succ) then
                    insert(roots, node)
                end
            end
        end
    end
    return roots
end

-- Call func(node, isleaf) for each node in depth-first order.
-- All nodes must have _visited=false before searching.
-- roots is a table of nodes to start searching from.
local function depthfirst(roots, func)
    local stack = {}  -- stack of {node, i}
    local push, pop = insert, remove
    for _, root in pairs(roots) do
        root._visited = true
        push(stack, {root, 1})
        while not isempty(stack) do
            local top = stack[#stack]
            local node, i = unpack(top)
            local dep = node.depends[i]
            if dep then
                --print("From:", node.target)
                --print("Dep:", dep.target)
                if dep._visited then
                    --print("Already visited")
                    -- already visited: do we have a cycle?
                    local j = 1
                    while j <= #stack and stack[j][1] ~= dep do j = j + 1 end
                    if j <= #stack then
                        -- a cycle was found
                        local cycle_nodes = {}
                        while j <= #stack do
                            insert(cycle_nodes, stack[j][1].target)
                            j = j + 1
                        end
                        insert(cycle_nodes, dep.target)
                        error("Dependency cycle: " .. table.concat(cycle_nodes, " <-- "))
                    end
                else
                    dep._visited = true
                    push(stack, {dep, 1})
                end
                i = i + 1
                top[2] = i
            else
                -- run out of dependencies
                --print("Done deps of:", node.target)
                func(node, i == 1)
                pop(stack)
            end
        end
    end
end

function builder:detectcycles()
    -- TODO: re-use results from this search, somehow,
    -- for leaf finding?
    depthfirst(self.table, function()end)
end

-- Main build function.
function builder:make()
    --if not subprocess then self:debug("Subprocess module not available: parallel job execution disabled") end
    self:detectcycles()

    local dtable = self.table
    local roots = self:roots()
    if self.opts.debug then
        self:debug("Targets: %s",
          util.concat(
            util.map(util.getter("target"), roots), " "))
    end

    self:loadstate()

    -- Reset all fields (for repeating algorithm for profiling)
    for _, node in pairs(dtable) do
        node._visited = false
        node._updated = false
    end

    local running_jobs = self.running_jobs
    local finished_jobs = self.finished_jobs
    local exitcode = 0

    -- Depth-first search to find leaves and prune nodes we don't need
    depthfirst(roots, function(node, isleaf)
        if isleaf then self:examine(node) end
    end)

    local function isneeded(node) return node._visited end

    -- Topological sort --
    
    while true do
        if isempty(finished_jobs) then
            if isempty(running_jobs) then break end -- all done!
            self:waitfor()
        end
        assert(not isempty(finished_jobs), "waitfor() didn't work!")
        -- n <- completed node in S
        -- remove n from S
        local n = remove(finished_jobs)
        if n._proc and n._proc.exitcode ~= 0 then
            exitcode = n._proc.exitcode
        else
            -- for each node m with an edge e from n to m do
            --     remove edge e
            n._updated = true
            -- for each node m with an edge e from n to m do
            for _, m in ipairs(n._succ) do
                if isneeded(m) then
                    -- if m has no more incoming edges
                    local more_edges = false
                    for _, dep in ipairs(m.depends) do
                        if not dep._updated then
                            more_edges = true
                            break
                        end
                    end
                    if not more_edges then
                        -- insert m into S
                        -- start m
                        self:examine(m)
                    end
                end
            end
        end
    end

    self:savestate()
    --inval_all_mtime()
    return exitcode
end

-- Dump dependency table
function builder:dump()
    --local str = ""
    --local function coll(x) str = str .. x end
    local function scannerinfo(node)
        if node.scanner then
            local dbg = debug.getinfo(node.scanner, "nS")
            if dbg.name then
                return ", scanner=["..dbg.namewhat.." \""..dbg.name.."\"]"
            else
                return ", scanner=["..dbg.short_src..":"..dbg.linedefined.."]"
            end
        else
            return ""
        end
    end
    print("Dump of dependency table:")
    for node_name, node in pairs(self.table) do
        print("target {\"" .. node_name .. "\", {"
          .. util.concat(
            util.map(
              function(d) return "\""..tostring(d.target).."\"" end,
              node.depends), ", ")
          .. "}"
          .. (node.command and (
              ", {" .. util.concat(
                util.map(
                  function(c) return "\""..tostring(c).."\"" end,
                  node.command), ", ") .. "}")
            or "")
          .. scannerinfo(node)
          .. "}")
    end
    print("Aliases:")
    for name, nodes in pairs(self.aliases) do
        print("alias(\"" .. name .. "\", {"
          .. util.concat(map(function(node) return "\""..node.target.."\"" end, nodes), ", ")
          .. "})")
    end
end

-- Visit a node for cleaning.
-- to_clean is a table to append nodes to.
-- node is the node to visit.
function builder:clean_visit(to_clean, node)
    if not node._visited then
        node._visited = true
        if node.command and self:get_mtime(node) then
            insert(to_clean, node)
        end
        for _, dep in ipairs(node.depends) do
            clean_visit(to_clean, dep)
        end
    end
end

-- Remove targets and dependencies
-- TODO: tidy this function up, factor out
--   code common with make()
function builder:clean()
    local dtable = self.table
    local atable = self.aliases
    local to_clean = {}
    if #self.opts > 0 then
        -- Remove targets specified on command line, and their intermediates
        for _, tgt in ipairs(self.opts) do
            local nodes = atable[tgt]
            if nodes then
                for _, node in ipairs(nodes) do clean_visit(to_clean, node) end
            else
                local node = dtable[tgt]
                if node then
                    clean_visit(to_clean, node)
                else
                    util.fprintf(io.stderr,
                        "%s: *** Cannot clean unknown target `%s'.\n",
                        argv0, tgt)
                end
            end
        end
    else
        -- local S = atable.default
        -- if S then
        --     -- Remove targets specified by "default" alias
        --     for _, node in ipairs(S) do
        --         if node.command and self:get_mtime(node) then
        --             to_clean:append(node)
        --         end
        --     end
        -- else
        -- end

        -- Remove all targets
        for _, node in pairs(dtable) do
            if node.command and self:get_mtime(node) then
                insert(to_clean, node)
            end
        end
    end
    -- TODO: dry run
    if not isempty(to_clean) then
        local dry_run = self.opts.dry_run
        io.stdout:write(dry_run and "Would delete:" or "Deleting:")
        for _, node in ipairs(to_clean) do
            io.stdout:write(" " .. node.target)
            io.stdout:flush()
            if not dry_run then
                local a, b = os.remove(node.target)
                if not a then
                    io.stdout:write("\n")
                    io.stdout:flush()
                    util.fprintf(io.stderr,
                        "Cannot delete %s: %s\nAborting\n",
                        node.target, b)
                    os.exit(1)
                end
            end
        end
        io.stdout:write("\n")
    else
        print("Nothing to clean.")
    end
end
