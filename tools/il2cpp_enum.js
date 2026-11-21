/*
 * il2cpp_enum.js — 运行时枚举 IL2CPP 类型/方法/字段（不需要 Il2CppDumper）
 *
 * 用途：把 metadata 里对不齐的 type ↔ method 关系在运行时补出来，
 *      直接拿到 Chillow.Bolt.Local / *Storage / *Proto 的真实成员表。
 *
 * 用法：
 *   frida -U -f com.Chillow.StandChillow -l il2cpp_enum.js --no-pause
 *   # 输出会同时写到 /var/mobile/... 可读位置；也可在 frida 控制台直接看
 */
'use strict';

const LIB = 'UnityFramework';

function E(n) {
  const p = Module.findExportByName(LIB, n);
  if (!p) throw new Error('missing export: ' + n);
  return p;
}

const A = {
  domain_get:             new NativeFunction(E('il2cpp_domain_get'), 'pointer', []),
  domain_get_assemblies:  new NativeFunction(E('il2cpp_domain_get_assemblies'), 'pointer', ['pointer', 'pointer']),
  assembly_get_image:     new NativeFunction(E('il2cpp_assembly_get_image'), 'pointer', ['pointer']),
  image_get_class_count:  new NativeFunction(E('il2cpp_image_get_class_count'), 'uint32', ['pointer']),
  image_get_class:        new NativeFunction(E('il2cpp_image_get_class'), 'pointer', ['pointer', 'uint32']),
  class_get_name:         new NativeFunction(E('il2cpp_class_get_name'), 'pointer', ['pointer']),
  class_get_namespace:    new NativeFunction(E('il2cpp_class_get_namespace'), 'pointer', ['pointer']),
  class_get_methods:      new NativeFunction(E('il2cpp_class_get_methods'), 'pointer', ['pointer', 'pointer']),
  method_get_name:        new NativeFunction(E('il2cpp_method_get_name'), 'pointer', ['pointer']),
  method_get_param_count: new NativeFunction(E('il2cpp_method_get_param_count'), 'uint32', ['pointer']),
  class_get_fields:       new NativeFunction(E('il2cpp_class_get_fields'), 'pointer', ['pointer', 'pointer']),
  field_get_name:         new NativeFunction(E('il2cpp_field_get_name'), 'pointer', ['pointer']),
  thread_attach:          new NativeFunction(E('il2cpp_thread_attach'), 'pointer', ['pointer']),
};

// 想看的类型：改这里
const FILTERS = [/Bolt/i, /Offline/i, /Storage/i, /Proto/i, /LocalBolt/i];

function cstr(p) {
  if (p.isNull()) return '';
  try { return p.readUtf8String(); } catch (e) { return ''; }
}

function match(s) {
  for (let i = 0; i < FILTERS.length; i++) if (FILTERS[i].test(s)) return true;
  return false;
}

function dumpClass(klass) {
  const ns = cstr(A.class_get_namespace(klass));
  const nm = cstr(A.class_get_name(klass));
  const full = ns ? ns + '.' + nm : nm;
  if (!match(full)) return false;

  console.log('\n=== ' + full + '  @ ' + klass);

  // 字段
  const fIt = Memory.alloc(Process.pointerSize);
  fIt.writePointer(ptr(0));
  let f;
  const fields = [];
  while (!(f = A.class_get_fields(klass, fIt)).isNull()) {
    fields.push(cstr(A.field_get_name(f)));
  }
  if (fields.length) console.log('  fields: ' + fields.join(', '));

  // 方法
  const mIt = Memory.alloc(Process.pointerSize);
  mIt.writePointer(ptr(0));
  let m;
  const methods = [];
  while (!(m = A.class_get_methods(klass, mIt)).isNull()) {
    const pn = A.method_get_param_count(m);
    methods.push(cstr(A.method_get_name(m)) + '/' + pn);
  }
  if (methods.length) console.log('  methods: ' + methods.join(', '));
  return true;
}

function main() {
  const dom = A.domain_get();
  A.thread_attach(dom);

  const cntPtr = Memory.alloc(4);
  const asms = A.domain_get_assemblies(dom, cntPtr);
  const n = cntPtr.readU32();
  console.log('[*] assemblies: ' + n);

  let hits = 0;
  for (let i = 0; i < n; i++) {
    const asm = asms.add(i * Process.pointerSize).readPointer();
    const img = A.assembly_get_image(asm);
    if (img.isNull()) continue;
    const cc = A.image_get_class_count(img);
    for (let k = 0; k < cc; k++) {
      const klass = A.image_get_class(img, k);
      if (klass.isNull()) continue;
      if (dumpClass(klass)) hits++;
    }
  }
  console.log('\n[*] matched classes: ' + hits);
  console.log('[*] done — 把这些行贴回来，我给你生成 hook 脚本');
}

// 等 Unity 初始化完再跑
setTimeout(() => { try { main(); } catch (e) { console.log('[!] ' + e.message); } }, 6000);
