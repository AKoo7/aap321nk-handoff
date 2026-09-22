# INSTALL — AAP321NK cold-boot hand-off

Two halves, both idempotent: the **stock half** (hook + kit) and the **mainline half** (the ack
writer).  The installer leaves the hand-off *disarmed*; you arm it at the end.

Throughout, `unit` = the AAP321NK's stock address (`root@192.168.1.1`, password `changeme` with
`stock/rootkeep.sh` installed, *empty* password in mainline OpenWrt).

---

## Phase 0 — prerequisites

**On the unit**

| need | check |
|---|---|
| AAP321NK (Nokia, IPQ5018) with stock firmware intact | `uname -r` → `5.4.213`, `uname -m` → `armv7l` |
| root shell on stock | `ssh root@unit 'id'` → `uid=0`; if not, install [`stock/rootkeep.sh`](stock/rootkeep.sh) first |
| our arm64 OpenWrt flashed in **slot B** (mtd19 `rootfs_1`) | `ubiattach -m 19; ubinfo /dev/ubi0` → volumes `kernel`, `rootfs`, `rootfs_data` |

Slot B is where the port's squashfs lives; this kit only *boots* it, it does not flash it.  If
`rootfs` is not there yet, complete the OpenWrt port/flash step first.

**On the host**

```sh
python3 --version            # tools/extract-kernel.py
dtc --version                # only for tools/make-dtb.sh
```

**Power cycling.**  A cold power cycle is the test.  A USB/relay-switched socket is ideal (the
bench rig used `http://<relay-host>/restart?seconds=8&token=…`); a mains switch works the same.

⚠️ **192.168.1.1 is not unique.** Several Airtel units default to it and the home LAN may route
you to the wrong one — always confirm you are on the unit's own link (`ip neigh` → the MAC you
recorded; the bench unit showed `bc:51:5f:c8:b3:xx` in mainline, `…:13` in stock).

---

## Phase 1 — artifacts

The 13.8 MB kernel is **not** shipped: extract it from the unit's own slot-B `kernel` volume (or
take it from your OpenWrt build).

```sh
# 1. dump slot B's kernel volume on the unit
ssh root@unit 'D=$(ubiattach -m 19 2>&1 | sed -n "s/.*UBI device number \([0-9]*\).*/\1/p"); \
               dd if=/dev/ubi${D}_0 of=/tmp/slotb_kvol.bin bs=4096 2>/dev/null; ubidetach -d $D'
scp -O root@unit:/tmp/slotb_kvol.bin /tmp/

# 2. pull the arm64 Image out of the FIT
python3 tools/extract-kernel.py /tmp/slotb_kvol.bin kit/owrt_Image
#  want: extracted 13836296 bytes … md5 8da349d50ac5cba1c0d9600903c1f2be

# 3. sanity check the rest of the kit against the shipped hashes
md5sum -c MANIFEST.md5
```

---

## Phase 2 — stock half, and a test fire

```sh
scp -O -r kit payload stock mainline root@unit:/tmp/      # scp -r will not create /tmp/kit for you
ssh root@unit 'sh /tmp/stock/install.sh /tmp'
```

What the installer does: copies the kit to `/opt/iduhandoff` (user_data), writes the
`/etc/rc.local` launcher, appends the keeper line to `/etc/crontabs/root`, refreshes
`/configs/sysupgrade.tgz` (this is what makes `/etc` survive a boot — see `docs/DESIGN.md`),
appends `maxcpus=1` to the U-Boot `bootargs` (recording the original in
`/configs/bootargs.orig`) and leaves the hand-off **disarmed** (`/configs/handoff.off`).

Fire it once by hand — this is the whole mechanism, minus rc.local:

```sh
ssh root@unit 'sh /tmp/stock/fire-once.sh'
```

Expect the SSH session to die and, on the serial console:

```
hand-off in 4 s - press Ctrl-C for stock
online cpus: 0 (waited 0)
staged owrt_Image  -> 0x44000000  13836296 bytes
staged owrt_mem.dtb -> 0x48c00000  27078 bytes
staged desc_blob.bin -> 0x48d00000  80 bytes
image         0x44000000: ok
dtb           0x48c00000: ok
descriptor    0x48d00000: ok
firing...
[    0.000000] Booting Linux on physical CPU 0x0000000000
[    0.000000] Linux version 6.12.92 (…) aarch64
[    0.068454] CPU1: Booted secondary processor 0x0000000001
[    2.808169] VFS: Mounted root (squashfs filesystem) …
[   49.111564] mount_root: switching to ubifs overlay
```

