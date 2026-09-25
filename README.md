# aap321nk-handoff — cold-boot mainline OpenWrt on a Nokia/Airtel AAP321NK IDU

The AAP321NK (Nokia, Airtel-branded 5G FWA indoor unit, Qualcomm IPQ5018) has fused secure boot:
SBL1 verifies QSEE/DEVCFG/APPSBL, U-Boot only autoboots the RSA-signed vendor image, and the
`kernel` UBI volume carries a second signature block for the rootfs.  There is no way to make the
signed chain boot a self-built kernel.

This kit sidesteps the chain instead of breaking it.  On a cold power cycle the **vendor's own
32-bit kernel** stages our arm64 kernel + DTB into RAM and calls the TrustZone *monitor boot*
service — the same service U-Boot uses for `bootm` — which switches the calling core to AArch64
and jumps in.  Nothing is flashed, nothing signed is modified, and one power cycle puts you back
in stock.

```
cold power cycle
   └─ PBL → SBL1 → U-Boot (signed, untouched) → vendor OpenWrt 19.07 / Linux 5.4.213   ~60 s
        └─ /etc/rc.local (restored from /configs/sysupgrade.tgz) → /opt/iduhandoff/handoff.sh
             ├─ check the ack counter / disarm flag, 4 s window, then park CPU1
             ├─ park CPU1, stage Image+DTB+descriptor into RAM, drop caches
             └─ insmod the spliced vehicle → cpsid if + cache flush + SMC 0x0200010F
                  └─ TZ switches core 0 to AArch64 → mainline OpenWrt 6.12.92 (arm64)
```

Verified on the bench unit (2026-09-22), three consecutive cold power cycles with nothing but the
relay cutting power:

| | |
|---|---|
| kernel | `Linux 6.12.92 aarch64`, `Machine model: Airtel/Nokia AAP321NK` |
| CPUs | `cpus: 0-1` — both cores (see `docs/DESIGN.md` for the `maxcpus=1` trick) |
| root | squashfs on `ubiblock0_1` + UBIFS `rootfs_data` as the **persistent** overlay (`mount_root: switching to ubifs overlay`), files survive power cycles |
| SSH / web | `ssh root@192.168.1.1` (empty password), LuCI on `:80` |
| loop | self-sustaining: mainline bumps a counter in `/configs`, the stock hook re-arms on a bump and auto-disarms if a fire never landed |
| scripts | the shipped ones were run against the unit: `stock/install.sh` (hashes verified) → `stock/fire-once.sh` → `mainline/install.sh` → arm → cold cycle → mainline `cpus=0-1`, counter bumped |

## How it works

1. **Root on stock** (`stock/rootkeep.sh`) — the vendor firmware runs `/etc/rc.local`, and
   `/etc/init.d/startup` restores `/configs/sysupgrade.tgz` over `/` early in every boot, so a
   file in that tarball is a persistent hook.  `/configs` (mtd15) and `/opt` (mtd22) are the two
   writable volumes.
2. **The service already exists.** `mtd04_QSEE.bin` is a plaintext AArch64 ELF whose SCM service
   table maps `0x0200010F → {a1=0x12, nargs=4, handler}` — U-Boot's monitor boot.  It checks only
   the descriptor size (0x50) and a one-shot flag, *not* the caller's EL or boot stage, so it is
   callable from Linux EL1.
3. **The descriptor** is 80 bytes: `{u64 F0 = DTB address, 64 zero bytes, u64 F1 = Image entry}`.
   Swapped, the TZ reads the kernel as a DTB and floods `WARN: Access Violation`.
4. **Cache/CPU/IRQ state is the hard part** (see `docs/DESIGN.md`): the staged ranges must be
   cleaned+invalidated by MVA (the TZ runs with the MMU off), the other core must be parked and
   actually offline, and IRQs must be masked across the SMC.
