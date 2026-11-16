// MaxGhost v3 — не читалка + режим призрака + панель настроек в MAX (iOS)
// Без ARC. Данные из sendData читаются только после безопасной проверки указателя.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kGhostKey  = @"maxghost.ghost";
static NSString *const kNoReadKey = @"maxghost.noread";

static BOOL gGhost = YES, gNoRead = YES;
static const unsigned short kOpPing = 1, kOpSessionInit = 6, kOpLogin = 19, kOpChatMark = 50;
static int gPings = 0, gPingsMod = 0, gReadsDropped = 0;
static char gDataClass[96] = "-";

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

// Возвращает класс объекта, только если указатель читается и isa указывает на зарегистрированный класс.
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

#pragma mark - network hook

typedef void (*SendIMP)(id, SEL, void *, unsigned short, BOOL, void *);
static SendIMP orig_send = NULL;

static void new_send(id self, SEL _cmd, void *data, unsigned short cmd, BOOL retry, void *cb) {
    if (gNoRead && cmd == kOpChatMark) {
        gReadsDropped++;
        return;
    }
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

#pragma mark - UI helpers

@interface MGGradientView : UIView
@end
@implementation MGGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
@end

static UIColor *MGAccent(void) { return [UIColor colorWithRed:0.62 green:0.45 blue:1.0 alpha:1.0]; }

static void MGSave(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:gGhost forKey:kGhostKey];
    [d setBool:gNoRead forKey:kNoReadKey];
}

static UIView *gBtn = nil;
static UIViewController *gSettingsVC = nil;

static void MGUpdateBtn(void) {
    UIImageView *iv = (UIImageView *)[gBtn viewWithTag:2];
    iv.tintColor = (gGhost || gNoRead) ? MGAccent() : [UIColor secondaryLabelColor];
}

static UIView *MGRow(NSString *sym, UIColor *c1, UIColor *c2, NSString *title, NSString *sub,
                     BOOL on, id target, SEL sel) {
    MGGradientView *icon = [[[MGGradientView alloc] init] autorelease];
    CAGradientLayer *g = (CAGradientLayer *)icon.layer;
    g.colors = @[(id)c1.CGColor, (id)c2.CGColor];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint = CGPointMake(1, 1);
    icon.layer.cornerRadius = 11;
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
    s.textColor = [UIColor colorWithWhite:1 alpha:0.55];
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

    UIStackView *row = [[[UIStackView alloc] initWithArrangedSubviews:@[icon, texts, sw]] autorelease];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 14;
    row.layoutMarginsRelativeArrangement = YES;
    row.layoutMargins = UIEdgeInsetsMake(14, 16, 14, 16);
    return row;
}

#pragma mark - sheet

@interface MGSheetVC : UIViewController
@property (nonatomic, retain) UILabel *diag;
@end

@implementation MGSheetVC

- (void)dealloc { [_diag release]; [super dealloc]; }

