// MaxGhost v4 — призрак, не читалка (+ «прочитано при ответе»), не печатает, панель в стиле Liquid Glass
// Без ARC. Данные из sendData читаются только после безопасной проверки указателя.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <Block.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kGhostKey  = @"maxghost.ghost";
static NSString *const kNoReadKey = @"maxghost.noread";
static NSString *const kReplyKey  = @"maxghost.readonreply";
static NSString *const kTypingKey = @"maxghost.notyping";

static BOOL gGhost = YES, gNoRead = YES, gReadOnReply = YES, gNoTyping = YES;
static const unsigned short kOpPing = 1, kOpSessionInit = 6, kOpLogin = 19,
                            kOpChatMark = 50, kOpMsgSend = 64, kOpTyping = 65;
static int gPings = 0, gPingsMod = 0, gReadsDropped = 0, gFlushed = 0, gTypingDropped = 0;
static char gDataClass[96] = "-";
static NSMutableDictionary *gPending = nil;   // chatKey -> @[dataCopy, cmd, retry, cbPtr]

#pragma mark - safe object inspection

static uintptr_t *gClasses = NULL;
static unsigned int gClassCount = 0;

static int cmpPtr(const void *a, const void *b) {
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return x < y ? -1 : (x > y);
}

static void loadClasses(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int n = 0;
        Class *list = objc_copyClassList(&n);
        uintptr_t *arr = (uintptr_t *)malloc(sizeof(uintptr_t) * (n ? n : 1));
        for (unsigned int i = 0; i < n; i++) arr[i] = (uintptr_t)list[i];
        free(list);
        qsort(arr, n, sizeof(uintptr_t), cmpPtr);
        gClassCount = n;
        gClasses = arr;
    });
}

static Class safeClassOf(void *p) {
    uintptr_t a = (uintptr_t)p;
    if (!a || (a & 7) || a < 0x100000000ULL) return Nil;
    uintptr_t isa = 0;
    vm_size_t sz = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)a, 8, (vm_address_t)&isa, &sz) != KERN_SUCCESS || sz != 8) return Nil;
    uintptr_t c = isa & 0x0000000ffffffff8ULL;
    loadClasses();
    if (gClasses && bsearch(&c, gClasses, gClassCount, sizeof(uintptr_t), cmpPtr)) return (Class)c;
    return Nil;
}

static NSDictionary *MGDict(void *data) {
    if (!safeClassOf(data)) return nil;
    id o = (id)data;
    return [o isKindOfClass:[NSDictionary class]] ? (NSDictionary *)o : nil;
}

#pragma mark - network hook

typedef void (*SendIMP)(id, SEL, void *, unsigned short, BOOL, void *);
static SendIMP orig_send = NULL;

static void MGStorePending(NSString *key, NSDictionary *d, unsigned short cmd, BOOL retry, void *cb) {
    NSDictionary *copy = [d copy];
    void *cbc = cb ? Block_copy(cb) : NULL;
    NSArray *entry = [[NSArray alloc] initWithObjects:copy, [NSNumber numberWithUnsignedShort:cmd],
                      [NSNumber numberWithBool:retry], [NSValue valueWithPointer:cbc], nil];
    [copy release];
    NSArray *old = nil;
    @synchronized (gPending) {
        old = [[gPending objectForKey:key] retain];
        [gPending setObject:entry forKey:key];
    }
    [entry release];
    if (old) {
        void *oc = [(NSValue *)[old objectAtIndex:3] pointerValue];
        if (oc) Block_release(oc);
        [old release];
    }
}

static void MGFlushPending(id self, SEL _cmd, NSString *key) {
    NSArray *e = nil;
    @synchronized (gPending) {
        e = [[gPending objectForKey:key] retain];
        [gPending removeObjectForKey:key];
    }
    if (!e) return;
    void *cbc = [(NSValue *)[e objectAtIndex:3] pointerValue];
    orig_send(self, _cmd, (void *)[e objectAtIndex:0],
              [(NSNumber *)[e objectAtIndex:1] unsignedShortValue],
              [(NSNumber *)[e objectAtIndex:2] boolValue], cbc);
    gFlushed++;
    if (cbc) Block_release(cbc);
    [e release];
}

static int MGPendingCount(void) {
    @synchronized (gPending) { return (int)[gPending count]; }
}

