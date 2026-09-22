#!/bin/sh
# iduhandoff v6: cold-boot hand-off stock armv7 -> mainline arm64 OpenWrt (TZ monitor SMC).
# Success is proven by mainline bumping /configs/handoff.ack (its own S00 script) so a
# failed hand-off (TZ hang -> watchdog reset) disarms instead of looping.
# NOTE: v5's `dmesg | grep -i watchdog` guard was a false positive -- stock's normal boot
# always prints "procd: - watchdog -", so every fire self-disarmed on the next boot.
K=/opt/iduhandoff; [ -d "$K" ] || K=/tmp/o/iduhandoff
C=/configs;        [ -d "$C" ] || C=/tmp/c
LOG=$C/handoff.log
log() { echo "$(date "+%m-%d %H:%M:%S") $*" >> $LOG; }

log "hook v6 ran (K=$K C=$C)"
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

echo "iduhandoff: booting Mainline OpenWrt in 4s - press a key for stock" > /dev/console
if read -t 4 -n 1 _k < /dev/console 2>/dev/null; then
  log "AUTO-DISARM: key pressed"; touch $C/handoff.off; sync; exit 0
fi

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
