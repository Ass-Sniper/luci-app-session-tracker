# luci-app-session-tracker

OpenWrt / ImmortalWrt 高性能终端会话追踪微服务及 LuCI 控制台界面。

## 特性

* **低资源占用**：纯内存数据结构与事件驱动，无外部数据库依赖。
* **智能防抖**：内置 180s 会话宽限期，兼容短连接与移动设备省电模式。
* **LuCI 原生集成**：基于 Client-Side Rendering (JS) 编写，支持 5s 实时自动刷新。

## 编译指南

### 方法一：直接 Clone 到源码包目录（推荐，适合 GitHub Actions 及本地快速编译）

进入你的 OpenWrt / ImmortalWrt 源码根目录：

```bash
# 1. 克隆本项目到 package/emortal 或 package/ 目录下
git clone [https://github.com/Ass-Sniper/luci-app-session-tracker.git](https://github.com/Ass-Sniper/luci-app-session-tracker.git) package/emortal/luci-app-session-tracker

# 2. 更新配置并选中插件
make menuconfig
# 依次进入: LuCI ---> 3. Applications ---> 勾选 <*> luci-app-session-tracker

# 3. 独立编译插件
make package/emortal/luci-app-session-tracker/compile V=s
```

### 方法二：通过 `feeds.conf` 引入

在你的固件源码根目录 `feeds.conf.default` 文件末尾加入：

```ini
src-git session_tracker [https://github.com/Ass-Sniper/luci-app-session-tracker.git](https://github.com/Ass-Sniper/luci-app-session-tracker.git)
```

然后执行更新与安装：

```bash
./scripts/feeds update session_tracker
./scripts/feeds install -a -p session_tracker
make menuconfig # 选中 luci-app-session-tracker 后编译
```

## API & 命令行交互 (ubus)

守护进程在后台运行后，会在系统的 `ubus` 总线上注册 `session.tracker` 服务。可以通过以下命令直接获取当前的在线终端与会话时长：

```bash
ubus call session.tracker get_terminals

```

**返回示例：**

```json
{
	"terminals": [
		{
			"mac": "70:4d:7b:64:3b:dd",
			"hostname": "(Static IP)",
			"status": "REACHABLE",
			"session_time_sec": 20,
			"dev": "br-lan",
			"ip": "192.168.16.120"
		},
		{
			"mac": "00:0c:29:7d:06:55",
			"hostname": "kay-vm",
			"status": "REACHABLE",
			"session_time_sec": 20,
			"dev": "br-lan",
			"ip": "192.168.16.118"
		}
	],
	"count": 2
}

```


---

## 依赖说明 (Dependencies)

本项目依赖以下 OpenWrt 基础组件（编译或通过 opkg 安装时系统会自动拉取与集成）：
* `lua`
* `libubox-lua`
* `lua-ubus`
* `nixio`
* `luci-base`

## License

[MIT](LICENSE) © Ass-Sniper
