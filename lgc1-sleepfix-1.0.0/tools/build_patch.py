#!/usr/bin/env python3
"""Reproduce the LG C1 sleep-warning patch, only for the audited original ELF.

Uses Python's standard library. Never edits the input or deploys to a TV.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import struct
from pathlib import Path

ORIGINAL_SHA256 = "6bee2e9fbe9836addede0a3f2e33342fb1914ff5f1793d2bffa030bfc0e38330"
SIZE = 953888
PATCH_OFFSET = 0x3099E
ORIGINAL_BYTES = bytes.fromhex("4df0bdfb")
PATCH_BYTES = bytes.fromhex("00bf00bf")
SYMBOLS = {
    "_ZN10SleepTimer16_checkSleepTimerEPv": (0x307CD, 792),
    "_ZN19ReservationPowerMgr19requestTurnOnScreenEv": (0x7E11D, 240),
    "_ZN10SleepTimer27_createSleepTimerAlertPopupEv": (0x2FB35, 372),
    "_ZN10SleepTimer21_startSleepTimerEventEv": (0x30709, 196),
    "_ZN10SleepTimer16_requestPowerOffEv": (0x30009, 164),
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_cstring(data: bytes, offset: int) -> str:
    require(0 <= offset < len(data), "String outside table")
    end = data.find(b"\0", offset)
    require(end >= offset, "Unterminated string")
    return data[offset:end].decode("ascii", errors="strict")


def decode_thumb_bl(data: bytes, offset: int, address: int) -> int:
    """Decode a Thumb-2 BL immediate independently of the disassembler."""
    h1, h2 = struct.unpack_from("<HH", data, offset)
    require(h1 & 0xF800 == 0xF000 and h2 & 0xD000 == 0xD000,
            f"Not a Thumb-2 BL at {address:#x}")
    s = (h1 >> 10) & 1
    j1, j2 = (h2 >> 13) & 1, (h2 >> 11) & 1
    i1, i2 = (~(j1 ^ s)) & 1, (~(j2 ^ s)) & 1
    imm = (s << 24) | (i1 << 23) | (i2 << 22) | ((h1 & 0x3FF) << 12) | ((h2 & 0x7FF) << 1)
    if s:
        imm -= 1 << 25
    return (address + 4 + imm) & 0xFFFFFFFF


def inspect(data: bytes) -> dict:
    require(len(data) == SIZE, "Wrong input length")
    require(sha(data) == ORIGINAL_SHA256, "Input is not the audited original; refusing to guess offsets")
    require(data[:7] == b"\x7fELF\x01\x01\x01", "Not ELF32 little endian")
    h = struct.unpack_from("<HHIIIIIHHHHHH", data, 16)
    e_type, machine, _, _, phoff, shoff, flags, _, phsize, phnum, shsize, shnum, shstridx = h
    require(e_type == 3 and machine == 40, "Not an ARM PIE ELF")
    require(phsize == 32 and shsize == 40, "Unexpected ELF layout")
    ph = [struct.unpack_from("<IIIIIIII", data, phoff+i*phsize) for i in range(phnum)]
    headers = [struct.unpack_from("<IIIIIIIIII", data, shoff+i*shsize) for i in range(shnum)]
    names_header = headers[shstridx]
    names = data[names_header[4]:names_header[4]+names_header[5]]
    sections = {read_cstring(names, x[0]): x for x in headers}
    text = sections[".text"]
    require(text[4] <= PATCH_OFFSET < text[4]+text[5]-3, "Patch outside .text")
    patch_address = text[3] + PATCH_OFFSET - text[4]
    require(patch_address == PATCH_OFFSET, "Unexpected VA-to-file mapping")
    loads = [p for p in ph if p[0] == 1 and p[1] <= PATCH_OFFSET < p[1]+p[4]]
    require(len(loads) == 1 and loads[0][6] & 1, "Patch not in an executable PT_LOAD")
    symheader = sections[".dynsym"]
    strheader = headers[symheader[6]]
    strings = data[strheader[4]:strheader[4]+strheader[5]]
    symbols = {}
    for pos in range(symheader[4], symheader[4]+symheader[5], symheader[9]):
        name, value, size, info, other, idx = struct.unpack_from("<IIIBBH", data, pos)
        if name:
            symbols[read_cstring(strings, name)] = (value, size)
    for name, expected in SYMBOLS.items():
        require(symbols.get(name) == expected, f"Unexpected symbol: {name}")
    require(data[PATCH_OFFSET:PATCH_OFFSET+4] == ORIGINAL_BYTES, "Wrong original instruction")
    require(decode_thumb_bl(data, PATCH_OFFSET, patch_address) == 0x7E11C, "Wrong call target")
    require(data[0x309A2:0x309A4] == bytes.fromhex("2046"), "Expected MOV r0,r4 after call")
    require(decode_thumb_bl(data, 0x309A4, 0x309A4) == 0x2FB34, "Alert call differs")
    require(decode_thumb_bl(data, 0x3090A, 0x3090A) == 0x30708, "Expiry call differs")
    require(decode_thumb_bl(data, 0x30790, 0x30790) == 0x30008, "Shutdown call differs")
    # No ELF dynamic relocation may touch the modified instruction.
    for section_name in (".rel.dyn", ".rel.plt"):
        section = sections[section_name]
        for pos in range(section[4], section[4]+section[5], section[9]):
            offset, _ = struct.unpack_from("<II", data, pos)
            require(not (patch_address-3 <= offset < patch_address+4), "Relocation overlaps patch")
    return {"architecture": "ARMv7 Thumb-2, ELF32 little-endian PIE, EABI5 soft-float",
            "elf_flags": hex(flags), "patch_virtual_address": hex(patch_address),
            "symbols": {k: {"value": hex(v[0]), "size": v[1]} for k,v in SYMBOLS.items()},
            "relocation_overlap": False}


def make_patch(data: bytes) -> tuple[bytes, dict]:
    metadata = inspect(data)
    patched = data[:PATCH_OFFSET] + PATCH_BYTES + data[PATCH_OFFSET+4:]
    diff = [i for i, (a,b) in enumerate(zip(data, patched)) if a != b]
    require(diff == list(range(PATCH_OFFSET, PATCH_OFFSET+4)), "Unexpected binary differences")
    require(len(patched) == len(data), "ELF size changed")
    metadata.update({"package_version": "1.0.0", "size": SIZE,
                     "original_sha256": sha(data), "patched_sha256": sha(patched),
                     "patch_file_offset": hex(PATCH_OFFSET),
                     "before": ORIGINAL_BYTES.hex(" "), "after": PATCH_BYTES.hex(" "),
                     "changed_byte_offsets": [hex(i) for i in diff],
                     "tv_runtime_tested": False})
    return patched, metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    require(args.original.resolve() != args.output.resolve(), "Refusing to overwrite the original")
    patched, metadata = make_patch(args.original.read_bytes())
    # Exclusive creation avoids changing an already mapped or previously verified file.
    with args.output.open("xb") as f:
        f.write(patched)
    if args.manifest:
        args.manifest.write_text(json.dumps(metadata, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))

if __name__ == "__main__":
    main()
