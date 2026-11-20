include $(TOPDIR)/rules.mk

PKG_NAME:=truba
PKG_VERSION:=1.2.0
PKG_RELEASE:=13
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

# Full cone NAT есть не во всякой прошивке: модуль kmod-nft-fullcone и опция fullcone в fw4 — из
# ImmortalWrt, в фидах OpenWrt их нет. Зависимость от модуля попадает в пакет, только если сборку
# запустили с TRUBA_FULLCONE=1 в окружении: CI ставит флаг, когда нашёл модуль в фиде прошивки,
# под которую собирает (build.yml), и сверяет зависимости готового пакета. Без модуля пакет
# ставится и работает без Full cone (uci-defaults/90-truba).
TRUBA_FULLCONE ?= 0

define Package/truba
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Truba: home network through your own VPS (AmneziaWG, full cone, geoip/geosite routing)
  PKGARCH:=all
  # Зависимости — только в метаданных пакета (EXTRA_DEPENDS), а не в DEPENDS: иначе
  # SDK перед упаковкой компилирует их все из исходников (mosdns вместе с Go, curl,
  # openssl…) и выбрасывает — роутер берёт их из фидов прошивки и фида Трубы. Сборка apk требует
  # у EXTRA_DEPENDS ограничение версии; «>=0» выполняется для любой. CI сверяет итог.
  EXTRA_DEPENDS:= \
	amneziawg-tools (>=0), \
	mosdns (>=0), \
	curl (>=0), \
	ip-full (>=0), \
	$(if $(filter 1,$(TRUBA_FULLCONE)),kmod-nft-fullcone (>=0)$(comma)) \
	kmod-nft-socket (>=0), \
	ucode (>=0), \
	ucode-mod-fs (>=0), \
	ucode-mod-uci (>=0), \
	ucode-mod-ubus (>=0), \
	ucode-mod-uloop (>=0), \
	ucode-mod-math (>=0), \
	ucode-mod-socket (>=0), \
	rpcd-mod-ucode (>=0)
endef

define Package/truba/description
  Routes the home network through an AmneziaWG tunnel to your own VPS, which
  forwards its whole public IP to the router (full cone NAT where the firmware has it).
  Traffic is classified by geoip.dat/geosite.dat from kirilllavrov/*-builder,
  used unchanged, via mosdns + nftables sets and policy routing.
endef

define Package/truba/conffiles
/etc/config/truba
endef

define Build/Compile
endef

define Package/truba/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/hotplug.d/iface \
		$(1)/etc/truba $(1)/lib/upgrade/keep.d $(1)/usr/sbin $(1)/usr/share/ucode/truba $(1)/usr/share/truba \
		$(1)/usr/share/rpcd/ucode
	$(INSTALL_CONF) ./files/etc/config/truba $(1)/etc/config/truba
	$(INSTALL_BIN) ./files/etc/init.d/truba $(1)/etc/init.d/truba
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-truba $(1)/etc/uci-defaults/90-truba
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/50-truba $(1)/etc/hotplug.d/iface/50-truba
	$(INSTALL_BIN) ./files/etc/truba/reinstall.sh $(1)/etc/truba/reinstall.sh
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/truba $(1)/lib/upgrade/keep.d/truba
	$(INSTALL_BIN) ./files/usr/sbin/truba $(1)/usr/sbin/truba
	$(INSTALL_DATA) ./files/usr/share/ucode/truba/*.uc $(1)/usr/share/ucode/truba/
	$(INSTALL_BIN) ./files/usr/share/truba/uninstall.sh $(1)/usr/share/truba/uninstall.sh
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/truba-api.uc $(1)/usr/share/rpcd/ucode/truba-api.uc
endef

# ubus-объект truba — плагин rpcd (ADR 0008). rpcd загружает плагины при запуске,
# а по HUP перезапускается сам, сохраняя сессии LuCI.
define Package/truba/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || killall -HUP rpcd 2>/dev/null
exit 0
endef

define Package/truba/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /usr/share/truba/uninstall.sh
exit 0
endef

define Package/truba/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || killall -HUP rpcd 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,truba))
