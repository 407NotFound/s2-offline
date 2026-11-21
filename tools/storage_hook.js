/*
 * storage_hook.js — 抓住离线存档「落盘那一刻」的明文
 *
 * 两条线同时挂：
 *   1) Objective-C 层：-[NSData writeToFile:atomically:] / NSFileManager createFileAtPath:contents:
 *      → 不依赖 il2cpp，任何存档写盘都会经过这里，直接拿字节。
 *   2) il2cpp 层：把 *Storage / *ProtoStorage / LocalBolt* 的 Save/Load/Write/Read 挂上，
 *      打印 this 指针 + byte[] 内容。
 *
 * 用法：
 *   frida -U -f com.Chillow.StandChillow -l storage_hook.js --no-pause
 *   mkdir -p /tmp/s2dump   （iOS 上写 /var/mobile/Library/Caches/s2dump）
 *
 * 产物：每个被写的文件一份 .bin，文件名里带原始路径的可读化版本。
 */
'use strict';

const OUT_DIR = '/var/mobile/Library/Caches/s2dump';
const LIB = 'UnityFramework';
const PATH_HINT = /bolt|offline|save|profile|inventory|stats|match|StandChillow|\.dat|\.bin|\.proto/i;

function ensureDir() {
  try { new File(OUT_DIR, 'wx').close(); } catch (e) {}
  // 用 ObjC 建目录更稳
  try {
    ObjC.classes.NSFileManager.defaultManager()
      .createDirectoryAtPath_withIntermediateDirectories_attributes_error_(OUT_DIR, 1, ptr(0), ptr(0));
  } catch (e) {}
}

