#!/bin/sh
# Undo the stock half of the hand-off.  Keeps rootkeep (root+ssh) unless --purge is given.
#   ssh root@192.168.1.1 'sh /tmp/kit/stock/uninstall.sh [--purge]'
set -u
C=/configs
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

touch "$C/handoff.off"                 # disarm FIRST - never leave an armed hand-off behind
rm -f "$C/handoff.fired"
echo "disarmed: $C/handoff.off"

if [ -f /etc/rc.local ]; then          # drop the /opt waiter, keep the keeper
	cat > /etc/rc.local <<'EOH'
#!/bin/sh
grep -qF rootkeep /etc/crontabs/root 2>/dev/null || echo '* * * * * /configs/rootkeep.sh' >> /etc/crontabs/root
[ -f /etc/init.d/cron ] && /etc/init.d/cron restart 2>/dev/null
[ -f /configs/rootkeep.sh ] && sh /configs/rootkeep.sh &
exit 0
EOH
	chmod +x /etc/rc.local
	echo "rc.local: hand-off launcher removed"
fi

if [ -s "$C/bootargs.orig" ]; then
	orig=$(cat "$C/bootargs.orig")
	fw_setenv bootargs "$orig" && echo "bootargs restored: $orig"
else
	echo "note: no $C/bootargs.orig - remove 'maxcpus=1' from fw_printenv bootargs by hand if you want it gone"
fi

# make the change survive the next boot
if [ -f "$C/rootkeep.sh" ]; then sh "$C/rootkeep.sh" >/dev/null 2>&1 || true; fi
if [ ! -s "$C/sysupgrade.tgz" ] || ! tar tzf "$C/sysupgrade.tgz" >/dev/null 2>&1; then
	rm -f "$C/sysupgrade.tgz.new"
	( cd / && tar czf "$C/sysupgrade.tgz.new" etc/rc.local etc/crontabs/root etc/config/luci ) 2>/dev/null
	if tar tzf "$C/sysupgrade.tgz.new" >/dev/null 2>&1; then
		mv "$C/sysupgrade.tgz.new" "$C/sysupgrade.tgz"
		echo "rebuilt $C/sysupgrade.tgz"
	fi
fi

if [ "$PURGE" = 1 ]; then
	rm -rf /opt/iduhandoff "$C/bootargs.orig"
	echo "purged /opt/iduhandoff"
fi
sync
echo "done - the next cold boot stays in stock."
