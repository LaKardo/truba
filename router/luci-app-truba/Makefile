include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI interface for Truba
# Только в метаданных пакета, без сборки зависимостей (см. router/truba/Makefile).
LUCI_EXTRA_DEPENDS:=truba (>=0), luci-base (>=0)
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_VERSION:=1.0.0
PKG_RELEASE:=13
# luci.mk берёт версию перевода из git-истории po/, а в CI исходники лежат вне git,
# и перевод получал версию 0 — apk upgrade никогда бы его не обновил.
PKG_PO_VERSION=$(PKG_VERSION)-r$(PKG_RELEASE)

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
