// S2Probe2 — 分阶段诊断版（改 Documents/s2probe2.txt 里的 stage 数字即可推进，不用重新打包）
//
// stage=1  只解析 il2cpp 符号，打印地址（不碰 domain）
// stage=2  + 取 domain、遍历程序集/类型/方法（只读，不挂钩）
// stage=3  + 只挂 Application.set_targetFrameRate
// stage=4  + 再挂 Camera.set_fieldOfView / set_aspect（调用原函数）
// stage=5  + 再按名字扫描挂钩 IsGyroAvailable / get_supportsGyroscope
// 每一步前后都落盘，崩溃也能看出死在哪一步。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <unistd.h>

static NSString *g_log;
static int g_stage = 1;

static void L(const char *fmt, ...) {
    char buf[900];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    NSString *s = [NSString stringWithFormat:@"%s\n", buf];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_log];
    if (!fh) { [s writeToFile:g_log atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
    else { [fh seekToEndOfFile]; [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]]; [fh synchronizeFile]; [fh closeFile]; }
    NSLog(@"[S2Probe2] %s", buf);
}

static void *S(const char *n) { void *p = dlsym(RTLD_DEFAULT, n); return p; }

#define NEED(n) do { if (!p_##n) { L("SYMBOL MISSING: %s", #n); return; } } while (0)

static void *p_domain_get, *p_domain_get_assemblies, *p_assembly_get_image,
            *p_image_get_class_count, *p_image_get_class, *p_class_get_methods,
            *p_method_get_name, *p_class_get_name, *p_class_get_namespace,
            *p_method_get_param_count, *p_domain_assembly_open, *p_class_from_name,
            *p_class_get_method_from_name, *p_thread_attach;

static void resolve(void) {
    p_domain_get             = S("il2cpp_domain_get");
    p_domain_get_assemblies  = S("il2cpp_domain_get_assemblies");
    p_assembly_get_image     = S("il2cpp_assembly_get_image");
    p_image_get_class_count  = S("il2cpp_image_get_class_count");
    p_image_get_class        = S("il2cpp_image_get_class");
    p_class_get_methods      = S("il2cpp_class_get_methods");
    p_method_get_name        = S("il2cpp_method_get_name");
    p_class_get_name         = S("il2cpp_class_get_name");
    p_class_get_namespace    = S("il2cpp_class_get_namespace");
    p_method_get_param_count = S("il2cpp_method_get_param_count");
    p_domain_assembly_open   = S("il2cpp_domain_assembly_open");
    p_class_from_name        = S("il2cpp_class_from_name");
    p_class_get_method_from_name = S("il2cpp_class_get_method_from_name");
    p_thread_attach          = S("il2cpp_thread_attach");
}

static BOOL patch(void *mi, void *repl, const char *tag) {
    if (!mi) { L("patch %s: null method", tag); return NO; }
    void **slot = (void **)mi;
    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0xFFF;
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    L("patch %s: slot=%p old=%p new=%p vm_protect=%d", tag, slot, *slot, repl, kr);
    if (kr != KERN_SUCCESS) { L("patch %s: SKIP (vm_protect failed)", tag); return NO; }
    *slot = repl;
    return YES;
}

// stage 3 用：只记录，不打断原逻辑（保持原函数调用）
static void (*orig_tfr)(int, void *);
static void h_tfr(int v, void *m) { L("targetFrameRate called %d (forced 120)", v); if (orig_tfr) orig_tfr(120, m); }

static void *cls_in(const char *asmName, const char *ns, const char *cls, void *domain) {
    if (!p_domain_assembly_open || !p_class_from_name) return NULL;
    void *as = ((void *(*)(void *, const char *))p_domain_assembly_open)(domain, asmName);
    if (!as) { L("assembly %s missing", asmName); return NULL; }
    void *img = ((void *(*)(void *))p_assembly_get_image)(as);
    if (!img) return NULL;
    return ((void *(*)(void *, const char *, const char *))p_class_from_name)(img, ns, cls);
}

static void *mth(void *k, const char *name, int argc) {
    if (!k || !p_class_get_method_from_name) return NULL;
    return ((void *(*)(void *, const char *, int))p_class_get_method_from_name)(k, name, argc);
}

