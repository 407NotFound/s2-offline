// OfflineOnly.m — 把「只玩离线」固化进 IPA 的补丁 dylib
//
// 原理：不删代码（IL2CPP 原生代码删了必崩），只做两件事
//   1) 写持久化开关：bolt_force_localhost / AccountModeField
//   2) 运行时改 MethodInfo->methodPointer：把「是否已登录 / 是否在线」这类
//      无参 getter 换成 return 1 的 stub。不需要 substrate / fishhook / Dobby，
//      纯内存写 + vm_protect，侧载包也能跑。
//
// 编译（macOS + theos）:
//   make                      # 产出 .theos/obj/OfflineOnly.dylib
// 或手搓（Xcode SDK，二选一）:
//   xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -o OfflineOnly.dylib \
//        OfflineOnly.m -framework Foundation -fobjc-arc -miphoneos-version-min=12.0
//
// 注入 + 重签: 见 tools/repack_ipa.sh

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>

// ---------- il2cpp 导出类型 ----------
typedef void *(*fn_ptr0)(void);
typedef void **(*fn_asms)(void *, uint32_t *);
typedef void *(*fn_p1)(void *);
typedef uint32_t (*fn_u32_p1)(void *);
typedef void *(*fn_p2)(void *, uint32_t);
typedef void *(*fn_iter)(void *, void **);

static void *il2cpp_sym(const char *n) { return dlsym(RTLD_DEFAULT, n); }

// 替换后的 stub：无参、返回 1 的 int 函数
static int stub_return_1(void) { return 1; }

// MethodInfo->methodPointer 位于偏移 0（Unity 2019+ 全版本适用）
static BOOL replace_with_true(void *methodInfo) {
    if (!methodInfo) return NO;
    void **slot = (void **)methodInfo;
    if (*slot == (void *)&stub_return_1) return YES;   // 已替换
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)slot, sizeof(void *),
                                  false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[OfflineOnly] vm_protect failed: %d", kr);
        return NO;
    }
    *slot = (void *)&stub_return_1;
    return YES;
}

static void set_prefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:YES forKey:@"bolt_force_localhost"];
    [d setObject:@"Offline" forKey:@"AccountModeField"];
    [d synchronize];
    NSLog(@"[OfflineOnly] prefs forced (bolt_force_localhost=1, AccountModeField=Offline)");
}

static BOOL is_bool_getter(const char *n) {
    static const char *names[] = {
        "get_IsOffline", "get_Offline", "get_IsAuthorized", "get_IsAuthenticated",
        "get_IsLoggedIn", "get_HasSession", "get_IsOnline", "get_IsGuest",
        "get_CanPlayOffline", "get_IsConnected", "get_HasCredentials", "get_IsReady",
        NULL
    };
    for (int i = 0; names[i]; i++) if (strcmp(n, names[i]) == 0) return YES;
    return NO;
}

static BOOL class_of_interest(const char *full) {
    return (strstr(full, "Account") || strstr(full, "Auth") ||
            strstr(full, "Session") || strstr(full, "Offline") ||
            strstr(full, "LocalBolt") || strstr(full, "Bolt")) ? YES : NO;
}

static void patch_types(void) {
    fn_ptr0  domain_get     = (fn_ptr0)il2cpp_sym("il2cpp_domain_get");
    fn_asms  domain_asms    = (fn_asms)il2cpp_sym("il2cpp_domain_get_assemblies");
    fn_p1    asm_image      = (fn_p1)il2cpp_sym("il2cpp_assembly_get_image");
    fn_u32_p1 image_cc      = (fn_u32_p1)il2cpp_sym("il2cpp_image_get_class_count");
    fn_p2    image_class    = (fn_p2)il2cpp_sym("il2cpp_image_get_class");
    fn_p1    class_name     = (fn_p1)il2cpp_sym("il2cpp_class_get_name");
    fn_p1    class_ns       = (fn_p1)il2cpp_sym("il2cpp_class_get_namespace");
    fn_iter  class_methods  = (fn_iter)il2cpp_sym("il2cpp_class_get_methods");
    fn_p1    method_name    = (fn_p1)il2cpp_sym("il2cpp_method_get_name");
    fn_u32_p1 method_params = (fn_u32_p1)il2cpp_sym("il2cpp_method_get_param_count");
    fn_p1    thread_attach  = (fn_p1)il2cpp_sym("il2cpp_thread_attach");

    if (!domain_get || !domain_asms || !image_class || !class_methods) {
        NSLog(@"[OfflineOnly] il2cpp symbols missing, abort");
        return;
    }

    void *domain = domain_get();
    if (!domain) { NSLog(@"[OfflineOnly] no domain"); return; }
    if (thread_attach) thread_attach(domain);

    uint32_t n = 0;
    void **asms = domain_asms(domain, &n);
    if (!asms) return;

    int patched = 0;
    for (uint32_t i = 0; i < n; i++) {
        void *img = asm_image(asms[i]);
        if (!img) continue;
        uint32_t cc = image_cc ? image_cc(img) : 0;
        for (uint32_t k = 0; k < cc; k++) {
            void *kl = image_class(img, k);
            if (!kl) continue;
            const char *nm = class_name ? class_name(kl) : "";
            const char *ns = class_ns ? class_ns(kl) : "";
            char full[512];
            snprintf(full, sizeof(full), "%s.%s", ns ? ns : "", nm ? nm : "");
            if (!class_of_interest(full)) continue;

            void *it = NULL;
            void *m = NULL;
            while ((m = class_methods(kl, &it)) != NULL) {
                const char *mn = method_name ? method_name(m) : NULL;
                if (!mn) continue;
                if (method_params && method_params(m) != 0) continue;
                if (!is_bool_getter(mn)) continue;
                if (replace_with_true(m)) {
                    patched++;
                    NSLog(@"[OfflineOnly] patched %s::%s", full, mn);
                }
            }
        }
    }
    NSLog(@"[OfflineOnly] total patched = %d", patched);
}

__attribute__((constructor))
static void offline_only_init(void) {
    @autoreleasepool {
        NSLog(@"[OfflineOnly] loaded");
        set_prefs();
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            for (int i = 0; i < 240; i++) {          // 最多等 2 分钟
                usleep(500 * 1000);
                fn_ptr0 domain_get = (fn_ptr0)il2cpp_sym("il2cpp_domain_get");
                if (domain_get && domain_get()) {
                    patch_types();
                    return;
                }
            }
            NSLog(@"[OfflineOnly] timeout waiting for il2cpp domain");
        });
    }
}
