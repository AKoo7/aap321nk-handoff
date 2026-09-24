#!/bin/sh
# Install the AAP321NK cold-boot hand-off (stock half).
# Run ON THE UNIT as root while STOCK is running.  Idempotent.
#
#   scp -O -r kit payload stock mainline root@192.168.1.1:/tmp/    # from the host
#   ssh root@192.168.1.1 'sh /tmp/stock/install.sh /tmp'
#
# The hand-off is left DISARMED: arm it only after the mainline half is installed
# (INSTALL.md phase 2 -> `rm /configs/handoff.off`).
set -eu
SRC=${1:-/tmp}
K=/opt/iduhandoff
C=/configs

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -f "$C/rootkeep.sh" ] || [ -d "$C" ] || { echo "error: $C not mounted - is this stock?" >&2; exit 1; }
grep -qi 'ipq5018\|AAP321NK' /proc/device-tree/model 2>/dev/null || \
	echo "note: /proc/device-tree/model does not look like an AAP321NK - continuing anyway"

echo "== 1. kit -> $K"
mkdir -p "$K"
for f in idu_tool owrt_Image owrt_mem.dtb desc_blob.bin pty_owrt2.ko; do
	src=""
	for d in "$SRC/kit" "$SRC/payload"; do	# pty_owrt2.ko lives in payload/, the rest in kit/
		if [ -e "$d/$f" ]; then src="$d/$f"; break; fi
	done
	if [ -n "$src" ]; then
		cp -f "$src" "$K/$f"
	elif [ ! -e "$K/$f" ]; then
		echo "   MISSING: $f (looked in \$SRC/kit and \$SRC/payload - copy it into $K manually)" >&2
	fi
done
cp -f "$SRC/stock/handoff.sh" "$K/handoff.sh"
chmod +x "$K/idu_tool" "$K/handoff.sh"
ls -l "$K"

# The hand-off DTB must be the MAINLINE tree.  A vendor-flavoured one (ess-switch / nss-dp nodes,
# no ethernet@) boots a kernel with NO Ethernet at all - no ipq5018-gmac-dwmac probe, PHY "failed
# to get and enable RX clock", and the unit comes up with only `lo`.  Warn loudly, do not abort.
if [ -e "$K/owrt_mem.dtb" ]; then
	bad=""
	grep -q 'ethernet@39c00000' "$K/owrt_mem.dtb" 2>/dev/null || bad="no mainline ethernet@ node"
	grep -q 'ess-switch' "$K/owrt_mem.dtb" 2>/dev/null && bad="${bad:+$bad; }vendor ess-switch nodes"
	if [ -n "$bad" ]; then
		echo "   !!! owrt_mem.dtb is NOT a mainline DTB ($bad)" >&2
		echo "       -> the hand-off will come up with NO Ethernet (only 'lo')." >&2
		echo "       -> copy kit/owrt_mem.dtb (slot B) or kit/owrt_mem.slotA.dtb (slot A/K95)." >&2
	else
		slot=$(strings -a "$K/owrt_mem.dtb" 2>/dev/null | sed -n 's/.*ubi\.mtd=\(rootfs[_0-9]*\).*/\1/p' | head -1)
		echo "   owrt_mem.dtb: mainline DTB, slot=${slot:-?} ($(md5sum "$K/owrt_mem.dtb" | cut -c1-8))"
	fi
fi

echo "== 2. stock-side launcher (/etc/rc.local + crontab)"
# /etc lives on a tmpfs overlay: these files only survive because rootkeep packages them into
# /configs/sysupgrade.tgz, which the vendor's restore_configs() unpacks at S00 of every boot.
mkdir -p /etc/crontabs
cat > /etc/rc.local <<'EOH'
#!/bin/sh
# Runs from /etc/init.d/done (S95).  /configs is mounted by now, /opt is not.
echo "[iduhandoff] rc.local RAN" > /dev/console
grep -qF rootkeep /etc/crontabs/root 2>/dev/null || echo '* * * * * /configs/rootkeep.sh' >> /etc/crontabs/root
[ -f /etc/init.d/cron ] && /etc/init.d/cron restart 2>/dev/null
if [ -f /configs/rootkeep.sh ]; then
	echo "[iduhandoff] /configs visible -> starting keeper" > /dev/console
	sh /configs/rootkeep.sh &
