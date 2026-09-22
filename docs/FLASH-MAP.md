# FLASH MAP — what this kit writes, and what it must never touch

NAND layout as Linux sees it on the unit (mtd names are the vendor's).  Sizes from `/proc/mtd`.

| mtd | size | name | stock's view | this kit |
|---|---|---|---|---|
| 0 | 1.25 M | `0:SBL1` | signed, verified by PBL | **never** |
| 1 | 1.25 M | `0:MIBIB` | partition table | **never** |
| 2,3 | 1 M | `0:BOOTCONFIG`, `…1` | U-Boot A/B config | **never** |
| 4,5 | 2 M | `0:QSEE_1`, `0:QSEE` | TZ firmware (plaintext ELF on this unit) | **never** (read for RE only) |
| 6,7 | 1 M | `0:DEVCFG`, `…_1` | signed device config | **never** |
| 8,9 | 1 M | `0:CDT`, `…_1` | DDR config | **never** |
| **10** | 1.25 M | `0:APPSBLENV` | U-Boot env (`/etc/fw_env.config` → `0x0 0x40000 0x20000 0x2`) | appends `maxcpus=1` to `bootargs`; original saved in `/configs/bootargs.orig` |
| 11 | 2.75 M | `RI` | runtime info | untouched |
| 12,13 | 1.75 M | `0:APPSBL_1`, `0:APPSBL` | signed U-Boot A/B | **never** |
| 14 | 1.25 M | `0:ART` | wifi calibration | untouched |
| **15** | 32 M | `cfg` | UBI → volume `cfg`, mounted `/configs` | **written**: the hook, `rootkeep.sh`, `sysupgrade.tgz`, `handoff.off/fired/ack/ack_seen`, logs |
| 16 | 32 M | `cfg_1` | UBI → `cfg_1` (A/B twin) | untouched |
| 17 | 512 K | `0:TRAINING` | DDR training | untouched |
| 18 | 100 M | `rootfs` | UBI `ubi1`: `kernel`, `wifi_fw`, `bt_fw`, `ubi_rootfs`, `rootfs_data` — the **vendor's** firmware, what U-Boot autoboots | read-only at most |
| **19** | 100 M | `rootfs_1` | UBI: vol 0 `kernel`, vol 1 `rootfs`, vol 2 `rootfs_data` — **our** arm64 OpenWrt (slot B).  Stock never attaches it | mainline mounts vol 1 (squashfs) + vol 2 (overlay); U-Boot's `kernel` vol is where phase 1 extracts the Image from |
| 20 | 32 M | `log` | UBI → vendor logs / pstore | read for debugging |
| 21 | 12 M | `extfs` | spare | untouched |
| **22** | 171 M | `user_data` | UBI → mounted `/opt` | **written**: `/opt/iduhandoff/` (the kit) |
| 26…34 | — | `kernel`, `wifi_fw`, … | the UBI volumes above, exposed again as sub-devices | — |

Notes

* **Nothing signed is ever written.**  The only boot-visible change outside `/configs` and `/opt`
  is the `maxcpus=1` word in the U-Boot environment; with a redundant env (two copies, flag `0x2`)
  and the original value saved on the unit, this is recoverable even if power dies mid-write.
* `handoff.ack` lives in **mtd15**, not in mainline's overlay, because mainline formats its
  overlay with zstd and the vendor's kernel cannot read zstd UBIFS (see `docs/DESIGN.md` §5).
* Slot names are confusing: the vendor boots **mtd18 `rootfs`**, we live in **mtd19 `rootfs_1`**.
  U-Boot's own "mtd1"/"mtd=0" numbering in its logs is unrelated to Linux's.
* To look inside any of these from the other side:
  `ubiattach -m <mtd>` → `mount -t ubifs ubiN:<volname>` (or `ubiN_0` by id) → **always `umount`
  and `ubidetach` afterwards**, and use `sync` before pulling power.
