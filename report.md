# Standoff 2 iOS 2.07 — 离线模式「剥离」工作包

样本：`2.07 F1.ipa`（2,300,747,566 B, sha256 `0154051e…`）
Bundle：`com.Chillow.StandChillow` 2.07｜Unity 2022.3.62f3｜IL2CPP（metadata v31）

---

## 0. 已经落地的东西（目录 `standoff2_re/`）

| 路径 | 内容 |
|---|---|
| `bin/UnityFramework` | 242,836,048 B，arm64 主逻辑（IL2CPP 代码全在这），`cryptid=0` 已脱壳 |
| `bin/StandChillow` | 86,144 B，壳层可执行 |
| `meta/global-metadata.dat` | 23,027,696 B，明文 metadata（`0xFAB11BAF` v31） |
| `meta/Info.plist` / `meta/boot.config` | 包信息 / Unity 启动配置 |
| `meta/entries.txt` | 354 条 zip 条目清单，含大小 |
| `tools/il2cpp_enum.js` | Frida：运行时枚举 `Bolt/Offline/Storage/Proto` 类型 + 方法 + 字段 |
| `tools/storage_hook.js` | Frida：双线抓落盘（NSData/NSFileManager + il2cpp 存储方法），字节直接落 `.bin` |
| `tools/proto_probe.py` | 无 schema 解 protobuf，输出字段树 / 熵 / 字符串 |

未拆：`Data/data.unity3d`（2,058,746,512 B）留在 IPA 里按需读，避免吃掉磁盘（当前剩 ~5.3 GB）。

---

## 1. 「剥离」分三种，先选你要哪种

### A. 只想要**存档数据**能独立读写（最实用，2 小时）

不碰代码，运行时抓明文再解析：

```bash
# 越狱机 / 或 Corellium
frida -U -f com.Chillow.StandChillow -l tools/storage_hook.js --no-pause
# 进离线模式 → 打一局 → 买件东西 → 退出
# 产物: /var/mobile/Library/Caches/s2dump/*.bin
```

拉回来解析：

```bash
python3 tools/proto_probe.py s2dump/ --raw
```

- 首字节 `0x08/0x0A/0x12` 且能完整走完 → 明文 protobuf，字段树直接可读
- 熵 > 7.9 或解析中途报错 → 这一层确有压缩/加密，再谈下一步

拿到字段树后，改存档就三条路：改完重算长度（protobuf 天然支持）、或直接改内存对象、或改完让游戏自己 Save。

### B. 想要**代码逻辑**（ProtoStorage.Save/Load 到底干了啥）

需要桌面 + 三个工具，半小时出 dump：

```bash
# 1) Il2CppDumper（.NET 8）
dotnet Il2CppDumper.dll bin/UnityFramework meta/global-metadata.dat out/
#    产物: out/dump.cs（全部类型/方法签名）, out/script.json, out/DummyDll/*.dll

# 2) 定位
grep -n "class ProtoStorage" -A 60 out/dump.cs
grep -n "LocalBoltApi\|LocalBoltServiceProvider" out/dump.cs
```

然后 IDA / Ghidra 载入 `bin/UnityFramework`，用 `script.json` 的 `ScriptMethod`/`ScriptString` 恢复符号，看 `ProtoStorage::Save` 里有没有 `Aes/Rijndael/Deflate` 调用——有就是压缩层，没有就是裸写。

> 我在这台设备上试过直接按 metadata 的 `firstMethodIdx` 拼 type↔method，结果对不上（v31 的字段顺序和我假设的不一致，`nested_type` 那组能 100% 对上、method 组对不上）。所以别用裸 metadata 手搓，用 Il2CppDumper 或 `tools/il2cpp_enum.js`（运行时枚举，绕过这个问题）。

### C. 想要**资源/配置**（本地化表、商店配置、avatar 定义）

`data.unity3d` 是标准 UnityFS，按 40 字节头 + LZ4 block 解：

```bash
pip install UnityPy
python3 - <<'PY'
import UnityPy
env = UnityPy.load('data/data.unity3d')
for o in env.objects:
    if o.type.name in ('TextAsset','MonoBehaviour','AssetBundle'):
        print(o.type.name, o.path_id)
PY
```

重点找：`localbolt` 相关 TextAsset、`*Definitions*`、商店/武器配置。资源层不涉及加密，纯解包。

---

## 2. 关于「离线模式有没有加密」的当前结论（复核用）

| 层 | 证据 | 状态 |
|---|---|---|
| FairPlay | 两个 Mach-O `LC_ENCRYPTION_INFO cryptid=0` | 无 |
| IL2CPP metadata | `af1bb1fa` = `0xFAB11BAF`, v31 | 明文 |
| AssetBundle | `UnityFS\0…5.x.x` + `2022.3.62f3` | 明文 |
| 离线存档 | `ProtoStorage` + `BoltFileStorage`，无密钥/盐字段；本地化文案 `Cannot save bolt proto to disk - not loaded` | 推断为裸 protobuf，待 A 方案实测确认 |

