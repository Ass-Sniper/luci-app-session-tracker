include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-session-tracker
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Kay <kay@example.com>
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for Native Session Tracker
  DEPENDS:=+lua +libubox-lua +lua-ubus +nixio +luci-base
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  OpenWrt/ImmortalWrt high-performance terminal session tracking microservice and LuCI interface.
endef

define Build/Compile
	# Pure script application, no build required.
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./root/usr/sbin/session_tracker.lua $(1)/usr/sbin/session_tracker.lua

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/session_tracker $(1)/etc/init.d/session_tracker

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-session-tracker.json $(1)/usr/share/rpcd/acl.d/luci-app-session-tracker.json

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-session-tracker.json $(1)/usr/share/luci/menu.d/luci-app-session-tracker.json

	$(INSTALL_DIR) $(1)/usr/share/luci-static/resources/view/status
	$(INSTALL_DATA) ./root/usr/share/luci-static/resources/view/status/session_tracker.js $(1)/usr/share/luci-static/resources/view/status/session_tracker.js
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