Then `ssh root@unit 'uname -m'` → `aarch64`.

**If you land back in stock**, the TZ call did not take: check `dmesg | tail`, the console, and
`docs/RECOVERY.md`.  Do not proceed to arming until a manual fire works.

---

## Phase 3 — mainline half (do this in the same mainline session)

The mainline root is a different filesystem, so copy the mainline half again:

```sh
scp -O -r mainline root@unit:/tmp/
ssh root@unit 'sh /tmp/mainline/install.sh /tmp'
```

It installs `/etc/init.d/handoff-ack` + `S00` symlink, runs it once, and prints the counter it
read back:

```
handoff-ack: bumped to 1
  handoff.ack = 1
```

`/etc` here is the persistent overlay, so the service survives every future boot.  Each mainline
boot bumps `/configs/handoff.ack`; that bump is the only proof the stock hook accepts.

---

## Phase 4 — arm it and verify a cold cycle

```sh
# back in stock (power cycle without the hook: hand-off is still disarmed)
ssh root@unit 'rm /configs/handoff.off && sync && cat /configs/handoff.log | tail -3'
```

Now cut the power cold and let it run, hands off.  In stock you should see:

```
[iduhandoff] rc.local RAN
[iduhandoff] /configs visible -> starting keeper
[iduhandoff] running hook
iduhandoff: handing off to mainline in 4s (disarm: touch /configs/handoff.off)
iduhandoff: handing off to mainline arm64 OpenWrt...
```

and then mainline, as in phase 2.  After that boot, `/configs/handoff.log` on the next stock
visit should show the loop closing:

```
OK: last hand-off reached mainline (ack 1 > seen 0) - re-arming
```

Run `sh stock/verify.sh` on either side for a full state dump (flags, counter, hashes, log tail).

### Controls

| action | effect |
|---|---|
| any key during the 4 s window | disarms — best effort only: with stock up the vendor's console owner eats the input (works in failsafe/early boot) |
| `touch /configs/handoff.off` (either side) | disarm; later boots stay in stock |
| `rm /configs/handoff.off` | arm again |
| a fire that never reaches mainline | auto-disarm (no reset loop) |

### Uninstall

```sh
sh stock/uninstall.sh            # disarm, drop the launcher, restore bootargs
sh stock/uninstall.sh --purge    # …and delete /opt/iduhandoff
# then, in mainline:
sh mainline/uninstall.sh
```

---

## Troubleshooting

| symptom | cause / fix |
|---|---|
| cold boot lands in stock, `handoff.off` present | it disarmed — read `handoff.log` for the reason (a fire that never landed, or a pressed key) |
| cold boot lands in stock, no `[iduhandoff]` lines on the console | `/configs/sysupgrade.tgz` missing/corrupt, so `/etc/rc.local` was not restored → re-run `stock/install.sh` |
| hook runs but the box resets ~90 s later, `dmesg` has no `panic` | the TZ hang: fire failed; check staging hashes and that CPU1 was really offline |
| `MISMATCH` from `idu_tool verify` | staging clobbered or truncated — re-copy `kit/*` from the host, re-run |
| mainline panics on CPU1 (`bad PC value`) | `maxcpus=1` missing from the stock bootargs (`fw_printenv bootargs`) |
| mainline comes up with one CPU (`cpus: 0`) | something onlined CPU1 in stock before the fire; the hook had to park it, and an AArch32 `CPU_OFF` cannot be revived by AArch64 PSCI.  Leave CPU1 alone in stock |
| mainline: `System is deadlocked on memory` | DTB declares too little RAM — use the shipped `owrt_mem.dtb` (448 MB) |
| mainline has no `root=` / drops to a panic | the DTB's `/chosen/bootargs` is not the merged one (`tools/make-dtb.sh`) |
| `ssh: Connection refused` at 192.168.1.1 | you are talking to a different Airtel unit — check the MAC on your own link |
| mainline booted but `/etc` changes vanish | overlay not mounted (`mount \| grep overlay`); the volume must be `ubi0:2 rootfs_data` |
