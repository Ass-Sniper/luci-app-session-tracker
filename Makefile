include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0-2
PKG_PO_VERSION:=$(PKG_VERSION)
PKG_LICENSE:=MIT

LUCI_TITLE:=LuCI Support for Native Session Tracker
LUCI_DEPENDS:=+lua +libubox-lua +libubus-lua +luci-lib-nixio
LUCI_PKGARCH:=all
LUCI_MAINTAINER:=Ass-Sniper <zoukaiass@gmail.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