- (void)refreshDiag {
    self.diag.text = [NSString stringWithFormat:@"пингов: %d · изменено: %d · прочтений скрыто: %d\nтип данных пинга: %s",
                      gPings, gPingsMod, gReadsDropped, gDataClass];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.08 alpha:1.0];

    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.text = @"MaxGhost";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    UILabel *sub = [[[UILabel alloc] init] autorelease];
    sub.text = @"Приватность в MAX";
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    sub.font = [UIFont systemFontOfSize:14];
    UIStackView *header = [[[UIStackView alloc] initWithArrangedSubviews:@[title, sub]] autorelease];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 2;

    UIView *r1 = MGRow(@"eye.slash.fill",
                       [UIColor colorWithRed:0.62 green:0.40 blue:1.0 alpha:1],
                       [UIColor colorWithRed:0.38 green:0.25 blue:0.85 alpha:1],
                       @"Режим призрака", @"Не показывать, что вы онлайн",
                       gGhost, self, @selector(ghostChanged:));
    UIView *r2 = MGRow(@"checkmark.circle.fill",
                       [UIColor colorWithRed:0.25 green:0.62 blue:1.0 alpha:1],
                       [UIColor colorWithRed:0.15 green:0.40 blue:0.92 alpha:1],
                       @"Не читалка", @"Собеседник не увидит, что вы прочитали",
                       gNoRead, self, @selector(readChanged:));
    UIView *sep = [[[UIView alloc] init] autorelease];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [sep.heightAnchor constraintEqualToConstant:0.5].active = YES;

    UIStackView *rows = [[[UIStackView alloc] initWithArrangedSubviews:@[r1, sep, r2]] autorelease];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *card = [[[UIView alloc] init] autorelease];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    card.layer.cornerRadius = 20;
    card.clipsToBounds = YES;
    [card addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:card.topAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:card.trailingAnchor]]];

    UILabel *hint = [[[UILabel alloc] init] autorelease];
    hint.text = @"Призрак вступает в силу при следующем обращении к серверу, обычно через несколько секунд.";
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    hint.font = [UIFont systemFontOfSize:12];
    hint.numberOfLines = 0;

    self.diag = [[[UILabel alloc] init] autorelease];
    self.diag.textColor = [UIColor colorWithWhite:1 alpha:0.3];
    self.diag.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    self.diag.numberOfLines = 0;
    [self refreshDiag];

    UIStackView *root = [[[UIStackView alloc] initWithArrangedSubviews:@[header, card, hint, self.diag]] autorelease];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 16;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:30],
        [root.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [root.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20]]];
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
}
- (void)ghostChanged:(UISwitch *)s { gGhost = s.on; [self tick]; }
- (void)readChanged:(UISwitch *)s { gNoRead = s.on; [self tick]; }

@end

#pragma mark - floating button in Settings

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
        sp.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
        sp.prefersGrabberVisible = YES;
        sp.preferredCornerRadius = 28;
    }
    [host presentViewController:vc animated:YES completion:nil];
}
@end

static void MGShowButton(UIViewController *vc) {
    UIWindow *w = vc.view.window;
    if (!w) return;
    if (gBtn) { [gBtn removeFromSuperview]; [gBtn release]; gBtn = nil; }

    CGFloat size = 52;
    UITabBarController *tb = vc.tabBarController;
    CGFloat bottom = (tb && !tb.tabBar.hidden) ? tb.tabBar.bounds.size.height : w.safeAreaInsets.bottom;
    CGRect f = CGRectMake(w.bounds.size.width - size - 16, w.bounds.size.height - bottom - size - 16, size, size);

    UIView *b = [[UIView alloc] initWithFrame:f];
    b.layer.cornerRadius = size / 2;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.35;
    b.layer.shadowRadius = 10;
    b.layer.shadowOffset = CGSizeMake(0, 4);

    UIVisualEffectView *bl = [[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]] autorelease];
    bl.frame = b.bounds;
    bl.layer.cornerRadius = size / 2;
    bl.clipsToBounds = YES;
    bl.layer.borderWidth = 0.5;
    bl.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [b addSubview:bl];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash.fill" withConfiguration:cfg]] autorelease];
    iv.frame = b.bounds;
    iv.contentMode = UIViewContentModeCenter;
    iv.tag = 2;
    [b addSubview:iv];

    UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc] initWithTarget:[MGHelper class] action:@selector(open)] autorelease];
    [b addGestureRecognizer:tap];

    b.alpha = 0;
    b.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [w addSubview:b];
    gBtn = b;
    MGUpdateBtn();
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5
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

static void new_appear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))origAppear)(self, _cmd, animated);
    gSettingsVC = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSettingsVC == (UIViewController *)self) MGShowButton((UIViewController *)self);
    });
}

static void new_disappear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))origDisappear)(self, _cmd, animated);
    // не прячем кнопку, пока поверх открыта наша панель
    UIViewController *vc = (UIViewController *)self;
    if (![vc.presentedViewController isKindOfClass:[MGSheetVC class]]) {
        if (gSettingsVC == vc) gSettingsVC = nil;
        MGHideButton();
    }
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
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kGhostKey])  gGhost  = [d boolForKey:kGhostKey];
    if ([d objectForKey:kNoReadKey]) gNoRead = [d boolForKey:kNoReadKey];

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
