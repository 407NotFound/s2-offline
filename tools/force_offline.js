/*
 * force_offline.js — 验证「这游戏能不能只靠 localbolt 跑起来」
 *
 * 目标：不改包、不签名的前提下，用运行时手段把 App 逼进离线账号，
 *      看它是否还需要联网（auth / rpc / firebase）才能进主菜单。
 *      跑通了 → 再固化成补丁版 IPA（见 tools/repack_ipa.sh + tweak/）。
 *
 * 用法：
 *   frida -U -f com.Chillow.StandChillow -l force_offline.js --no-pause
 *   # 观察日志：哪一步卡住、报什么错，就是必须改的那一处
 */
'use strict';

const LIB = 'UnityFramework';
const PREF_KEYS = ['bolt_force_localhost', 'bolt', 'boltPlayer', 'bolt_avatars', 'AccountModeField'];

/* ---------- 1) 先把持久化开关写进去 ---------- */
function setPrefs() {
  const d = ObjC.classes.NSUserDefaults.standardUserDefaults();
  for (const k of PREF_KEYS) {
    const cur = d.objectForKey_(k);
    console.log('[*] pref ' + k + ' = ' + (cur ? cur.toString() : '<nil>'));
  }
  d.setBool_forKey_(1, 'bolt_force_localhost');
  d.setObject_forKey_('Offline', 'AccountModeField');
  d.synchronize();
  console.log('[*] prefs forced: bolt_force_localhost=1, AccountModeField=Offline');
}

/* ---------- 2) il2cpp 帮助函数 ---------- */
function E(n) { return Module.findExportByName(LIB, n); }
function cstr(p) { try { return p.isNull() ? '' : p.readUtf8String(); } catch (e) { return ''; } }

function il2cpp() {
  const need = ['il2cpp_domain_get', 'il2cpp_domain_get_assemblies', 'il2cpp_assembly_get_image',
                'il2cpp_image_get_class_count', 'il2cpp_image_get_class', 'il2cpp_class_get_name',
                'il2cpp_class_get_namespace', 'il2cpp_class_get_methods', 'il2cpp_method_get_name',
                'il2cpp_method_get_param_count', 'il2cpp_thread_attach'];
  for (const n of need) if (!E(n)) return null;
  const A = {
    domain: new NativeFunction(E('il2cpp_domain_get'), 'pointer', []),
    asms:   new NativeFunction(E('il2cpp_domain_get_assemblies'), 'pointer', ['pointer', 'pointer']),
    image:  new NativeFunction(E('il2cpp_assembly_get_image'), 'pointer', ['pointer']),
    cc:     new NativeFunction(E('il2cpp_image_get_class_count'), 'uint32', ['pointer']),
    klass:  new NativeFunction(E('il2cpp_image_get_class'), 'pointer', ['pointer', 'uint32']),
    cname:  new NativeFunction(E('il2cpp_class_get_name'), 'pointer', ['pointer']),
    cns:    new NativeFunction(E('il2cpp_class_get_namespace'), 'pointer', ['pointer']),
    methods:new NativeFunction(E('il2cpp_class_get_methods'), 'pointer', ['pointer', 'pointer']),
    mname:  new NativeFunction(E('il2cpp_method_get_name'), 'pointer', ['pointer']),
    mparams:new NativeFunction(E('il2cpp_method_get_param_count'), 'uint32', ['pointer']),
    attach: new NativeFunction(E('il2cpp_thread_attach'), 'pointer', ['pointer']),
  };
  return A;
}

/* ---------- 3) 找 AccountMode / Auth 的判定方法，记录 + 篡改返回值 ---------- */
const BOOL_GETTERS = /^(get_IsOffline|get_Offline|get_IsAuthorized|get_IsAuthenticated|get_IsLoggedIn|get_HasSession|get_IsOnline|get_IsGuest|get_CanPlayOffline)$/;
const MODE_GETTERS = /^(get_AccountMode|get_Mode|get_CurrentAccountMode|get_AccountModeField)$/;

function patchIl2cpp() {
  const A = il2cpp();
  if (!A) { console.log('[!] il2cpp exports missing'); return; }

  const dom = A.domain();
  A.attach(dom);
  const cnt = Memory.alloc(4);
  const asms = A.asms(dom, cnt);
  const n = cnt.readU32();

  const findings = [];
  for (let i = 0; i < n; i++) {
    const img = A.image(asms.add(i * Process.pointerSize).readPointer());
    if (img.isNull()) continue;
    const cc = A.cc(img);
    for (let k = 0; k < cc; k++) {
      const kl = A.klass(img, k);
      if (kl.isNull()) continue;
      const full = (cstr(A.cns(kl)) + '.' + cstr(A.cname(kl))).replace(/^\./, '');
      if (!/Account|Auth|Bolt|Session|Offline/i.test(full)) continue;

      const it = Memory.alloc(Process.pointerSize);
      it.writePointer(ptr(0));
      let m;
      while (!(m = A.methods(kl, it)).isNull()) {
        const mn = cstr(A.mname(m));
        const np = A.mparams(m);
        if (np !== 0) continue;

        // MethodInfo->methodPointer 在偏移 0；直接换函数体 = 不需要任何 hook 框架
        if (BOOL_GETTERS.test(mn)) {
          const fn = m.readPointer();
          if (fn.isNull()) continue;
          const val = /Offline|Guest|CanPlay/i.test(mn) ? 1 : 1; // 一律 true
          const stub = new NativeCallback(function () { return val; }, 'int', []);
          Memory.protect(fn, 8, 'rwx');
          fn.writePointer(stub);
          findings.push(full + '::' + mn + ' -> ' + val);
        } else if (MODE_GETTERS.test(mn)) {
          // 返回枚举：Offline 通常是 0/1/2 之一，先记录真实值
          const fn = m.readPointer();
          if (fn.isNull()) continue;
          try {
            const orig = new NativeFunction(fn, 'int', []);
            console.log('[*] ' + full + '::' + mn + '() = ' + orig());
          } catch (e) {}
        }
      }
    }
  }
  console.log('\n[*] patched ' + findings.length + ' getters:');
  findings.slice(0, 60).forEach(f => console.log('    ' + f));
}

function main() {
  setPrefs();
  patchIl2cpp();
  console.log('[*] 现在手动走一遍登录/主菜单，把卡住的地方和报错贴回来');
}

setTimeout(() => { try { main(); } catch (e) { console.log('[!] ' + e); } }, 6000);
