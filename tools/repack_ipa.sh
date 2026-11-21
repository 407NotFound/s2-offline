#!/usr/bin/env bash
# repack_ipa.sh — 把补丁 dylib 注入原包，重新签名，产出可侧载的 IPA
#
# 用法:
#   ./repack_ipa.sh "2.07 F1.ipa" build/OfflineOnly.dylib out/Standoff2-Offline.ipa
#
# 依赖（macOS）: xcode command line tools（codesign/zip）、insert_dylib 或 optool
#   brew install insert_dylib   # 或自己编 https://github.com/Tyilo/insert_dylib
#
# 说明:
#   * 原包 cryptid=0（已脱壳），所以不需要 dumpdecrypted
#   * dylib 放到 .app/Frameworks/ 下，并给主二进制加 LC_LOAD_DYLIB
#   * 免签（--sign -）只能本机/越狱机跑；给别人装必须用自己的证书重签
set -euo pipefail

IPA="${1:?usage: repack_ipa.sh <in.ipa> <patch.dylib> [out.ipa]}"
DYLIB="${2:?missing dylib}"
OUT="${3:-offline.ipa}"
APP_NAME="StandChillow"

[ -f "$IPA" ] || { echo "no such ipa: $IPA"; exit 1; }
[ -f "$DYLIB" ] || { echo "no such dylib: $DYLIB"; exit 1; }

WORK="$(mktemp -d /tmp/repack.XXXXXX)"
echo "[*] workdir $WORK"
unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/$APP_NAME.app"
[ -d "$APP" ] || { echo "unexpected layout: $APP missing"; exit 1; }

echo "[*] copying dylib"
mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/"
chmod 755 "$APP/Frameworks/$(basename "$DYLIB")"

echo "[*] injecting LC_LOAD_DYLIB"
BIN="$APP/$APP_NAME"
LOAD_PATH="@executable_path/Frameworks/$(basename "$DYLIB")"
# 优先用仓库自带的纯 python 注入器（已对真实二进制实测）
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/macho_inject.py" ]; then
  python3 "$HERE/macho_inject.py" "$BIN" "$LOAD_PATH"
elif command -v insert_dylib >/dev/null 2>&1; then
  insert_dylib --inplace --codesign - "$LOAD_PATH" "$BIN"
else
  echo "!! 没有 macho_inject.py 也没有 insert_dylib"; exit 1
fi

echo "[*] re-signing (ad-hoc)"
# 先签内嵌 framework/dylib，再签 .app，顺序很重要
find "$APP/Frameworks" -maxdepth 2 \( -name "*.dylib" -o -name "*.framework" \) | while read -r f; do
  codesign --force --sign - "$f" 2>/dev/null || true
done
codesign --force --deep --sign - "$APP"
codesign -dv "$APP" 2>&1 | head -5

echo "[*] packaging"
mkdir -p "$(dirname "$OUT")"
( cd "$WORK" && zip -qry "$OLDPWD/$OUT" Payload )
ls -lh "$OUT"
echo "[*] done -> $OUT"
echo "    安装: Sideloadly / AltStore / TrollStore(越狱或 <iOS17.0 漏洞机)"
echo "    免费证书 7 天过期；2.3 GB，装之前确认设备剩余空间 > 6 GB"
