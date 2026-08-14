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

## License

[MIT](LICENSE) © Ass-Sniper
