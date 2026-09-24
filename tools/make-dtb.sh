#!/bin/sh
# Check the hand-off DTB, and re-point its bootargs between slots — WITHOUT recompiling.
#
#   sh tools/make-dtb.sh check  [file]        verify a DTB (default: kit/owrt_mem.dtb)
#   sh tools/make-dtb.sh slotA  [src] [dst]   default: cp kit/owrt_mem.dtb -> kit/owrt_mem.slotA.dtb
#   sh tools/make-dtb.sh slotB  [src] [dst]   default: the reverse
#
# ⚠ NEVER REBUILD THIS DTB FROM kit/owrt_mem.dts.  That .dts is only a reference dump of the
# shipped blob; recompiling it invites two failures we have already paid for once:
#   1. a stale/vendor-flavoured .dts (ess-switch / nss-dp nodes, no ethernet@) — the mainline
#      kernel then binds NO Ethernet: no `ipq5018-gmac-dwmac` probe, the internal PHY fails with
#      "failed to get and enable RX clock", an mdio child sits in deferred probe, and the booted
#      unit shows only `lo`.  That is exactly what a tester hit on 2026-09-24 via the old
#      docs §2b rebuild step.
#   2. dtc version drift quietly reordering nodes/properties.
# Patch the /chosen/bootargs string in the blob instead (fdtput) — every other node is untouched.
#
# A valid hand-off DTB has:
#   /memory           0x44000000 + 0x1c000000   (448 MB — the Image sits at the start of it)
#   ethernet@39c00000 and ethernet@39d00000     (mainline stmmac nodes; NOT vendor ess-switch)
#   /chosen/bootargs  console=ttyMSM0,115200n8 earlycon loglevel=7 ubi.mtd=<slot> \
#                     root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1 coherent_pool=2M
#   (slot B = rootfs_1 / mtd19, slot A = rootfs / mtd18 — that token is the ONLY difference)
set -eu
CMD=${1:-check}; shift 2>/dev/null || true

check() {
	f=${1:-kit/owrt_mem.dtb}
	[ -e "$f" ] || { echo "$f: missing"; exit 1; }
	bad=""
	grep -q 'ethernet@39c00000' "$f" || bad="no mainline ethernet@39c00000 node"
	grep -q 'ethernet@39d00000' "$f" || bad="${bad:+$bad; }no mainline ethernet@39d00000 node"
	grep -q 'ess-switch' "$f" && bad="${bad:+$bad; }has vendor ess-switch nodes"
	if [ -n "$bad" ]; then
		echo "$f: BAD — $bad"
		echo "      a kernel booted with this DTB comes up with NO Ethernet (only \`lo\`)."
		exit 1
	fi
	slot=$(strings -a "$f" | sed -n 's/.*ubi\.mtd=\(rootfs[_0-9]*\).*/\1/p' | head -1)
	mem=""
	if command -v fdtget >/dev/null 2>&1; then
		mem=$(fdtget -t x "$f" /memory reg 2>/dev/null | tr -s ' ' | cut -d' ' -f2,4 || true)
		if [ -n "$mem" ] && [ "$mem" != "44000000 1c000000" ]; then
			echo "$f: BAD — /memory is $mem, expected 44000000 1c000000 (448 MB)"; exit 1
		fi
	fi
	echo "$f: ok"
	echo "      md5   $(md5sum "$f" | cut -d' ' -f1)"
	echo "      slot  ${slot:-?}${mem:+   /memory $mem}"
}

patch() { # patch <src> <dst> <token>
	src=$1; dst=$2; token=$3
	command -v fdtput >/dev/null 2>&1 || { echo "fdtput not found (apt install device-tree-compiler)"; exit 1; }
	[ -e "$src" ] || { echo "$src: missing"; exit 1; }
	old=$(strings -a "$src" | sed -n 's/.*\(console=ttyMSM0[^"]*\)/\1/p' | head -1)
	[ -n "$old" ] || { echo "$src: no bootargs found"; exit 1; }
	new=$(printf '%s' "$old" | sed "s/ubi\.mtd=rootfs[_0-9]*/ubi.mtd=$token/")
	cp -f "$src" "$dst"
	fdtput -t s "$dst" /chosen bootargs "$new"
	echo "$dst: bootargs re-pointed to ubi.mtd=$token"
	check "$dst"
}

case "$CMD" in
	check) check "${1:-kit/owrt_mem.dtb}" ;;
	slotA) patch "${1:-kit/owrt_mem.dtb}"      "${2:-kit/owrt_mem.slotA.dtb}" rootfs ;;
	slotB) patch "${1:-kit/owrt_mem.slotA.dtb}" "${2:-kit/owrt_mem.dtb}"      rootfs_1 ;;
	*) echo "usage: $0 check|slotA|slotB [args]"; exit 1 ;;
esac
