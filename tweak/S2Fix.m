// S2Fix v6 — 修正版
// v3/v5 的致命问题：il2cpp_* 符号不在主程序的符号空间里，UnityFramework 是独立 framework，
// dlsym(RTLD_DEFAULT) 全是 0 —— 所以之前所有版本一条 hook 都没装上。
// v6：先 dlopen UnityFramework.framework/UnityFramework，再对它的 handle 取符号。
// 另：去掉 v3 的弹窗（启动早期 present UIAlertController 会直接把进程带走）。
//
// 配置 Documents/s2fix.txt:
//   stage=5   1符号 2遍历 3帧率 4视野/比例(记录) 5全量挂钩
//   fov=1.10  hands_fov=1.10  aspect=1.25  fps=120  gyro=1

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <unistd.h>

static NSString *g_log;
static int g_stage = 5;
static float g_fov = 1.10f, g_hands = 1.10f, g_aspect = 1.25f;
static int g_fps = 120, g_gyro = 1;
static void *g_uf;
static int g_attempt = 0;

static void try_init(void);
static void bootstrap_body(void *domain);
static void resolve(void);

static void L(const char *fmt, ...) {
    char buf[900];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    NSString *s = [NSString stringWithFormat:@"%s\n", buf];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_log];
    if (!fh) { [s writeToFile:g_log atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
    else { [fh seekToEndOfFile]; [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]]; [fh synchronizeFile]; [fh closeFile]; }
    NSLog(@"[S2Fix] %s", buf);
}

static void *ds(const char *n) {
    void *p = g_uf ? dlsym(g_uf, n) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, n);
    return p;
}

static void *p_domain_get, *p_domain_get_assemblies, *p_assembly_get_image,
            *p_image_get_class_count, *p_image_get_class, *p_class_get_methods,
            *p_method_get_name, *p_class_get_name, *p_class_get_namespace,
            *p_method_get_param_count, *p_domain_assembly_open, *p_class_from_name,
            *p_class_get_method_from_name, *p_thread_attach;

static void resolve(void) {
    p_domain_get = ds("il2cpp_domain_get");
    p_domain_get_assemblies = ds("il2cpp_domain_get_assemblies");
    p_assembly_get_image = ds("il2cpp_assembly_get_image");
    p_image_get_class_count = ds("il2cpp_image_get_class_count");
    p_image_get_class = ds("il2cpp_image_get_class");
    p_class_get_methods = ds("il2cpp_class_get_methods");
    p_method_get_name = ds("il2cpp_method_get_name");
    p_class_get_name = ds("il2cpp_class_get_name");
    p_class_get_namespace = ds("il2cpp_class_get_namespace");
    p_method_get_param_count = ds("il2cpp_method_get_param_count");
    p_domain_assembly_open = ds("il2cpp_domain_assembly_open");
    p_class_from_name = ds("il2cpp_class_from_name");
    p_class_get_method_from_name = ds("il2cpp_class_get_method_from_name");
    p_thread_attach = ds("il2cpp_thread_attach");
}

static BOOL open_unity(void) {
    if (g_uf) return YES;
    NSString *fw = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"UnityFramework.framework/UnityFramework"];
    const char *cands[] = {
        fw.UTF8String,
        "/private/var/containers/Bundle/Application/UnityFramework.framework/UnityFramework",
        "@rpath/UnityFramework.framework/UnityFramework",
        "UnityFramework",
    };
    for (int i = 0; i < 4; i++) {
        if (!cands[i]) continue;
        void *h = dlopen(cands[i], RTLD_NOW | RTLD_GLOBAL);
        L("dlopen[%d] %s -> %p %s", i, cands[i], h, h ? "" : dlerror());
        if (h) { g_uf = h; return YES; }
    }
    return NO;
}

static BOOL patch(void *mi, void *repl, const char *tag) {
    if (!mi) { L("patch %s: null method", tag); return NO; }
    void **slot = (void **)mi;
    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0xFFF;
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { L("patch %s: vm_protect rc=%d, skip", tag, kr); return NO; }
    L("patch %s @%p: %p -> %p", tag, slot, *slot, repl);
    *slot = repl;
    return YES;
}


// ---- 机器码级 hook：IL2CPP 对非虚方法编译成直接调用，改 MethodInfo->methodPointer 对
// 直接调用无效（那只是给反射/委托用的）。所以真正的修法是把函数体开头几条指令改掉。
static void dump_code(void *fn, const char *tag) {
    if (!fn) { L("code %s: null", tag); return; }
    uint32_t *w = (uint32_t *)fn;
    L("code %s @%p: %08x %08x %08x %08x", tag, fn, w[0], w[1], w[2], w[3]);
}

