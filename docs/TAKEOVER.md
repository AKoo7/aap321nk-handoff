# TAKEOVER — what happens to the stock kernel at hand-off

Short version: the stock kernel does **not** *exit*. There is no shutdown, no `reboot`, no
teardown. It is **abandoned in place and overwritten**. This note explains the mechanics, because
"does the stock kernel exit?" is the first thing everyone asks.

## CPU0 is hijacked mid-instruction
At the moment of hand-off the stock (vendor, AArch32) kernel is running our payload module, which:

1. masks IRQs (`cpsid if`),
2. cleans + invalidates the D-cache over the staged RAM ranges, then
3. executes `SMC 0x0200010F` (a1 = `0x12`).

That SMC traps into TrustZone, and the TZ **switches the calling core from AArch32 to AArch64 and
jumps to our kernel's entry point**. The SMC *never returns*. The stock kernel's execution on CPU0
simply stops at the call site — it does not run another instruction. It is not paused, saved, or
cleanly exited; the core it was living on now runs our kernel.

## Its RAM is reclaimed
Our arm64 kernel was staged at `0x44000000`, and its DTB declares `/memory = 0x44000000 +
0x1c000000` (448 MB). As it boots it builds its own page tables and reuses that RAM — the stock
kernel's code, data and structures become stale bytes that get overwritten. The stock kernel is
not "running in the background"; it is dead.

## No orphaned cores
Stock is booted with `maxcpus=1`, so CPU1/CPU2 are never onlined — they sit in reset the whole
time. Our kernel then PSCI-`CPU_ON`s them itself, which is how we reach `cpus: 0-1`. There is no
second core still executing stock code.

> This is *why* the design uses `maxcpus=1` rather than hot-unplugging a running core: a core you
> `CPU_OFF` from AArch32 cannot be revived by AArch64 PSCI, so it would be lost for good.

## Consequences

- **It is one-way.** There is no path back to *that* stock instance. The only route to stock is a
  full reboot / power cycle, which re-runs SBL → U-Boot → stock from scratch.
- **It is not kexec.** kexec is Linux orchestrating a clean handoff of its own resources. Here the
  stock kernel does nothing of the sort — it calls a TZ service and gets replaced. The IRQ-mask +
  cache-flush before the SMC are exactly what make that abrupt takeover safe: otherwise the new
  kernel would read stale cache lines, or a stray interrupt would land in a half-torn-down handler.
- **On failure it is the opposite.** If the SMC does *not* take (TZ hangs or rejects the request),
  the call *returns* and stock **keeps running**. That is the fallback the boot hook relies on: it
  later sees the `/configs/handoff.ack` counter did not move and auto-disarms, instead of looping
  into resets. So "stock continues" is the *failure* signature.

## Why the console is decisive
A real hand-off prints our `Linux version 6.18.x …` banner with **no SBL/U-Boot output before it**.
That absence is the proof: it was a CPU-mode switch out of the still-running stock kernel, not a
reboot. If you see SBL1/U-Boot lines first, the SMC did not take and stock (or a watchdog reset)
brought the box back.

---
See also: [OVERVIEW.md](OVERVIEW.md) (the whole mechanism in one page) and
[DESIGN.md](DESIGN.md) (the service, the descriptor, and what the caller must get right).
