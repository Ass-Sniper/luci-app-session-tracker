#!/usr/bin/lua

-- ==============================================================================
-- OpenWrt Session Tracker Daemon (Package Integrated Version)
-- ==============================================================================

local uloop = require("uloop")
local ubus  = require("ubus")
local nixio = require("nixio")

local GRACE_PERIOD = 180  -- 防抖宽限期 180 秒
local INTERVAL     = 5000 -- 采样间隔 5 秒
local PROBE_AFTER  = 60   -- 连续 60 秒未确认后触发邻居探测
local PROBE_PERIOD = 60   -- 同一终端最多每 60 秒探测一次
local BRIDGE_NAME  = "br-lan"
local session_db   = {}   -- 纯内存数据库: mac -> { start, last, ip, status, hostname, dev }
local probe_db     = {}   -- mac -> 最近一次主动探测时间

-- MTK 私有驱动的结构化 STA 表接口由 luci-app-mtk 提供。
-- 作为可选增强加载，缺失时仍可依靠内核邻居状态运行。
local has_mtk_stainfo = pcall(require, "ioctl_helper") and type(c_StaInfo) == "function"

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

local function get_mtk_wireless_stations()
    local stations = {}

    if not has_mtk_stainfo then
        return stations
    end

    local net_dir = nixio.fs.dir("/sys/class/net")
    if not net_dir then
        return stations
    end

    for iface in net_dir do
        -- MTK 私有驱动常见 AP 接口名：ra0、rax0、rai0 及其多 BSSID 接口。
        if iface:match("^ra[%w_.-]*$") then
            local ok, sta_list = pcall(c_StaInfo, iface)
            if ok and type(sta_list) == "table" then
                for _, sta in pairs(sta_list) do
                    if type(sta) == "table" and type(sta.MacAddr) == "string" then
                        local mac = sta.MacAddr:lower()
                        if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
                            stations[mac] = iface
                        end
                    end
                end
            end
        end
    end

    return stations
end

local function get_ipv4_neighbors(valid_devs)
    local neighbors = {}
    local f = io.popen("ip -4 neigh show 2>/dev/null", "r")

    if not f then
        return neighbors
    end

    for line in f:lines() do
        local ip, dev, rest = line:match("^(%S+)%s+dev%s+(%S+)%s+(.+)$")
        local mac = rest and rest:match("lladdr%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
        local state = rest and rest:match("(%u+)%s*$")

        if ip and dev and mac and state and is_valid_dev(valid_devs, dev) and
           not ip:find("^169%.254%.") then
            mac = mac:lower()
            if mac ~= "00:00:00:00:00:00" then
                neighbors[mac] = {
                    ip = ip,
                    dev = dev,
                    state = state
                }
            end
        end
    end

    f:close()
    return neighbors
end

local function is_confirmed_neighbor(state)
    return state == "REACHABLE" or state == "PERMANENT" or state == "NOARP"
end

local function trigger_neighbor_probe(mac, neighbor, now)
    local last_probe = probe_db[mac] or 0

    if now - last_probe < PROBE_PERIOD then
        return
    end

    -- ip/dev 均来自内核邻居表，仍限制字符集，避免拼接 shell 命令时产生歧义。
    if not neighbor.ip:match("^%d+%.%d+%.%d+%.%d+$") or
       not neighbor.dev:match("^[%w_.:-]+$") then
        return
    end

    probe_db[mac] = now

    -- 不以 ICMP 返回码直接判活。发送数据会触发内核 ARP/NUD；后续扫描只在
    -- 邻居状态真正恢复为 REACHABLE 后刷新 session.last。
    os.execute(string.format(
        "ping -c 1 -W 1 -I %s %s >/dev/null 2>&1 &",
        neighbor.dev, neighbor.ip
    ))
end

local function scan_neighbors()
    local now = os.time()
    local dhcp_hosts = get_dhcp_hosts()
    local valid_devs = get_valid_devices(BRIDGE_NAME, conn)
    local wireless_stations = get_mtk_wireless_stations()
    local neighbors = get_ipv4_neighbors(valid_devs)

    for mac, data in pairs(session_db) do
        local neighbor = neighbors[mac]

        if neighbor and is_confirmed_neighbor(neighbor.state) then
            data.last = now
            data.ip = neighbor.ip
            data.dev = neighbor.dev
            data.status = "REACHABLE"
            data.hostname = dhcp_hosts[mac] or "(Static IP)"
            data.wireless_iface = wireless_stations[mac]
            probe_db[mac] = nil
        else
            if neighbor then
                data.ip = neighbor.ip
                data.dev = neighbor.dev
                data.hostname = dhcp_hosts[mac] or data.hostname or "(Static IP)"
            end
            data.wireless_iface = wireless_stations[mac]

            if (now - data.last) > GRACE_PERIOD then
                session_db[mac] = nil
                probe_db[mac] = nil
            else
                data.status = "STALE"
                if neighbor and (now - data.last) >= PROBE_AFTER then
                    trigger_neighbor_probe(mac, neighbor, now)
                end
            end
        end
    end

    for mac, neighbor in pairs(neighbors) do
        if not session_db[mac] then
            if is_confirmed_neighbor(neighbor.state) then
                session_db[mac] = {
                    start = now,
                    last = now,
                    ip = neighbor.ip,
                    dev = neighbor.dev,
                    status = "REACHABLE",
                    hostname = dhcp_hosts[mac] or "(Static IP)",
                    wireless_iface = wireless_stations[mac]
                }
            elseif wireless_stations[mac] then
                -- 守护进程刚启动时，已关联终端可能只有 STALE 邻居项；先探测，
                -- 待内核确认 REACHABLE 后再创建会话，避免把驱动残留表项算在线。
                trigger_neighbor_probe(mac, neighbor, now)
            end
        end
    end

    for mac, probed_at in pairs(probe_db) do
        if not neighbors[mac] and now - probed_at > GRACE_PERIOD then
            probe_db[mac] = nil
        end
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
