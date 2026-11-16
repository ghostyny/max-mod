// MaxGhost: режим призрака + не читалка для MAX (iOS)
// Хукает центральную точку отправки команд в OKMMessengerClient.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define GHOST_ENABLED  1   // не светить онлайн
#define NOREAD_ENABLED 1   // не отправлять "прочитано"

// Опкоды протокола MAX (по открытым реверсам протокола)
static const NSInteger kOpChatMark = 50;   // CHAT_MARK

typedef id (*SendIMP)(id, SEL, id, NSInteger, BOOL, id);
static SendIMP orig_send = NULL;
static BOOL cmdIs32 = NO;

static id new_send(id self, SEL _cmd, id data, NSInteger cmd, BOOL retry, id cb) {
    NSInteger c = cmdIs32 ? (NSInteger)(int32_t)cmd : cmd;

#if NOREAD_ENABLED
    if (c == kOpChatMark) {
        NSLog(@"[MaxGhost] CHAT_MARK dropped");
        return nil;
    }
#endif

#if GHOST_ENABLED
    // PING / LOGIN / SESSION_INIT: флаг interactive = NO -> сервер не считает тебя онлайн
    if ([data isKindOfClass:[NSDictionary class]] && ((NSDictionary *)data)[@"interactive"]) {
        NSMutableDictionary *m = [(NSDictionary *)data mutableCopy];
        m[@"interactive"] = @NO;
        data = m;
        NSLog(@"[MaxGhost] interactive forced NO (cmd %ld)", (long)c);
    }
#endif
    return orig_send(self, _cmd, data, cmd, retry, cb);
}

__attribute__((constructor))
static void MaxGhostInit(void) {
    Class k = objc_getClass("OKMMessengerClient");
    SEL s = sel_registerName("sendData:withCommand:retry:callback:");
    Method m = k ? class_getInstanceMethod(k, s) : NULL;
    if (!m) { NSLog(@"[MaxGhost] method not found, skip"); return; }

    NSLog(@"[MaxGhost] encoding: %s", method_getTypeEncoding(m));
    if (method_getNumberOfArguments(m) != 6) { NSLog(@"[MaxGhost] unexpected arg count, skip"); return; }

    char *t = method_copyArgumentType(m, 3);   // тип параметра command
    BOOL ok = t && strchr("qQiIlLsS", t[0]);
    cmdIs32 = t && strchr("iI", t[0]);
    if (t) free(t);
    if (!ok) { NSLog(@"[MaxGhost] command arg is not integer, skip"); return; }

    orig_send = (SendIMP)method_setImplementation(m, (IMP)new_send);
    NSLog(@"[MaxGhost] hooked");
}
