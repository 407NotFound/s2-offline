#!/usr/bin/env python3
"""
macho_inject.py — 纯 Python 给 Mach-O 加 LC_LOAD_DYLIB（不依赖 insert_dylib/optool）

为什么自己写：CI 上装 insert_dylib 麻烦，而且它遇到 header padding 不足时会自己
重建整个文件。这里先做「有 padding 就地插入」这条最安全的路径，padding 不够就
明确报错，不偷偷改文件。

用法:
    python3 macho_inject.py <macho> <@executable_path/Frameworks/X.dylib> [--dry-run]

注意：插入后原来的 code signature 立刻失效，必须重新 ldid/codesign。
"""
import sys, struct

LC_LOAD_DYLIB = 0x0C
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE


def align(v, a):
    return (v + a - 1) // a * a


def dylib_cmd(path):
    """构造 struct dylib_command + 路径（name offset 24）"""
    name = path.encode() + b'\0'
    size = align(24 + len(name), 8)
    cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, size, 24, 2, 0x10000, 0x10000)
    body = name + b'\0' * (size - 24 - len(name))
    return cmd + body


def parse(buf):
    magic = struct.unpack_from('<I', buf, 0)[0]
    if magic == MH_MAGIC_64:
        is64 = True
        hdrsize = 32
    elif magic == MH_MAGIC:
        is64 = False
        hdrsize = 28
    else:
        raise SystemExit(f"not a Mach-O (magic {magic:#x})")

    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack_from('<iiIIII', buf, 4)
    off = hdrsize
    cmds = []
    for i in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        cmds.append((cmd, size, off))
        off += size
    return dict(is64=is64, hdrsize=hdrsize, ncmds=ncmds, sizeofcmds=sizeofcmds,
                cputype=cputype, filetype=filetype, cmds=cmds,
                cmd_end=hdrsize + sizeofcmds)


def first_data_offset(buf, info):
    """__TEXT 段里第一个 section 的 file offset = header 区的硬上限"""
    best = None
    for cmd, size, off in info['cmds']:
        if cmd != LC_SEGMENT_64:
            continue
        segname = buf[off + 8:off + 24].rstrip(b'\0').decode('latin1')
        fileoff, filesize = struct.unpack_from('<QQ', buf, off + 40)
        nsects = struct.unpack_from('<I', buf, off + 64)[0]
        s = off + 72
        for _ in range(nsects):
            soff = struct.unpack_from('<I', buf, s + 48)[0]
            if soff > 0 and (best is None or soff < best):
                best = soff
            s += 80
        if segname == '__TEXT' and fileoff > 0:
            pass
    return best


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    dry = '--dry-run' in sys.argv
    if len(args) != 2:
        print(__doc__)
        return 1
    path, dylib_path = args
    buf = bytearray(open(path, 'rb').read())
    info = parse(buf)

    print(f"[*] {path}")
    print(f"    cputype={info['cputype']:#x} filetype={info['filetype']} ncmds={info['ncmds']} "
          f"sizeofcmds={info['sizeofcmds']} cmd_end={info['cmd_end']:#x}")

    for cmd, size, off in info['cmds']:
        if cmd == LC_LOAD_DYLIB:
            nm = buf[off + 24:off + size].split(b'\0')[0].decode('latin1', 'replace')
            print(f"    existing dylib: {nm}")
            if dylib_path.encode() in nm.encode() or nm == dylib_path:
                print("[=] already injected, nothing to do")
                return 0

    limit = first_data_offset(buf, info)
    print(f"    header limit (first section offset) = {limit:#x}")
    cmd = dylib_cmd(dylib_path)
    slack = (limit - info['cmd_end']) if limit else 0
    print(f"    need {len(cmd)} B, slack {slack} B")

    if limit is None or slack < len(cmd):
        print("[!] 头部空间不足 —— 需要重排（shift）整个文件，或改用 __TEXT 尾部扩展。")
        print("    建议：改用 theos 的 insert_dylib，或先在 CI 上把 dylib 做成弱加载。")
        return 2

    # 就地插入：把新命令写到 load command 区末尾
    at = info['cmd_end']
    buf[at:at + len(cmd)] = cmd
    struct.pack_into('<I', buf, 16, info['ncmds'] + 1)          # ncmds
    struct.pack_into('<I', buf, 20, info['sizeofcmds'] + len(cmd))  # sizeofcmds

    if dry:
        print("[*] dry-run: 不写文件")
        return 0

    open(path, 'wb').write(buf)
    print(f"[+] injected: {dylib_path}  (ncmds={info['ncmds'] + 1})")
    print("[!] code signature 已失效，必须重新签名（ldid -S / codesign --force --sign -）")
    return 0


if __name__ == '__main__':
    sys.exit(main())
