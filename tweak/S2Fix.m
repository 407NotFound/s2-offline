// S2Fix v3 — Standoff 2 iOS 修复补丁（离线账号可用，不依赖游戏内「应用」按钮）
//
// 设计前提（v2 实测反馈）：离线 localbolt 账号下，游戏内「视 → 其他」点应用会一直转圈，
// 说明那条 apply 链路在等一个不存在的服务器；陀螺仪也显示「此设备上不可用」。
// 所以 v3 不再指望 UI，直接在引擎层改值：
//   * 视野 / 手视野  → 拦截 Camera.set_fieldOfView，乘系数
//   * 纵横比        → 拦截 Camera.set_aspect，强制目标值
//   * 帧率          → 拦截 Application.set_targetFrameRate，强制 120
//   * 陀螺仪        → 全程序集按名挂钩 IsGyroAvailable / supportsGyroscope
// 配置放在 Documents/s2fix.txt，改完重启游戏生效，不用重新打包。
//
// 启动时弹一次窗（每次装包弹一次），用来确认 dylib 到底有没有被加载。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <unistd.h>

#define S2LOG(fmt, ...) s2log(fmt, ##__VA_ARGS__)

static NSString *g_logPath;

static void s2log(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    NSString *msg = [NSString stringWithUTF8String:buf];
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

#pragma mark - 配置

static float g_fovMult      = 1.00f;   // 视野系数（世界）
static float g_handsMult    = 1.00f;   // 手部视野系数
static float g_aspect       = 0.0f;    // 0 = 不干预；1.25 = 5:4；1.3333 = 4:3；1.6 = 16:10
static int   g_fps          = 120;
static int   g_gyro         = 1;

static NSString *g_cfgPath;
static NSString *g_docs;

static void load_config(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:g_cfgPath]) {
        NSString *def = @"# S2Fix 配置，改完重启游戏生效\n"
                        @"# fov: 视野系数, 1.00 = 原样, 1.10 = 放大 10%\n"
                        @"fov=1.10\n"
                        @"# hands_fov: 手部视野系数\n"
                        @"hands_fov=1.10\n"
                        @"# aspect: 0=不干预, 1.25=5:4, 1.3333=4:3, 1.6=16:10\n"
                        @"aspect=1.25\n"
                        @"# fps: 目标帧率\n"
                        @"fps=120\n"
                        @"# gyro: 1=强制可用\n"
                        @"gyro=1\n";
        [def writeToFile:g_cfgPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    NSString *txt = [NSString stringWithContentsOfFile:g_cfgPath encoding:NSUTF8StringEncoding error:NULL];
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (ln.length == 0 || [ln hasPrefix:@"#"]) continue;
        NSArray *kv = [ln componentsSeparatedByString:@"="];
        if (kv.count < 2) continue;
        NSString *k = [kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = [kv[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k isEqualToString:@"fov"])            g_fovMult   = v.floatValue;
        else if ([k isEqualToString:@"hands_fov"]) g_handsMult = v.floatValue;
        else if ([k isEqualToString:@"aspect"])    g_aspect    = v.floatValue;
        else if ([k isEqualToString:@"fps"])       g_fps       = v.intValue;
        else if ([k isEqualToString:@"gyro"])      g_gyro      = v.intValue;
    }
    S2LOG("config fov=%.3f hands=%.3f aspect=%.4f fps=%d gyro=%d",
          g_fovMult, g_handsMult, g_aspect, g_fps, g_gyro);
}

#pragma mark - il2cpp 符号

static void *(*fn_domain_get)(void);
static void *(*fn_domain_get_assemblies)(void *, size_t *);
static void *(*fn_assembly_get_image)(void *);
static size_t (*fn_image_get_class_count)(void *);
static void *(*fn_image_get_class)(void *, size_t);
static void *(*fn_class_get_methods)(void *, void **);
static const char *(*fn_class_get_name)(void *);
static const char *(*fn_class_get_namespace)(void *);
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

static NSString *il2s(void *s) {
    if (!s) return @"";
    int32_t n = *(int32_t *)((char *)s + 16);
    if (n < 0 || n > 4096) n = 0;
    return [[NSString alloc] initWithCharacters:(const unichar *)((char *)s + 20) length:n];
}
static const char *ilsc(void *s) {
    static __thread char buf[512];
    snprintf(buf, sizeof buf, "%s", [il2s(s) UTF8String]);
    return buf;
}

static void patch_pointer(void *methodInfo, void *replacement) {
    void **slot = (void **)methodInfo;
    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0xFFF;
    vm_protect(mach_task_self(), page, 0x4000, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *slot = replacement;
}

#pragma mark - 替换函数

static BOOL r_supportsGyroscope(void *m) { return g_gyro ? YES : NO; }
static BOOL r_isGyroAvailable(void *m) { return g_gyro ? YES : NO; }

static void (*o_setTargetFrameRate)(int, void *);
static void r_setTargetFrameRate(int v, void *m) {
    S2LOG("game set targetFrameRate=%d -> %d", v, g_fps);
    if (o_setTargetFrameRate) o_setTargetFrameRate(g_fps, m);
}

static void (*o_setFieldOfView)(void *, float, void *);
static void *(*g_getCameraName)(void *, void *);
static const char *cname(void *cam) { if (!g_getCameraName) return "?"; return ilsc(g_getCameraName(cam, NULL)); }
static int g_fovLog;
static void r_setFieldOfView(void *cam, float v, void *m) {
    float nv = v * g_fovMult;
    if (g_fovLog < 14) { S2LOG("Camera[%s].fieldOfView %.2f -> %.2f", cname(cam), v, nv); g_fovLog++; }
    if (o_setFieldOfView) o_setFieldOfView(cam, nv, m);
}

static void (*o_setAspect)(void *, float, void *);
static int g_aspectLog;
static void r_setAspect(void *cam, float v, void *m) {
    float nv = (g_aspect > 0.01f) ? g_aspect : v;
    if (g_aspectLog < 8) { S2LOG("Camera.aspect %.4f -> %.4f", v, nv); g_aspectLog++; }
    if (o_setAspect) o_setAspect(cam, nv, m);
}

static void r_prefsSetFloat(void *k, float v, void *m) { S2LOG("Prefs.SetFloat(%s)=%.3f", ilsc(k), v); }
static void r_prefsSetInt(void *k, int v, void *m)     { S2LOG("Prefs.SetInt(%s)=%d", ilsc(k), v); }
static void r_prefsSetString(void *k, void *v, void *m){ S2LOG("Prefs.SetString(%s)=%s", ilsc(k), ilsc(v)); }

#pragma mark - 扫描挂钩

typedef struct { const char *name; void *repl; int argc; int hit; } hookwant;

static hookwant kWants[] = {
    { "IsGyroAvailable",         (void *)r_isGyroAvailable,      0, 0 },
    { "get_supportsGyroscope",   (void *)r_supportsGyroscope,    0, 0 },
    { "SupportsGyroscope",       (void *)r_supportsGyroscope,    0, 0 },
};

static void scan_all(void) {
    if (!g_domain || !fn_domain_get_assemblies) return;
    size_t n = 0;
    void **asms = (void **)fn_domain_get_assemblies(g_domain, &n);
    S2LOG("scan %zu assemblies", n);
    size_t totalTypes = 0, totalMethods = 0;
    for (size_t a = 0; a < n; a++) {
        void *img = fn_assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = fn_image_get_class_count ? fn_image_get_class_count(img) : 0;
        totalTypes += cc;
        for (size_t i = 0; i < cc; i++) {
            void *k = fn_image_get_class ? fn_image_get_class(img, i) : NULL;
            if (!k) continue;
            void *it = NULL; void *m;
            while ((m = fn_class_get_methods(k, &it))) {
                totalMethods++;
                const char *mn = fn_method_get_name(m);
                if (!mn) continue;
                for (unsigned j = 0; j < sizeof(kWants)/sizeof(kWants[0]); j++) {
                    if (!kWants[j].repl || kWants[j].hit) continue;
                    if (strcmp(mn, kWants[j].name) == 0 &&
                        fn_method_get_param_count(m) == kWants[j].argc) {
                        S2LOG("HIT %s.%s::%s", fn_class_get_namespace(k) ?: "", fn_class_get_name(k) ?: "", mn);
                        patch_pointer(m, kWants[j].repl);
                        kWants[j].hit = 1; g_hooked++;
                    }
                }
            }
        }
    }
    S2LOG("scan done types=%zu methods=%zu hooked=%d", totalTypes, totalMethods, g_hooked);
    for (unsigned j = 0; j < sizeof(kWants)/sizeof(kWants[0]); j++)
        if (!kWants[j].hit) S2LOG("MISS %s", kWants[j].name);
}

static void *hook_named(const char *cls, const char *name, int argc, void *repl, const char *asmName, const char *ns) {
    if (!g_domain || !fn_domain_assembly_open) return NULL;
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
    S2LOG("hooked %s::%s (old=%p)", cls, name, old);
    return old;
}

#pragma mark - install

static void install(void) {
    S2LOG("=== install v3 ===");
    const char *u = "UnityEngine.CoreModule";
    o_setTargetFrameRate = (void (*)(int, void *))hook_named("Application", "set_targetFrameRate", 1, (void *)r_setTargetFrameRate, u, "UnityEngine");
    o_setFieldOfView     = (void (*)(void *, float, void *))hook_named("Camera", "set_fieldOfView", 1, (void *)r_setFieldOfView, u, "UnityEngine");
    if (g_domain) {
        void *as = fn_domain_assembly_open(g_domain, u);
        void *img = as ? fn_assembly_get_image(as) : NULL;
        void *kc = img ? fn_class_from_name(img, "UnityEngine", "Camera") : NULL;
        void *gm = kc ? fn_class_get_method_from_name(kc, "get_name", 0) : NULL;
        if (gm) { g_getCameraName = (void *(*)(void *, void *))*(void **)gm; S2LOG("camera name getter=%p", g_getCameraName); }
    }
    o_setAspect          = (void (*)(void *, float, void *))hook_named("Camera", "set_aspect", 1, (void *)r_setAspect, u, "UnityEngine");
    hook_named("PlayerPrefs", "SetFloat", 2, (void *)r_prefsSetFloat, u, "UnityEngine");
    hook_named("PlayerPrefs", "SetInt", 2, (void *)r_prefsSetInt, u, "UnityEngine");
    hook_named("PlayerPrefs", "SetString", 2, (void *)r_prefsSetString, u, "UnityEngine");
    scan_all();
    if (o_setTargetFrameRate) o_setTargetFrameRate(g_fps, NULL);
    S2LOG("=== install done ===");
}

static void bootstrap(void) {
    resolve_il2cpp();
    for (int i = 0; i < 75 && !fn_domain_get; i++) { usleep(200 * 1000); resolve_il2cpp(); }
    S2LOG("il2cpp domain_get=%p class_from_name=%p", fn_domain_get, fn_class_from_name);
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
    g_docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    g_logPath = [g_docs stringByAppendingPathComponent:@"s2fix.log"];
    g_cfgPath = [g_docs stringByAppendingPathComponent:@"s2fix.txt"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:[NSData data] attributes:nil];
    load_config();
    S2LOG("loaded pid=%d uid=%d", getpid(), getuid());

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bootstrap();
        // 加载证明：每次装包第一次启动弹一次
        NSString *flag = [g_docs stringByAppendingPathComponent:@"s2fix.shown"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:flag]) {
            [[NSData data] writeToFile:flag atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"S2Fix v3 已加载"
                    message:[NSString stringWithFormat:@"fov=%.2f hands=%.2f aspect=%.2f fps=%d\n日志: 文件App/StandChillow/s2fix.log", g_fovMult, g_handsMult, g_aspect, g_fps]
                    preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
                if (vc) [vc presentViewController:ac animated:YES completion:nil];
            });
        }
    });
}
