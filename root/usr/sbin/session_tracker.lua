#!/usr/bin/lua

-- ==============================================================================
-- OpenWrt Session Tracker Daemon (Package Integrated Version)
-- ==============================================================================

local uloop = require("uloop")
local ubus  = require("ubus")
local nixio = require("nixio")

local GRACE_PERIOD = 180  -- 防抖宽限期 180 秒
local INTERVAL     = 5000 -- 采样间隔 5 秒
local BRIDGE_NAME  = "br-lan"
local session_db   = {}   -- 纯内存数据库: mac -> { start, last, ip, status, hostname, dev }

-- 动态获取网桥及成员接口 (带多级 Fallback 策略)
local function get_valid_devices(br_name, conn)
    local dev_map = { [br_name] = true }
    local found = false

    -- 策略 1: 扫描 sysfs brif
    local brif_path = "/sys/class/net/" .. br_name .. "/brif"
    local dir = nixio.fs.dir(brif_path)
    if dir then
        for iface in dir do
            dev_map[iface] = true
            found = true
        end
    end

    -- 策略 2: 扫描 net 下带 brport 的接口
    if not found then
        local net_dir = nixio.fs.dir("/sys/class/net")
        if net_dir then
            for iface in net_dir do
                if nixio.fs.stat("/sys/class/net/" .. iface .. "/brport") then
                    dev_map[iface] = true
                    found = true
                end
            end
        end
    end

    -- 策略 3: ubus RPC 回退
    if not found and conn then
        local status = conn:call("network.device", "status", { name = br_name })
        if status and status["bridge-members"] then
            for _, iface in ipairs(status["bridge-members"]) do
                dev_map[iface] = true
                found = true
            end
        end
    end

    -- 策略 4: 正则兜底
    if not found then
        dev_map._fallback_matcher = function(dev)
            if dev == br_name then return true end
            if dev:match("^lan%d*") or dev:match("^rax%d*") or dev:match("^wlan%d*") or dev:match("^eth%d*") then
                return true
            end
            return false
        end
    end

    return dev_map
end

local function is_valid_dev(valid_devs, dev)
    if not dev then return false end
    if valid_devs[dev] then return true end
    if valid_devs._fallback_matcher then
        return valid_devs._fallback_matcher(dev)
    end
    return false
end

local function get_dhcp_hosts()
    local hosts = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            local mac, hostname = line:match("%s+(%S+)%s+%S+%s+(%S+)")
            if mac and hostname and hostname ~= "*" then
                hosts[mac:lower()] = hostname
            end
        end
        f:close()
    end
    return hosts
end

local conn

local function scan_neighbors()
    local now = os.time()
    local active_now = {}
    local dhcp_hosts = get_dhcp_hosts()
    local valid_devs = get_valid_devices(BRIDGE_NAME, conn)

    local f = io.open("/proc/net/arp", "r")
    if f then
        f:read("*line")
        for line in f:lines() do
            local ip, hw_type, flags, mac, mask, dev = line:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            
            if ip and mac and flags and (flags == "0x2" or flags == "0x6") and is_valid_dev(valid_devs, dev) then
                mac = mac:lower()
                if mac ~= "00:00:00:00:00:00" and not ip:find("^169%.254%.") then
                    active_now[mac] = {
                        ip = ip,
                        dev = dev,
                        status = (flags == "0x2") and "REACHABLE" or "DELAY"
                    }
                end
            end
        end
        f:close()
    end

    for mac, data in pairs(session_db) do
        if active_now[mac] then
            data.last = now
            data.ip = active_now[mac].ip
            data.dev = active_now[mac].dev
            data.status = active_now[mac].status
            data.hostname = dhcp_hosts[mac] or "(Static IP)"
            active_now[mac] = nil
        else
            if (now - data.last) > GRACE_PERIOD then
                session_db[mac] = nil
            else
                data.status = "STALE"
            end
        end
    end

    for mac, info in pairs(active_now) do
        session_db[mac] = {
            start = now,
            last = now,
            ip = info.ip,
            dev = info.dev,
            status = info.status,
            hostname = dhcp_hosts[mac] or "(Static IP)"
        }
    end
end

uloop.init()

conn = ubus.connect()
if not conn then
    error("Failed to connect to ubus daemon")
end

local tracker_methods = {
    ["get_terminals"] = {
        function(req, msg)
            local now = os.time()
            local list = {}
            for mac, info in pairs(session_db) do
                table.insert(list, {
                    ip = info.ip,
                    mac = mac,
                    dev = info.dev,
                    status = info.status,
                    hostname = info.hostname,
                    session_time_sec = math.max(0, now - info.start)
                })
            end
            conn:reply(req, { terminals = list, count = #list })
        end,
        {}
    }
}

conn:add({
    ["session.tracker"] = tracker_methods
})

local timer
timer = uloop.timer(function()
    scan_neighbors()
    timer:set(INTERVAL)
end, INTERVAL)

scan_neighbors()
uloop.run()