static void new_send(id self, SEL _cmd, void *data, unsigned short cmd, BOOL retry, void *cb) {
    // не печатает
    if (gNoTyping && cmd == kOpTyping) {
        gTypingDropped++;
        return;
    }
    // не читалка (+ отложенная отметка до ответа)
    if (gNoRead && cmd == kOpChatMark) {
        gReadsDropped++;
        if (gReadOnReply) {
            @autoreleasepool {
                NSDictionary *d = MGDict(data);
                id chat = d ? [d objectForKey:@"chatId"] : nil;
                if (chat) MGStorePending([chat description], d, cmd, retry, cb);
            }
        }
        return;
    }
    // ответ в чате -> отправляем отложенную отметку
    if (gNoRead && gReadOnReply && cmd == kOpMsgSend) {
        @autoreleasepool {
            NSDictionary *d = MGDict(data);
            id chat = d ? [d objectForKey:@"chatId"] : nil;
            orig_send(self, _cmd, data, cmd, retry, cb);
            if (chat) MGFlushPending(self, _cmd, [chat description]);
        }
        return;
    }
    // призрак: interactive = NO
    if (cmd == kOpPing || cmd == kOpLogin || cmd == kOpSessionInit) {
        @autoreleasepool {
            Class c = safeClassOf(data);
            if (cmd == kOpPing) {
                gPings++;
                if (c) strlcpy(gDataClass, class_getName(c), sizeof(gDataClass));
            }
            if (gGhost && c && [(id)data isKindOfClass:[NSDictionary class]] &&
                [(NSDictionary *)data objectForKey:@"interactive"]) {
                NSMutableDictionary *m = [(NSDictionary *)data mutableCopy];
                [m setObject:@NO forKey:@"interactive"];
                if (cmd == kOpPing) gPingsMod++;
                orig_send(self, _cmd, m, cmd, retry, cb);
                [m release];
                return;
            }
            orig_send(self, _cmd, data, cmd, retry, cb);
            return;
        }
    }
    orig_send(self, _cmd, data, cmd, retry, cb);
}

#pragma mark - Liquid Glass helpers

@interface MGGradientView : UIView
@end
@implementation MGGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
@end

static UIColor *MGAccent(void) { return [UIColor colorWithRed:0.66 green:0.50 blue:1.0 alpha:1.0]; }

// Настоящее жидкое стекло (UIGlassEffect, iOS 26+), иначе — тонкий блюр с рамкой.
static UIVisualEffectView *MGGlass(CGFloat radius, UIColor *tint, BOOL interactive) {
    UIVisualEffect *eff = nil;
    BOOL real = NO;
    Class gc = NSClassFromString(@"UIGlassEffect");
    SEL mk = sel_registerName("effectWithStyle:");
    if (gc && [gc respondsToSelector:mk]) {
        id g = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(gc, mk, 0);
        if (g) {
            @try {
                if (tint) [g setValue:tint forKey:@"tintColor"];
                [g setValue:[NSNumber numberWithBool:interactive] forKey:@"interactive"];
            } @catch (NSException *ex) {}
            eff = (UIVisualEffect *)g;
            real = YES;
        }
    }
    if (!eff) eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *v = [[[UIVisualEffectView alloc] initWithEffect:eff] autorelease];
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.clipsToBounds = YES;
    if (!real) {
        v.layer.borderWidth = 0.6;
        v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        if (tint) {
            UIView *t = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
            t.backgroundColor = tint;
            t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            t.frame = v.bounds;
            [v.contentView addSubview:t];
        }
    }
    return v;
}

static void MGSave(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:gGhost forKey:kGhostKey];
    [d setBool:gNoRead forKey:kNoReadKey];
    [d setBool:gReadOnReply forKey:kReplyKey];
    [d setBool:gNoTyping forKey:kTypingKey];
}

static UIView *gBtn = nil;
static UIViewController *gSettingsVC = nil;

static void MGUpdateBtn(void) {
    UIImageView *iv = (UIImageView *)[gBtn viewWithTag:2];
    BOOL any = gGhost || gNoRead || gNoTyping;
    iv.tintColor = any ? MGAccent() : [UIColor colorWithWhite:1 alpha:0.6];
}

