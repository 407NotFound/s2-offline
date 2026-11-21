// S2Fix v2 — Standoff 2 (Unity 2022.3 / IL2CPP) iPhone 15 Pro 修复 + 诊断
//
// v1 已解决：120Hz（Info.plist CADisableMinimumFrameDuration + 强制 targetFrameRate）
// v2 目标：
//   1) 陀螺仪：不靠猜类名，全程序集扫描方法名后挂钩
//        IsGyroAvailable / get_supportsGyroscope / SupportsGyroscope / get_gyro
//      并把 GetDeviceModel 打出来（判定游戏是否走机型白名单）
//   2) 纵横比 / 视野 / 手视野 / 黑色天空「应用不了」：
//      挂 PlayerPrefs 的 Set*/Get* + Camera.set_fieldOfView + Screen.SetResolution + Camera.set_aspect
//      全量写日志，看「应用」那一刻到底写了什么、有没有写到。
//   3) 日志落 Documents/s2fix.log，配合 Info.plist 的 UIFileSharingEnabled 可在「文件」App 里直接取。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <unistd.h>

#define S2LOG(fmt, ...) s2log(fmt, ##__VA_ARGS__)

static NSString *g_logPath;

static void s2log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[S2Fix] %@", msg);
    if (!g_logPath) return;
    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS"; });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    if (!fh) {
        [line writeToFile:g_logPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

#pragma mark - il2cpp

static void *(*fn_domain_get)(void);
static void *(*fn_domain_get_assemblies)(void *, size_t *);
static void *(*fn_assembly_get_image)(void *);
static void *(*fn_image_get_class_count)(void *);
static void *(*fn_image_get_class)(void *, size_t);
static void *(*fn_class_get_methods)(void *, void **);
static void *(*fn_class_get_name)(void *);
static void *(*fn_class_get_namespace)(void *);
static const char *(*fn_method_get_name)(void *);
static int32_t (*fn_method_get_param_count)(void *);
static void *(*fn_domain_assembly_open)(void *, const char *);
static void *(*fn_class_from_name)(void *, const char *, const char *);
static void *(*fn_class_get_method_from_name)(void *, const char *, int);
static void *(*fn_thread_attach)(void *);

static void *g_domain;
static int g_hooked;

static void resolve_il2cpp(void) {
    void *h = dlopen(NULL, RTLD_NOW);
    if (!h) return;
#define SYM(n) fn_##n = dlsym(h, "il2cpp_" #n)
    SYM(domain_get); SYM(domain_get_assemblies); SYM(assembly_get_image);
    SYM(image_get_class_count); SYM(image_get_class); SYM(class_get_methods);
    SYM(class_get_name); SYM(class_get_namespace); SYM(method_get_name);
    SYM(method_get_param_count); SYM(domain_assembly_open); SYM(class_from_name);
    SYM(class_get_method_from_name); SYM(thread_attach);
#undef SYM
}

static NSString *il2s(void *s) {   // Il2CppString: [klass][monitor][len:i32][utf16 chars]
    if (!s) return @"(null)";
    int32_t n = *(int32_t *)((char *)s + 16);
    if (n < 0 || n > 4096) n = 0;
    const unichar *p = (const unichar *)((char *)s + 20);
    return [[NSString alloc] initWithCharacters:p length:n];
}

static void patch_pointer(void *methodInfo, void *replacement) {
    void **slot = (void **)methodInfo;
    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0xFFF;
    vm_protect(mach_task_self(), page, 0x4000, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *slot = replacement;
}

#pragma mark - 替换函数（v1 已有行为保留）

static BOOL r_supportsGyroscope(void *m) { return YES; }
static BOOL r_isGyroAvailable(void *m) { return YES; }

static int g_fps = 120;
static void (*o_setTargetFrameRate)(int, void *);
static void r_setTargetFrameRate(int v, void *m) {
    if (o_setTargetFrameRate) o_setTargetFrameRate(g_fps, m);
}

static void r_setFieldOfView(void *cam, float v, void *m) { S2LOG("Camera.fieldOfView <- %.2f", v); }
static void r_setAspect(void *cam, float v, void *m) { S2LOG("Camera.aspect <- %.4f", v); }
static void r_setResolution(void *a, void *b, void *c, void *m) { S2LOG("Screen.SetResolution(...)"); }

static void r_prefsSetFloat(void *k, float v, void *m) { S2LOG("PlayerPrefs.SetFloat(%@) = %.3f", il2s(k), v); }
static void r_prefsSetInt(void *k, int v, void *m) { S2LOG("PlayerPrefs.SetInt(%@) = %d", il2s(k), v); }
static void r_prefsSetString(void *k, void *v, void *m) { S2LOG("PlayerPrefs.SetString(%@) = %@", il2s(k), il2s(v)); }

#pragma mark - 扫描挂钩

typedef struct { const char *name; void *repl; int argc; } hookwant;

static const hookwant kWants[] = {
    { "IsGyroAvailable",       (void *)r_isGyroAvailable,     0 },
    { "get_supportsGyroscope", (void *)r_supportsGyroscope,   0 },
    { "get_fieldOfView",       NULL,                           0 }, // 只占位，不挂
};

static void scan_all(void) {
    if (!g_domain) return;
    size_t n = 0;
    void **asms = (void **)fn_domain_get_assemblies(g_domain, &n);
    S2LOG("scan: %zu assemblies", n);
    for (size_t a = 0; a < n; a++) {
        void *img = fn_assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = (size_t)(uintptr_t)fn_image_get_class_count(img);
        for (size_t i = 0; i < cc; i++) {
            void *k = fn_image_get_class(img, i);
            if (!k) continue;
            void *it = NULL;
            void *m;
            while ((m = fn_class_get_methods(k, &it))) {
                const char *mn = fn_method_get_name(m);
                if (!mn) continue;
                for (unsigned j = 0; j < sizeof(kWants)/sizeof(kWants[0]); j++) {
                    if (!kWants[j].repl) continue;
                    if (strcmp(mn, kWants[j].name) == 0 &&
                        fn_method_get_param_count(m) == kWants[j].argc) {
                        S2LOG("hook %s.%s::%s (%d args)",
                              fn_class_get_namespace(k) ? fn_class_get_namespace(k) : "",
                              fn_class_get_name(k), mn, kWants[j].argc);
                        patch_pointer(m, kWants[j].repl);
                        g_hooked++;
                    }
                }
            }
        }
    }
    S2LOG("scan done, hooked %d methods", g_hooked);
}

static void *hook_named(const char *ns, const char *cls, const char *name, int argc, void *repl, const char *asmName) {
    if (!g_domain) return NULL;
    void *as = fn_domain_assembly_open(g_domain, asmName);
    if (!as) { S2LOG("assembly %s missing", asmName); return NULL; }
    void *img = fn_assembly_get_image(as);
    if (!img) return NULL;
    void *k = fn_class_from_name(img, ns, cls);
    if (!k) { S2LOG("class %s.%s NOT found", ns, cls); return NULL; }
    void *m = fn_class_get_method_from_name(k, name, argc);
    if (!m) { S2LOG("method %s::%s/%d NOT found", cls, name, argc); return NULL; }
    void *old = *(void **)m;
    patch_pointer(m, repl);
    S2LOG("hook %s.%s::%s (old=%p)", ns, cls, name, old);
    return old;
}

#pragma mark - install

static void install(void) {
    S2LOG("=== install v2 ===");
    S2LOG("device=%@ sys=%@", [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]);
    scan_all();

    const char *unity = "UnityEngine.CoreModule";
    o_setTargetFrameRate = (void (*)(int, void *))hook_named("UnityEngine", "Application", "set_targetFrameRate", 1, (void *)r_setTargetFrameRate, unity);
    hook_named("UnityEngine", "Camera",      "set_fieldOfView", 1, (void *)r_setFieldOfView, unity);
    hook_named("UnityEngine", "Camera",      "set_aspect",      1, (void *)r_setAspect,      unity);
    hook_named("UnityEngine", "Screen",      "SetResolution",   3, (void *)r_setResolution,  unity);
    hook_named("UnityEngine", "PlayerPrefs", "SetFloat",        2, (void *)r_prefsSetFloat,  unity);
    hook_named("UnityEngine", "PlayerPrefs", "SetInt",          2, (void *)r_prefsSetInt,    unity);
    hook_named("UnityEngine", "PlayerPrefs", "SetString",       2, (void *)r_prefsSetString, unity);

    if (o_setTargetFrameRate) {
        S2LOG("forcing targetFrameRate=%d now", g_fps);
        o_setTargetFrameRate(g_fps, NULL);
    }
    S2LOG("=== install done ===");
}

static void bootstrap(void) {
    resolve_il2cpp();
    for (int i = 0; i < 60 && !fn_domain_get; i++) { usleep(200 * 1000); resolve_il2cpp(); }
    S2LOG("il2cpp domain_get=%p asm_open=%p class_from_name=%p", fn_domain_get, fn_domain_assembly_open, fn_class_from_name);
    for (int i = 0; i < 150; i++) {
        g_domain = fn_domain_get ? fn_domain_get() : NULL;
        if (g_domain) break;
        usleep(200 * 1000);
    }
    S2LOG("domain=%p", g_domain);
    if (!g_domain) return;
    if (fn_thread_attach) fn_thread_attach(g_domain);
    usleep(1200 * 1000);
    install();
}

__attribute__((constructor))
static void s2fix_init(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    g_logPath = [docs stringByAppendingPathComponent:@"s2fix.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:[NSData data] attributes:nil];
    S2LOG("loaded pid=%d uid=%d log=%@", getpid(), getuid(), g_logPath);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ bootstrap(); });
}
