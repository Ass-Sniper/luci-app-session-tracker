# Session Tracker 项目整体技术方案

## 1. 文档信息

| 项目 | 内容 |
|---|---|
| 项目名称 | `luci-app-session-tracker` |
| 当前基线版本 | `1.0.0-3` |
| 目标系统 | ImmortalWrt/OpenWrt |
| 前端框架 | LuCI JavaScript View |
| 后端实现 | Lua + uloop + ubus + nixio |
| 文档范围 | 总体架构、后端、前端、判活、API、权限、国际化、构建、测试和演进 |

## 2. 项目目标

本项目为 ImmortalWrt/OpenWrt 提供轻量级局域网终端会话跟踪能力：

- 自动发现 LAN 中近期可达的 IPv4 终端。
- 以 MAC 地址作为终端会话主键。
- 记录终端本次会话开始时间和在线时长。
- 展示 IP、MAC、主机名、接口、状态和在线时长。
- 对短暂休眠、丢包和无线漫游提供宽限期。
- 通过 ubus 提供结构化查询接口。
- 通过 LuCI 页面每 5 秒局部刷新。
- 支持 LuCI 标准中文语言包。
- 对 MTK 私有 Wi-Fi 驱动提供可选增强。

项目定位是“小型、无数据库、低资源占用的当前状态跟踪器”，不是完整的流量审计或历史会话数据库。

## 3. 设计原则

### 3.1 明确确认后才续期

ARP 缓存、无线 STA 表或 `STALE` 邻居项存在，都不能单独证明终端在线。只有内核明确确认邻居可达时才刷新会话最后确认时间。

### 3.2 被动观察与有限主动验证结合

平时读取内核邻居状态；状态不明确时，经过阈值和限频控制后主动触发一次 ARP/NUD 验证。

### 3.3 软依赖厂商能力

MTK `ioctl_helper` 是可选增强，不应成为守护进程启动的硬条件。非 MTK 或未安装相关模块的系统仍应正常工作。

### 3.4 内存状态与事件循环

不引入数据库，使用 Lua 内存表保存当前会话，通过 `uloop.timer` 周期扫描，降低部署和维护复杂度。

### 3.5 遵循 LuCI 标准工程结构

静态资源使用 `htdocs/`，设备文件使用 `root/`，翻译使用 `po/`，构建统一交给 `luci.mk`。

## 4. 功能边界

### 4.1 已覆盖

- IPv4 LAN 终端发现。
- 动态和静态 IPv4 主机。
- 有线终端。
- MTK 私有驱动无线终端辅助识别。
- 当前内存会话及在线时长。
- 活跃与宽限期状态。
- ubus 只读查询。
- LuCI 实时页面。
- 简体中文国际化。

### 4.2 未覆盖

- IPv6 NDP 会话跟踪。
- 历史会话持久化。
- 流量、速率和应用层行为统计。
- 用户身份认证和设备归属管理。
- 精确的上下线审计时间。
- 跨服务或设备重启保持会话开始时间。
- 所有厂商 Wi-Fi 驱动的关联事件适配。

## 5. 仓库结构

```text
luci-app-session-tracker/
├── Makefile
├── README.md
├── docs/
│   └── session-tracker-technical-design.md
├── htdocs/
│   └── luci-static/resources/view/status/
│       └── session_tracker.js
├── po/
│   └── zh_Hans/
│       └── session-tracker.po
└── root/
    ├── etc/init.d/
    │   └── session_tracker
    └── usr/
        ├── sbin/
        │   └── session_tracker.lua
        └── share/
            ├── luci/menu.d/
            │   └── luci-app-session-tracker.json
            └── rpcd/acl.d/
                └── luci-app-session-tracker.json
```

## 6. 总体架构

