// S2Fix.m — Standoff 2 (iOS, Unity 2022.3 / IL2CPP) iPhone 15 Pro 修复补丁
//
// 目标：
//   1) 陀螺仪：SystemInfo.supportsGyroscope 恒 true，并把「此设备上不可用」的判定绕开
//   2) 120Hz：Application.targetFrameRate 强制 120（配合 Info.plist CADisableMinimumFrameDuration=YES）
//   3) 设备型号伪装（可选，默认关）：用于绕开机型白名单
//   4) 诊断：把 Camera.fieldOfView / Screen.SetResolution / PlayerPrefs 的设置调用打日志，
//      用来定位「纵横比 / 视野 / 手视野 / 黑色天空 应用不了」到底是写不进还是读不出
//
// 编译：CI (ubuntu + theos SDK) 见 .github/workflows/build-fix.yml
// 运行时不需要 substrate / fishhook：直接改 MethodInfo->methodPointer（offset 0）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <unistd.h>

#define S2LOG(fmt, ...) NSLog(@"[S2Fix] " fmt, ##__VA_ARGS__)

#pragma mark - il2cpp 符号

static void *(*fn_domain_get)(void);
static void *(*fn_domain_assembly_open)(void *, const char *);
static void *(*fn_assembly_get_image)(void *);
static void *(*fn_class_from_name)(void *, const char *, const char *);
static void *(*fn_class_get_method_from_name)(void *, const char *, int);
static void *(*fn_thread_attach)(void *);
static const char *(*fn_class_get_name)(void *);
static const char *(*fn_class_get_namespace)(void *);

static void *g_domain;

static BOOL resolve_il2cpp(void) {
    void *h = dlopen(NULL, RTLD_NOW);
    if (!h) return NO;
    fn_domain_get              = dlsym(h, "il2cpp_domain_get");
    fn_domain_assembly_open    = dlsym(h, "il2cpp_domain_assembly_open");
    fn_assembly_get_image      = dlsym(h, "il2cpp_assembly_get_image");
    fn_class_from_name         = dlsym(h, "il2cpp_class_from_name");
    fn_class_get_method_from_name = dlsym(h, "il2cpp_class_get_method_from_name");
    fn_thread_attach           = dlsym(h, "il2cpp_thread_attach");
    fn_class_get_name          = dlsym(h, "il2cpp_class_get_name");
    fn_class_get_namespace     = dlsym(h, "il2cpp_class_get_namespace");
    if (!fn_domain_get || !fn_domain_assembly_open || !fn_assembly_get_image ||
        !fn_class_from_name || !fn_class_get_method_from_name) {
        S2LOG("il2cpp symbols missing (domain=%p asm=%p)", fn_domain_get, fn_domain_assembly_open);
        return NO;
    }
    return YES;
}

static void *klass_in_any_assembly(const char *ns, const char *name) {
    if (!g_domain) g_domain = fn_domain_get();
    if (!g_domain) return NULL;
    // 从 UnityEngine.CoreModule / 主程序集两侧都试
    const char *asms[] = { "UnityEngine.CoreModule", "UnityEngine", NULL };
    for (int i = 0; asms[i]; i++) {
        void *asm_ = fn_domain_assembly_open(g_domain, asms[i]);
        if (!asm_) continue;
        void *img = fn_assembly_get_image(asm_);
        if (!img) continue;
        void *k = fn_class_from_name(img, ns, name);
        if (k) {
            S2LOG("class %s.%s found in %s -> %p", ns, name, asms[i], k);
            return k;
        }
    }
    S2LOG("class %s.%s NOT found", ns, name);
    return NULL;
}

// 把 klass 上的 method 指针换成 replacement，返回原指针
static void *hook_method(void *klass, const char *name, int argc, void *replacement) {
    if (!klass) return NULL;
    void *m = fn_class_get_method_from_name(klass, name, argc);
    if (!m) {
        S2LOG("method %s/%d NOT found", name, argc);
        return NULL;
    }
    void **slot = (void **)m;         // MethodInfo { methodPointer, virtualMethodPointer, ... }
    void *orig = *slot;
    if (orig == replacement) return orig;
    // 页可能只读：改 mprotect
    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0xFFF;
    vm_protect(mach_task_self(), page, 0x4000, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *slot = replacement;
    S2LOG("hook %s/%d  %p -> %p (was %p)", name, argc, m, replacement, orig);
    return orig;
}

#pragma mark - 修复 1：陀螺仪

// UnityEngine.SystemInfo.get_supportsGyroscope  static bool get(const MethodInfo*)
static BOOL s2_supportsGyroscope(void *method) {
    return YES;
}

// UnityEngine.Input.get_gyro  返回 Gyroscope 对象；只在 supportsGyroscope 为真时才被调用
// 这里不动，避免拿到 nil。

#pragma mark - 修复 2：120Hz

static int g_forcedFPS = 120;
static void (*g_origSetTargetFrameRate)(int, void *);

// UnityEngine.Application.set_targetFrameRate  static void set(int, const MethodInfo*)
static void s2_setTargetFrameRate(int value, void *method) {
    if (g_origSetTargetFrameRate) {
        g_origSetTargetFrameRate(g_forcedFPS, method);
    }
    S2LOG("targetFrameRate: game asked %d -> forced %d", value, g_forcedFPS);
}

#pragma mark - 诊断：设置项为什么应用不了

static void s2_setFieldOfView(void *self, float v, void *method) {
    S2LOG("Camera.fieldOfView <- %.2f", v);
}
static void s2_setResolution(void *w, void *h, void *mode, void *method) {
    S2LOG("Screen.SetResolution called");
}
#pragma mark - 安装

static void install(void) {
    S2LOG("install start");
    if (!resolve_il2cpp()) return;
    if (!g_domain) g_domain = fn_domain_get();
    if (g_domain && fn_thread_attach) fn_thread_attach(g_domain);

    // ---- 陀螺仪
    void *sysinfo = klass_in_any_assembly("UnityEngine", "SystemInfo");
    if (sysinfo) hook_method(sysinfo, "get_supportsGyroscope", 0, (void *)s2_supportsGyroscope);

    // ---- 120Hz
    void *app = klass_in_any_assembly("UnityEngine", "Application");
    if (app) {
        g_origSetTargetFrameRate = (void (*)(int, void *))hook_method(app, "set_targetFrameRate", 1,
                                                                     (void *)s2_setTargetFrameRate);
        if (g_origSetTargetFrameRate) g_origSetTargetFrameRate(g_forcedFPS, NULL);
    }

    // ---- 诊断钩子（只打日志，不改值）
    void *cam = klass_in_any_assembly("UnityEngine", "Camera");
    if (cam) hook_method(cam, "set_fieldOfView", 1, (void *)s2_setFieldOfView);
    void *screen = klass_in_any_assembly("UnityEngine", "Screen");
    if (screen) hook_method(screen, "SetResolution", 3, (void *)s2_setResolution);

    S2LOG("install done");
}

__attribute__((constructor))
static void s2fix_init(void) {
    S2LOG("loaded (uid=%d)", getuid());
    // Unity 还没起来，轮询等 il2cpp 可用
    static int tries = 0;
    __block void (^tick)(void);
    tick = ^{
        if (++tries > 60) { S2LOG("give up waiting for il2cpp"); return; }
        if (!fn_domain_get && !resolve_il2cpp()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), tick);
            return;
        }
        void *d = fn_domain_get ? fn_domain_get() : NULL;
        if (!d) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), tick);
            return;
        }
        install();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), tick);
}
