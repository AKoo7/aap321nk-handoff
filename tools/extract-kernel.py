#!/usr/bin/env python3
"""Extract a kernel Image out of a dumped AAP321NK UBI "kernel" volume.

The volume layout is  <0x28-byte vendor boot header> + FIT [+ RSA trailer], and the mtd-utils
on the unit have no `dumpimage -x`, so this walks the FIT (a plain FDT) itself: it finds the
kernel sub-image's inline `data` property, decompresses it per `compression`, and checks the
result looks like a kernel Image.

usage: extract-kernel.py <volume.bin> <out-Image> [--config config@NAME] [--list]

  # dump the volume on the unit first (see INSTALL.md):
  #   ubiattach -m 19 && dd if=/dev/ubi0_0 of=/tmp/slotb_kvol.bin bs=4096
"""
import gzip, hashlib, lzma, struct, sys, zlib

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
VENDOR_HDR = 0x28                      # BIH: image_id 0x17, hdr_vsn 3, image_size @0x10 ...


def parse_fdt(b, off=0):
    """Minimal FDT reader -> nested dicts, avoiding a libfdt/dtc dependency."""
    if struct.unpack_from('>I', b, off)[0] != 0xd00dfeed:
        raise SystemExit('not a DTB/FIT image at %#x' % off)
    off_struct, off_strings = struct.unpack_from('>II', b, off + 8)

    def cstr(p):
        e = b.index(b'\0', p)
        return b[p:e].decode('utf-8', 'replace')

    def node(p):
        assert struct.unpack_from('>I', b, p)[0] == FDT_BEGIN_NODE
        p += 4
        name = cstr(p)
        p = (p + len(name) + 1 + 3) & ~3
        props, kids = {}, []
        while True:
            tok = struct.unpack_from('>I', b, p)[0]
            if tok == FDT_PROP:
                ln, noff = struct.unpack_from('>II', b, p + 4)
                props[cstr(off_strings + noff)] = b[p + 12:p + 12 + ln]
                p += 12 + ((ln + 3) & ~3)
            elif tok == FDT_BEGIN_NODE:
                kid, p = node(p)
                kids.append(kid)
            elif tok == FDT_END_NODE:
                return {'name': name, 'props': props, 'children': kids}, p + 4
            elif tok == FDT_NOP:
                p += 4
            else:
                raise SystemExit('bad FDT token %#x at %#x' % (tok, p))

    return node(off + off_struct)[0]


def txt(props, key):
    v = props.get(key)
    return v.rstrip(b'\0').decode('utf-8', 'replace') if v is not None else ''


def decompress(data, how, name):
    if how in ('', 'none'):
        out = data
    elif how == 'gzip':
        out = gzip.decompress(data)
    elif how == 'zlib':
        out = zlib.decompress(data)
    elif how == 'lzma':
        out = lzma.decompress(data)
    else:
        raise SystemExit('%s: unsupported compression %r' % (name, how))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    want_cfg = None
    for i, a in enumerate(sys.argv):
        if a == '--config':
            want_cfg = sys.argv[i + 1]
    if len(args) < 2:
        raise SystemExit(__doc__)
    vol, out = args[0], args[1]
    b = open(vol, 'rb').read()

    # The FIT usually starts right after the 0x28-byte header; fall back to a search if the
    # volume was dumped without it (e.g. straight out of the FIT partition).
    off = VENDOR_HDR
    if struct.unpack_from('>I', b, off)[0] != 0xd00dfeed:
        off = b.find(b'\xd0\x0d\xfe\xed')
        if off < 0:
            raise SystemExit('no FIT found in %s' % vol)
    print('FIT at %#x (%d bytes total dump)' % (off, len(b)))
    root = parse_fdt(b, off)

    def child(node, name):
        for k in node['children']:
            if k['name'].split('@')[0] == name:
                return k
        return None

    images = child(root, 'images')
    if images is None:
        raise SystemExit('no /images node - not a FIT with inline data')

    cands = []
    for im in images['children']:
        p = im['props']
        if 'data' in p or txt(p, 'type') == 'kernel':
            cands.append((im['name'], p))

    print('kernel sub-images:')
    for name, p in cands:
        print('  %-16s %-28s %9s %s' % (
            name, txt(p, 'description')[:28],
            txt(p, 'compression') or 'none',
            'data=%d bytes' % len(p['data']) if 'data' in p else 'NO INLINE DATA'))
    if not cands:
        print('  (none - this FIT keeps its payloads out of line, e.g. the vendor volume;')
        print('   only our own slot-B volume carries an inline arm64 Image)')

    chosen = None
    cfgs = child(root, 'configurations')
    if want_cfg and cfgs is not None:
        c = child(cfgs, want_cfg)
        if c is None:
            raise SystemExit('no such configuration: %s' % want_cfg)
        ref = txt(c['props'], 'kernel').split('@')[0]
        chosen = next((p for n, p in cands if n.split('@')[0] == ref), None)
        print('config %s -> kernel %s' % (want_cfg, ref))
    if chosen is None:
        chosen = next((p for n, p in cands if 'data' in p), None)
    if chosen is None:
        raise SystemExit('no kernel sub-image with inline data')

    img = decompress(chosen['data'], txt(chosen, 'compression'), 'kernel')
    load = chosen.get('load')
    where = ('load %#x' % struct.unpack('>I', load)[0]) if load and len(load) == 4 else ''
    print('extracted %d bytes %s' % (len(img), where))
    if img[0x38:0x3c] == b'ARM\x64':                      # arm64 Image (Documentation/arm64/booting)
        print('arm64 Image magic: OK (text_offset %#x image_size %#x)' % (
            struct.unpack_from('<Q', img, 8)[0], struct.unpack_from('<Q', img, 16)[0]))
    elif struct.unpack_from('<I', img, 0x24)[0] == 0x016f2818:
        print('note: this is an arm32 zImage, not an arm64 Image')
    open(out, 'wb').write(img)
    print('wrote %s  md5 %s' % (out, hashlib.md5(img).hexdigest()))


if __name__ == '__main__':
    main()