static UIView *MGRow(NSString *sym, UIColor *c1, UIColor *c2, NSString *title, NSString *sub,
                     BOOL on, id target, SEL sel, UISwitch **swOut) {
    MGGradientView *icon = [[[MGGradientView alloc] init] autorelease];
    CAGradientLayer *g = (CAGradientLayer *)icon.layer;
    g.colors = @[(id)c1.CGColor, (id)c2.CGColor];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint = CGPointMake(1, 1);
    icon.layer.cornerRadius = 12;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.clipsToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:40].active = YES;
    [icon.heightAnchor constraintEqualToConstant:40].active = YES;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sym withConfiguration:cfg]] autorelease];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeCenter;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [icon addSubview:iv];
    [iv.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor].active = YES;
    [iv.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor].active = YES;

    UILabel *t = [[[UILabel alloc] init] autorelease];
    t.text = title;
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    UILabel *s = [[[UILabel alloc] init] autorelease];
    s.text = sub;
    s.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    s.font = [UIFont systemFontOfSize:12.5];
    s.numberOfLines = 0;
    UIStackView *texts = [[[UIStackView alloc] initWithArrangedSubviews:@[t, s]] autorelease];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;

    UISwitch *sw = [[[UISwitch alloc] init] autorelease];
    sw.on = on;
    sw.onTintColor = [UIColor colorWithRed:0.55 green:0.38 blue:1.0 alpha:1.0];
    [sw addTarget:target action:sel forControlEvents:UIControlEventValueChanged];
    [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sw setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    if (swOut) *swOut = sw;

    UIStackView *row = [[[UIStackView alloc] initWithArrangedSubviews:@[icon, texts, sw]] autorelease];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 14;
    row.layoutMarginsRelativeArrangement = YES;
    row.layoutMargins = UIEdgeInsetsMake(13, 16, 13, 16);
    return row;
}

static UIView *MGSeparator(void) {
    UIView *wrap = [[[UIView alloc] init] autorelease];
    UIView *line = [[[UIView alloc] init] autorelease];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:70],
        [line.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [line.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [line.heightAnchor constraintEqualToConstant:0.5]]];
    return wrap;
}

#pragma mark - sheet

@interface MGSheetVC : UIViewController
@property (nonatomic, retain) UILabel *diag;
@property (nonatomic, retain) UIView *replyRow;
@property (nonatomic, retain) UISwitch *replySw;
@end

@implementation MGSheetVC

- (void)dealloc { [_diag release]; [_replyRow release]; [_replySw release]; [super dealloc]; }

- (void)refreshDiag {
    self.diag.text = [NSString stringWithFormat:
        @"пингов: %d · изменено: %d\nпрочтений скрыто: %d · ждут ответа: %d · отправлено: %d\nпечатает скрыто: %d · тип данных: %s",
        gPings, gPingsMod, gReadsDropped, MGPendingCount(), gFlushed, gTypingDropped, gDataClass];
}

