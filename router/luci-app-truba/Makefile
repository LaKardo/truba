include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI interface for Truba
# Только в метаданных пакета, без сборки зависимостей (см. router/truba/Makefile).
# ubus-API Трубы (rpcd-плагин), к которому обращается интерфейс, — в пакете truba (ADR 0008):
# версии интерфейса и службы совпадают. С 1.2.0-r1 интерфейс вызывает devices и connections
# (ADR 0018) и читает status.watchdog, с 1.2.0-r5 — проверяет адреса DNS по upstream_re из schema.
LUCI_EXTRA_DEPENDS:=truba (>=1.2.0-r7), luci-base (>=0)
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_VERSION:=1.2.0
PKG_RELEASE:=7
# luci.mk берёт версию перевода из git-истории po/, а в CI исходники лежат вне git,
# и перевод получал версию 0 — apk upgrade никогда бы его не обновил.
PKG_PO_VERSION=$(PKG_VERSION)-r$(PKG_RELEASE)

# Файлы ставятся как есть: jsmin не понимает шаблонных строк htm, а копии библиотек в lib/
# должны оставаться побайтно равными закреплённым (sha256 в lib/VERSIONS). Заодно стенд
# тестов (копирует htdocs) и Роутер получают одни и те же файлы.
LUCI_MINIFY_JS:=0
LUCI_MINIFY_CSS:=0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