```text
 ┌────────────────────── 数据源层 ──────────────────────┐
 │                                                     │
 │  /tmp/dhcp.leases       ip -4 neigh show            │
 │  MAC → hostname         IP/MAC/dev/NUD state        │
 │          │                       │                  │
 │          │            c_StaInfo(ra*)（可选）         │
 │          │            MTK wireless MAC/interface    │
 └──────────┼───────────────────────┼──────────────────┘
            │                       │
            ▼                       ▼
 ┌────────────────── 守护进程层 ────────────────────────┐
 │  session_tracker.lua                                │
 │                                                     │
 │  设备接口发现 → 邻居采集 → 组合判定 → 主动探测       │
 │                           │                         │
 │                    session_db / probe_db            │
 │                           │                         │
 │                    ubus session.tracker             │
 └───────────────────────────┼─────────────────────────┘
                             │ get_terminals
                             ▼
 ┌────────────────── LuCI 展示层 ───────────────────────┐
 │ rpc.declare → 首次加载 → 生成表格 → poll 5 秒刷新    │
 │                                                     │
 │ IP / MAC / Hostname / Interface / Status / Duration │
 └─────────────────────────────────────────────────────┘
```

## 7. 组件说明

| 组件 | 职责 |
|---|---|
| `session_tracker.lua` | 采集邻居和无线信息、维护会话状态、注册 ubus 服务 |
| init 脚本 | 使用 procd 启动、守护和重启 Lua 服务 |
| ACL JSON | 允许 LuCI 会话只读调用 `get_terminals` |
| 菜单 JSON | 在“状态”菜单注册终端会话页面 |
| `session_tracker.js` | 调用 ubus、渲染表格、格式化状态与时长、周期刷新 |
| PO 文件 | 保存插件中文翻译源码 |
| `luci.mk` | 生成主包、语言包、LMO 并安装静态资源 |

## 8. 后端运行模型

### 8.1 启动流程

```text
procd 启动 /usr/bin/lua /usr/sbin/session_tracker.lua
  → 加载 uloop、ubus、nixio
  → 可选加载 ioctl_helper
  → 初始化 uloop
  → 连接 ubus
  → 注册 session.tracker 对象
  → 创建 5 秒周期定时器
  → 立即执行首次扫描
  → 进入 uloop.run()
```

### 8.2 procd 管理

init 脚本启用：

```sh
USE_PROCD=1
```

并配置自动拉起：

```sh
procd_set_param respawn 3600 5 5
```

守护进程异常退出后由 procd 管理恢复，不在 Lua 内部实现自守护。

### 8.3 单线程事件循环

程序基于 uloop 单线程运行：

- ubus 请求回调读取内存状态。
- 定时器每 5 秒执行一次扫描。
- 主动 ping 使用后台进程，避免阻塞事件循环。

因此扫描函数不得执行长时间同步等待。

## 9. 核心数据结构

### 9.1 会话数据库

```lua
session_db[mac] = {
    start = now,
    last = now,
    ip = neighbor.ip,
    dev = neighbor.dev,
    status = "REACHABLE",
    hostname = hostname,
    wireless_iface = wireless_stations[mac]
}
```

| 字段 | 说明 |
|---|---|
| `start` | 本次内存会话开始时间 |
| `last` | 最后一次明确确认可达的时间 |
| `ip` | 当前 IPv4 地址 |
| `dev` | 邻居表中的三层设备，通常为 `br-lan` |
| `status` | `REACHABLE` 或 `STALE` |
| `hostname` | DHCP 主机名或 `(Static IP)` |
| `wireless_iface` | MTK 无线接口；无法识别或有线终端为空 |

MAC 地址统一转为小写并作为主键，避免 IP 变化导致会话被拆分。

### 9.2 探测限频数据库

```lua
probe_db[mac] = last_probe_timestamp
```

探测控制状态与业务会话分开存放，不通过 ubus 暴露。

### 9.3 单次扫描快照

```lua
neighbors[mac] = {
    ip = ip,
    dev = dev,
    state = nud_state
}

wireless_stations[mac] = wireless_interface
dhcp_hosts[mac] = hostname
```

每轮扫描先构建快照，再统一更新会话，避免在读取外部数据时反复修改共享状态。

## 10. LAN 接口发现

默认桥设备：

```lua
local BRIDGE_NAME = "br-lan"
```

有效设备集合按以下优先级获取：

1. `/sys/class/net/br-lan/brif` 中的桥成员。
2. `/sys/class/net/*/brport` 中的桥端口。
3. `ubus network.device status` 返回的 `bridge-members`。
4. 接口名规则回退：`lan*`、`rax*`、`wlan*`、`eth*`。

`br-lan` 自身始终包含在集合中。邻居记录只有属于有效设备才进入跟踪，避免把 WAN 侧邻居纳入 LAN 会话。