- (void)refreshReplyRow {
    self.replyRow.alpha = gNoRead ? 1.0 : 0.38;
    self.replySw.enabled = gNoRead;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.08 alpha:1.0];

    // фон: тёмный градиент + два мягких цветных пятна, чтобы стекло было что преломлять
    MGGradientView *bg = [[[MGGradientView alloc] initWithFrame:self.view.bounds] autorelease];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ((CAGradientLayer *)bg.layer).colors = @[(id)[UIColor colorWithRed:0.05 green:0.04 blue:0.12 alpha:1].CGColor,
                                             (id)[UIColor colorWithRed:0.10 green:0.06 blue:0.22 alpha:1].CGColor,
                                             (id)[UIColor colorWithRed:0.04 green:0.09 blue:0.20 alpha:1].CGColor];
    ((CAGradientLayer *)bg.layer).startPoint = CGPointMake(0, 0);
    ((CAGradientLayer *)bg.layer).endPoint = CGPointMake(1, 1);
    [self.view addSubview:bg];

    CGSize sz = self.view.bounds.size;
    NSArray *blobs = @[ @[[NSNumber numberWithDouble:-60], [NSNumber numberWithDouble:40],
                          [UIColor colorWithRed:0.58 green:0.32 blue:1.0 alpha:0.55]],
                        @[[NSNumber numberWithDouble:sz.width - 150], [NSNumber numberWithDouble:330],
                          [UIColor colorWithRed:0.20 green:0.50 blue:1.0 alpha:0.45]] ];
    for (NSArray *b in blobs) {
        MGGradientView *blob = [[[MGGradientView alloc] initWithFrame:CGRectMake([b[0] doubleValue], [b[1] doubleValue], 260, 260)] autorelease];
        CAGradientLayer *gl = (CAGradientLayer *)blob.layer;
        gl.type = kCAGradientLayerRadial;
        gl.colors = @[(id)((UIColor *)b[2]).CGColor, (id)[((UIColor *)b[2]) colorWithAlphaComponent:0].CGColor];
        gl.startPoint = CGPointMake(0.5, 0.5);
        gl.endPoint = CGPointMake(1, 1);
        [self.view addSubview:blob];
    }

    // шапка
    MGGradientView *logo = [[[MGGradientView alloc] init] autorelease];
    CAGradientLayer *lg = (CAGradientLayer *)logo.layer;
    lg.colors = @[(id)[UIColor colorWithRed:0.70 green:0.50 blue:1.0 alpha:1].CGColor,
                  (id)[UIColor colorWithRed:0.38 green:0.26 blue:0.92 alpha:1].CGColor];
    lg.startPoint = CGPointMake(0, 0);
    lg.endPoint = CGPointMake(1, 1);
    logo.layer.cornerRadius = 13;
    logo.layer.cornerCurve = kCACornerCurveContinuous;
    logo.clipsToBounds = YES;
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:46].active = YES;
    [logo.heightAnchor constraintEqualToConstant:46].active = YES;
    UIImageView *liv = [[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash.fill"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]]] autorelease];
    liv.tintColor = [UIColor whiteColor];
    liv.contentMode = UIViewContentModeCenter;
    liv.translatesAutoresizingMaskIntoConstraints = NO;
    [logo addSubview:liv];
    [liv.centerXAnchor constraintEqualToAnchor:logo.centerXAnchor].active = YES;
    [liv.centerYAnchor constraintEqualToAnchor:logo.centerYAnchor].active = YES;

    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.text = @"MaxGhost";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    UILabel *sub = [[[UILabel alloc] init] autorelease];
    sub.text = @"Приватность в MAX";
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    sub.font = [UIFont systemFontOfSize:13.5];
    UIStackView *tt = [[[UIStackView alloc] initWithArrangedSubviews:@[title, sub]] autorelease];
    tt.axis = UILayoutConstraintAxisVertical;
    tt.spacing = 1;
    UIStackView *header = [[[UIStackView alloc] initWithArrangedSubviews:@[logo, tt]] autorelease];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 14;

    // стеклянная карточка с переключателями
    UISwitch *swGhost = nil, *swRead = nil, *swReply = nil, *swType = nil;
    UIView *r1 = MGRow(@"eye.slash.fill",
                       [UIColor colorWithRed:0.66 green:0.44 blue:1.0 alpha:1], [UIColor colorWithRed:0.40 green:0.26 blue:0.90 alpha:1],
                       @"Режим призрака", @"Не показывать, что вы онлайн",
                       gGhost, self, @selector(ghostChanged:), &swGhost);
    UIView *r2 = MGRow(@"checkmark.circle.fill",
                       [UIColor colorWithRed:0.28 green:0.66 blue:1.0 alpha:1], [UIColor colorWithRed:0.16 green:0.42 blue:0.94 alpha:1],
                       @"Не читалка", @"Собеседник не увидит, что вы прочитали",
                       gNoRead, self, @selector(readChanged:), &swRead);
    UIView *r3 = MGRow(@"arrowshape.turn.up.left.fill",
                       [UIColor colorWithRed:0.30 green:0.80 blue:0.55 alpha:1], [UIColor colorWithRed:0.12 green:0.62 blue:0.42 alpha:1],
                       @"Прочитано при ответе", @"Чат отметится прочитанным, когда вы в нём ответите",
                       gReadOnReply, self, @selector(replyChanged:), &swReply);
    UIView *r4 = MGRow(@"ellipsis.bubble.fill",
                       [UIColor colorWithRed:1.0 green:0.68 blue:0.30 alpha:1], [UIColor colorWithRed:0.95 green:0.45 blue:0.20 alpha:1],
                       @"Не печатает", @"Скрыть «печатает...» у собеседника",
                       gNoTyping, self, @selector(typingChanged:), &swType);
    self.replyRow = r3;
    self.replySw = swReply;

    UIStackView *rows = [[[UIStackView alloc] initWithArrangedSubviews:@[r1, MGSeparator(), r2, MGSeparator(), r3, MGSeparator(), r4]] autorelease];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.translatesAutoresizingMaskIntoConstraints = NO;

    UIVisualEffectView *card = MGGlass(26, nil, NO);
    [card.contentView addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor]]];

    UILabel *hint = [[[UILabel alloc] init] autorelease];
    hint.text = @"Призрак вступает в силу при следующем обращении к серверу, обычно через несколько секунд.";
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    hint.font = [UIFont systemFontOfSize:12];
    hint.numberOfLines = 0;

    self.diag = [[[UILabel alloc] init] autorelease];
    self.diag.textColor = [UIColor colorWithWhite:1 alpha:0.32];
    self.diag.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.diag.numberOfLines = 0;
    [self refreshDiag];
    [self refreshReplyRow];

    UIStackView *root = [[[UIStackView alloc] initWithArrangedSubviews:@[header, card, hint, self.diag]] autorelease];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 16;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:30],
        [root.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18],
        [root.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18]]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDiag];
}