fi
(
	i=0
	while [ ! -f /opt/iduhandoff/handoff.sh ] && [ $i -lt 90 ]; do sleep 2; i=$((i+1)); done
	if [ -f /opt/iduhandoff/handoff.sh ]; then
		echo "[iduhandoff] running hook" > /dev/console
		sh /opt/iduhandoff/handoff.sh
	else
		echo "[iduhandoff] kit missing in /opt" > /dev/console
	fi
) &
exit 0
EOH
chmod +x /etc/rc.local
grep -qF rootkeep /etc/crontabs/root 2>/dev/null || echo '* * * * * /configs/rootkeep.sh' >> /etc/crontabs/root

echo "== 2b. root keeper (root + ssh on stock)"
if [ -f "$C/rootkeep.sh" ]; then
	echo "   keeper already present - leaving it alone"
elif [ -f "$SRC/stock/rootkeep.sh" ]; then
	cp -f "$SRC/stock/rootkeep.sh" "$C/rootkeep.sh"
	chmod +x "$C/rootkeep.sh" 2>/dev/null || chmod 600 "$C/rootkeep.sh"
	echo "   installed: it sets the stock root password to '${ROOTKEEP_PW:-Nok@123}' every minute"
	echo "   (export ROOTKEEP_PW=... before running to use another password)"
else
	echo "   note: $SRC/stock/rootkeep.sh missing - root+ssh will not be re-applied each boot" >&2
fi

echo "== 3. persistent tarball (atomic build, verified)"
# If the keeper is installed it rebuilds this every minute; build it once here so a fresh unit
# is persistent immediately.  Never leave a half-written sysupgrade.tgz behind: the vendor's
# restore does `tar -xzf ... && rm` and will neither notice nor clean a corrupt archive.
build_tgz() {
	list=""
	for f in etc/rc.local etc/crontabs/root etc/config/luci; do
		[ -e "/$f" ] && list="$list $f"
	done
	rm -f "$C/sysupgrade.tgz.new"
	( cd / && tar czf "$C/sysupgrade.tgz.new" $list ) || return 1
	tar tzf "$C/sysupgrade.tgz.new" >/dev/null 2>&1 || return 1
	mv "$C/sysupgrade.tgz.new" "$C/sysupgrade.tgz"
	echo "   tgz: $(wc -c < "$C/sysupgrade.tgz") bytes:$(tar tzf "$C/sysupgrade.tgz" | tr '\n' ' ')"
}
if [ -x "$C/rootkeep.sh" ] || [ -f "$C/rootkeep.sh" ]; then
	echo "   keeper present - running it once (it rebuilds the tarball itself)"
	sh "$C/rootkeep.sh" >/dev/null 2>&1 || true
else
	build_tgz
fi
[ -s "$C/sysupgrade.tgz" ] || build_tgz

echo "== 4. stock U-Boot bootargs: maxcpus=1"
# CPU1/CPU2 must never be brought up by the 32-bit kernel: an AArch32 CPU_OFF leaves them in a
# state the AArch64 PSCI in mainline cannot revive.  Left in reset, mainline brings them up fine.
cur=$(fw_printenv -n bootargs 2>/dev/null || fw_printenv bootargs 2>/dev/null | sed 's/^bootargs=//')
[ -n "$cur" ] || cur="console=ttyMSM0,115200n8 ubi.mtd=rootfs_1"
[ -e "$C/bootargs.orig" ] || { echo "$cur" > "$C/bootargs.orig"; echo "   saved original -> $C/bootargs.orig"; }
case "$cur" in
	*maxcpus=1*) echo "   already set: $cur" ;;
	*) fw_setenv bootargs "$cur maxcpus=1" && echo "   set: $cur maxcpus=1" ;;
esac

echo "== 5. arm state + sync"
touch "$C/handoff.off"                       # disarmed until phase 2
rm -f "$C/handoff.fired"
echo 0 > "$C/handoff.ack_seen"
sync

echo
echo "Installed and DISARMED.  Kit hashes (compare with kit/ in the repo):"
md5sum "$K"/idu_tool "$K"/owrt_Image "$K"/owrt_mem.dtb "$K"/desc_blob.bin "$K"/pty_owrt2.ko 2>/dev/null | sed 's/^/   /'
echo
echo "Next:"
echo "  * phase 1 test ..... sh $SRC/stock/fire-once.sh"
echo "  * then in MAINLINE . sh $SRC/mainline/install.sh $SRC"
echo "  * then arm ......... rm $C/handoff.off"
