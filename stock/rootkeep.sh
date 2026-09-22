#!/bin/sh
# AAP321NK root hand-over keep-alive.
#
# Re-applied every minute by cron because the stock boot regenerates /tmp/shadow from the
# account database, so a one-shot chpasswd would be undone.  Idempotent: no duplicate
# iptables rules, bounded log.
#
#   scp stock/rootkeep.sh root@192.168.1.1:/configs/rootkeep.sh && chmod +x ...
#   echo '* * * * * /configs/rootkeep.sh' >> /etc/crontabs/root
#
# /configs is the vendor "cfg" UBI volume (mtd15) - the only writable place that survives a
# reboot, and the one the vendor's restore_configs() reads sysupgrade.tgz from.
#
# NOTE: the file is mode 0600 on the bench unit; callers must test `-f`, not `-x`.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
NEWROOTPW="${ROOTKEEP_PW:-changeme}"
CRONLINE='* * * * * /configs/rootkeep.sh'

# 1. known root password
echo "root:$NEWROOTPW" | chpasswd 2>/dev/null

# 2. keep root login possible: drop pam_faillock (3-fail 5-min lockout, even root)
#    and pam_access ("-:root EXCEPT (wheel):ALL" rejects root outright)
sed -i '/pam_faillock/d; /pam_access/d' /etc/pam.d/system-login 2>/dev/null

# 3. :22 reachable despite the xiptmgr whitelist -- idempotent
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null

# 3b. collapse duplicates left by earlier keepers (keep exactly one)
n=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep -c "tcp dpt:22")
if [ "$n" -gt 1 ]; then
  iptables -L INPUT -n --line-numbers 2>/dev/null | grep "tcp dpt:22" \
    | awk '{print $1}' | tail -n +2 | sort -rn \
    | while read -r ln; do iptables -D INPUT "$ln" 2>/dev/null; done
fi

# 3c. LuCI on :8080: rpcd + uhttpd in CGI mode needs no lua/ubus plugin
mkdir -p /tmp/luci-sessions
[ -s /etc/config/luci ] || cat > /etc/config/luci <<'LCFG'
config core 'main'
	option lang 'auto'
	option mediaurlbase '/luci-static/bootstrap'
	option resourcebase '/luci-static/resources'
config internal 'sauth'
	option sessionpath '/tmp/luci-sessions'
	option sessiontime '3600'
config internal 'themes'
	option Bootstrap '/luci-static/bootstrap'
LCFG
iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT 2>/dev/null
pidof dropbear >/dev/null 2>&1 || /usr/sbin/dropbear -p 22 2>/dev/null
pidof rpcd     >/dev/null 2>&1 || /sbin/rpcd >/dev/null 2>&1 &
netstat -ltn 2>/dev/null | grep -q ':8080 ' \
  || /usr/sbin/uhttpd -h /www -x /cgi-bin -p 0.0.0.0:8080 -p '[::]:8080' >/dev/null 2>&1

# 4. usable shell for root (uid 0, /bin/ash)
[ -x /bin/ash ] && sed -i 's|^root:x:0:0:.*|root:x:0:0:root:/root:/bin/ash|' /etc/passwd 2>/dev/null

# 5. SURVIVE REBOOT.  "/" is an overlayfs whose upper layer is on tmpfs, so /etc/crontabs/root
#    is volatile.  /etc/init.d/startup's restore_configs() extracts /configs/sysupgrade.tgz
#    over / at S00 (before cron's S50) and then deletes it, so keep the crontab + rc.local
#    inside that tarball.  Self-perpetuating: boot restores them -> cron runs this -> rewrite.
#    Rebuild ONLY when missing/corrupt (a minute-by-minute rewrite would wear the flash and is
#    how a truncated archive once killed the box), and verify before replacing.
mkdir -p /etc/crontabs
grep -qF rootkeep /etc/crontabs/root 2>/dev/null || echo "$CRONLINE" >> /etc/crontabs/root
if [ -e /configs/sysupgrade.tgz ] && ! tar tzf /configs/sysupgrade.tgz >/dev/null 2>&1; then
  rm -f /configs/sysupgrade.tgz
fi
if [ ! -e /configs/sysupgrade.tgz ]; then
  list=""
  for f in etc/crontabs/root etc/config/luci etc/rc.local; do
    [ -e "/$f" ] && list="$list $f"
  done
  rm -f /configs/sysupgrade.tgz.new
  ( cd / && tar czf /configs/sysupgrade.tgz.new $list ) 2>/dev/null
  if tar tzf /configs/sysupgrade.tgz.new >/dev/null 2>&1; then
    mv /configs/sysupgrade.tgz.new /configs/sysupgrade.tgz
  fi
fi

# 6. bounded log
echo "$(date '+%H:%M:%S') rootkeep applied (rules22=$(iptables -L INPUT -n 2>/dev/null | grep -c 'tcp dpt:22') tgz=$([ -e /configs/sysupgrade.tgz ] && echo yes || echo no))" >> /configs/rootkeep.log
tail -n 200 /configs/rootkeep.log > /configs/rootkeep.log.tmp 2>/dev/null && mv /configs/rootkeep.log.tmp /configs/rootkeep.log

exit 0