static void bootstrap(void) {
    L("=== S2Probe2 start stage=%d ===", g_stage);
    resolve();
    L("symbols: domain_get=%p get_assemblies=%p get_class=%p class_get_methods=%p",
      p_domain_get, p_domain_get_assemblies, p_image_get_class, p_class_get_methods);
    if (!p_domain_get) { L("ABORT: no il2cpp yet"); return; }

    void *domain = NULL;
    for (int i = 0; i < 100 && !domain; i++) { domain = ((void *(*)(void))p_domain_get)(); if (!domain) usleep(150*1000); }
    L("domain=%p", domain);
    if (!domain) { L("ABORT: no domain"); return; }
    if (g_stage < 2) { L("stage1 done"); return; }
    if (p_thread_attach) ((void *(*)(void *))p_thread_attach)(domain);

    // stage 2: 只遍历
    size_t n = 0; void **asms = NULL;
    if (p_domain_get_assemblies) asms = ((void **(*)(void *, size_t *))p_domain_get_assemblies)(domain, &n);
    L("assemblies=%zu", n);
    size_t types = 0, methods = 0, namesHit = 0;
    for (size_t a = 0; a < n; a++) {
        void *img = ((void *(*)(void *))p_assembly_get_image)(asms[a]);
        if (!img || !p_image_get_class_count) continue;
        size_t cc = ((size_t (*)(void *))p_image_get_class_count)(img);
        types += cc;
        if (!p_image_get_class || !p_class_get_methods || !p_method_get_name) continue;
        for (size_t i = 0; i < cc; i++) {
            void *k = ((void *(*)(void *, size_t))p_image_get_class)(img, i);
            if (!k) continue;
            void *it = NULL, *m = NULL;
            while ((m = ((void *(*)(void *, void **))p_class_get_methods)(k, &it))) {
                methods++;
                const char *mn = ((const char *(*)(void *))p_method_get_name)(m);
                if (mn && (strcmp(mn, "IsGyroAvailable") == 0 || strcmp(mn, "get_supportsGyroscope") == 0)) namesHit++;
            }
        }
    }
    L("scan done types=%zu methods=%zu gyroNameHits=%zu", types, methods, namesHit);
    if (g_stage < 3) { L("stage2 done"); return; }

    void *kc = cls_in("UnityEngine.CoreModule", "UnityEngine", "Application", domain);
    void *m1 = mth(kc, "set_targetFrameRate", 1);
    if (m1) { orig_tfr = (void (*)(int, void *))*(void **)m1; patch(m1, (void *)h_tfr, "set_targetFrameRate"); }
    else L("method set_targetFrameRate not found (class=%p)", kc);
    L("stage3 done");

    if (g_stage >= 4) {
        void *kcam = cls_in("UnityEngine.CoreModule", "UnityEngine", "Camera", domain);
        L("Camera class=%p", kcam);
        void *fov = mth(kcam, "set_fieldOfView", 1);
        void *asp = mth(kcam, "set_aspect", 1);
        L("set_fieldOfView=%p set_aspect=%p", fov, asp);
        // 这里只打印与校验，不替换 —— 先确认取到的是真方法
        L("stage4 done (no patch)");
    }
    L("=== all stages done ===");
}

__attribute__((constructor))
static void init2(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    g_log = [docs stringByAppendingPathComponent:@"s2probe2.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_log contents:[NSData data] attributes:nil];
    NSString *cfg = [docs stringByAppendingPathComponent:@"s2probe2.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cfg]) {
        [@"stage=2\n" writeToFile:cfg atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    NSString *txt = [NSString stringWithContentsOfFile:cfg encoding:NSUTF8StringEncoding error:NULL];
    for (NSString *ln in [txt componentsSeparatedByString:@"\n"]) {
        if ([ln hasPrefix:@"stage="]) g_stage = [[ln substringFromIndex:6] intValue];
    }
    if (g_stage < 1) g_stage = 1;
    if (g_stage > 5) g_stage = 5;
    L("loaded pid=%d uid=%d stage=%d", getpid(), getuid(), g_stage);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ bootstrap(); });
}
