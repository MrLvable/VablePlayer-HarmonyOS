#!/usr/bin/env python3
"""Rewrite the DT_SONAME string in an ELF shared library in place.

Used when normalizing a versioned SONAME (e.g. libsmb2.so.1) to the plain
file name (libsmb2.so) that hvigor packages into the HAR. Only shortens the
string, so it is a safe in-place edit of .dynstr.
"""
import struct
import sys


def patch_soname(path: str, new_soname: str) -> None:
    with open(path, 'r+b') as f:
        data = bytearray(f.read())
    if data[:4] != b'\x7fELF':
        raise SystemExit(f'{path}: not an ELF file')
    is64 = data[4] == 2

    if is64:
        e_phoff = struct.unpack_from('<Q', data, 0x20)[0]
        e_phentsize = struct.unpack_from('<H', data, 0x36)[0]
        e_phnum = struct.unpack_from('<H', data, 0x38)[0]
        d_tag_fmt, d_val_fmt, d_entsz = '<q', '<Q', 16
    else:
        e_phoff = struct.unpack_from('<I', data, 0x1c)[0]
        e_phentsize = struct.unpack_from('<H', data, 0x2a)[0]
        e_phnum = struct.unpack_from('<H', data, 0x2c)[0]
        d_tag_fmt, d_val_fmt, d_entsz = '<i', '<I', 8

    PT_LOAD, PT_DYNAMIC = 1, 2
    loads = []          # (vaddr, offset, filesz)
    dyn_vaddr = dyn_size = None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from('<I', data, off)[0]
        if p_type == PT_LOAD:
            if is64:
                p_vaddr = struct.unpack_from('<Q', data, off + 0x10)[0]
                p_offset = struct.unpack_from('<Q', data, off + 0x08)[0]
                p_filesz = struct.unpack_from('<Q', data, off + 0x20)[0]
            else:
                p_vaddr = struct.unpack_from('<I', data, off + 0x08)[0]
                p_offset = struct.unpack_from('<I', data, off + 0x04)[0]
                p_filesz = struct.unpack_from('<I', data, off + 0x10)[0]
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == PT_DYNAMIC:
            if is64:
                dyn_vaddr = struct.unpack_from('<Q', data, off + 0x10)[0]
                dyn_size = struct.unpack_from('<Q', data, off + 0x20)[0]
            else:
                dyn_vaddr = struct.unpack_from('<I', data, off + 0x08)[0]
                dyn_size = struct.unpack_from('<I', data, off + 0x14)[0]

    def vaddr_to_offset(vaddr: int) -> int:
        for v, o, sz in loads:
            if v <= vaddr < v + sz:
                return o + (vaddr - v)
        raise SystemExit(f'{path}: cannot map vaddr 0x{vaddr:x} to file offset')

    DT_STRTAB, DT_SONAME = 5, 14
    strtab_vaddr = soname_idx = None
    dyn_off = vaddr_to_offset(dyn_vaddr)
    for p in range(0, dyn_size, d_entsz):
        tag = struct.unpack_from(d_tag_fmt, data, dyn_off + p)[0]
        val = struct.unpack_from(d_val_fmt, data, dyn_off + p + d_entsz // 2)[0]
        if tag == DT_STRTAB:
            strtab_vaddr = val
        elif tag == DT_SONAME:
            soname_idx = val
    if strtab_vaddr is None or soname_idx is None:
        raise SystemExit(f'{path}: no DT_SONAME found')

    strtab_off = vaddr_to_offset(strtab_vaddr) + soname_idx
    end = data.index(b'\x00', strtab_off)
    old = bytes(data[strtab_off:end])
    if len(new_soname) > len(old):
        raise SystemExit(f'{path}: new soname too long: {old!r} -> {new_soname!r}')
    data[strtab_off:strtab_off + len(new_soname)] = new_soname.encode()
    for i in range(strtab_off + len(new_soname), end):
        data[i] = 0

    with open(path, 'wb') as f:
        f.write(data)
    print(f'{path}: soname {old.decode()} -> {new_soname}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: patch-soname.py <lib.so> <new-soname>')
    patch_soname(sys.argv[1], sys.argv[2])
