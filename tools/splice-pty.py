#!/usr/bin/env python3
"""Splice a payload into a stock .ko's init (and optionally exit) function window.

The vehicle is the unit's own `ptyconsole.ko`: its module_init/cleanup_module bodies are large
enough to hold the payload, and the module is only loaded by the pty console so loading it early
is harmless.  Symbols come from the module struct's relocations; st_value is section-relative.

    splice-pty.py payload.bin ptyconsole.ko out.ko [exit_payload.bin]

Relocations that point into the overwritten window are rewritten to R_ARM_NONE - the payload is
position-independent asm and calls nothing, so the stale entries must not be applied.

Requires pyelftools.
"""
import struct
import shutil
import sys

from elftools.elf.elffile import ELFFile


def neutralise(f, elf, sec, v, ln):
    rel = elf.get_section_by_name('.rel' + sec.name)
    if rel is None:
        return []
    killed = []
    for i in range(rel.num_relocations()):
        e = rel.get_relocation(i)
        if v <= e['r_offset'] < v + ln:
            f.seek(rel['sh_offset'] + i * rel['sh_entsize'] + 4)
            f.write(struct.pack('<I', 0))
            killed.append(hex(e['r_offset']))
    return killed


def load(payload, SRC, DST, exit_payload=None):
    shutil.copyfile(SRC, DST)
    elf = ELFFile(open(DST, 'rb'))
    sy = elf.get_section_by_name('.symtab')
    mrel = elf.get_section_by_name('.rel.gnu.linkonce.this_module')
    targets = []
    for i in range(mrel.num_relocations()):
        targets.append(sy.get_symbol(mrel.get_relocation(i)['r_info_sym']).name)
    f = open(DST, 'r+b')
    out = []
    for symname, pay in zip(targets, (payload, exit_payload)):
        if pay is None:
            continue
        s = [x for x in sy.iter_symbols() if x.name == symname][0]
        sec = elf.get_section(s['st_shndx'])
        v, isz = s['st_value'], s['st_size']
        assert len(pay) <= isz, f"{symname}: payload {len(pay)} > window {isz}"
        f.seek(sec['sh_offset'] + v)
        f.write(pay)
        killed = neutralise(f, elf, sec, v, len(pay))
        out.append(f"{symname}: {len(pay)}B @ {sec.name}+0x{v:x} (win {isz}), {len(killed)} relocs->NONE")
    f.close()
    print(f"{DST}: " + " | ".join(out))


if __name__ == '__main__':
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    load(open(sys.argv[1], 'rb').read(), sys.argv[2], sys.argv[3],
         open(sys.argv[4], 'rb').read() if len(sys.argv) > 4 else None)
