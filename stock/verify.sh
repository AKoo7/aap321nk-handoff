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
	# owrt_Image is per-unit by design (extracted from the slot you flashed, §2c), so it is NOT
	# hash-checked — verify it is an arm64 kernel Image instead (magic "ARM\x64" at offset 56).
	if [ -e "$K/owrt_Image" ]; then
		magic=$(dd if="$K/owrt_Image" bs=1 skip=56 count=4 2>/dev/null)
		if [ "$magic" = "ARMd" ]; then
			printf '  %-20s ok (arm64 Image %s B, md5 %s)\n' owrt_Image \
				"$(wc -c < "$K/owrt_Image")" "$(md5sum "$K/owrt_Image" | cut -c1-8)"
		else
			printf '  %-20s BAD: not an arm64 Image (magic=%s) - re-run §2c\n' owrt_Image "$magic"
		fi
	else
		printf '  %-20s MISSING (extract it from the slot: docs §2c)\n' owrt_Image
	fi
	# The hand-off DTB must come from the MAINLINE tree.  A vendor-flavoured DTB (ess-switch /
	# nss-dp nodes, no ethernet@) boots a kernel with NO Ethernet at all — that is a trap we hit
	# for real (no ipq5018-gmac-dwmac probe, PHY "failed to get and enable RX clock", only `lo`).
	dtbchk() { # dtbchk <dtb> [label]
		[ -e "$1" ] || return 0
		why=""
		grep -q 'ethernet@39c00000' "$1" 2>/dev/null || why="lacks the mainline ethernet@39c00000 node"
		grep -q 'ess-switch' "$1" 2>/dev/null && why="${why:+$why; }has vendor ess-switch nodes"
		if [ -z "$why" ]; then
			printf '  %-20s ok (mainline DTB %s, %s)\n' "${1##*/}" "$(md5sum "$1" | cut -c1-8)" "${2:-}"
		else
			printf '  %-20s BAD: %s -> no Ethernet will come up\n' "${1##*/}" "$why"
		fi
	}
	dtbchk "$K/owrt_mem.dtb" slot-B
	dtbchk "$K/owrt_mem.slotA.dtb" slot-A
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
