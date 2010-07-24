module(..., package.seeall)

local atexit_table = {}

local function atexit_cleanup()
    --print("Running atexit handlers...")
    for i = #atexit_table,1,-1 do
        atexit_table[i]()
    end
    atexit_table = {}
end

-- atexit handlers are run when this object gets GCed
gcobj = newproxy(true)
getmetatable(gcobj).__gc = atexit_cleanup

-- Hook os.exit
-- Look away now. This is pretty gross.
-- Inspired by Tcl!
local real_os_exit = os.exit
function os.exit(...)
    atexit_cleanup()
    return real_os_exit(...)
end

-- Call this to register your atexit function
function atexit(f)
    atexit_table[#atexit_table + 1] = f
end
