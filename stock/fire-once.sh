#!/bin/sh
# Fire the hand-off once, by hand, from STOCK.  Same sequence the hook uses; useful as the
# phase-1 test (it does not touch /configs/handoff.fired, so the hook's ack logic is unaffected).
#
#   ssh root@192.168.1.1 'sh /tmp/kit/stock/fire-once.sh'
#
# On success this does not return: the TZ switches the calling core to AArch64 and mainline
# boots (~10 s).  On failure the box resets and stock comes back.
K=/opt/iduhandoff
[ -x "$K/idu_tool" ] || { echo "kit missing in $K" >&2; exit 1; }
for f in owrt_Image owrt_mem.dtb desc_blob.bin pty_owrt2.ko; do
	[ -e "$K/$f" ] || { echo "kit incomplete: $f" >&2; exit 1; }
done

echo "hand-off in 4 s - press Ctrl-C for stock"
sleep 4

# CPU1 must be parked (and *actually* offline) before the SMC: a core still executing the stock
# kernel takes a bogus PSCI call and panics the box out of the hand-off.
echo 0 > /sys/devices/system/cpu/cpu1/online 2>/dev/null
i=0
while [ "$(cat /sys/devices/system/cpu/online 2>/dev/null)" != "0" ] && [ $i -lt 24 ]; do
	sleep 0.5; i=$((i+1))
done
echo "online cpus: $(cat /sys/devices/system/cpu/online) (waited $i)"
sleep 2

sync
echo 3 > /proc/sys/vm/drop_caches
cd "$K" && ./idu_tool stage && ./idu_tool verify || { echo "staging failed" >&2; exit 1; }
echo "firing..."
./idu_tool fire
echo "fire returned rc=$? (stock continues if the SMC did not take)"