static BOOL wr_code(void *fn, const void *bytes, size_t n, const char *tag) {
    if (!fn) return NO;
    uintptr_t a = (uintptr_t)fn, page = a & ~(uintptr_t)0xFFF;
    size_t len = (a + n) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, len, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { L("wr %s: vm_protect rc=%d", tag, kr); return NO; }
    memcpy((void *)a, bytes, n);
    sys_icache_invalidate((void *)a, n);
    L("wr %s @%p ok", tag, fn);
    return YES;
}

// mov w0,#1 ; ret   → 恒返回 true
static BOOL hook_true(void *fn, const char *tag) {
    static const uint32_t ins[2] = {0x52800020u, 0xD65F03C0u};
    return wr_code(fn, ins, 8, tag);
}
// ret → 什么都不做
static BOOL hook_nop(void *fn, const char *tag) {
    static const uint32_t ins[1] = {0xD65F03C0u};
    return wr_code(fn, ins, 4, tag);
}

static void *cls_in(const char *asmName, const char *ns, const char *cls, void *domain) {
    if (!p_domain_assembly_open || !p_class_from_name || !p_assembly_get_image) return NULL;
    void *as = ((void *(*)(void *, const char *))p_domain_assembly_open)(domain, asmName);
    if (!as) { L("assembly %s missing", asmName); return NULL; }
    void *img = ((void *(*)(void *))p_assembly_get_image)(as);
    return img ? ((void *(*)(void *, const char *, const char *))p_class_from_name)(img, ns, cls) : NULL;
}
static void *mth(void *k, const char *name, int argc) {
    if (!k || !p_class_get_method_from_name) return NULL;
    return ((void *(*)(void *, const char *, int))p_class_get_method_from_name)(k, name, argc);
}

static void (*o_tfr)(int, void *);
static void h_tfr(int v, void *m) { if (o_tfr) o_tfr(g_fps, m); }

static void (*o_fov)(void *, float, void *);
static int g_fovLog;
static void h_fov(void *cam, float v, void *m) {
    if (g_fovLog < 10) { L("Camera.fieldOfView %.2f -> %.2f", v, v * g_fov); g_fovLog++; }
    if (o_fov) o_fov(cam, v * g_fov, m);
}
static void (*o_asp)(void *, float, void *);
static int g_aspLog;
static void h_asp(void *cam, float v, void *m) {
    float nv = g_aspect > 0.01f ? g_aspect : v;
    if (g_aspLog < 10) { L("Camera.aspect %.4f -> %.4f", v, nv); g_aspLog++; }
    if (o_asp) o_asp(cam, nv, m);
}

static BOOL h_gyro(void *m) { return g_gyro ? YES : NO; }

static void try_init(void) {
    g_attempt++;
    if (g_attempt > 30) { L("give up after %d attempts", g_attempt); return; }
    Class uac = NSClassFromString(@"UnityAppController");
    BOOL window = [UIApplication sharedApplication].keyWindow != nil || [UIApplication sharedApplication].windows.count > 0;
    L("attempt %d: UnityAppController=%d window=%d", g_attempt, uac != nil, window);
    if (!uac || !window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ try_init(); });
        return;
    }
    if (g_stage < 1) return;
    open_unity();
    resolve();
    L("symbols: domain_get=%p asm_open=%p class_from_name=%p", p_domain_get, p_domain_assembly_open, p_class_from_name);
    if (!p_domain_get) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ try_init(); });
        return;
    }
    void *domain = ((void *(*)(void))p_domain_get)();
    L("domain=%p", domain);
    if (!domain) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ try_init(); });
        return;
    }
    bootstrap_body(domain);
}

