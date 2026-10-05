include $(TOPDIR)/rules.mk

PKG_NAME:=truba
PKG_VERSION:=1.0.0
PKG_RELEASE:=5
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/truba
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Truba: home network through your own VPS (AmneziaWG, full cone, geoip/geosite routing)
  PKGARCH:=all
  DEPENDS:= \
	+amneziawg-tools \
	+mosdns \
	+curl \
	+ip-full \
	+kmod-nft-fullcone \
	+kmod-nft-socket \
	+ucode \
	+ucode-mod-fs \
	+ucode-mod-uci \
	+ucode-mod-ubus \
	+ucode-mod-uloop \
	+ucode-mod-math \
	+ucode-mod-socket
endef

define Package/truba/description
  Routes the home network through an AmneziaWG tunnel to your own VPS, which
  forwards its whole public IP to the router (full cone NAT is done by ImmortalWrt).
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
		$(1)/etc/truba $(1)/lib/upgrade/keep.d $(1)/usr/sbin $(1)/usr/share/ucode/truba $(1)/usr/share/truba
	$(INSTALL_CONF) ./files/etc/config/truba $(1)/etc/config/truba
	$(INSTALL_BIN) ./files/etc/init.d/truba $(1)/etc/init.d/truba
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-truba $(1)/etc/uci-defaults/90-truba
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/50-truba $(1)/etc/hotplug.d/iface/50-truba
	$(INSTALL_BIN) ./files/etc/truba/reinstall.sh $(1)/etc/truba/reinstall.sh
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/truba $(1)/lib/upgrade/keep.d/truba
	$(INSTALL_BIN) ./files/usr/sbin/truba $(1)/usr/sbin/truba
	$(INSTALL_DATA) ./files/usr/share/ucode/truba/*.uc $(1)/usr/share/ucode/truba/
	$(INSTALL_BIN) ./files/usr/share/truba/uninstall.sh $(1)/usr/share/truba/uninstall.sh
endef

define Package/truba/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /usr/share/truba/uninstall.sh
exit 0
endef

$(eval $(call BuildPackage,truba))
