#!/bin/sh
# Print the hand-off state.  Works on either side of the boot.
K=/opt/iduhandoff
C=/configs

echo "== side =="
echo "  $(uname -m) / $(uname -r)"

if [ -d "$C" ] && [ -r /proc/mtd ]; then
	echo "== flags ($C) =="
	for f in handoff.off handoff.fired handoff.ack handoff.ack_seen; do
		if [ -e "$C/$f" ]; then
			printf '  %-18s %s\n' "$f" "$(cat "$C/$f" 2>/dev/null)"
		else
			printf '  %-18s (absent)\n' "$f"
		fi
	done
	[ -e "$C/handoff.off" ] && echo "  => DISARMED" || echo "  => ARMED (a cold boot will hand off)"
	echo "== stock bootargs =="
	echo "  $(fw_printenv bootargs 2>/dev/null)"
	[ -e "$C/bootargs.orig" ] && echo "  original: $(cat "$C/bootargs.orig")"
	echo "== persistent tarball =="
	if [ -s "$C/sysupgrade.tgz" ]; then
		echo "  $(wc -c < "$C/sysupgrade.tgz") bytes: $(tar tzf "$C/sysupgrade.tgz" 2>&1 | tr '\n' ' ')"
	else
		echo "  MISSING or empty (no /etc persistence: root+ssh and the hook will not come back)"
	fi
	echo "== handoff.log (tail) =="
	tail -8 "$C/handoff.log" 2>/dev/null | sed 's/^/  /'
fi

# Artifact hashes as shipped.  Rebuild something -> update the expectation here too (and
# kit/MANIFEST.md5).
check() { # check <file> <md5>
	if [ ! -e "$1" ]; then printf '  %-14s MISSING\n' "${1##*/}"; return; fi
	got=$(md5sum "$1" | cut -d' ' -f1)
	if [ "$got" = "$2" ]; then printf '  %-14s ok\n' "${1##*/}"
	else printf '  %-14s MISMATCH got=%s want=%s\n' "${1##*/}" "$got" "$2"; fi
}

echo "== kit in $K =="
if [ -d "$K" ]; then
	check "$K/idu_tool"     88e3954177b6451ee5d3a6a6a8af78f3
	check "$K/owrt_Image"   8da349d50ac5cba1c0d9600903c1f2be
	check "$K/owrt_mem.dtb" 888eeebfb2038b8dfa0295194d837042
	check "$K/desc_blob.bin" 70efe97ba0dfd18960c73ca21f8ec72a
	check "$K/pty_owrt2.ko" 9e30e1e8efef6d12a54ad823a6ac00be
	check "$K/handoff.sh"   d3abeb2036e1765b1579187fc69db30d
else
	echo "  $K not mounted (in mainline: ubiattach -m 22 then mount ubiN:user_data ...)"
fi

echo "== mainline ack service (visible in mainline) =="
if [ -x /etc/init.d/handoff-ack ]; then
	echo "  /etc/init.d/handoff-ack present; rc.d link: $(readlink /etc/rc.d/S00handoff-ack 2>/dev/null)"
else
	echo "  not installed here"
fi
dmesg 2>/dev/null | grep -i 'handoff-ack' | tail -2 | sed 's/^/  /'