static void bootstrap_body(void *domain) {
    L("=== body start stage=%d ===", g_stage);
    if (g_stage < 2) { L("stage1 done"); return; }
    void *kcam = cls_in("UnityEngine.CoreModule", "UnityEngine", "Camera", domain);
    void *kapp = cls_in("UnityEngine.CoreModule", "UnityEngine", "Application", domain);
    L("classes: Application=%p Camera=%p", kapp, kcam);

    if (g_stage >= 3) {
        void *m = mth(kapp, "set_targetFrameRate", 1);
        if (m) {
            void *code = *(void **)m;
            dump_code(code, "set_targetFrameRate");
            o_tfr = (void (*)(int, void *))code;
            patch(m, (void *)h_tfr, "targetFrameRate(mi)");
            hook_nop(code, "set_targetFrameRate");
        } else L("set_targetFrameRate not found");
    }
    if (g_stage >= 4) {
        void *f = mth(kcam, "set_fieldOfView", 1);
        void *a = mth(kcam, "set_aspect", 1);
        L("fov=%p aspect=%p", f, a);
        if (f) { dump_code(*(void **)f, "set_fieldOfView"); o_fov = (void (*)(void *, float, void *))*(void **)f; patch(f, (void *)h_fov, "fieldOfView(mi)"); }
        if (a) { dump_code(*(void **)a, "set_aspect");    o_asp = (void (*)(void *, float, void *))*(void **)a; patch(a, (void *)h_asp, "aspect(mi)"); }
    }
    if (g_stage >= 5) {
        // 按名扫描陀螺仪能力方法
        if (!p_domain_get_assemblies || !p_class_get_methods || !p_method_get_name) { L("scan api missing"); return; }
        size_t n = 0; void **asms = ((void **(*)(void *, size_t *))p_domain_get_assemblies)(domain, &n);
        int hits = 0;
        for (size_t a2 = 0; a2 < n; a2++) {
            void *img = ((void *(*)(void *))p_assembly_get_image)(asms[a2]);
            if (!img || !p_image_get_class_count) continue;
            size_t cc = ((size_t (*)(void *))p_image_get_class_count)(img);
            if (!p_image_get_class) continue;
            for (size_t i = 0; i < cc; i++) {
                void *k = ((void *(*)(void *, size_t))p_image_get_class)(img, i);
                if (!k) continue;
                void *it = NULL, *m = NULL;
                while ((m = ((void *(*)(void *, void **))p_class_get_methods)(k, &it))) {
                    const char *mn = ((const char *(*)(void *))p_method_get_name)(m);
                    if (!mn) continue;
                    if ((strcmp(mn, "IsGyroAvailable") == 0 || strcmp(mn, "get_supportsGyroscope") == 0)
                        && ((int32_t (*)(void *))p_method_get_param_count)(m) == 0) {
                        L("gyro hook %s.%s::%s",
                          p_class_get_namespace ? ((const char *(*)(void *))p_class_get_namespace)(k) : "?",
                          p_class_get_name ? ((const char *(*)(void *))p_class_get_name)(k) : "?", mn);
                        void *code = *(void **)m;      // 原始函数体地址（必须在改 methodPointer 之前取）
                        dump_code(code, mn);
                        patch(m, (void *)h_gyro, mn);   // 反射/委托路径
                        hook_true(code, mn);            // 直接调用路径：函数体改成 mov w0,#1; ret
                        hits++;
                    }
                }
            }
        }
        L("gyro hooks installed=%d", hits);

        // 诊断：设备型号这条链。很多游戏用型号白名单判断陀螺仪，新机型不在表里就标"此设备上不可用"
        void *kinfo = cls_in("UnityEngine.CoreModule", "UnityEngine", "SystemInfo", domain);
        if (kinfo) {
            void *gm = mth(kinfo, "GetDeviceModel", 0);
            void *gt = mth(kinfo, "get_deviceModel", 0);
            L("SystemInfo: GetDeviceModel=%p", gm);
            if (gm) dump_code(*(void **)gm, "GetDeviceModel");
            if (gt && gt != gm) dump_code(*(void **)gt, "get_deviceModel");
        } else L("SystemInfo class missing");
    }
    L("=== v6 install done ===");
}


__attribute__((constructor))
static void init7(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    g_log = [docs stringByAppendingPathComponent:@"s2fix.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_log contents:[NSData data] attributes:nil];
    NSString *cfg = [docs stringByAppendingPathComponent:@"s2fix.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cfg]) {
        [@"stage=5\nfov=1.10\nhands_fov=1.10\naspect=1.25\nfps=120\ngyro=1\n"
            writeToFile:cfg atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    NSString *txt = [NSString stringWithContentsOfFile:cfg encoding:NSUTF8StringEncoding error:NULL];
    for (NSString *ln in [txt componentsSeparatedByString:@"\n"]) {
        NSArray *kv = [ln componentsSeparatedByString:@"="];
        if (kv.count < 2) continue;
        NSString *k = [kv[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *v = [kv[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([k isEqualToString:@"stage"]) g_stage = v.intValue;
        else if ([k isEqualToString:@"fov"]) g_fov = v.floatValue;
        else if ([k isEqualToString:@"hands_fov"]) g_hands = v.floatValue;
        else if ([k isEqualToString:@"aspect"]) g_aspect = v.floatValue;
        else if ([k isEqualToString:@"fps"]) g_fps = v.intValue;
        else if ([k isEqualToString:@"gyro"]) g_gyro = v.intValue;
    }
    L("loaded pid=%d stage=%d fov=%.2f aspect=%.2f (v7: 主线程延迟初始化)", getpid(), g_stage, g_fov, g_aspect);
    // 关键：绝不在这里碰 il2cpp，也不开线程；等 UIKit/Unity 都起来，回主线程再动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        try_init();
    });
}
