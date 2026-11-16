// MaxGhost v2: не читалка для MAX (iOS)
// Сигнатура из бинарника: -(void)sendData:(id)data withCommand:(unsigned short)cmd retry:(BOOL)retry callback:(block)cb
// Без ARC и без обращения к data/cb как к объектам, чтобы не падать.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define NOREAD_ENABLED 1
static const unsigned short kOpChatMark = 50;   // CHAT_MARK
static const unsigned short kOpPing = 1;        // PING (только лог)

typedef void (*SendIMP)(id, SEL, void *, unsigned short, BOOL, void *);
static SendIMP orig_send = NULL;
static int pingLogged = 0;

static void new_send(id self, SEL _cmd, void *data, unsigned short cmd, BOOL retry, void *cb) {
#if NOREAD_ENABLED
    if (cmd == kOpChatMark) {
        NSLog(@"[MaxGhost] CHAT_MARK dropped");
        return;
    }
#endif
    if (cmd == kOpPing && pingLogged < 3) {
        pingLogged++;
        NSLog(@"[MaxGhost] ping seen, data=%p", data);
    }
    orig_send(self, _cmd, data, cmd, retry, cb);
}

__attribute__((constructor))
static void MaxGhostInit(void) {
    Class k = objc_getClass("OKMMessengerClient");
    SEL s = sel_registerName("sendData:withCommand:retry:callback:");
    Method m = k ? class_getInstanceMethod(k, s) : NULL;
    if (!m) { NSLog(@"[MaxGhost] method not found, skip"); return; }

    const char *enc = method_getTypeEncoding(m);
    NSLog(@"[MaxGhost] encoding: %s", enc);
    // ожидаем v40@0:8@16S24B28@?32
    if (!enc || strncmp(enc, "v40@0:8@16S24B28@?32", 20) != 0) {
        NSLog(@"[MaxGhost] unexpected encoding, skip");
        return;
    }
    orig_send = (SendIMP)method_setImplementation(m, (IMP)new_send);
    NSLog(@"[MaxGhost] hooked");
}