- (void)tick {
    UIImpactFeedbackGenerator *g = [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] autorelease];
    [g impactOccurred];
    MGSave();
    MGUpdateBtn();
    [self refreshReplyRow];
}
- (void)ghostChanged:(UISwitch *)s  { gGhost = s.on; [self tick]; }
- (void)readChanged:(UISwitch *)s   { gNoRead = s.on; [self tick]; }
- (void)replyChanged:(UISwitch *)s  { gReadOnReply = s.on; [self tick]; }
- (void)typingChanged:(UISwitch *)s { gNoTyping = s.on; [self tick]; }

@end

#pragma mark - floating glass button in Settings

@interface MGHelper : NSObject
+ (void)open;
@end
@implementation MGHelper
+ (void)open {
    UIViewController *host = gSettingsVC;
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host || [host isKindOfClass:[MGSheetVC class]]) return;
    MGSheetVC *vc = [[[MGSheetVC alloc] init] autorelease];
    vc.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sp = vc.sheetPresentationController;
    if (sp) {
        Class dc = [UISheetPresentationControllerDetent class];
        if ([dc respondsToSelector:@selector(customDetentWithIdentifier:resolver:)]) {
            UISheetPresentationControllerDetent *d = [dc customDetentWithIdentifier:@"mg"
                resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> ctx) {
                    return MIN(600.0, ctx.maximumDetentValue);
                }];
            sp.detents = @[d, [UISheetPresentationControllerDetent largeDetent]];
        } else {
            sp.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
        }
        sp.prefersGrabberVisible = YES;
        sp.preferredCornerRadius = 30;
    }
    [host presentViewController:vc animated:YES completion:nil];
}
@end

static void MGShowButton(UIViewController *vc) {
    UIWindow *w = vc.view.window;
    if (!w) return;
    if (gBtn) { [gBtn removeFromSuperview]; [gBtn release]; gBtn = nil; }

    CGFloat size = 56;
    UITabBarController *tb = vc.tabBarController;
    CGFloat bottom = (tb && !tb.tabBar.hidden) ? tb.tabBar.bounds.size.height : w.safeAreaInsets.bottom;
    CGRect f = CGRectMake(w.bounds.size.width - size - 16, w.bounds.size.height - bottom - size - 16, size, size);

    UIView *b = [[UIView alloc] initWithFrame:f];
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.30;
    b.layer.shadowRadius = 14;
    b.layer.shadowOffset = CGSizeMake(0, 6);

    UIVisualEffectView *glass = MGGlass(size / 2, [UIColor colorWithRed:0.55 green:0.38 blue:1.0 alpha:0.18], YES);
    glass.frame = b.bounds;
    [b addSubview:glass];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash.fill" withConfiguration:cfg]] autorelease];
    iv.frame = glass.bounds;
    iv.contentMode = UIViewContentModeCenter;
    iv.tag = 2;
    [glass.contentView addSubview:iv];

    UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc] initWithTarget:[MGHelper class] action:@selector(open)] autorelease];
    [b addGestureRecognizer:tap];

    b.alpha = 0;
    b.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [w addSubview:b];
    gBtn = b;
    MGUpdateBtn();
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.6
                        options:0 animations:^{ b.alpha = 1; b.transform = CGAffineTransformIdentity; } completion:nil];
}

