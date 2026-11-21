// S2Probe v5.0 — 最小探针：只证明 dylib 能不能被 dyld 加载
// 不做任何 il2cpp 操作，不挂钩，不改内存。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static void W(NSString *s) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *p = [docs stringByAppendingPathComponent:@"s2probe.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) { [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    NSLog(@"[S2Probe] %@", s);
}

__attribute__((constructor))
static void probe_init(void) {
    W([NSString stringWithFormat:@"v5.0 loaded pid=%d uid=%d model=%@", getpid(), getuid(),
       [[UIDevice currentDevice] model]]);
}
