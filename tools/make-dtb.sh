#!/bin/sh
# Rebuild kit/owrt_mem.dtb from kit/owrt_mem.dts.
#
# The shipped .dtb (md5 888eeebfb2038b8dfa0295194d837042) is a byte-for-byte rebuild of the
# shipped .dts with dtc from device-tree-compiler 1.6.x.  Newer dtc may reorder/pad things and
# produce a different hash - the boot does not care, but stock/verify.sh does.
#
# What the .dts changes vs the port's own DTB (fdt-1 inside the FIT):
#   /memory        0x44000000 + 0x1c000000 (448 MB, was 80 MB)  - the Image must sit at the
#                  start of a RAM range this size, and mainline needs the RAM
#   /chosen/bootargs  the merged command line, because the TZ hand-off applies no
#                  bootargs-append: ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs
#                  rootwait + console/earlycon/loglevel/swiotlb/coherent_pool
set -eu
dtc -I dts -O dtb -f -o kit/owrt_mem.dtb kit/owrt_mem.dts
dtc --version
md5sum kit/owrt_mem.dtb
echo "expected: 888eeebfb2038b8dfa0295194d837042"
