# PROVENANCE — what is original here, what is derived, what is not shipped

Written while reverse-engineering one bench unit (Nokia/Airtel AAP321NK, IPQ5018, stock kernel
5.4.213 / OpenWrt 19.07-SNAPSHOT `ipq50xx_32`, fw dated 2025-02-28).  Every claim in
`docs/DESIGN.md` was measured on that unit; hashes below are the artifacts this repo ships.

## Original work (GPL-2.0, this repo)

| artifact | md5 | notes |
|---|---|---|
| `kit/idu_tool.c` / `kit/idu_tool` | `88e3954177b6451ee5d3a6a6a8af78f3` | static ARM stager/firer, written for this job |
| `payload/pj_owrt2.s` / `.bin` | — / 164 B | cache-flush + SMC payload |
| `payload/exitnop.s` | — | 8-byte `mov r0,#0; bx lr` exit stub |
| `kit/desc_blob.bin` | `70efe97ba0dfd18960c73ca21f8ec72a` | 80-byte descriptor |
| `kit/owrt_mem.dtb` (slot B) / `owrt_mem.slotA.dtb` | `25788e43ac5bf3e1f62b84a7b0ebc047` / `1bd363de013324b09f0ffe40d09a0c90` | **mainline** DTB — 172 nodes, `ethernet@39c00000`/`ethernet@39d00000`, 448 MB `/memory`, merged `/chosen/bootargs`; the two differ only in `ubi.mtd=rootfs_1` vs `rootfs`. `kit/owrt_mem.dts` is a **reference dump** of the slot-B blob — never recompile it (the old vendor-flavoured pair gave a kernel with **no Ethernet**). |
| `stock/handoff.sh`, `stock/rootkeep.sh`, `stock/*.sh` | `9fa54ccc…` (hook) | the hook and helpers |
| `mainline/handoff-ack`, `mainline/install.sh` | — | ack writer |
| `tools/*` | — | extractor, splicer, console client |

The QSEE analysis (service table at file offset `0x86b2c`, handler `0x4ac26ef8`, the one-shot flag
at `0x4acb0e78`, descriptor semantics) is original reverse engineering of the unit's own
`mtd04_QSEE.bin`, which is **not** redistributed here.

## Derived from the unit (shipped, with caveats)

| artifact | what it is |
|---|---|
| `payload/pty_owrt2.ko` (4,092 B, `9e30e1e8efef6d12a54ad823a6ac00be`) | the unit's own vendor kernel module `ptyconsole.ko` with a 164-byte payload spliced into `init_module` and an 8-byte stub into `cleanup_module`.  It is **vendor binary code with our patch**, included because it is what actually runs.  Prefer rebuilding it from your own unit: `VEHICLE=/path/to/ptyconsole.ko tools/build.sh`, or `tools/splice-pty.py`. |
| `kit/owrt_Image` (13,836,296 B, `8da349d50ac5cba1c0d9600903c1f2be`) | **not shipped** (size).  It is the arm64 kernel built for the OpenWrt port on this unit, extracted from slot B's `kernel` volume — see `INSTALL.md` phase 1.  Get it from your own flash or from your build of the port. |

Nothing else on the unit is redistributed: no vendor rootfs, no QSEE/APPSBL blobs, no firmware
images, no vendor config volumes.

## Third-party

* OpenWrt (GPL-2.0) — the mainline side is an OpenWrt build for this board; the port's DTS is
  derived from the vendor's device tree in the usual OpenWrt way.
* `tools/splice-pty.py` needs [pyelftools](https://github.com/eliben/pyelftools) (public domain /
  UPL) to run.
* U-Boot 2016.01 is referenced only as behaviour (how it calls `0x0200010F`, what it puts in the
  descriptor); no U-Boot code is included.

## Not affiliated

This is independent interoperability work on hardware the author owns.  Nokia, Airtel and Qualcomm
are trademarks of their owners; no vendor code or endorsement is implied.