## 11. DHCP 主机名解析

读取：

```text
/tmp/dhcp.leases
```

建立小写 MAC 到主机名的映射。租约中主机名为 `*` 或不存在时不记录；页面最终回退为：

```text
(Static IP)
```

当前解析只使用主机名，不把 DHCP 剩余租期作为在线依据。

## 12. IPv4 邻居采集

### 12.1 数据来源

```sh
ip -4 neigh show
```

示例：

```text
192.168.16.120 dev br-lan lladdr 70:4d:7b:64:3b:da REACHABLE
192.168.16.183 dev br-lan lladdr 02:67:70:44:a3:01 STALE
192.168.16.119 dev br-lan FAILED
```

只接受同时具备以下字段的记录：

- IPv4 地址。
- 设备名。
- MAC 地址。
- 大写 NUD 状态。
- 设备属于有效 LAN 集合。

过滤：

- `00:00:00:00:00:00`。
- `169.254.0.0/16` 链路本地地址。
- 不带 MAC 的 `FAILED/INCOMPLETE` 条目。

### 12.2 为什么不使用 `/proc/net/arp`

`/proc/net/arp` 的完成标志只说明缓存项具备地址映射，不能表达 NUD 的 `REACHABLE/STALE/PROBE/FAILED` 状态。终端断开后缓存仍可能保留，从而无限刷新会话。

## 13. MTK 私有 Wi-Fi 集成

### 13.1 结构化接口

MTK `luci-app-mtk` 提供：

```text
/usr/lib/lua/ioctl_helper.so
```

加载后注册：

```lua
c_StaInfo(ifname)
```

该函数使用 `RTPRIV_IOCTL_GET_MAC_TABLE_STRUCT`，直接返回 Lua 表，不需要解析 `iwpriv ... show stainfo` 输出的内核日志。

### 13.2 可选加载

```lua
local has_mtk_stainfo =
    pcall(require, "ioctl_helper") and
    type(c_StaInfo) == "function"
```

模块不存在时自动退回 `ip neigh + 主动探测`，因此没有将 `luci-app-mtk` 设置为硬依赖。

### 13.3 无线接口发现

遍历 `/sys/class/net`，对匹配以下规则的接口调用 `c_StaInfo()`：

```text
^ra[%w_.-]*$
```

覆盖常见接口：

- `ra0`
- `rax0`
- `rai0`
- MTK 多 BSSID 派生接口

每次私有 ioctl 使用 `pcall()` 隔离错误，单接口失败不影响扫描。

### 13.4 STA 表的使用边界

STA 表只用于：

- 标记无线终端 MAC。
- 记录无线接口。
- 服务启动时对无线 `STALE` 条目触发验证。

STA 表存在不能直接刷新会话。终端异常离开后驱动可能继续保留 STA 条目；实际测试曾观察到 `Idle` 数百秒但条目仍存在。

## 14. 终端在线组合判定

### 14.1 参数

```lua
local GRACE_PERIOD = 180
local INTERVAL     = 5000
local PROBE_AFTER  = 60
local PROBE_PERIOD = 60
```

| 参数 | 默认值 | 作用 |
|---|---:|---|
| `INTERVAL` | 5 秒 | 全量扫描周期 |
| `PROBE_AFTER` | 60 秒 | 未确认达到该时间后允许主动探测 |
| `PROBE_PERIOD` | 60 秒 | 同一 MAC 两次探测的最小间隔 |
| `GRACE_PERIOD` | 180 秒 | 最后确认后保留会话的时间 |

### 14.2 确认在线状态

只有以下邻居状态允许刷新 `last`：

```text
REACHABLE
PERMANENT
NOARP
```

### 14.3 未确认状态

以下状态不刷新 `last`：

```text
STALE
DELAY
PROBE
FAILED
INCOMPLETE
```

- `STALE`：缓存存在但近期没有可达确认。
- `DELAY/PROBE`：内核正在验证，不代表成功。
- `FAILED/INCOMPLETE`：邻居解析失败或尚未完成。

### 14.4 状态机

