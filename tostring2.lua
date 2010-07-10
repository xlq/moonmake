module(..., package.seeall)

-- Table printing
function tostring2(obj, indent, key, visited)
    indent = indent or 0
    local typ = type(obj)
    local indent_str = string.rep("    ", indent)
    visited = visited or {}
    if typ == "table" and not key then
        if visited[obj] then
            return tostring(obj)
        else
            visited[obj] = true
            str = "{ -- " .. tostring(obj) .. "\n"
            local highest_ikey = 0
            for k,v in ipairs(obj) do
                str = str .. indent_str .. "    " .. tostring2(v, indent + 1, false, visited) .. ",\n"
                highest_ikey = k
            end
            for k,v in pairs(obj) do
                if type(k) == "number"
                  and math.floor(k) == k
                  and k >= 1
                  and k <= highest_ikey
                then
                    -- Already done this item
                else
                    str = str .. indent_str .. "    "
                    if type(k) == "string" and k:match("^[_%a][_%w]*$") then
                        str = str .. k
                    else
                        str = str .. "[" .. tostring2(k, 0, true, visited) .. "]"
                    end
                    str = str .. " = " .. tostring2(v, indent + 1, false, visited) .. ",\n"
                end
            end
            str = str .. indent_str .. "}"
            return str
        end
    elseif typ == "string" then
        return "\"" .. obj:gsub("\"", "\\\"") .. "\""
    else
        return tostring(obj)
    end
end