5. **The vehicle** is the unit's own `ptyconsole.ko` with a 164-byte payload spliced into its
   init window (`tools/splice-pty.py`), so no compiler, module loader or dependency is needed
   from the (now clobbered) stock rootfs.

Requirements, step-by-step install, and the arming procedure: **[INSTALL.md](INSTALL.md)**.

## Layout

| path | what |
|---|---|
| `kit/` | staged artifacts: `idu_tool` (+ source), the 448 MB mainline DTB — `owrt_mem.dtb` (slot B) + `owrt_mem.slotA.dtb` (slot A) + the `.dts` reference dump (`tools/make-dtb.sh` checks/patches them) — and `desc_blob.bin` |
| `payload/` | the ARM asm payload, the exit stub, and the spliced `pty_owrt2.ko` vehicle |
| `stock/` | run-on-the-unit: `install.sh`, `fire-once.sh`, `verify.sh`, `uninstall.sh`, `handoff.sh` (the hook), `rootkeep.sh` |
| `mainline/` | the arm64 half: `handoff-ack` (S00 ack writer) + `install.sh` |
| `tools/` | `extract-kernel.py` (UBI kernel volume → arm64 Image), `splice-pty.py`, `build.sh`, `make-dtb.sh`, `console.py`, `wifi-bdf-fix.sh` (restores full WiFi TX power — see `docs/WIFI-POWER-FIX.md`) |
| `docs/` | `OVERVIEW.md`, `TAKEOVER.md`, `DESIGN.md`, `FLASH-MAP.md`, `PROVENANCE.md`, `RECOVERY.md`, `WIFI-POWER-FIX.md` |

## Safety

* **Nothing signed is written.** The kit stages into RAM only; the U-Boot env change is one
  appended word (`maxcpus=1`) and `$C/bootargs.orig` records the original.
* **Escape:** `touch /configs/handoff.off` — from stock, from mainline, or from the failsafe
  shell (`docs/RECOVERY.md`); later boots then stay in stock.  Re-arm with `rm`.  A keypress in
  the 4 s window also disarms, but only while the console is free: once stock is up the vendor's
  console owner consumes every byte (measured — `dd`/`read`/`cat` see 0 while the tty echoes), so
  treat the U-Boot prompt or the disarm flag as the way in.
* **Watchdog:** if a hand-off ever hangs the TZ, the box resets into stock and the hook
  auto-disarms on the next boot rather than looping.  See `docs/RECOVERY.md`.
* **Credentials:** the mainline image in this port ships with an *empty* root password and
  `stock/rootkeep.sh` sets the stock root password every minute (`Nok@123` unless `ROOTKEEP_PW`
  says otherwise) — change both before putting a unit anywhere but a bench.
* Staging clobbers ~14 MB of live RAM on purpose — a busy stock userspace can crash *during*
  staging.  That is harmless (the SMC follows within a second) but it looks alarming on the
  console.

## Caveats

* Built for this model and this stock firmware (kernel `5.4.213`, OpenWrt 19.07-SNAPSHOT
  `ipq50xx_32`): the vehicle module, the mtd layout and the QSEE service table are all
  firmware-specific.  It is not a generic IPQ5018 trick.
* Stock still boots first for ~60 s; that is the price of leaving the signed chain intact.
* The auto-disarm path is logic-verified but has not been exercised by a real TZ hang.
* Both cores only come up if nothing onlined CPU1 in stock: a parked (AArch32 `CPU_OFF`) core
  cannot be revived by mainline's AArch64 PSCI.  The hook parks one only when it is actually
  running.

## License / provenance

GPL-2.0 (`LICENSE`).  Every artifact here was produced by reverse-engineering this unit and
building OpenWrt for it; there is no vendor code except the deliberately patched `pty_owrt2.ko`
vehicle and the kernel Image extracted from the unit's own flash — see
[docs/PROVENANCE.md](docs/PROVENANCE.md).
