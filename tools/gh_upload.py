#!/usr/bin/env python3
"""
gh_upload.py — 用 http.client 流式上传大文件到 GitHub Release asset

为什么不用 curl：这个沙箱里 curl 读文件上限 10 MB（EFBIG），传 1.8 GB 的分片直接失败。
python 的 socket 流式写没有这个限制。

用法:
    python3 gh_upload.py <token> <upload_url_without_template> <file> <asset_name> [--chunk 8388608]
"""
import sys, os, json, http.client, time, urllib.parse

def upload(token, upload_url, path, name, chunk=8 * 1024 * 1024):
    u = urllib.parse.urlsplit(upload_url)
    host, base = u.netloc, u.path
    q = urllib.parse.urlencode({'name': name})
    size = os.path.getsize(path)
    conn = http.client.HTTPSConnection(host, timeout=120)
    conn.putrequest('POST', f'{base}?{q}')
    conn.putheader('Authorization', f'Bearer {token}')
    conn.putheader('Accept', 'application/vnd.github+json')
    conn.putheader('Content-Type', 'application/octet-stream')
    conn.putheader('Content-Length', str(size))
    conn.endheaders()

    sent = 0
    t0 = time.time()
    last = t0
    with open(path, 'rb') as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            conn.send(b)
            sent += len(b)
            now = time.time()
            if now - last > 5:
                speed = sent / max(1e-6, now - t0) / 1e6
                pct = 100.0 * sent / size
                print(f'  {sent/1e9:.2f}/{size/1e9:.2f} GB  {pct:5.1f}%  {speed:.2f} MB/s', flush=True)
                last = now
    resp = conn.getresponse()
    body = resp.read().decode('utf-8', 'replace')
    print('HTTP', resp.status)
    if resp.status in (200, 201):
        d = json.loads(body)
        print('asset id', d.get('id'), 'size', d.get('size'),
              'browser_download_url', d.get('browser_download_url'))
        return d
    print(body[:500])
    return None

if __name__ == '__main__':
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    chunk = 8 * 1024 * 1024
    for i, x in enumerate(sys.argv):
        if x == '--chunk':
            chunk = int(sys.argv[i + 1])
    if len(a) != 4:
        print(__doc__)
        sys.exit(1)
    upload(a[0], a[1], a[2], a[3], chunk)
