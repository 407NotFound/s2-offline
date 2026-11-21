#!/usr/bin/env python3
"""
proto_probe.py — 不依赖 .proto 文件，直接把存档二进制按 protobuf wire format 拆开看。

用法：
    python3 proto_probe.py <file-or-dir> [--raw]

能做的事：
  * 判断是不是明文 protobuf（首字段 tag 合法 + 能完整走完）
  * 打印字段树（嵌套 message 会自动递归）
  * 计算熵，熵 > 7.9 且解不开 → 说明这一层确实被压过/加过密
  * --raw 额外打印可打印字符串（装备/昵称/皮肤 id 通常在里面）
"""
import sys, os, math, collections, struct

def varint(buf, i):
    shift = 0; val = 0
    while True:
        if i >= len(buf): raise ValueError('truncated varint')
        b = buf[i]; i += 1
        val |= (b & 0x7f) << shift
        if not b & 0x80: return val, i
        shift += 7
        if shift > 70: raise ValueError('varint too long')

def entropy(b):
    if not b: return 0.0
    c = collections.Counter(b)
    n = len(b)
    return -sum((v / n) * math.log2(v / n) for v in c.values())

def printable_runs(b, minlen=4):
    out, cur = [], bytearray()
    for ch in b:
        if 32 <= ch < 127:
            cur.append(ch)
        else:
            if len(cur) >= minlen: out.append(cur.decode('latin1'))
            cur = bytearray()
    if len(cur) >= minlen: out.append(cur.decode('latin1'))
    return out

def walk(buf, depth=0, maxdepth=8, out=None):
    if out is None: out = []
    i = 0
    try:
        while i < len(buf):
            start = i
            key, i = varint(buf, i)
            field, wt = key >> 3, key & 7
            if field == 0: raise ValueError('field 0')
            if wt == 0:
                v, i = varint(buf, i)
                out.append((depth, field, 'varint', v, start))
            elif wt == 1:
                v = struct.unpack_from('<Q', buf, i)[0]; i += 8
                out.append((depth, field, 'fixed64', v, start))
            elif wt == 2:
                ln, i = varint(buf, i)
                if i + ln > len(buf): raise ValueError('length overflow')
                data = buf[i:i + ln]
                out.append((depth, field, 'bytes', f'len={ln} {data[:24].hex()}', start))
                if depth < maxdepth and ln >= 2 and is_message(data):
                    walk(data, depth + 1, maxdepth, out)
                elif ln and ln < 200:
                    try:
                        s = data.decode('utf-8')
                        if all(32 <= ord(c) < 127 or c in '\u4e00' for c in s) and s.isprintable():
                            out.append((depth + 1, field, 'str', s, start))
                    except Exception:
                        pass
                i += ln
            elif wt == 5:
                v = struct.unpack_from('<I', buf, i)[0]; i += 4
                out.append((depth, field, 'fixed32', v, start))
            else:
                raise ValueError(f'bad wiretype {wt}')
    except Exception as e:
        out.append((depth, -1, 'ERROR', str(e), i))
    return out

def is_message(b):
    """启发式：能否完整解析成 protobuf"""
    try:
        tmp = walk(b, 0, 1, [])
        if not tmp: return False
        if tmp[-1][2] == 'ERROR' and tmp[-1][4] < len(b) - 1: return False
        tags = [t for t in tmp if t[1] > 0]
        if not tags: return False
        # field 编号要合理
        return all(0 < t[1] < 1000 for t in tags)
    except Exception:
        return False

def report(path):
    b = open(path, 'rb').read()
    print(f"\n=== {path}  ({len(b)} B)  entropy={entropy(b):.3f}")
    if b[:2] == b'\x1f\x8b':  print("  gzip  → gunzip 后再看"); return
    if b[:4] == b'\x04\x22\x4d\x18': print("  lz4 frame → lz4 -d 后再看"); return
    tree = walk(b)
    err = [t for t in tree if t[2] == 'ERROR']
    print(f"  fields={len([t for t in tree if t[1] > 0])}  parse_err={len(err)}")
    for d, f, k, v, off in tree[:400]:
        print(f"  {'  ' * d}#{f:<4} {k:<8} {v}")
    if err: print("  !! 不能完整走完 → 可能是压缩/加密，或不是 protobuf")
    if '--raw' in sys.argv:
        ss = printable_runs(b)
        if ss: print("  strings:", ss[:40])

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        print(__doc__); return
    for a in args:
        if os.path.isdir(a):
            for f in sorted(os.listdir(a)):
                p = os.path.join(a, f)
                if os.path.isfile(p): report(p)
        else:
            report(a)

if __name__ == '__main__':
    main()
