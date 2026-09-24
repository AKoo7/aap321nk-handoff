#!/bin/sh
# Install the mainline half: an S00 service that bumps /configs/handoff.ack on every boot.
# That counter is how the stock-side hook knows a hand-off landed (see docs/DESIGN.md).
#
# Run ON THE UNIT while MAINLINE OpenWrt is running:
#   scp -O -r mainline root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/mainline/install.sh /tmp'
set -u
SRC=${1:-/tmp}
[ "$(uname -m)" = "aarch64" ] || echo "warning: $(uname -m) - this half belongs on mainline (aarch64)"

cp -f "$SRC/mainline/handoff-ack" /etc/init.d/handoff-ack || exit 1
chmod +x /etc/init.d/handoff-ack
ln -sf ../init.d/handoff-ack /etc/rc.d/S00handoff-ack

sh -n /etc/init.d/handoff-ack && echo "syntax ok"
echo "installed:"
ls -l /etc/init.d/handoff-ack /etc/rc.d/S00handoff-ack

echo "== first run =="
/etc/init.d/handoff-ack boot
sleep 1
dmesg | grep -i 'handoff-ack' | tail -2

echo "== counter read-back =="
M=$(awk -F'"' '$2=="cfg"{sub("mtd","",$1); sub(":.*","",$1); print $1; exit}' /proc/mtd)
D=$(ubiattach -m "$M" 2>&1 | sed -n 's/.*UBI device number \([0-9]*\).*/\1/p')
if [ -n "$D" ]; then
	sleep 1
	mkdir -p /mnt/cfg
	if mount -t ubifs "ubi${D}:cfg" /mnt/cfg 2>/dev/null || mount -t ubifs "ubi${D}_0" /mnt/cfg 2>/dev/null; then
		echo "  handoff.ack = $(cat /mnt/cfg/handoff.ack 2>/dev/null || echo MISSING)"
		umount /mnt/cfg
	else
		echo "  could not mount the cfg volume"
	fi
	ubidetach -d "$D" 2>/dev/null
else
	echo "  ubiattach -m $M failed"
fi

# == optional: the unit's 5G WAN identity (ODCPE lock + PPPoE) ==
# Images carry no identity on purpose (see identity/odcpe.local.conf.example);
# without this the hand-off still works and the WAN simply stays on dhcp.
if [ -f "$SRC/identity/odcpe.conf" ]; then
	cp -f "$SRC/identity/odcpe.conf" /etc/odcpe/odcpe.local.conf || exit 1
	chmod 600 /etc/odcpe/odcpe.local.conf
	echo "identity installed: /etc/odcpe/odcpe.local.conf"
	if [ -x /etc/init.d/odcpe-wan ]; then
		/etc/init.d/odcpe-wan enable
		/etc/init.d/odcpe-wan start
		sleep 2
		logread -e odcpe-wan 2>/dev/null | tail -3
		echo "  (to also survive a mtd19 reflash, copy the same file to /mnt/cfg/odcpe.conf)"
	fi
else
	echo "no identity/odcpe.conf in $SRC - the 5G WAN stays unconfigured (see INSTALL.md)"
fi

sync
echo
echo "mainline half installed.  Back in stock: rm /configs/handoff.off to arm the hand-off."
