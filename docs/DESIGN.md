# DESIGN — why this works, and what it depends on

## 1. The chain we do *not* touch

```
PBL → SBL1 (RSA: QSEE, DEVCFG, APPSBL) → U-Boot 2016.01 → TZ do_boot_signedimg → vendor Linux 5.4.213
                                            │                                    (armv7l)
                                            └─ autoboot ignores `bootcmd`; it reads the `kernel`
                                               UBI volume, checks the FIT hashes, then hands TZ a
                                               buffer whose 0x28-byte header carries the image
                                               pointers + an RSA signature, and a second
                                               signature block for the rootfs (6,440 B trailer)
```

Everything above is signed and verified with fused keys, so a self-built kernel cannot enter
through it.  But the *last* step — "switch to the kernel in this buffer" — is a TrustZone
service, and services answer their callers.

## 2. The service

`mtd04_QSEE.bin` is a plaintext AArch64 ELF (`entry 0x4ac00000`).  Its SCM service table sits at
file offset `0x86b2c` as 24-byte records `{fnid, expected_a1, nargs, handler, 0, 0}`:

| fnid | a1 | nargs | handler | what |
|---|---|---|---|---|
| `0x0200010F` | `0x12` | 4 | `0x4ac26ef8` | monitor boot — the one U-Boot calls for `bootm` |
| `0x02000118` | `1` | 0 | `0x4ac4d67c` | second BOOT-service command (unused here) |

Handler `0x4ac26ef8` validates exactly two things: the descriptor **size == 0x50**, and a one-shot
flag (`0x4acb0e78`, cleared every boot).  There is **no** check of the caller's exception level,
boot stage or image signature — a Linux EL1 caller is accepted just like U-Boot.  A wrong `a1`
is rejected with `-5`, a second call in the same boot with `-13`.

```
SMC 0x0200010F  a1=0x12  a2=<descriptor PA>  a3=0x50  r6=<scratch PA>
descriptor (80 B):  u64 F0 = DTB address
                    64 zero bytes
                    u64 F1 = kernel entry (Image + text_offset)
```

Swapping F0/F1 makes the TZ parse kernel text as a DTB: ten `WARN: Access Violation!!!` lines and
no boot — good evidence for which way round it goes.

## 3. What the caller must get right

The TZ jumps with the MMU **off** on the calling core, so the caller's caches are the only copy
of the staged image.  The payload (`payload/pj_owrt2.s`, 164 B) therefore:

1. `cpsid if` — mask IRQ/FIQ.  An interrupt during/after the hand-off executes 32-bit vectors on
   a core about to become AArch64.
2. `ICIALLU`, then clean+invalidate **by MVA** (`DCCIMVAC`, `c7,c14,1`) over exactly the staged
   ranges — `0x84000000..0x86000000`, `0x88c00000..0x88c08000`, `0x88d00000..0x88d01000`, i.e.
   physical + `PAGE_OFFSET 0x40000000` (confirmed by `_stext == 0x80300000`).
3. `smc #0` with the arguments above and a scratch pointer, exactly as U-Boot passes them.

Requirements outside the payload:

* **No other core may be running** across the switch.  A core still executing the 32-bit kernel
  takes a bogus PSCI call and panics the box out of the hand-off (`Comm: swapper/1 …
  __invoke_psci_fn_smc … Code: bad PC value`), so an *online* secondary has to be parked — but a
  core the 32-bit kernel `CPU_OFF`s can never be revived by AArch64 PSCI, so parking costs SMP.
  Boot the stock side with **`maxcpus=1`** (what `stock/install.sh` sets) and the secondaries never
  run at all: they stay in reset, nothing needs parking, and mainline brings both up
  (`CPU1: Booted secondary processor`).  The hook therefore parks a core **only if it is online**
  — which is why something onlining CPU1 in stock silently costs you a core in mainline.
* **The Image must be at the start of the RAM range the DTB declares** (`text_offset = 0`), and
  the DTB must declare enough RAM: `/memory = <0x0 0x44000000 0x0 0x1c000000>` (448 MB).  The
  original port DTB's 80 MB produced `Kernel panic - not syncing: System is deadlocked on memory`.
* **The command line must be inside the DTB.**  `bootargs-append` is a U-Boot concept; the TZ
  path applies none of it, so `/chosen/bootargs` must already contain
  `ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs rootwait …`.