```text
                     明确确认可达
              ┌─────────────────────────┐
              ▼                         │
        ┌────────────┐                   │
 新设备 │ REACHABLE  │                   │
 ─────→ │ 活跃       │                   │
        └─────┬──────┘                   │
              │ 未确认状态               │
              ▼                         │
        ┌────────────┐   探测后恢复可达   │
        │ STALE      │ ──────────────────┘
        │ 宽限期     │
        └─────┬──────┘
              │ now - last > 180s
              ▼
        ┌────────────┐
        │ REMOVED    │
        └────────────┘
```

### 14.5 新会话创建

仅在邻居状态确认在线时创建会话。

服务重启后，如果无线 STA 表中存在 MAC，但邻居状态只有 `STALE`：

1. 不立即创建活跃会话。
2. 触发一次限频探测。
3. 后续扫描恢复 `REACHABLE` 后再创建。

这可以避免驱动残留 STA 表项在服务启动时直接造成误报。

### 14.6 活跃会话刷新

邻居明确可达时：

```lua
data.last = now
data.status = "REACHABLE"
```

同时更新 IP、设备、主机名和无线接口，并清除对应 `probe_db` 记录。

### 14.7 宽限期

邻居不存在或状态未确认时：

```lua
data.status = "STALE"
```

但不更新 `last`。页面显示“暂时离线（宽限期）”。终端在 180 秒内重新得到确认会恢复活跃，不会创建新的会话。

### 14.8 会话删除

```lua
if now - data.last > GRACE_PERIOD then
    session_db[mac] = nil
    probe_db[mac] = nil
end
```

删除后终端不再出现在 ubus 和页面中。以后重新可达时创建新会话并重置 `start`。

## 15. 主动邻居探测

### 15.1 目的

`STALE` 既可能表示在线但休眠，也可能表示已经离线且缓存尚未老化。主动发送一个数据包可促使内核执行 ARP/NUD 验证。

### 15.2 触发条件

已有会话满足以下条件时探测：

```text
邻居记录存在并带 MAC
且状态未确认可达
且 now - session.last ≥ PROBE_AFTER
且 now - last_probe ≥ PROBE_PERIOD
```

无线 STA 表存在、服务刚启动且邻居为未确认状态时，也允许触发首次验证。

### 15.3 命令

```sh
ping -c 1 -W 1 -I <device> <IPv4> >/dev/null 2>&1 &
```

不直接使用 ping 退出码更新会话。后续扫描只有看到内核邻居状态恢复为确认在线状态时才续期。

### 15.4 限频

每个 MAC 最多每 60 秒探测一次。默认 180 秒宽限期内通常最多发起约三次验证，避免：

- 每 5 秒创建 ping 进程。
- 频繁唤醒省电无线终端。
- 大量无效 ARP/ICMP 流量。

### 15.5 命令安全

虽然 IP 和接口来自内核邻居表，仍在拼接命令前执行白名单校验：

```lua
neighbor.ip:match("^%d+%.%d+%.%d+%.%d+$")
neighbor.dev:match("^[%w_.:-]+$")
```

任何来自 ubus 或前端的值都不得直接用于探测命令。

## 16. 扫描流程

每 5 秒执行：

```text
1. 读取当前时间
2. 读取 DHCP 主机名映射
3. 计算有效 LAN 设备集合
4. 可选读取所有 MTK ra* STA 表
5. 读取并解析 IPv4 邻居表
6. 遍历已有 session_db
   ├─ 明确可达：刷新会话
   └─ 未确认：进入宽限期、按需探测或删除
7. 遍历未建会话邻居
   ├─ 明确可达：创建会话
   └─ 无线且未确认：先探测，不创建活跃会话
8. 清理失去邻居且超时的 probe_db 记录
```

## 17. ubus API

### 17.1 对象和方法

```text
对象：session.tracker
方法：get_terminals
参数：无
```

调用：

```sh
ubus call session.tracker get_terminals
```

### 17.2 返回结构

```json
{
  "terminals": [
    {
      "ip": "192.168.16.183",
      "mac": "02:67:70:44:a3:01",
      "dev": "br-lan",
      "status": "STALE",
      "hostname": "MIA-AL00",
      "session_time_sec": 120
    }
  ],
  "count": 1
}
```

