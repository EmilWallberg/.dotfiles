Name = "rdp"
NamePretty = "Remote Desktop"
Description = "LiU Remote Hosts"
Icon = "🖥️"
Cache = false 

local hosts_file = os.getenv("HOME") .. "/.rdp_hosts"

function GetEntries()
    local entries = {}
    local f = io.open(hosts_file, "r")
    
    if not f then 
        return {{ Text = "Error", Subtext = "File not found" }}
    end

    for line in f:lines() do
        if not line:match("^#") and line:match("%|") then
            local name, ip, user, account = line:match("([^|]+)%|([^|]+)%|([^|]+)%|([^|]+)")
            
            if name then
                name = name:gsub("^%s*(.-)%s*$", "%1")
                ip = ip:gsub("^%s*(.-)%s*$", "%1")
                user = user:gsub("^%s*(.-)%s*$", "%1")
                account = account:gsub("^%s*(.-)%s*$", "%1")

                local rdp_bin = "/usr/bin/xfreerdp3"
                local pass_bin = "/usr/sbin/pass"

                local cmd = string.format(
                    "{ " ..
                    "P=$(%s show rdp/%s 2>/dev/null); " ..
                    "printf \"/u:%s\\n/p:$P\\n/v:%s\\n/cert:ignore\\n/dynamic-resolution\\n/floatbar\\n/clipboard\\n" ..
                    "/gfx:avc444\\n/gfx-h264:avc444\\n/network:lan\\n/gdi:hw\\n/video\\n\" | %s /args-from:stdin & " ..
                    "} >> /tmp/rdp_final.log 2>&1 &",
                    pass_bin, account, user, ip, rdp_bin
                )

                table.insert(entries, {
                    Text = name,
                    Subtext = ip,
                    Icon = "🖥️",
                    Actions = {
                        default = cmd
                    }
                })
            end
        end
    end
    f:close()
    return entries
end
