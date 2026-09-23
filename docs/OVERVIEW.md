# OVERVIEW — how the cold-boot handoff works

A one-page tour of the mechanism. For the full rationale and what each step depends on see
[DESIGN.md](DESIGN.md); for the flash layout see [FLASH-MAP.md](FLASH-MAP.md); to get back to
stock see [RECOVERY.md](RECOVERY.md).

## The problem
The AAP321NK (Nokia/Airtel IDU, Qualcomm IPQ5018) has *fused* secure boot: SBL1 verifies
QSEE/DEVCFG/APPSBL, U-Boot only autoboots the RSA-signed vendor image, and the `kernel` UBI
volume carries a second signature for the rootfs. There is no way to make the signed chain boot
a self-built kernel.

## The trick — ride on top of the chain, don't break it
The vendor's own *signed* 32-bit kernel boots normally, then from userspace stages our arm64
OpenWrt kernel + DTB into RAM and calls a TrustZone "monitor boot" SMC — the same service
U-Boot's `bootm` uses. TZ switches the calling CPU core to AArch64 and jumps into our kernel.
No reboot, nothing signed is modified.

## Boot chain (cold power → our OpenWrt), ~2 min

```
cold power cycle
  → SBL1 → U-Boot → vendor signed 5.4 kernel boots (~60 s)
      → /etc/rc.local hook (S95)
          → if /configs/handoff.off exists → stay in stock
          → else: stage Image+DTB+descriptor into RAM, flush caches, fire the SMC
              → TZ switches CPU0 to AArch64 → our OpenWrt boots (~60 s)
```

## The SMC
`SMC 0x0200010F` (a1 = `0x12`) with an 80-byte descriptor =
`{u64 DTB phys addr, 64 zero bytes, u64 kernel entry}`. `idu_tool` pwrites the raw arm64 Image →
`0x44000000`, DTB → `0x48C00000`, descriptor → `0x48D00000` via `/dev/mem`; a small kernel module
(`pty_owrt2.ko`) masks IRQs, cleans + invalidates the D-cache over those ranges (U-Boot runs
cache-off, Linux does not — stale lines would boot garbage), then fires. On success it never
returns; the new kernel brings up its own UART.

## What's where on flash
| piece | location |
|---|---|
| Stock (signed) firmware | untouched — always the fallback |
| Our OpenWrt (squashfs + ubifs overlay) | NAND **slot B** (`mtd19` / `rootfs_1`), booted `root=/dev/ubiblock0_1` |
| The kit (`idu_tool`, `owrt_Image`, `owrt_mem.dtb`, `desc_blob.bin`, `pty_owrt2.ko`, hook) | stock side, `/opt/iduhandoff` (`mtd22`) |

`owrt_mem.dtb` is our DTB with `/memory` widened to 448 MB and the full command line merged into
`/chosen` (the TZ handoff applies no bootargs of its own).

## Why it self-sustains and can't brick-loop
Every time our OpenWrt boots, an `S00` service bumps a counter `/configs/handoff.ack` in the
vendor `cfg` volume. On the next cold boot the stock hook fires **only if that counter moved** —
proof the previous handoff actually reached mainline. If a fire ever hangs the TZ (counter
unchanged), the hook **auto-disarms** instead of looping into resets.

## Escape hatches (back to stock)
- `touch /configs/handoff.off` (from stock, mainline, or failsafe) → next boot stays in stock;
  `rm` to re-arm.
- U-Boot console (`en` + password) → interactive `bootm` / `tftpboot`.
- Consecutive fires that never reach mainline → automatic disarm.
