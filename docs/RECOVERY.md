# RECOVERY — getting back, and staying out of trouble

Nothing in this kit writes a signed partition, so there is no brick state to recover from: the
unit can always be made to boot stock again.  The ladder, cheapest first.

## 1. The 4-second window (best effort, not the normal escape)

On every cold boot the hook prints

```
iduhandoff: handing off to mainline in 4s (disarm: touch /configs/handoff.off)
```

and watches the console for a keypress.  On this unit that almost never fires: serial input is not
broadcast — the vendor's console owner consumes every byte once stock is up, so a second reader sees
nothing (`dd`, `read` and `cat` all measured 0 bytes while the tty still echoed the characters).
It does work while the console is free (failsafe, very early boot).  Use §2 or §4 instead, and note
the hook is careful about the window: `read -t` never times out on this busybox (v1.35.0), so the
window is a `sleep` with a killer child — otherwise the box would silently stop firing.

## 2. Disarm from either side

```sh
touch /configs/handoff.off    # stock: mtd15, mounted as /configs
                              # mainline: ubiattach -m 15; mount -t ubifs ubiN:cfg /mnt/cfg
```

Every later boot then stays in stock, whatever else is installed.  Re-arm with `rm`.

## 3. Auto-disarm (when something is broken)

If a fire hangs the TZ, the box watchdog-resets into stock and the hook disarms itself on the next
boot (`AUTO-DISARM: last hand-off never reached mainline` in `/configs/handoff.log`).  It never
loops.  Read the log — it names the reason:

```sh
tail -20 /configs/handoff.log
```

## 4. No shell at all: the serial console

The console is 115200 8N1 on the unit's UART.  Bridge it and keep it readable:

```sh
socat -d -d /dev/ttyUSB0,b115200,raw,echo=0 TCP-LISTEN:4600,reuseaddr,fork
./tools/console.py                  # watch
./tools/console.py 'fw_printenv'    # type
```

Then, in order:

* **U-Boot prompt** — hit a key during the ribbon (`NOKIA >`), password `airtelroot12` → an
  `IPQ5018#` prompt.  From there `bootipq` boots the signed vendor image by hand.  (Do **not**
  expect `bootcmd`, `booti` or a UBI write of yours to autoboot: `bootcmd` is ignored, and the
  `kernel` volume carries a rootfs signature block beside the kernel's.)
* **Stock failsafe** — start a normal boot and spam `f` during preinit: `root@(none):/#`.
  `/` is read-only here; mount what you need under `/tmp`:

  ```sh
  D=$(ubiattach -m 15 2>&1 | sed -n 's/.*UBI device number \([0-9]*\).*/\1/p')
  mkdir -p /tmp/c && mount -t ubifs ubi${D}:cfg /tmp/c     # or ubi${D}_0 by id
  cat /tmp/c/handoff.log
  ```

  From here you can repair the persistent state: fix `/tmp/c/rootkeep.sh`, delete a corrupt
  `sysupgrade.tgz`, or `touch /tmp/c/handoff.off`.  **`sync` before pulling power** — a hard cut
  makes the UBIFS journal replay discard unsynced writes, which is how the tarball goes to
  0 bytes in the first place.

## 5. Broken persistent state (the classic)

Symptom: boots always land in stock, no `[iduhandoff]` breadcrumbs on the console, ssh gone.
Cause: `/configs/sysupgrade.tgz` missing or truncated — the vendor's restore does `tar … && rm`
and will not clean a bad archive, so `/etc/rc.local` and the crontab never come back.

Fix (failsafe shell or stock ssh):

```sh
# rebuild from what is on the box right now
mkdir -p /tmp/t/etc/crontabs
printf '* * * * * /configs/rootkeep.sh\n' > /tmp/t/etc/crontabs/root
cp /etc/rc.local /tmp/t/etc/            # or re-run stock/install.sh, which rewrites it
( cd /tmp/t && tar czf /tmp/c/sysupgrade.tgz.new etc ) && tar tzf /tmp/c/sysupgrade.tgz.new
mv /tmp/c/sysupgrade.tgz.new /tmp/c/sysupgrade.tgz && sync
```

`stock/install.sh` does exactly this, verified and atomic, so re-running it is the easy answer.

## 6. Mainline-side surprises

* **Both cores up but the box wedges** — the stock side booted without `maxcpus=1`
  (`fw_printenv bootargs`); fix it in stock.
* **`rootfs_data` will not mount in stock** — expected, it is zstd-formatted by mainline
  (`UBIFS error: compressor "zstd" is not compiled in`).  Mainline itself is fine.
* **Want mainline's overlay gone** (fresh config): in mainline `ubirmvol` / reformat from
  `mount_root`'s first-boot path, or simply delete files under `/overlay/upper` and reboot.
* **Editing mainline's `/etc` from stock is impossible** for the same zstd reason — do it from
  mainline, or use the vendor `cfg` volume for anything both sides must see.

## 7. Returning the unit to a plain vendor state

1. `touch /configs/handoff.off` (disarm) — or full `stock/uninstall.sh [--purge]`, and
   `mainline/uninstall.sh` while in mainline.
2. Confirm `fw_printenv bootargs` no longer carries `maxcpus=1` (the original is in
   `/configs/bootargs.orig`).
3. Slot B still holds our OpenWrt; it is simply never booted.  To reclaim the space or reflash the
   vendor's slot-B image, use U-Boot (`bootipq` boots slot A regardless) and the vendor's own
   flashing path — this kit neither needs nor blocks it.