static void MGHideButton(void) {
    if (!gBtn) return;
    UIView *b = gBtn;
    gBtn = nil;
    [UIView animateWithDuration:0.2 animations:^{ b.alpha = 0; } completion:^(BOOL f) {
        [b removeFromSuperview];
        [b release];
    }];
}

#pragma mark - hooks

static IMP origAppear = NULL, origDisappear = NULL;
static NSTimer *gTimer = nil;

// Экран настроек реально виден: он в окне, на экране и ничего не перекрывает центр.
static BOOL MGSettingsVisible(void) {
    UIViewController *vc = gSettingsVC;
    if (!vc) return NO;
    UIView *v = vc.viewIfLoaded;
    UIWindow *w = v.window;
    if (!w || v.hidden || v.alpha < 0.05) return NO;
    CGRect r = [v convertRect:v.bounds toView:w];
    CGRect inter = CGRectIntersection(r, w.bounds);
    if (CGRectIsNull(inter)) return NO;
    if (inter.size.width < w.bounds.size.width * 0.6 || inter.size.height < w.bounds.size.height * 0.4) return NO;
    // проверка перекрытия: что лежит в центре экрана — часть экрана настроек?
    CGPoint c = CGPointMake(CGRectGetMidX(inter), CGRectGetMidY(inter));
    UIView *hit = [w hitTest:c withEvent:nil];
    if (!hit) return NO;
    return [hit isDescendantOfView:v];
}

static void MGTick(void) {
    BOOL vis = MGSettingsVisible();
    if (vis && !gBtn && gSettingsVC) MGShowButton(gSettingsVC);
    else if (!vis && gBtn) MGHideButton();
}

static void MGStartTimer(void) {
    if (gTimer) return;
    gTimer = [[NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { MGTick(); }] retain];
}

static void new_appear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))origAppear)(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    if (gSettingsVC != vc) {
        [gSettingsVC release];
        gSettingsVC = [vc retain];
    }
    MGStartTimer();
    dispatch_async(dispatch_get_main_queue(), ^{ MGTick(); });
}

static void new_disappear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))origDisappear)(self, _cmd, animated);
    dispatch_async(dispatch_get_main_queue(), ^{ MGTick(); });
}

static void MGHook(Class cls, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    IMP inherited = method_getImplementation(m);
    if (class_addMethod(cls, sel, imp, t)) *orig = inherited;
    else *orig = method_setImplementation(m, imp);
}

__attribute__((constructor))
static void MaxGhostInit(void) {
    gPending = [[NSMutableDictionary alloc] init];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kGhostKey])  gGhost       = [d boolForKey:kGhostKey];
    if ([d objectForKey:kNoReadKey]) gNoRead      = [d boolForKey:kNoReadKey];
    if ([d objectForKey:kReplyKey])  gReadOnReply = [d boolForKey:kReplyKey];
    if ([d objectForKey:kTypingKey]) gNoTyping    = [d boolForKey:kTypingKey];

    Class k = objc_getClass("OKMMessengerClient");
    SEL s = sel_registerName("sendData:withCommand:retry:callback:");
    Method m = k ? class_getInstanceMethod(k, s) : NULL;
    if (m) {
        const char *enc = method_getTypeEncoding(m);
        if (enc && strncmp(enc, "v40@0:8@16S24B28@?32", 20) == 0) {
            orig_send = (SendIMP)method_setImplementation(m, (IMP)new_send);
            NSLog(@"[MaxGhost] network hooked");
        } else {
            NSLog(@"[MaxGhost] unexpected encoding, network hook skipped");
        }
    }

    Class sc = objc_getClass("_TtC10SettingsUI22SettingsViewController");
    if (sc) {
        MGHook(sc, @selector(viewDidAppear:), (IMP)new_appear, &origAppear);
        MGHook(sc, @selector(viewWillDisappear:), (IMP)new_disappear, &origDisappear);
        NSLog(@"[MaxGhost] settings UI hooked");
    } else {
        NSLog(@"[MaxGhost] SettingsViewController not found");
    }
}
