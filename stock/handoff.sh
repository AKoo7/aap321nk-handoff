#!/bin/sh
# iduhandoff: cold-boot hand-off stock armv7 -> mainline arm64 OpenWrt (TZ monitor boot).
#
# Success is proven by mainline bumping /configs/handoff.ack (its own S00 script) so a failed
# hand-off (TZ hang -> watchdog reset) disarms instead of looping.
#
# Two traps this script exists to avoid:
#   * `dmesg | grep -i watchdog` is NOT a failure signal here - stock's normal boot logs
#     "procd: - watchdog -", so that check disarmed after every successful fire.
#   * `read -t N < /dev/console` never times out on this busybox (v1.35.0): it sleeps in the
#     tty read forever and the box would never fire again.  The key window therefore runs the
#     blocking read in a child and kills it when the window closes.
K=/opt/iduhandoff; [ -d "$K" ] || K=/tmp/o/iduhandoff
C=/configs;        [ -d "$C" ] || C=/tmp/c
LOG=$C/handoff.log
log() { echo "$(date "+%m-%d %H:%M:%S") $*" >> $LOG; }

log "hook v7 ran (K=$K C=$C)"
[ -d "$K" ] || { log "kit not mounted - skipping"; exit 0; }
[ -e $C/handoff.off ] && { log "disarmed (flag)"; exit 0; }

ACK=$(tr -dc 0-9 < $C/handoff.ack 2>/dev/null); ACK=${ACK:-0}
SEEN=$(tr -dc 0-9 < $C/handoff.ack_seen 2>/dev/null); SEEN=${SEEN:-0}

if [ -e $C/handoff.fired ]; then
	if [ "$ACK" -gt "$SEEN" ]; then
		log "OK: last hand-off reached mainline (ack $ACK > seen $SEEN) - re-arming"
	else
		log "AUTO-DISARM: last hand-off never reached mainline (ack=$ACK seen=$SEEN)"
		echo "$ACK" > $C/handoff.ack_seen
		rm -f $C/handoff.fired
		touch $C/handoff.off; sync; exit 0
	fi
fi
echo "$ACK" > $C/handoff.ack_seen
rm -f $C/handoff.fired; sync

# ---- 4 s window ----
# Best-effort key check, NOT the documented escape: the vendor's console owner consumes all
# serial input, so with stock fully up another reader sees nothing (measured: dd/read/cat all
# get 0 bytes while the tty still echoes).  It does work when the console is free (early boot,
# failsafe).  The real escapes are `touch /configs/handoff.off` and the U-Boot prompt.
# The window is a plain `sleep` with killer children, because `read -t` never returns on this
# busybox and this unit has no /dev/input (so `idu_tool btn` answers instantly).
KEY=$C/.hokey; BKEY=$C/.hokeybtn
rm -f $KEY $BKEY
( if read -n 1 _k < /dev/console 2>/dev/null; then : > $KEY; fi ) &
RP=$!
( $K/idu_tool btn 4 >/dev/null 2>&1; [ $? = 1 ] && : > $BKEY ) &
BP=$!
echo "iduhandoff: handing off to mainline in 4s (disarm: touch /configs/handoff.off)" > /dev/console
sleep 4
kill -9 $RP $BP 2>/dev/null
if [ -f $KEY ] || [ -f $BKEY ]; then
	log "AUTO-DISARM: key pressed (console=$([ -f $KEY ] && echo yes || echo no) button=$([ -f $BKEY ] && echo yes || echo no))"
	rm -f $KEY $BKEY; touch $C/handoff.off; sync; exit 0
fi
rm -f $KEY $BKEY

# ---- fire ----
for f in owrt_Image owrt_mem.dtb desc_blob.bin pty_owrt2.ko; do [ -e /tmp/$f ] || ln -sf $K/$f /tmp/$f; done
echo 0 > /sys/devices/system/cpu/cpu1/online 2>/dev/null
i=0; while [ "$(cat /sys/devices/system/cpu/online 2>/dev/null)" != "0" ] && [ $i -lt 24 ]; do sleep 0.5; i=$((i+1)); done
log "online cpus: $(cat /sys/devices/system/cpu/online) (waited $i)"; sleep 2
sync; echo 3 > /proc/sys/vm/drop_caches
touch $C/handoff.fired; sync
log "firing (uptime=$(cut -d. -f1 /proc/uptime)s)"
cd $K && ./idu_tool stage && ./idu_tool verify && ./idu_tool fire
log "fire returned rc=$? (stock continues)"
rm -f $C/handoff.fired
exit 0