| 字段 | 类型 | 含义 |
|---|---|---|
| `terminals` | array | 当前活跃或宽限期终端 |
| `count` | integer | 终端数量 |
| `ip` | string | IPv4 地址 |
| `mac` | string | 小写 MAC 地址 |
| `dev` | string | 邻居设备 |
| `status` | string | `REACHABLE` 或 `STALE` |
| `hostname` | string | DHCP 主机名或静态地址占位 |
| `session_time_sec` | integer | `now - start`，最小为 0 |

### 17.3 一致性

ubus 回调只遍历 Lua 内存表，不读取外部命令，因此响应快速。当前实现没有定义排序顺序；前端展示顺序由 Lua `pairs()` 结果决定。

## 18. rpcd ACL

ACL 只开放：

```json
{
  "session.tracker": [ "get_terminals" ]
}
```

该 API 不接受参数、不修改配置，不授予守护进程控制能力。LuCI 页面依赖 `luci-app-session-tracker` ACL 才可显示菜单并调用接口。

## 19. LuCI 菜单

菜单节点：

```text
admin/status/session_tracker
```

配置：

- 标题：`Terminal Sessions`
- 顺序：`50`
- 动作：加载 `status/session_tracker` JS View
- ACL：`luci-app-session-tracker`
- 翻译域：`session-tracker`

页面位于 LuCI 的“状态”分类下。

## 20. LuCI 前端设计

### 20.1 RPC 声明

```javascript
var callGetTerminals = rpc.declare({
    object: 'session.tracker',
    method: 'get_terminals',
    expect: { '': {} }
});
```

### 20.2 首次加载

View 的 `load()` 调用 ubus，在 `render(data)` 前获取第一份终端数据，避免初次页面为空后再闪烁填充。

### 20.3 表格字段

```text
IP 地址
MAC 地址
主机名
接口
状态
在线时长
```

MAC 使用 `<code>` 样式展示；缺失值统一回退为 `-`。

### 20.4 状态展示

| 后端值 | 前端文本 | 样式 |
|---|---|---|
| `REACHABLE` | 活跃 | `badge label success` |
| `STALE` | 暂时离线（宽限期） | `badge label warning` |
| 其他 | 原状态或未知 | 普通 badge |

### 20.5 局部轮询

```javascript
poll.add(function() {
    return callGetTerminals().then(function(newData) {
        renderTableRows(newData);
    });
}, 5);
```

轮询只删除并重建数据行，保留表头和页面结构，不进行整页刷新。

### 20.6 空状态

终端数组为空时显示跨 6 列占位行：

```text
未发现活跃终端。
```

### 20.7 在线时长格式化

后端返回秒数，前端按非零单位组合：

```text
2 天 3 小时 4 分钟 5 秒
```

格式词条使用完整可翻译字符串：

```javascript
_('%d min').format(minutes)
```

宽限期内在线时长仍从 `start` 计算，表示当前会话持续时间，不是最后活动时间。

## 21. 国际化方案

### 21.1 标准流程

```text
JS/菜单 msgid
  → po/zh_Hans/session-tracker.po
  → po2lmo
  → session-tracker.zh-cn.lmo
  → LuCI /admin/translations/zh-cn
  → window.TR
  → 浏览器 _()
```

不使用手写原文映射 JSON 作为翻译目录。

### 21.2 语言包

构建生成：

```text
luci-i18n-session-tracker-zh-cn_<version>_all.ipk
```

内部包含：

```text
/usr/lib/lua/luci/i18n/session-tracker.zh-cn.lmo
```

### 21.3 词条要求

- `_()` 参数优先使用静态字面量。
- PO `msgid` 必须与 JS/菜单完全一致。
- 格式单位使用 `%d` 完整词条。
- `_()` 第二参数是上下文，不是翻译域或复数说明。
- 动态状态应显式映射，避免提取工具漏词。

## 22. 构建与打包

### 22.1 Makefile

项目使用：

```make
include $(TOPDIR)/feeds/luci/luci.mk
```

由 `luci.mk` 负责：

- 定义主包。
- 将 `htdocs/` 安装到 `/www/`。
- 将 `root/` 安装到设备根目录。
- 压缩 JavaScript。
- 将 PO 编译为 LMO。
- 生成独立语言包。

### 22.2 依赖

主包依赖：

```text
lua
libubox-lua
libubus-lua
luci-lib-nixio
```

