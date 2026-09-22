#!/bin/sh
# Fire the hand-off once, by hand, from STOCK.  Same sequence the hook uses; useful as the
# phase-1 test (it does not touch /configs/handoff.fired, so the hook's ack logic is unaffected).
#
#   ssh root@192.168.1.1 'sh /tmp/stock/fire-once.sh'
#
# On success this does not return: the TZ switches the calling core to AArch64 and mainline
# boots (~10 s).  On failure the box resets and stock comes back.
K=/opt/iduhandoff
[ -x "$K/idu_tool" ] || { echo "kit missing in $K" >&2; exit 1; }
for f in owrt_Image owrt_mem.dtb desc_blob.bin pty_owrt2.ko; do
	[ -e "$K/$f" ] || { echo "kit incomplete: $f" >&2; exit 1; }
done

# idu_tool reads fixed /tmp paths; the hook links them the same way
for f in owrt_Image owrt_mem.dtb desc_blob.bin pty_owrt2.ko; do
	[ -e "/tmp/$f" ] || ln -sf "$K/$f" "/tmp/$f"
done

echo "hand-off in 4 s - press Ctrl-C for stock"
sleep 4

# Park the secondaries - but ONLY if one is running (see stock/handoff.sh): a CPU_OFF'd core
# cannot be revived by mainline's AArch64 PSCI, so this costs SMP when it is needed at all.
if [ "$(cat /sys/devices/system/cpu/online 2>/dev/null)" != "0" ]; then
	echo "parking secondaries (mainline will come up with one core)"
	for c in 1 2 3; do echo 0 > /sys/devices/system/cpu/cpu$c/online 2>/dev/null; done
	i=0; while [ "$(cat /sys/devices/system/cpu/online 2>/dev/null)" != "0" ] && [ $i -lt 24 ]; do sleep 0.5; i=$((i+1)); done
else
	echo "secondaries already in reset (maxcpus=1) - leaving them alone"
fi
echo "online cpus: $(cat /sys/devices/system/cpu/online)"; sleep 2

sync
echo 3 > /proc/sys/vm/drop_caches
if ! "$K/idu_tool" stage || ! "$K/idu_tool" verify; then
	echo "staging failed - restoring CPU1, staying in stock" >&2
	echo 1 > /sys/devices/system/cpu/cpu1/online 2>/dev/null
	exit 1
fi
echo "firing..."
"$K/idu_tool" fire
echo "fire returned rc=$? (stock continues if the SMC did not take)"
echo 1 > /sys/devices/system/cpu/cpu1/online 2>/dev/null   # no hand-off: give the core back
