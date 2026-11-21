# 编译 + 打包：一页操作单

目标产物：`Standoff2-Offline-unsigned.ipa`（只能玩单机，ad-hoc 签名，装之前用 Sideloadly/AltStore 用自己的证书重签）

---

## 一、为什么不能在这台设备上直接编

这台跑我的机器是 iOS App 的沙箱 shell：`/usr/bin` 下只有 `node`、`python3`、`git`、`curl`，
**没有 clang、没有 Xcode SDK、没有 codesign、没有 theos**。

编译 arm64 iOS dylib 必须三件套：iPhoneOS SDK + clang 交叉 + 链接器。所以编译只能在下面两处之一跑：

- **A. GitHub Actions（macos-14 runner）** ← 你把 key 给我，我推 CI，全自动
- **B. 你自己的 Mac** ← 三条命令，2 分钟，不用 CI

我能在这台机器上做的、并且已经做完并**实测通过**的部分：

- 拆包、注入器、脚本、CI 配置、dylib 源码
- `tools/macho_inject.py` 已对真实 `StandChillow` 二进制跑过：header slack 14,472 B，需要 72 B，
  注入后 `ncmds 24 → 25`，`LC_LOAD_DYLIB = @executable_path/Frameworks/OfflineOnly.dylib` 已核实可解析

---

## 二、走 CI（你给 key 的方式）

### 你需要提供 3 样

1. **Fine-grained PAT**，权限只要两个：`Contents: Read and write` + `Actions: Read and write`，
   限制到 **单个仓库**，有效期设 1 天，用完立刻 revoke。
2. **仓库**：新建一个空仓库即可（比如 `s2-offline`），我把整个 `standoff2_re/` 推上去。
3. **原版 IPA 的可下载地址**：2.3 GB，仓库里放不下（单文件 100 MB 上限），必须外部可达：
   - 私有 Release asset（**注意单文件 2 GB 上限** → 先 `split -b 1800m` 切成两半再传，CI 里合并）
   - 或 Cloudflare R2 / S3 预签名 URL（推荐，一个 `curl` 就下完，不限速）

### 我拿到之后做什么

```bash
# 1) 建仓库 + 推代码（用 API，不依赖本地 git 配置）
# 2) 触发 workflow_dispatch，参数 ipa_url
gh workflow run build-ipa.yml -f ipa_url="<你的地址>"
gh run watch
```

CI 里依次执行（全部已写进 `.github/workflows/build-ipa.yml`）：

| 步骤 | 命令要点 |
|---|---|
| 编 dylib | `xcrun -sdk iphoneos clang -arch arm64 -dynamiclib … -install_name @executable_path/Frameworks/OfflineOnly.dylib` |
| 签 dylib | `codesign --force --sign -` |
| 下原包 | `curl -L`，随后打印 sha256 |
| 注入 | `python3 tools/macho_inject.py`（不装 insert_dylib） |
| 重签 | 先签内嵌 dylib，再 `codesign --force --deep --sign - "$APP"` |
| 打包 | `zip -qry -1` → `split -b 1800m` 切两半 |
| 交付 | artifact（4 个 part）或 `gh release upload` |

### 你要预留的时间/空间

- runner 磁盘 14 GB：2.3 GB 原包 + 2.3 GB 解包 + 2.3 GB 重压 ≈ 7 GB，够，但别同时跑两个 job
- 单次 CI 约 8–20 分钟（取决于下载速度）
- 产物约 2.3 GB，分 2 个 part

---

## 三、走本机（更快，不用给 key）

```bash
cd standoff2_re/tweak
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -isysroot "$SDK" \
  -framework Foundation -fobjc-arc -O2 -miphoneos-version-min=12.0 \
  -install_name @executable_path/Frameworks/OfflineOnly.dylib \
  -o ../build/OfflineOnly.dylib OfflineOnly.m
codesign --force --sign - ../build/OfflineOnly.dylib

cd .. && ./tools/repack_ipa.sh "2.07 F1.ipa" build/OfflineOnly.dylib out/Standoff2-Offline.ipa
```

`repack_ipa.sh` 里已经换成 `macho_inject.py`（不需要 `insert_dylib`/`optool`）。

---

## 四、CI 做不到的两件事（别指望自动化）

1. **运行时验证**：dylib 到底有没有把 App 逼进 localbolt，只有在真机/模拟器上跑才知道。
   CI 只能保证「编译通过 + 签名通过 + 包结构正确」。
2. **你的证书签名**：CI 出的是 ad-hoc 包。要装到你手机上，还是 Sideloadly/AltStore 用你的
   Apple ID 重签一次（免费证书 7 天）。

所以最省事的顺序是：**CI 出包 → 你 Sideloadly 装 → 卡住就把 Console 日志给我 → 我改 hook 点 → CI 重出**。

---

## 五、风险清单（按可能性）

| 风险 | 触发条件 | 对策 |
|---|---|---|
| 装上闪退 | `GUPS.Obfuscator` / ACTk 校验镜像 | 先在真机用 Frida 跑 `force_offline.js` 验证，再固化 |
| dylib 不加载 | 路径/权限/签名任一不对 | Console 搜 `[OfflineOnly] loaded`，没有就是没加载 |
| 进菜单但连不上 | 启动时强依赖服务端配置 | 改走 Plan B：本地 mock 服务端回放响应 |
| 2 GB 上传失败 | release asset 单文件限制 | 已 split 1800m，两段分别上传 |
