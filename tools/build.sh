#!/bin/sh
# Rebuild the kit artifacts.  Run from the repo root:  ./tools/build.sh
#
#   CROSS_COMPILE  ARM (32-bit) toolchain that can link *statically*, e.g. the OpenWrt SDK's
#                  staging_dir/toolchain-arm_cortex-a7_neon-vfpv4_gcc-*/bin/arm-openwrt-linux-muslgnueabi-
#                  (Debian's arm-linux-gnueabihf- also works for the payload, and for idu_tool
#                  if its libc has static libs)
#   VEHICLE        pristine ptyconsole.ko pulled off the unit - only needed to rebuild
#                  payload/pty_owrt2.ko (the shipped one is already spliced):
#                    scp -O root@192.168.1.1:$(ssh root@192.168.1.1 'ls /lib/modules/*/ptyconsole.ko') \
#                        /tmp/ptyconsole.ko
set -eu
CC=${CROSS_COMPILE:-}gcc
AS=${CROSS_COMPILE:-}as
OC=${CROSS_COMPILE:-}objcopy

echo "== idu_tool =="
$CC -O2 -static -o kit/idu_tool kit/idu_tool.c
file kit/idu_tool | sed 's/^/   /'

echo "== payloads =="
$AS -o /tmp/pj_owrt2.o payload/pj_owrt2.s
$OC -O binary -j .probe /tmp/pj_owrt2.o payload/pj_owrt2.bin
$AS -o /tmp/exitnop.o payload/exitnop.s
$OC -O binary -j .exitnop /tmp/exitnop.o /tmp/exitnop.bin
wc -c payload/pj_owrt2.bin /tmp/exitnop.bin | sed 's/^/   /'

if [ -n "${VEHICLE:-}" ] && [ -e "${VEHICLE:-}" ]; then
	echo "== splice $VEHICLE -> payload/pty_owrt2.ko =="
	python3 tools/splice-pty.py payload/pj_owrt2.bin "$VEHICLE" payload/pty_owrt2.ko /tmp/exitnop.bin
else
	echo "== splice skipped (set VEHICLE=/path/to/ptyconsole.ko to rebuild pty_owrt2.ko) =="
fi

echo "== md5s =="
md5sum kit/idu_tool payload/pj_owrt2.bin payload/pty_owrt2.ko | sed 's/^/   /'
echo "   (stock/verify.sh has the shipped expectations baked in - update it after a rebuild)"
