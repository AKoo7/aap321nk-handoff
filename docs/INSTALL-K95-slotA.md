# AAP321NK **HJL.K95** cold-boot hand-off — install runbook (active-slot-B variant)

**What this is.** How to bring the OpenWrt monitor-SMC hand-off up on a second
AAP321NK, whose backup is in `~/Sand_aap321nk/`. It is a thin **delta on the packaged runbook**
`~/aap321nk-handoff/INSTALL.md` — read that for the full mechanism; this file only calls out what
is different for this unit and adds the one step INSTALL.md assumes you already did (flashing
OpenWrt into a slot).

**Why it "wasn't working":** OpenWrt was simply never installed here — `rootfs_1` (mtd19) is still
stock, `/opt` has no kit, `rc.local` is the default. Root *is* already installed and healthy. So
this is a from-scratch install, not a repair.

---

## 0 — How this unit differs from the bench unit (READ FIRST)

| thing | bench unit (.194) | **this K95 unit** | consequence |
|---|---|---|---|
| Mgmt IP | `192.168.1.1` | **`192.168.18.1`** | it was locally factory-reset & un-provisioned; SSH/relay here |
| Firmware | JJM.I34 (2025-05) | **HJL.K95p02 (2024-09)** — older | keep *its own* stock images; see §Anti-rollback |
| Active boot slot | **A** | **B** (BOOTCONFIG all attrs=1) | OpenWrt must go in the **inactive** slot = **A / `mtd18` / `rootfs`** |
| Hand-off DTB bootargs | `ubi.mtd=rootfs_1 … ubiblock0_1` | **`ubi.mtd=rootfs … ubiblock0_1`** | one-token edit to `owrt_mem.dts` (§2) |
| QSEE / TZ (mtd4) | reference | **code byte-identical** (only re-signed) | kit `idu_tool`/`desc_blob`/addresses port **verbatim** — no re-RE |
| Root | installed | **installed & running** (packaged `rootkeep.sh`, owner key + `Nok@123`) | you already have the shell you need |

**The rule that drives everything:** *stock keeps booting from the **active** slot; OpenWrt lives
in the **other** slot and is only ever mounted by the RAM hand-off kernel.* Bench: active A →
OpenWrt in B. **Here: active B → OpenWrt in A.** If you flash OpenWrt into the **active** slot,
signed `bootipq` will try to boot it and fail. This choice also means **the active stock slot (B)
is never touched → it is your guaranteed rollback.**

## 0.1 — Prereqs / what you need at the bench