* **`/opt` must be readable when the hook runs**, and it is not mounted at S20 — hence the
  background waiter in `/etc/rc.local` that polls for `/opt/iduhandoff/handoff.sh`.

**Staging is destructive by design.** `idu_tool stage` `pwrite()`s 13.8 MB at `0x44000000` and the
DTB/descriptor at `0x48c00000`/`0x48d00000` — live RAM belonging to the vendor userspace.  That is
why `stage`+`fire` are executed back-to-back (~1 s) from a **static** binary
(`squashfs metadata cache goes bad → EIO → nothing on the rootfs can be executed any more`) and
why a busy stock userspace occasionally dies during staging.  It does not matter: the SMC follows
immediately, and if it does not, the box resets into stock.

## 4. The vehicle

The payload must run in kernel context (EL1) in 32-bit mode, so a kernel module is the natural
carrier.  Building one against the vendor kernel is not possible; instead the unit's own
`ptyconsole.ko` is patched:

* `tools/splice-pty.py` finds `init_module`/`cleanup_module` through the module struct's
  relocations, writes the payload into that window (164 B into a much larger function), rewrites
  every relocation that lands inside the window to `R_ARM_NONE` (the payload is position
  independent and calls nothing), and drops an 8-byte `mov r0,#0; bx lr` into `cleanup_module`.
* `idu_tool fire` loads it with `finit_module()` from a file already copied to `/tmp` — the
  module loader needs no compiler, no dependencies and no readable rootfs.

Unloading is impossible (the SMC does not return on success) and unnecessary: the stock kernel is
about to stop existing.  On failure the module has already run and cannot be removed; the box
resets, which clears everything.

## 5. The ack protocol (why the loop is self-sustaining and safe)

A fire either lands in mainline or hangs the TZ until the watchdog resets the box back into stock.
Both look identical from stock's point of view, so the hook needs hard proof of the first case:

* **mainline half** — `/etc/init.d/handoff-ack` (`START=00`, persisted in the overlay) attaches
  the vendor **cfg** volume (mtd15) and increments `/configs/handoff.ack` *at every boot*.
* **stock half** — `handoff.sh` compares `handoff.ack` with the last value it saw
  (`handoff.ack_seen`).  A pending fire (`handoff.fired`) whose counter moved ⇒ the last hand-off
  reached mainline ⇒ clear the flag and **fire again** (this is what makes every cold cycle end in
  mainline).  A pending fire whose counter did **not** move ⇒ the fire hung the TZ ⇒
  **auto-disarm** and stop, instead of resetting forever.

The counter deliberately lives in the vendor's cfg volume and not in mainline's own overlay:
mainline's `mkfs.ubifs` formats `rootfs_data` with **zstd**, and the vendor's 5.4 kernel has no
zstd — `UBIFS error: compressor "zstd" is not compiled in` — so stock cannot read mainline's
overlay at all.

Traps found the hard way, all encoded in the scripts:

* `dmesg | grep -i watchdog` is **not** a failure signature on this box: stock's normal boot logs
  `procd: - watchdog -`, so a v5 hook disarmed itself after every successful fire and the
  hand-off "randomly stopped working".
* Serial input is **not** broadcast: with stock up, the vendor's console owner consumes every byte
  (`dd`/`read`/`cat` all get 0 while the tty echoes), so a keystroke escape only works while the
  console is free.  Relatedly, `read -t N < /dev/console` never times out on this busybox
  (v1.35.0) — the hook would block in the tty read and never fire again — so the window is a
  `sleep` with killer children.
* A truncated `/configs/sysupgrade.tgz` is fatal and invisible: the vendor's restore does
  `tar … && rm`, which never removes a corrupt archive, so the hook (and root+ssh) silently never
  comes back.  Build the tarball to `.new`, verify with `tar tzf`, then `mv`.

## 6. Measured behaviour (bench unit, 2026-09-22)

| phase | time |
|---|---|
| PBL → U-Boot ribbon → vendor userspace → `S95done` (rc.local) | ~55–60 s |
| hook: key window + CPU1 park | ~6 s |
| staging + verify | < 1 s |
| SMC → mainline banner | < 1 s |
| mainline → ssh reachable | ~15–20 s |

One-way costs, all inherent: the signed chain has to boot before anything of ours can run.
