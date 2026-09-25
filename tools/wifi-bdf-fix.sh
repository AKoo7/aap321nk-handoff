#!/bin/sh
# wifi-bdf-fix.sh - restore full WiFi TX power on the AAP321NK after the OpenWrt install.
#
# SYMPTOM this fixes
#   WiFi signal is far weaker than stock ("almost dead"). iwinfo reports 22 dBm on 5 GHz
#   (and 27 dBm on 2.4 GHz) no matter what 'txpower' is set to - setting 30 is accepted and
#   silently clamped.
#
# CAUSE
#   The image ships the GENERIC upstream ath11k board files (board-2.bin/board.bin from the
#   ath11k-firmware package). A board file carries the radio's per-rate power and antenna
#   limits, and the generic one clamps this board's 5 GHz to 22 dBm. The vendor's own board
#   files are still on the unit, in the STOCK firmware's "wifi_fw" UBI volume on the other
#   slot, and they allow the full 30 dBm.
#
#   Stock selects them by name, not by board id (both radios report board_id 0xff):
#     IPQ5018/bdwlan.b24  -> 2.4 GHz        qcn6122/bdwlan.b60 -> 5 GHz
#
# RUN ON THE UNIT, IN MAINLINE OPENWRT:
#   scp -O tools/wifi-bdf-fix.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/wifi-bdf-fix.sh'
#   ssh root@192.168.1.1 'reboot'        # REQUIRED - see below
#
#   A reboot is required because ath11k reads the board file once, at driver probe;
#   'wifi reload' does not re-fetch it.
#
# Safe to re-run. Originals are kept in /root/bdf-backup/. If the vendor files cannot be
# found, nothing is changed (the unit keeps working, just with the weak generic limits).

set -u

FWROOT=/lib/firmware/ath11k
MP=/mnt/wififw
BACKUP=/root/bdf-backup

say()  { echo "$*"; }
ok()   { echo "  [ok]   $*"; }
warn() { echo "  [WARN] $*"; }
die()  { echo; echo "ABORT: $*"; cleanup; exit 1; }

# mtd number of the partition with this exact name ("cfg", "rootfs", ...)
mtd_by_name() {
	awk -F'"' -v n="$1" '$2==n {sub("mtd","",$1); sub(":.*","",$1); print $1; exit}' /proc/mtd
}

# ubi device number already holding this mtd, if any
ubi_of_mtd() {
	for u in /sys/class/ubi/ubi[0-9]*; do
		[ -r "$u/mtd_num" ] || continue
		[ "$(cat "$u/mtd_num")" = "$1" ] && { echo "${u##*/ubi}"; return 0; }
	done
	return 1
}

BLOCK=""; ATTACHED=0; MOUNTED=0
cleanup() {
	[ "$MOUNTED" = 1 ] && umount "$MP" 2>/dev/null
	[ -n "$BLOCK" ] && ubiblock --remove "/dev/ubiblock$BLOCK" 2>/dev/null
	[ "$ATTACHED" = 1 ] && ubidetach -d "$D" 2>/dev/null
	return 0
}

echo "=============================================================="
echo " AAP321NK WiFi TX-power fix (vendor board files)"
echo "=============================================================="
echo

[ "$(uname -m)" = "aarch64" ] || warn "not aarch64 - this is meant for the mainline side"
[ -d "$FWROOT" ] || die "no $FWROOT - is this really the mainline OpenWrt side?"

