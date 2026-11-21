# s2-offline — Standoff 2 iOS 2.07 离线版构建包

- [BUILD.md](BUILD.md) — 编译与打包一页操作单
- [report.md](report.md) — 静态分析结论 + 离线化路线 + 风险清单
- `tweak/OfflineOnly.m` — 补丁 dylib（强制 localbolt、改 methodPointer）
- `tools/macho_inject.py` — 纯 Python `LC_LOAD_DYLIB` 注入器（已对真实二进制实测）
- `tools/*.js` — Frida 脚本（枚举类型 / 抓存档 / 强制离线验证）
- `tools/proto_probe.py` — 无 schema protobuf 解析
- `.github/workflows/build-dylib.yml` — 只编 dylib（无需 IPA）
- `.github/workflows/build-ipa.yml` — 完整注入 + 重签 + 切包