`ioctl_helper` 是可选运行时增强，没有设置硬依赖。

### 22.3 版本

当前固定版本：

```make
PKG_VERSION:=1.0.0-3
PKG_PO_VERSION:=$(PKG_VERSION)
```

显式设置 `PKG_PO_VERSION`，避免第三方目录或嵌套 Git 仓库导致语言包版本为 `unknown`。

### 22.4 编译

```sh
make defconfig
make package/emortal/luci-app-session-tracker/clean
make package/emortal/luci-app-session-tracker/compile V=s
```

临时显式启用中文语言包：

```sh
make package/emortal/luci-app-session-tracker/compile V=s \
  CONFIG_PACKAGE_luci-i18n-session-tracker-zh-cn=y
```

### 22.5 产物

```text
luci-app-session-tracker_1.0.0-3_all.ipk
luci-i18n-session-tracker-zh-cn_1.0.0-3_all.ipk
```

主包关键文件：

```text
/etc/init.d/session_tracker
/usr/sbin/session_tracker.lua
/usr/share/luci/menu.d/luci-app-session-tracker.json
/usr/share/rpcd/acl.d/luci-app-session-tracker.json
/www/luci-static/resources/view/status/session_tracker.js
```

## 23. 安装与升级

安装或覆盖升级：

```sh
opkg install --force-reinstall luci-app-session-tracker_1.0.0-3_all.ipk
opkg install --force-reinstall luci-i18n-session-tracker-zh-cn_1.0.0-3_all.ipk
```

重启服务：

```sh
/etc/init.d/session_tracker restart
```

必要时清理 LuCI 缓存：

```sh
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd restart
```

然后浏览器强制刷新。

## 24. 性能与资源占用

每 5 秒执行：

- 读取一次 DHCP 租约。
- 执行一次 `ip -4 neigh show`。
- 对匹配的 MTK `ra*` 接口各执行一次结构化 ioctl。
- 线性遍历邻居、会话和 STA 集合。

近似复杂度：

```text
O(N_neighbor + N_session + N_sta)
```

主动探测按 MAC 每 60 秒最多一次，并在后台运行。对于家庭和小型办公网络，集合规模通常较小，整体开销可控。

当前最主要的外部进程开销是周期执行 `ip` 和按需执行 `ping`。

## 25. 安全设计

### 25.1 最小权限 API

LuCI 用户仅获得 `get_terminals` 只读权限，没有配置写入和命令执行入口。

### 25.2 输入边界

- 邻居字段来自内核命令输出。
- STA 字段来自驱动 ioctl。
- DHCP 主机名仅作为页面文本。
- ubus 方法不接受调用者参数。

### 25.3 命令拼接

主动探测前严格验证 IP 和接口格式。未来如果引入可配置接口或地址，必须继续使用白名单或避免 shell 拼接。

### 25.4 故障隔离

- 模块加载使用 `pcall()`。
- 每个 MTK 接口查询使用 `pcall()`。
- 探测结果不直接改变会话。
- 外部数据源失败时按宽限期保守退化。

## 26. 可观测性与诊断

检查服务：

```sh
pgrep -af session_tracker
/etc/init.d/session_tracker status
```

检查 ubus：

```sh
ubus list session.tracker -v
ubus call session.tracker get_terminals
```

检查邻居：

```sh
ip -4 neigh show
```

检查 MTK STA：

```sh
iwpriv ra0 show stainfo
iwpriv rax0 show stainfo
```

检查日志：

```sh
logread -e session_tracker
```

注意：`iwpriv ... show stainfo` 可能通过内核日志输出，不适合作为守护进程文本输入；运行时使用的是结构化 `c_StaInfo()`。

## 27. 测试方案

### 27.1 静态检查

```sh
lua -e 'assert(loadfile("root/usr/sbin/session_tracker.lua"))'
git diff --check
```

### 27.2 构建测试

```sh
make package/emortal/luci-app-session-tracker/clean
make package/emortal/luci-app-session-tracker/compile \
  CONFIG_PACKAGE_luci-i18n-session-tracker-zh-cn=y
```

验收：

- 主包和语言包均生成。
- 版本一致且不是 `unknown`。
- 主包包含守护进程、菜单、ACL 和 JS。
- 语言包包含 `session-tracker.zh-cn.lmo`。

