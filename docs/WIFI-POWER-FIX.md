# WiFi TX-power fix — "the signal is almost dead"

**Applies to:** AAP321NK units running the mainline OpenWrt image.
**Symptom:** WiFi range is far worse than the stock firmware. 5 GHz especially — a phone a few
metres away sees a nearly dead signal, even with the AP set to its maximum transmit power.
**Cause:** our image ships the **generic upstream WiFi board files**, which clamp the radios'
power. It is not your configuration, and no `txpower` setting can override it.
**Fix time:** about 3 minutes, plus one reboot.

---

## 1. Check whether you have it

SSH to the unit (`root@192.168.1.1`, no password on a fresh install) and run:

```sh
iwinfo phy1-ap0 info | grep Tx-Power     # 5 GHz
iwinfo phy0-ap0 info | grep Tx-Power     # 2.4 GHz
```

| reading | meaning |
|---|---|
| **5 GHz = 22 dBm, 2.4 GHz = 27 dBm** | you have the bug — apply the fix |
| **5 GHz = 30 dBm, 2.4 GHz = 30 dBm** | already fixed, nothing to do |

If an interface is missing, that radio is still disabled — enable it and retry:

```sh
uci set wireless.radio1.disabled=0; uci set wireless.default_radio1.disabled=0
uci commit wireless; wifi reload
```

> The stock image ships both radios **disabled**, so on a fresh install there is no WiFi at all
> until you turn it on. That is expected, and separate from this bug.

## 2. Apply the fix

The vendor's proper board files are still on your unit, inside the **stock firmware's `wifi_fw`
volume on the other slot**. The script pulls them from there and installs them — it does not
download anything, and it does not need the internet.

```sh
scp -O tools/wifi-bdf-fix.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'sh /tmp/wifi-bdf-fix.sh'
```

Expected output ends with `[ok]` lines and a reminder to reboot:

```
  [ok]   mounted (squashfs)
  [ok]   2.4 GHz: bdwlan.b24
  [ok]   5 GHz:   qcn6122/bdwlan.b60
  [ok]   5 GHz board.bin installed (md5 verified)
  [ok]   2.4 GHz board.bin installed (md5 verified)
```

Then **reboot — this is required**:

```sh
ssh root@192.168.1.1 'reboot'
```

`wifi reload` is **not** enough: the driver reads the board file once, when it probes the radio
at boot.

## 3. Verify

After the unit is back (it boots stock first, then hands off to OpenWrt — give it ~3 minutes):

```sh
iwinfo phy1-ap0 info | grep Tx-Power     # want 30 dBm (was 22)
iwinfo phy0-ap0 info | grep Tx-Power     # want 30 dBm (was 27)
```

That is **+8 dB on 5 GHz — about 6× the radiated power**, and 2× on 2.4 GHz. Range should now
match or beat stock.

## 4. If it goes wrong

Originals are kept in `/root/bdf-backup/` (the first run's copies are never overwritten):

```sh
Q=/lib/firmware/ath11k/QCN6122/hw1.0
I=/lib/firmware/ath11k/IPQ5018/hw1.0
cp -f /root/bdf-backup/5g.board.bin      $Q/board.bin
cp -f /root/bdf-backup/5g.board-2.bin    $Q/board-2.bin
cp -f /root/bdf-backup/24g.board.bin     $I/board.bin
cp -f /root/bdf-backup/24g.board-2.bin   $I/board-2.bin
sync; reboot
```

If the script reports `no 'wifi_fw' volume found`, the stock firmware is no longer on the unit,
so the vendor files cannot be recovered from it. Nothing is changed in that case — the unit keeps
working, just with the weaker limits. Tell us, and we will send you the files.

## 5. Good to know

* **160 MHz on channel 36 is not broken.** A 160 MHz channel on ch36 spans ch36–64, which
  includes the DFS channels 52–64, so the AP must do a ~60 second radar check before it may
  transmit. During that minute it is silent — `Tx-Power: 0 dBm`, and the SSID is not broadcast
  yet. Wait it out; it comes up on its own at full power. The image default (80 MHz on ch36) has
  no such wait and is what we recommend unless you specifically need 160 MHz.
* **160 MHz on channel 149 and above is genuinely not allowed** — the regulatory database marks
  those channels `NO_160MHZ`. Selecting 160 MHz there leaves the radio silent permanently. Use
  80 MHz, or a lower channel.
* Your radio calibration data is per-unit and was already correct; this fix is only about the
  board/power file.
