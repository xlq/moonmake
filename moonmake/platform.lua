-- Platform detection routines

module(..., package.seeall)

if os.getenv("SYSTEMROOT") then
    platform = "windows"
    pathsep = "\\"
    pathenvsep = ";"
else
    platform = "posix"
    pathsep = "/"
    pathenvsep = ":"
end