### 27.3 正常在线

1. 终端连接 LAN 并产生流量。
2. 邻居状态为 `REACHABLE`。
3. ubus 和页面显示“活跃”。
4. 在线时长持续增长。

### 27.4 无线正常断开

1. 手机关闭 Wi-Fi 或离开覆盖范围。
2. 邻居转为未确认状态。
3. 页面显示“暂时离线（宽限期）”。
4. 主动验证不能恢复 `REACHABLE`。
5. 最后确认超过 180 秒后终端消失。

### 27.5 无线休眠但仍连接

1. 手机保持 Wi-Fi 连接并锁屏。
2. 邻居进入 `STALE`。
3. 达到阈值后触发主动探测。
4. 二层验证成功后恢复 `REACHABLE`。
5. 原会话继续，不重置 `start`。

### 27.6 服务重启与残留 STA

1. 准备 STA 表存在但邻居仅为 `STALE` 的终端。
2. 重启服务。
3. 不应立即显示活跃。
4. 只有探测后恢复可达才创建会话。

### 27.7 无 MTK 模块

1. 移除或禁用 `ioctl_helper`。
2. 确认服务正常启动。
3. 验证 `ip neigh + 主动探测` 路径仍能工作。

### 27.8 多终端回归

验证：

- 有线与无线同时存在。
- 多个 `ra*` 接口。
- DHCP 和静态 IP。
- IP 变化但 MAC 不变。
- `FAILED` 条目没有 MAC。
- 169.254/16 地址被过滤。
- 页面 5 秒轮询无重复行。
- 空列表占位正确。
- 中文标题、状态和时长单位正确。

## 28. 已知限制

1. 仅支持 IPv4。
2. 会话仅驻留内存，服务重启会丢失。
3. 当前 `c_StaInfo()` 没有暴露驱动的 `Idle` 字段。
4. 驱动 STA 表可能保留异常离线条目。
5. 主动探测会产生少量网络流量并可能唤醒省电终端。
6. 某些网络策略可能使实际在线终端无法恢复 `REACHABLE`。
7. 后台探测依赖系统存在兼容的 `ping` 命令。
8. `ip neigh` 通过外部进程获取，不是原生 netlink。
9. ubus 返回终端顺序不固定。
10. 在线时长不是最后活动时长，宽限期内仍继续增长。

## 29. 后续演进

### 29.1 配置化

增加 UCI 配置：

- LAN 桥名称。
- 扫描周期。
- 宽限期。
- 探测开始阈值和限频间隔。
- 是否启用主动探测。
- 需要扫描的无线接口。

### 29.2 原生 netlink

通过 netlink 读取邻居事件和状态，替代每 5 秒执行 `ip`：

- 降低进程创建开销。
- 获得更实时的状态变化。
- 支持 IPv6 NDP。

### 29.3 非 shell 主动探测

使用 nixio UDP socket 触发邻居解析，替代后台 ping，进一步降低 shell 和进程管理风险。

### 29.4 MTK 数据增强

扩展 `ioctl_helper` 暴露：

- `NoDataIdleCount`。
- 关联时间。
- 最近收发字节或数据包计数。
- 明确的关联状态。

结合计数变化可减少主动探测。

### 29.5 事件驱动 Wi-Fi

监听厂商无线关联、解除关联和 station timeout 事件，作为 STA 表轮询的补充。

### 29.6 历史与指标

- 持久化上下线历史。
- 区分会话时长、最后确认时间、最后业务活动时间。
- 增加 Prometheus/ubus 指标。
- 页面支持排序、过滤和设备备注。

## 30. 关键设计结论

项目采用以下组合模型：

```text
DHCP 租约提供名称
    +
MTK STA 表辅助识别无线终端
    +
Linux NUD 状态提供明确可达确认
    +
限频主动探测解决 STALE 歧义
    +
180 秒宽限期抑制短暂抖动
    +
ubus + LuCI 提供只读实时展示
```

核心原则：

> 只有得到明确的邻居可达确认才刷新会话；缓存存在、STA 表存在或探测正在进行，都不能无限延长在线时间。

这一原则解决了终端断开后因 ARP 或驱动 STA 缓存残留而长期误报活跃的问题，同时保留了休眠终端重新确认并恢复活跃的机会。