# ---- 1. locate and mount the stock firmware's wifi_fw volume -------------------
echo "1) looking for the vendor 'wifi_fw' volume (stock slot)"
D=""
for part in rootfs rootfs_1; do
	M=$(mtd_by_name "$part")
	[ -n "$M" ] || continue
	if D=$(ubi_of_mtd "$M"); then
		say "   mtd$M ($part) is already attached as ubi$D"
	else
		D=$(ubiattach -m "$M" 2>/dev/null | sed -n 's/.*UBI device number \([0-9]*\).*/\1/p')
		if [ -z "$D" ]; then
			say "   mtd$M ($part): not a UBI slot, skipping"
			continue
		fi
		ATTACHED=1
		say "   mtd$M ($part) -> ubi$D"
	fi
	V=""
	for v in /sys/class/ubi/ubi${D}_*; do
		[ -r "$v/name" ] || continue
		[ "$(cat "$v/name")" = "wifi_fw" ] && { V=${v##*_}; break; }
	done
	if [ -n "$V" ]; then
		say "   found volume 'wifi_fw' = ubi${D}_${V}"
		break
	fi
	say "   no wifi_fw on ubi$D"
	[ "$ATTACHED" = 1 ] && { ubidetach -d "$D" 2>/dev/null; ATTACHED=0; }
	D=""
done

[ -n "$D" ] || die "no 'wifi_fw' volume found. Has the stock firmware been overwritten?
       (Without it, the vendor board files cannot be recovered from this unit.)"

mkdir -p "$MP"
# static volume -> ubiblock+squashfs; fall back to ubifs for a dynamic volume
if ubiblock --create "/dev/ubi${D}_${V}" >/dev/null 2>&1 &&
   mount -t squashfs -o ro "/dev/ubiblock${D}_${V}" "$MP" 2>/dev/null; then
	BLOCK="${D}_${V}"; MOUNTED=1
	ok "mounted (squashfs)"
elif mount -t ubifs -o ro "ubi${D}_${V}" "$MP" 2>/dev/null; then
	MOUNTED=1
	ok "mounted (ubifs)"
else
	die "could not mount ubi${D}_${V}"
fi

# ---- 2. locate the vendor board files ----------------------------------------
echo
echo "2) locating the vendor board files"
V24="$MP/bdwlan.b24"		# IPQ5018  - 2.4 GHz
V60="$MP/qcn6122/bdwlan.b60"	# QCN6122  - 5 GHz
[ -f "$V24" ] || warn "2.4 GHz board file not found ($V24)"
[ -f "$V60" ] || warn "5 GHz board file not found ($V60)"
[ -f "$V24" ] || [ -f "$V60" ] || die "no vendor board files in the wifi_fw volume"
[ -f "$V24" ] && ok "2.4 GHz: bdwlan.b24"
[ -f "$V60" ] && ok "5 GHz:   qcn6122/bdwlan.b60"

# ---- 3. back up once, then install -------------------------------------------
echo
echo "3) installing"
mkdir -p "$BACKUP"

install_bdf() {			# $1 = source, $2 = dest dir, $3 = tag, $4 = label
	[ -f "$1" ] || return 0
	[ -d "$2" ] || { warn "$2 does not exist - skipping $4"; return 0; }
	# keep the FIRST backup (the real original); don't clobber it on a re-run
	for f in board.bin board-2.bin; do
		[ -f "$2/$f" ] || continue
		[ -f "$BACKUP/$3.$f" ] || cp -f "$2/$f" "$BACKUP/$3.$f"
	done
	cp -f "$1" "$2/board.bin" || { warn "copy failed for $4"; return 0; }
	# ath11k prefers the board-2 container; with it gone it uses board.bin
	rm -f "$2/board-2.bin"
	if [ "$(md5sum "$1" | awk '{print $1}')" = "$(md5sum "$2/board.bin" | awk '{print $1}')" ]; then
		ok "$4 board.bin installed (md5 verified)"
	else
		warn "$4 md5 mismatch after copy!"
	fi
	return 0
}

install_bdf "$V60" "$FWROOT/QCN6122/hw1.0" "5g"  "5 GHz"
install_bdf "$V24" "$FWROOT/IPQ5018/hw1.0" "24g" "2.4 GHz"

sync
say "   originals backed up in $BACKUP"
ls -1 "$BACKUP" 2>/dev/null | sed 's/^/     /'

cleanup
echo
echo "=============================================================="
echo " DONE - now REBOOT for it to take effect:"
echo
echo "     reboot"
echo
echo " After the reboot, check:"
echo "     iwinfo phy1-ap0 info | grep Tx-Power     # want 30 dBm (was 22)"
echo "     iwinfo phy0-ap0 info | grep Tx-Power     # want 30 dBm (was 27)"
echo
echo " If an interface does not exist yet, enable that radio first:"
echo "     uci set wireless.radio1.disabled=0; uci commit wireless; wifi reload"
echo
echo " To undo: restore the two originals from $BACKUP"
echo "   e.g. cp $BACKUP/5g.board.bin   $FWROOT/QCN6122/hw1.0/board.bin"
echo "        cp $BACKUP/5g.board-2.bin $FWROOT/QCN6122/hw1.0/board-2.bin"
echo "   (same pattern for 24g.* in $FWROOT/IPQ5018/hw1.0/), then reboot."
echo "=============================================================="