- **Serial console** on the unit (`ttyMSM0`, 115200 8N1) — the test fire is only observable there.
- **Cold power control** — relay or a mains switch. (Confirm the relay is wired to *this* unit; the
  `10.1.1.108` hook is the bench unit's.)
- **Root shell:** `ssh root@192.168.18.1` (pw `Nok@123` unless `ROOTKEEP_PW` was overridden, or
  the owner's authorized key). Verify: `ssh root@192.168.18.1 'id; uname -rm'` → `uid=0 … 5.4.213 armv7l`.
- **`scp` note:** stock has no sftp-server; the packaged commands use `scp -O` (legacy protocol),
  which works. If any `scp -O` fails, fall back to `tar c … | ssh root@192.168.18.1 'tar x -C /tmp'`.
- Host tools: `python3`, `dtc` (both present here).
- Backup already exists: `~/Sand_aap321nk/aap321nk-backup.zip` (full 23-partition dump). Good.

---

## 1 — Flash OpenWrt into the **inactive** slot A (`mtd18` / `rootfs`)

Stock boots from active slot **B**, so `mtd18` is detached and safe to overwrite from the running
stock system. **Back it up first**, then flash the freshly-built factory image.

```sh
U=root@192.168.18.1
IMG=~/idu-openwrt/openwrt/bin/targets/qualcommax/ipq50xx/openwrt-qualcommax-ipq50xx-airtel_aap321nk-squashfs-factory.ubi
# (18.3 MB, built 2026-09-23, 6.18.52 r36511 — same HW target as the bench unit)

# 1a. confirm mtd18 is 'rootfs' and NOT attached (must be detached to ubiformat)
ssh $U 'grep rootfs /proc/mtd; cat /proc/mtd | sed -n "1,25p"; echo ---; ls /sys/class/ubi/ 2>/dev/null'
#   expect: mtd18 == "rootfs" (100 MB); mtd19 == "rootfs_1" (the running stock slot B).
ssh $U 'for u in /sys/class/ubi/ubi[0-9]*; do [ -r $u/mtd_num ] && echo "$u -> mtd$(cat $u/mtd_num)"; done'
#   if any ubiX maps to mtd18:   ssh $U 'ubidetach -m 18'

# 1b. back up the stock slot-A rootfs before overwriting (rollback insurance)
ssh $U 'dd if=/dev/mtd18 bs=1M 2>/dev/null | gzip -1' > ~/Sand_aap321nk/mtd18_slotA_stock.gz
ls -l ~/Sand_aap321nk/mtd18_slotA_stock.gz     # ~ tens of MB

# 1c. push the factory image and flash it into slot A
cat "$IMG" | ssh $U 'cat > /tmp/factory.ubi'
ssh $U 'command -v ubiformat || echo NO_UBIFORMAT'      # stock should have mtd-utils
ssh $U 'ubiformat /dev/mtd18 -f /tmp/factory.ubi -y && echo FLASHED_OK'

# 1d. verify the 3-volume OpenWrt layout landed in slot A
ssh $U 'ubidetach -m 18 2>/dev/null; ubiattach -m 18; ubinfo /dev/ubi0 -a | grep -E "Name|Present|Type" ; ubidetach -m 18'
#   expect volumes: kernel (static), rootfs (static/squashfs), rootfs_data (dynamic)
```

> If `ubiformat` is missing on stock, boot the OpenWrt **initramfs** in RAM via U-Boot
> (`NOKIA >` → `en`/`airtelroot12` → `IPQ5018#`, tftp the `…-initramfs-uImage.itb`, `bootm`) and
> run `ubiformat /dev/mtd18` from there. Do **not** change BOOTCONFIG.

**Safety at this point:** the active slot is still B (stock), so a power cycle boots stock exactly
as before. Slot A now holds OpenWrt but nothing boots it yet.

---

## 2 — Patch the kit for **slot A**, then build the matched artifacts (on the host)

Only the DTB command line changes (attach `rootfs` instead of `rootfs_1`; the volume id stays `1`
because our OpenWrt UBI is the only one attached → `ubi0`, vol 1 = `rootfs`). The `owrt_Image`
kernel is **extracted from what you just flashed**, so kernel and rootfs are guaranteed same-build.

```sh
cd ~/aap321nk-handoff
cp kit/owrt_mem.dts kit/owrt_mem.dts.bench-bak

# 2a. slot-A bootargs (rootfs_1 -> rootfs); everything else identical
sed -i 's/ubi\.mtd=rootfs_1/ubi.mtd=rootfs/' kit/owrt_mem.dts
grep -n 'ubi.mtd=' kit/owrt_mem.dts
#   -> ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait …   (448 MB /memory unchanged)

# 2b. rebuild the DTB (md5 will differ from the shipped 888eeebf — expected: bootargs edit + dtc 1.7.2; the boot does not care)
sh tools/make-dtb.sh || dtc -I dts -O dtb -f -o kit/owrt_mem.dtb kit/owrt_mem.dts

# 2c. extract the matching arm64 Image FROM slot A's kernel volume (guarantees kernel==rootfs build)
U=root@192.168.18.1
ssh $U 'ubidetach -m 18 2>/dev/null; ubiattach -m 18; dd if=/dev/ubi0_0 of=/tmp/slotA_kvol.bin bs=4096 2>/dev/null; ubidetach -m 18; ls -l /tmp/slotA_kvol.bin'
cat /dev/null; ssh $U 'cat /tmp/slotA_kvol.bin' > /tmp/slotA_kvol.bin
python3 tools/extract-kernel.py /tmp/slotA_kvol.bin kit/owrt_Image
ls -l kit/owrt_Image           # ~13–15 MB arm64 Image

# 2d. sanity: desc_blob + idu_tool are unchanged (QSEE ports verbatim)
md5sum kit/desc_blob.bin kit/idu_tool      # must match MANIFEST.md5 for these two
```

---

## 3 — Stock half (kit into `/opt`, hook, `maxcpus=1`) — leaves it **disarmed**

`stock/install.sh` is idempotent and re-uses the root keeper that is already here.

```sh
cd ~/aap321nk-handoff
U=root@192.168.18.1
scp -O -r kit payload stock mainline $U:/tmp/      # or the tar|ssh fallback
ssh $U 'sh /tmp/stock/install.sh /tmp'
```

It: copies the kit to `/opt/iduhandoff`, (re)installs `/configs/rootkeep.sh`, writes
`/etc/rc.local` + the crontab line, refreshes `/configs/sysupgrade.tgz`, **appends `maxcpus=1`** to
the U-Boot `bootargs` (original saved to `/configs/bootargs.orig`), and creates
`/configs/handoff.off` (disarmed). Verify:

```sh
ssh $U 'fw_printenv bootargs; ls -l /opt/iduhandoff; ls /configs/handoff.off && echo DISARMED_OK'
#   bootargs must end with " maxcpus=1"   (this unit's base is "console=ttyMSM0,115200n8")
```

> No slot edit is needed in `stock/install.sh`: its line-101 fallback (`ubi.mtd=rootfs_1`) is the
> *stock* command line and only triggers if `bootargs` is empty — it isn't here — and stock does
> boot from slot B, so it would be correct anyway.

---

## 4 — Manual test fire (watch the serial console)

```sh
ssh root@192.168.18.1 'sh /tmp/stock/fire-once.sh'
```

On the **serial console** you want to see staging OK for all three blobs, `firing…`, then:

```
[    0.000000] Booting Linux on physical CPU 0x0000000000
[    0.000000] Linux version 6.18.52 … aarch64 … Machine model: Airtel/Nokia AAP321NK
[    2.8] VFS: Mounted root (squashfs filesystem) …
[   49.] mount_root: switching to ubifs overlay
```

Then, after it settles: `ssh root@192.168.18.1 'uname -m'` → `aarch64` (mainline SSH is
**empty-password**). **Do not arm until this manual fire lands in mainline.** If it drops back to
stock, see `~/aap321nk-handoff/docs/RECOVERY.md` (check staging hashes and that `maxcpus=1` is in
`bootargs`).

Watch for these unit-specific failure signatures:
- `System is deadlocked on memory` → wrong DTB (must be the 448 MB `owrt_mem.dtb` from §2b).
- panics with `no root=` / can't mount → the bootargs edit didn't take; confirm §2a shows
  `ubi.mtd=rootfs` and the dtb was rebuilt.
- mainline mounts but overlay changes vanish → `mount | grep overlay` must show `ubi0:2
  rootfs_data`; if the overlay volume is missing, `rootfs_data` didn't format (re-flash §1).

---

## 5 — Mainline half (the ack writer) — in the same mainline session

```sh
scp -O -r mainline root@192.168.18.1:/tmp/
ssh root@192.168.18.1 'sh /tmp/mainline/install.sh /tmp'
#   -> handoff-ack: bumped to 1 ;  handoff.ack = 1
```

Installs `/etc/init.d/handoff-ack` (S00) into the persistent overlay; every mainline boot bumps
`/configs/handoff.ack`, which is the only proof the stock hook accepts to re-arm.

---

## 6 — Arm and verify a real cold cycle

```sh
# power-cycle back into stock first (still disarmed), then arm:
ssh root@192.168.18.1 'rm /configs/handoff.off && sync'
```

Now **cold-cut the power** and let it run untouched. Stock (~60–70 s) → console shows
`[iduhandoff] … handing off to mainline …` → mainline. On the next stock visit
`/configs/handoff.log` should read `OK: last hand-off reached mainline (ack 1 > seen 0) - re-arming`.
Full state dump either side: `sh stock/verify.sh` (note: `verify.sh` will flag the `owrt_mem.dtb`
md5 as changed — that is **expected** here because of the slot-A bootargs edit).

Do **two** cold cycles to confirm the loop is self-sustaining (ack keeps incrementing untouched).

---

## Controls & rollback

| want | do |
|---|---|
| stay in stock | `touch /configs/handoff.off` (from stock, mainline, or failsafe); re-arm with `rm` |
| revert bootargs | `stock/uninstall.sh` restores `bootargs` from `/configs/bootargs.orig` |
| remove the kit | `stock/uninstall.sh --purge` then, in mainline, `mainline/uninstall.sh` |
| **full revert to bone-stock** | disarm, then reflash slot A back to stock: `zcat ~/Sand_aap321nk/mtd18_slotA_stock.gz \| ssh root@192.168.18.1 'ubidetach -m 18 2>/dev/null; dd of=/dev/mtd18 bs=1M'` (slot B stock was never touched, so even skipping this the box still cold-boots stock once disarmed) |

**Your safety net the whole way:** active slot **B** is untouched stock. As long as you never make
slot A active (this runbook never does), a disarmed box always cold-boots the original stock.

## Anti-rollback caveat (the one thing the dump can't clear)

This unit runs the **older** HJL.K95 build. All its images are validly Nokia-signed *for that
build*, and you only ever use its own images, so normal operation is fine. The single off-dump
risk: if this physical board's QFPROM anti-rollback fuses were ever advanced by a newer signed
build, secure boot could reject K95 at power-on. The dump strongly implies it boots (root keeper
ran to dump time, `boot_fail_count=0`), so this is a low-probability tail — but **on your first
power-on at the bench, watch the SBL/QSEE serial output** for any `… authentication failed` /
rollback rejection before starting §1. If you see it, stop and treat it as a fuse/secure-boot
issue, not a flash problem.

---

### One-line summary
OpenWrt → **slot A (`mtd18`/`rootfs`)** because active is B; change **one token** in the DTB
(`rootfs_1`→`rootfs`); everything else (QSEE hand-off, `idu_tool`, `desc_blob`, the whole
`~/aap321nk-handoff` flow) is **verbatim**; talk to the unit at **`192.168.18.1`**.