function safeName(p) {
  return p.replace(/^.*\//, '').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 80);
}

function dumpBytes(prefix, path, dataPtr, len) {
  if (len <= 0 || len > 32 * 1024 * 1024) return;
  try {
    const name = prefix + '_' + safeName(path || 'mem') + '_' + Date.now() + '.bin';
    const f = new File(OUT_DIR + '/' + name, 'wb');
    f.write(dataPtr.readByteArray(len));
    f.flush(); f.close();
    console.log('[+] ' + name + '  (' + len + ' B)  <- ' + path);
    // 顺手打前 32 字节，肉眼判断是不是明文 protobuf
    console.log('    head: ' + hexdump(dataPtr, { length: Math.min(32, len), ansi: false }).replace(/\n/g, ' | '));
  } catch (e) {
    console.log('[!] dump fail ' + e.message);
  }
}

/* ---------------- 1) ObjC 层 ---------------- */
function hookObjC() {
  try {
    const NSData = ObjC.classes.NSData;
    const w = NSData['- writeToFile:atomically:'];
    if (w) {
      Interceptor.attach(w.implementation, {
        onEnter(args) {
          const path = new ObjC.Object(args[2]).toString();
          if (!PATH_HINT.test(path)) return;
          const len = new ObjC.Object(args[0]).length();
          dumpBytes('nsdata', path, new ObjC.Object(args[0]).bytes(), len);
        }
      });
      console.log('[*] hooked -[NSData writeToFile:atomically:]');
    }
  } catch (e) { console.log('[!] NSData hook: ' + e.message); }

  try {
    const fm = ObjC.classes.NSFileManager['- createFileAtPath:contents:attributes:'];
    if (fm) {
      Interceptor.attach(fm.implementation, {
        onEnter(args) {
          const path = new ObjC.Object(args[2]).toString();
          if (!PATH_HINT.test(path)) return;
          const d = new ObjC.Object(args[3]);
          if (d.isNull()) return;
          dumpBytes('createfile', path, d.bytes(), d.length());
        }
      });
      console.log('[*] hooked -[NSFileManager createFileAtPath:contents:attributes:]');
    }
  } catch (e) { console.log('[!] NSFileManager hook: ' + e.message); }
}

/* ---------------- 2) il2cpp 层 ---------------- */
function E(n) { return Module.findExportByName(LIB, n); }

const TARGET_METHOD = /^(Save|Load|Write|Read|Serialize|Deserialize|Store|Flush|ToBytes|FromBytes)/i;
const TARGET_CLASS = /(Storage|Proto|LocalBolt|Offline)/i;

function cstr(p) { try { return p.isNull() ? '' : p.readUtf8String(); } catch (e) { return ''; } }

// Il2CppArray (64-bit): klass@0, monitor@8, bounds@0x10, max_length@0x18, data@0x20
function arrayInfo(arrPtr) {
  try {
    const len = arrPtr.add(0x18).readU64().toNumber();
    return { len: len, data: arrPtr.add(0x20) };
  } catch (e) { return null; }
}

function hookIl2cpp() {
  const need = ['il2cpp_domain_get', 'il2cpp_domain_get_assemblies', 'il2cpp_assembly_get_image',
                'il2cpp_image_get_class_count', 'il2cpp_image_get_class', 'il2cpp_class_get_name',
                'il2cpp_class_get_namespace', 'il2cpp_class_get_methods', 'il2cpp_method_get_name',
                'il2cpp_thread_attach'];
  for (const n of need) if (!E(n)) { console.log('[!] no export ' + n + ' — 跳过 il2cpp 线'); return; }

  const A = {
    domain_get:            new NativeFunction(E('il2cpp_domain_get'), 'pointer', []),
    domain_get_assemblies: new NativeFunction(E('il2cpp_domain_get_assemblies'), 'pointer', ['pointer', 'pointer']),
    assembly_get_image:    new NativeFunction(E('il2cpp_assembly_get_image'), 'pointer', ['pointer']),
    image_class_count:     new NativeFunction(E('il2cpp_image_get_class_count'), 'uint32', ['pointer']),
    image_get_class:       new NativeFunction(E('il2cpp_image_get_class'), 'pointer', ['pointer', 'uint32']),
    class_name:            new NativeFunction(E('il2cpp_class_get_name'), 'pointer', ['pointer']),
    class_ns:              new NativeFunction(E('il2cpp_class_get_namespace'), 'pointer', ['pointer']),
    class_methods:         new NativeFunction(E('il2cpp_class_get_methods'), 'pointer', ['pointer', 'pointer']),
    method_name:           new NativeFunction(E('il2cpp_method_get_name'), 'pointer', ['pointer']),
    thread_attach:         new NativeFunction(E('il2cpp_thread_attach'), 'pointer', ['pointer']),
  };

  const dom = A.domain_get();
  A.thread_attach(dom);
  const c = Memory.alloc(4);
  const asms = A.domain_get_assemblies(dom, c);
  const n = c.readU32();

  let hooked = 0;
  for (let i = 0; i < n; i++) {
    const img = A.assembly_get_image(asms.add(i * Process.pointerSize).readPointer());
    if (img.isNull()) continue;
    const cc = A.image_class_count(img);
    for (let k = 0; k < cc; k++) {
      const klass = A.image_get_class(img, k);
      if (klass.isNull()) continue;
      const full = (cstr(A.class_ns(klass)) + '.' + cstr(A.class_name(klass))).replace(/^\./, '');
      if (!TARGET_CLASS.test(full)) continue;

      const it = Memory.alloc(Process.pointerSize);
      it.writePointer(ptr(0));
      let m;
      while (!(m = A.class_methods(klass, it)).isNull()) {
        const mn = cstr(A.method_name(m));
        if (!TARGET_METHOD.test(mn)) continue;
        // MethodInfo->methodPointer 在偏移 0
        const fn = m.readPointer();
        if (fn.isNull()) continue;
        try {
          Interceptor.attach(fn, {
            onEnter(args) {
              this.tag = full + '::' + mn;
              console.log('>> ' + this.tag + '  this=' + args[0]);
              for (let a = 1; a <= 3; a++) {
                try {
                  const ai = arrayInfo(args[a]);
                  if (ai && ai.len > 0 && ai.len < 8 * 1024 * 1024) {
                    console.log('   arg' + a + ' byte[] len=' + ai.len);
                    dumpBytes('arg', this.tag.replace(/[^A-Za-z0-9._-]/g, '_') + '_a' + a, ai.data, ai.len);
                  }
                } catch (e) {}
              }
            }
          });
          hooked++;
        } catch (e) {}
      }
    }
  }
  console.log('[*] il2cpp hooks: ' + hooked);
}

function main() {
  ensureDir();
  hookObjC();
  hookIl2cpp();
  console.log('[*] ready — 现在在游戏里进离线模式、打一局、买个东西');
}

setTimeout(() => { try { main(); } catch (e) { console.log('[!] ' + e.message); } }, 6000);
