module(..., package.seeall)

atexit_table = {}

function atexit_cleanup()
    --print("Running atexit handlers...")
    for i = #atexit_table,1,-1 do
        atexit_table[i]()
    end
    atexit_table = {}
end

gcobj = newproxy(true)
getmetatable(gcobj).__gc = atexit_cleanup

-- Look away now. This is pretty gross.
-- Inspired by Tcl!
os.real_exit = os.exit
function os.exit(...)
    atexit_cleanup()
    return os.real_exit(...)
end

function atexit(f)
    atexit_table[#atexit_table + 1] = f
end