包里所有 crypto 都在别处：`Axlebolt.RpcSupport.Encrypting`（RPC AES）、BouncyCastle（TLS）、`Chillow.Netcode.Crypto.HashMD5`、ACTk `ObscuredPrefs`（只混淆 PlayerPrefs/内存值）。

---

## 3. 下一步（你选一个我就往下做）

1. **实测存档**：给一份 `s2dump` 的 bin，我用 `proto_probe.py` 出完整字段树 + 改档方案
2. **桌面 dump**：你把 `out/dump.cs` 丢回来，我把 `ProtoStorage` 全链路（Save/Load/LocalBoltApi）逐方法讲清楚，并给出 C# 独立读写器
3. **资源包**：先解 `data.unity3d` 出 localbolt 配置表
4. **Frida 深挖**：`il2cpp_enum.js` 的输出贴回来，我按真实成员表生成精确 hook（含 `OfflineCredentialProvider` 的凭据生成逻辑）

---

## 4. 做成「只能玩离线」的独立 IPA —— 可行，但不是「删掉联网部分」

### 4.1 先纠正一个预期

IL2CPP 的 C# 代码在编译期就变成 `UnityFramework` 里的原生代码，类型/方法表是静态索引的。
**删任何方法都会让方法表错位 → 启动即崩。** 所以「把 online 部分裁掉、只留 offline 变成小体积 IPA」这条路走不通。

能走通、且效果等价的路线是**改引导流程**：让 App 从头就走 `localbolt`（本地账号 + 本地存档 + 本地排行榜 + 本地商店），把联网当作不存在。产物还是 2.3 GB（资源全在 `data.unity3d` 里），但行为上是纯单机。

### 4.2 必须改动的三处（按优先级）

| # | 抓手 | 位置 | 改法 |
|---|---|---|---|
| 1 | `AccountModeField` / `OfflineAccountMode` | `Chillow.StandChillow.Settings.*` 的持久化字段 + `Main.Account.OfflineAccountModeSelectController` | 预置 NSUserDefaults 值 = Offline，让账号模式选择直接跳过 |
| 2 | provider 选择 | `Chillow.Bolt.Local.Core.LocalBoltApi` / `LocalBoltServiceProvider` vs 在线 `BoltApi` | 强制注册 local 实现；`bolt_force_localhost` 已存在于包内字面量，说明官方就留了这个开关 |
| 3 | 联网门禁 | `Account`/`Auth`/`Session` 类的 `get_IsAuthorized` / `get_HasSession` / `get_IsOnline` 一类无参 getter | 运行时换 `methodPointer` 成 `return 1`，无需 hook 框架 |

第 3 类之所以能这么做：`MethodInfo` 结构里 `methodPointer` 在偏移 0，`vm_protect` 后直接写指针即可，**不需要 substrate / fishhook / Dobby**，侧载包（无越狱）同样生效。

### 4.3 完整流水线

```bash
# 0) 先验证：不改包，纯运行时确认「真能不联网进主菜单」
frida -U -f com.Chillow.StandChillow -l tools/force_offline.js --no-pause

# 1) 编译补丁 dylib（macOS + theos，或 xcrun clang）
cd tweak && make            # -> .theos/obj/OfflineOnly.dylib

# 2) 注入 + 重签 + 打包
../tools/repack_ipa.sh "2.07 F1.ipa" .theos/obj/OfflineOnly.dylib out/Standoff2-Offline.ipa

# 3) 侧载（Sideloadly / AltStore / TrollStore）
```

`repack_ipa.sh` 做的事：解包 → dylib 放进 `StandChillow.app/Frameworks/` → `insert_dylib` 给主二进制加 `LC_LOAD_DYLIB`（`@executable_path/Frameworks/OfflineOnly.dylib`）→ 先签内嵌件再 `codesign --force --deep --sign -` → 重新 zip。
原包 `cryptid=0`，所以不需要先做 dumpdecrypted。

### 4.4 会踩的坑（按出现概率排序）

1. **完整性校验**：`GUPS.Obfuscator` + `CodeStage.AntiCheat` 有可能校验镜像/方法体，改指针不触发、改文件字节会触发。所以先用 Frida 验证再固化。
2. **签名**：免费证书 7 天过期；给别人装必须用你自己的 p12 + mobileprovision 重签，`--sign -` 只在本机/越狱机有效。
3. **空间**：2.3 GB 包，解包重签过程至少需要 8 GB 空闲。
4. **dylib 未加载**：`LC_LOAD_DYLIB` 路径写错 / dylib 没 chmod 755 / 没单独签名，三者任一都会静默不加载——先看 Console 里有没有 `[OfflineOnly] loaded`。
5. **升级覆盖**：游戏从 App Store 更新会覆盖 SideStore 版本，需要重新打包。

### 4.5 走不通时的 Plan B

若启动流程里存在服务端下发的强校验（如启动即拉配置、缺配置拒绝进菜单），改客户端不如把**响应本地化**：起一个假的服务端（`bolt_force_localhost` 已经指向 loopback），用 `mitmproxy` 记录真实响应后回放，再让 hosts/证书把它指到本机。这属于「离线化 + 本地 mock」，比改 IL2CPP 稳。
