#!/bin/sh
# Remove the mainline half.  Run ON THE UNIT in MAINLINE OpenWrt.
#   ssh root@192.168.1.1 'sh /tmp/mainline/uninstall.sh'
rm -f /etc/rc.d/S00handoff-ack /etc/init.d/handoff-ack
sync
echo "removed (the overlay keeps the change: /overlay/upper/etc is where those files lived)"
echo "note: with no ack writer left, an armed stock side will auto-disarm after its next fire."
