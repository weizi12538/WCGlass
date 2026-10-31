// WCGlass - 微信毛玻璃 UI 插件
// 纯 ObjC runtime 方法替换,不依赖 CydiaSubstrate,越狱 / lcsign 注入均可用
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>
#import <mach-o/dyld.h>

#define WG_SUITE @"com.wcglass.prefs"
#define TAG_GLASS_TOP   0x57A01
#define TAG_GLASS_INPUT 0x57A02
#define TAG_GLASS_TAB   0x57A03
#define TAG_TAB_PILL    0x57A04
#define TAG_TAB_PLUS    0x57A05
#define TAG_DRAWER      0x57A06
#define TAG_DIM         0x57A07

static __weak UIViewController *gTab;
static __weak UIView *gTabBar;
static __weak UIView *gTopBar;
static NSString *gTopInfo;
static BOOL gBarTouched;
static int gCntEdge;
static NSString *gEdgeWhy;
static UIWindow *gOverlay;   // 侧边栏专用窗口(盖在其他插件的视图和窗口之上)

@interface WGHelper : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)openDrawer;
@end

static UIViewController *WGVisibleVC(void);
static BOOL WGHomeVisible(void);
static int gCntChat, gCntTab;
static BOOL gHookChat, gHookTab, gHookSet;
static UIView *WGFindInputBar(UIView *root);

#pragma mark - 配置

static NSUserDefaults *WGD(void) {
    static NSUserDefaults *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:WG_SUITE];
        [d registerDefaults:@{@"glassInput": @YES, @"drawer": @YES, @"theme": @0, @"lang": @0,
                              @"topStyle": @2, @"topOn": @YES, @"liquidManual": @NO, @"botStyle": @5, @"botOn": @YES, @"chipSel": @0,
                              @"glassMode": @0, @"tint": @0.38, @"topCover": @NO, @"segLeft": @"", @"segRight": @""}];
    });
    return d;
}

// 已加载的同类插件(LiquidUI 等),用来在面板里提示共存状态
static NSString *WGOtherTweaks(void) {
    NSMutableArray *hits = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *name = [NSString stringWithUTF8String:p].lastPathComponent;
        NSString *low = name.lowercaseString;
        if ([low containsString:@"wcglass"]) continue;   // 自己
        if ([low containsString:@"liquid"] || [low containsString:@"wcg"] || [low containsString:@"glass"])
            if (![hits containsObject:name]) [hits addObject:name];
    }
    return [hits componentsJoinedByString:@", "];
}

#pragma mark - 工具函数

static IMP WGHook(Class c, SEL sel, IMP newImp) {
    if (!c) return NULL;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NULL;
    IMP old = method_getImplementation(m);
    if (!class_addMethod(c, sel, newImp, method_getTypeEncoding(m)))
        method_setImplementation(m, newImp);
    return old;
}

// 玻璃视图:叠加模式时在内部再放一层液态玻璃
@interface WGGlassView : UIVisualEffectView
@property (nonatomic, strong) UIVisualEffectView *inner;
@end
@implementation WGGlassView
- (void)layoutSubviews { [super layoutSubviews]; self.inner.frame = self.contentView.bounds; }
@end

static UIVisualEffect *WGGlassEffect(void) {
    Class g = NSClassFromString(@"UIGlassEffect"); // iOS 26 液态玻璃
    if (!g) return nil;
    id e = [[g alloc] init];
    @try { [e setValue:@YES forKey:@"interactive"]; } @catch (__unused NSException *x) {}
    return (UIVisualEffect *)e;
}

// 材质由设置面板决定: 0 液态玻璃 / 1 毛玻璃 / 2 叠加(毛玻璃 + 液态玻璃)
static UIVisualEffectView *WGBlur(CGFloat radius, BOOL unused) {
    NSInteger mode = [WGD() integerForKey:@"glassMode"];
    UIVisualEffect *glass = WGGlassEffect();
    if (!glass) mode = 1;   // 系统不支持液态玻璃,退回毛玻璃
    UIVisualEffect *eff = mode == 0 ? glass : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    WGGlassView *v = [[WGGlassView alloc] initWithEffect:eff];
    CGFloat tint = [WGD() floatForKey:@"tint"];
    if (mode != 0) {
        v.contentView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:tint * 0.16]
                                                                    : [UIColor colorWithWhite:1 alpha:tint];
        }];
        if (radius > 0) { v.layer.borderWidth = 0.6; v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor; }
    }
    if (mode == 2) {
        v.inner = [[UIVisualEffectView alloc] initWithEffect:glass];
        v.inner.userInteractionEnabled = NO;
        [v.contentView addSubview:v.inner];
    }
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.clipsToBounds = YES;
    v.userInteractionEnabled = NO;
    return v;
}

static UIView *WGFind(UIView *root, BOOL (^pred)(UIView *v)) {
    for (UIView *s in root.subviews) {
        if (pred(s)) return s;
        UIView *r = WGFind(s, pred);
        if (r) return r;
    }
    return nil;
}

static UIWindow *WGWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UINavigationController *WGNav(void) {
    UIViewController *v = WGVisibleVC();
    if ([v isKindOfClass:UINavigationController.class]) return (UINavigationController *)v;
    return v.navigationController;
}

#pragma mark - 自绘底栏 / 顶栏

static NSString *WGL(NSString *zh, NSString *en) { return [WGD() integerForKey:@"lang"] == 1 ? en : zh; }

static NSArray<UIView *> *WGItemsOf(UIView *bar) {
    NSMutableArray *items = [NSMutableArray array];
    for (UIView *sv in bar.subviews) {
        if (sv.tag == TAG_TAB_PILL) continue;
        if (sv.bounds.size.width < bar.bounds.size.width * 0.45 && sv.bounds.size.height >= 30) [items addObject:sv];
    }
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
}

static NSInteger WGCurrentIndex(UIViewController *tc, NSArray<UIView *> *items) {
    @try {
        id v = [tc valueForKey:@"selectedIndex"];
        if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    } @catch (__unused NSException *e) {}
    for (NSUInteger i = 0; i < items.count; i++)
        if ([items[i] isKindOfClass:UIControl.class] && ((UIControl *)items[i]).selected) return (NSInteger)i;
    return -1;
}

static void WGSelectIndex(UIViewController *tc, NSInteger i, NSArray<UIView *> *items) {
    SEL set = NSSelectorFromString(@"setSelectedIndex:");
    if ([tc respondsToSelector:set]) { ((void(*)(id, SEL, NSInteger))objc_msgSend)(tc, set, i); return; }
    @try { [tc setValue:@(i) forKey:@"selectedIndex"]; return; } @catch (__unused NSException *e) {}
    if (i >= 0 && i < (NSInteger)items.count && [items[i] isKindOfClass:UIControl.class])
        [(UIControl *)items[i] sendActionsForControlEvents:UIControlEventTouchUpInside];
}

static UIColor *WGDyn(UIColor *l, UIColor *d) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? d : l;
    }];
}
static UIColor *WGGreen(void) { return [UIColor colorWithRed:7 / 255.0 green:193 / 255.0 blue:96 / 255.0 alpha:1]; }
static void WGRound(UIView *v) { v.layer.cornerRadius = MIN(v.bounds.size.width, v.bounds.size.height) / 2; }

// ---- 底栏:6 种样式(经典 / 胶囊 / 文字胶囊 / 滑杆 / 双层分组 / 展开胶囊) ----
@interface WGTabView : UIView
@property (nonatomic) NSInteger selected;
@property (nonatomic) NSInteger style;
@property (nonatomic, copy) void (^onSelect)(NSInteger);
@property (nonatomic, copy) NSInteger (^indexProvider)(void);
+ (CGFloat)heightForStyle:(NSInteger)s;
- (void)setSelected:(NSInteger)i animated:(BOOL)a;
- (void)refreshTitles;
@end

@implementation WGTabView {
    UIVisualEffectView *_glass;
    UIView *_pill, *_fill, *_knob, *_chipPill;
    NSMutableArray<UIImageView *> *_icons;
    NSMutableArray<UILabel *> *_labels, *_chips;
    NSMutableArray<NSValue *> *_cells, *_chipCells;
    NSTimer *_timer;
}

+ (CGFloat)heightForStyle:(NSInteger)s {
    static const CGFloat hs[] = {64, 64, 56, 56, 104, 64};
    return hs[MAX(0, MIN(5, s))];
}

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _glass = WGBlur(32, NO);
    [self addSubview:_glass];
    _fill = [UIView new]; _knob = [UIView new]; _pill = [UIView new]; _chipPill = [UIView new];
    for (UIView *v in @[_fill, _knob, _pill, _chipPill]) { v.userInteractionEnabled = NO; [self addSubview:v]; }
    _fill.backgroundColor = WGDyn([UIColor colorWithWhite:0.13 alpha:1], [UIColor colorWithWhite:0.85 alpha:1]);
    _knob.backgroundColor = WGDyn(UIColor.whiteColor, [UIColor colorWithWhite:0.3 alpha:1]);
    _knob.layer.shadowColor = UIColor.blackColor.CGColor;
    _knob.layer.shadowOpacity = 0.18; _knob.layer.shadowRadius = 4; _knob.layer.shadowOffset = CGSizeMake(0, 2);
    _chipPill.backgroundColor = UIColor.labelColor;

    NSArray *syms = @[@"bubble.fill", @"person.2.fill", @"safari.fill", @"person.fill"];
    NSArray *fallback = @[@"message.fill", @"person.2.fill", @"safari", @"person.fill"];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    _icons = [NSMutableArray array]; _labels = [NSMutableArray array]; _chips = [NSMutableArray array];
    _cells = [NSMutableArray array]; _chipCells = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        UIImage *img = [UIImage systemImageNamed:syms[i] withConfiguration:cfg] ?: [UIImage systemImageNamed:fallback[i] withConfiguration:cfg];
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.bounds = CGRectMake(0, 0, 26, 26);
        [self addSubview:iv]; [_icons addObject:iv];
        UILabel *lb = [UILabel new];
        lb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        lb.textColor = UIColor.labelColor;
        [self addSubview:lb]; [_labels addObject:lb];
        UILabel *ch = [UILabel new];
        ch.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        [self addSubview:ch]; [_chips addObject:ch];
    }
    [self refreshTitles];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    return self;
}

- (void)refreshTitles {
    BOOL en = [WGD() integerForKey:@"lang"] == 1;
    NSArray *t = en ? @[@"Chats", @"Contacts", @"Discover", @"Me"] : @[@"微信", @"通讯录", @"发现", @"我"];
    NSArray *c = en ? @[@"All", @"Unread", @"Groups", @"Work"] : @[@"全部", @"未读", @"群聊", @"工作"];
    for (int i = 0; i < 4; i++) { _labels[i].text = t[i]; _chips[i].text = c[i]; }
    [self setNeedsLayout];
}

- (void)setStyle:(NSInteger)s {
    if (s == _style) return;
    _style = s;
    [self setNeedsLayout];
}

- (void)layoutForSelected:(NSInteger)sel {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 6;
    NSInteger st = _style;
    UIColor *green = WGGreen(), *sec = UIColor.secondaryLabelColor;
    [_cells removeAllObjects];
    _pill.hidden = !(st == 1 || st == 2 || st == 5);
    _fill.hidden = _knob.hidden = (st != 3);
    _chipPill.hidden = (st != 4);
    for (UILabel *c in _chips) c.hidden = (st != 4);

    CGFloat cw = (W - pad * 2) / 4;
    CGFloat dia = H - pad * 2, usable = W - pad * 2 - dia, kcx = pad + dia / 2 + sel * usable / 3;
    for (NSInteger i = 0; i < 4; i++) {
        CGRect r;
        if (st == 5) {
            CGFloat unit = (W - pad * 2) / 4.8, x = pad;
            for (NSInteger j = 0; j < i; j++) x += (j == sel ? 1.8 : 1.0) * unit;
            r = CGRectMake(x, pad, (i == sel ? 1.8 : 1.0) * unit, H - pad * 2);
        } else if (st == 4) {
            r = CGRectMake(pad + i * cw, 46, cw, H - 46 - 4);
        } else if (st == 3 || st == 0) {
            r = CGRectMake(pad + i * cw, 0, cw, H);
        } else {
            r = CGRectMake(pad + i * cw, pad, cw, H - pad * 2);
        }
        [_cells addObject:[NSValue valueWithCGRect:r]];
        UIImageView *iv = _icons[i]; UILabel *lb = _labels[i];
        BOOL on = (i == sel);
        CGFloat mx = CGRectGetMidX(r), my = CGRectGetMidY(r);
        iv.transform = CGAffineTransformIdentity;
        iv.alpha = 1;
        switch (st) {
            case 0:
                lb.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
                [lb sizeToFit];
                iv.center = CGPointMake(mx, H * 0.36);
                lb.center = CGPointMake(mx, H * 0.74);
                lb.alpha = 1; lb.textColor = on ? green : sec; iv.tintColor = on ? green : sec;
                if (on) iv.transform = CGAffineTransformMakeScale(1.1, 1.1);
                break;
            case 1:
                lb.alpha = 0; iv.center = CGPointMake(mx, my);
                iv.tintColor = on ? UIColor.labelColor : sec;
                break;
            case 2:
                lb.font = [UIFont systemFontOfSize:15 weight:on ? UIFontWeightSemibold : UIFontWeightMedium];
                [lb sizeToFit];
                lb.center = CGPointMake(mx, my); lb.alpha = 1;
                lb.textColor = on ? UIColor.labelColor : sec;
                iv.alpha = 0;
                break;
            case 3:
                lb.alpha = 0;
                iv.center = CGPointMake(kcx, H / 2);
                iv.alpha = on ? 1 : 0;
                iv.tintColor = UIColor.labelColor;
                break;
            case 4:
                lb.alpha = 0; iv.center = CGPointMake(mx, my);
                iv.tintColor = on ? green : sec;
                break;
            default: {   // 5 展开胶囊
                lb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                [lb sizeToFit];
                if (on) {
                    CGFloat total = 26 + 6 + lb.bounds.size.width;
                    CGFloat sx = r.origin.x + (r.size.width - total) / 2;
                    iv.center = CGPointMake(sx + 13, my);
                    lb.frame = CGRectMake(sx + 32, my - lb.bounds.size.height / 2, lb.bounds.size.width, lb.bounds.size.height);
                    lb.alpha = 1;
                    lb.textColor = UIColor.systemBackgroundColor;
                    iv.tintColor = UIColor.systemBackgroundColor;
                } else {
                    iv.center = CGPointMake(mx, my);
                    lb.center = iv.center; lb.alpha = 0;
                    iv.tintColor = sec;
                }
            }
        }
    }

    if (st == 1 || st == 2 || st == 5) {
        CGRect r = _cells[sel].CGRectValue;
        CGRect pr = r;
        if (st == 1) pr = CGRectMake(CGRectGetMidX(r) - r.size.height / 2, r.origin.y, r.size.height, r.size.height);
        else if (st == 2) pr = CGRectInset(r, 4, 0);
        _pill.frame = pr;
        _pill.layer.cornerRadius = pr.size.height / 2;
        _pill.backgroundColor = st == 5 ? UIColor.labelColor
                                        : WGDyn([UIColor colorWithWhite:1 alpha:0.92], [UIColor colorWithWhite:1 alpha:0.22]);
    }
    if (st == 3) {
        _knob.frame = CGRectMake(kcx - dia / 2, pad, dia, dia);
        _knob.layer.cornerRadius = dia / 2;
        _fill.frame = CGRectMake(pad, pad, kcx - pad + dia * 0.1, dia);
        _fill.layer.cornerRadius = dia / 2;
    }
    if (st == 4) {
        [_chipCells removeAllObjects];
        NSInteger cs = MAX(0, MIN(3, [WGD() integerForKey:@"chipSel"]));
        NSMutableArray *ws = [NSMutableArray array];
        CGFloat total = 0, gap = 8;
        for (UILabel *c in _chips) { [c sizeToFit]; CGFloat w = c.bounds.size.width + 22; [ws addObject:@(w)]; total += w; }
        total += gap * 3;
        CGFloat x = (W - total) / 2;
        for (NSInteger i = 0; i < 4; i++) {
            CGFloat w = [ws[i] doubleValue];
            CGRect cr = CGRectMake(x, 12, w, 26);
            [_chipCells addObject:[NSValue valueWithCGRect:cr]];
            _chips[i].frame = cr;
            _chips[i].textAlignment = NSTextAlignmentCenter;
            _chips[i].textColor = i == cs ? UIColor.systemBackgroundColor : UIColor.secondaryLabelColor;
            x += w + gap;
        }
        _chipPill.frame = _chipCells[cs].CGRectValue;
        _chipPill.layer.cornerRadius = 13;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _glass.frame = self.bounds;
    _glass.layer.cornerRadius = _style == 4 ? 30 : self.bounds.size.height / 2;
    [self layoutForSelected:_selected];
}

- (void)setSelected:(NSInteger)i animated:(BOOL)a {
    if (i < 0 || i > 3 || i == _selected) return;
    _selected = i;
    if (a && self.window) {
        [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ [self layoutForSelected:i]; } completion:nil];
    } else {
        [self layoutForSelected:i];
    }
}

- (NSInteger)indexAtX:(CGFloat)x {
    for (NSInteger i = 0; i < (NSInteger)_cells.count; i++) {
        CGRect r = _cells[i].CGRectValue;
        if (x >= CGRectGetMinX(r) && x < CGRectGetMaxX(r)) return i;
    }
    return -1;
}

- (NSInteger)chipAtX:(CGFloat)x {
    for (NSInteger i = 0; i < (NSInteger)_chipCells.count; i++) {
        CGRect r = _chipCells[i].CGRectValue;
        if (x >= CGRectGetMinX(r) - 4 && x < CGRectGetMaxX(r) + 4) return i;
    }
    return -1;
}

- (void)pick:(NSInteger)i {
    if (i < 0 || i == _selected) return;
    [self setSelected:i animated:YES];
    if (self.onSelect) self.onSelect(i);
}

- (void)tap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    if (_style == 4 && p.y < 46) {
        NSInteger c = [self chipAtX:p.x];
        if (c >= 0) {
            [WGD() setInteger:c forKey:@"chipSel"];
            [UIView animateWithDuration:0.3 animations:^{ [self layoutForSelected:self->_selected]; }];
        }
        return;
    }
    [self pick:[self indexAtX:p.x]];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint p = [g locationInView:self];
    if (_style == 4 && p.y < 46) return;
    [self pick:[self indexAtX:p.x]];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_timer invalidate]; _timer = nil;
    if (!self.window) return;
    __weak WGTabView *w = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        WGTabView *s = w;
        if (!s || !s.indexProvider) return;
        NSInteger i = s.indexProvider();
        if (i >= 0 && i < 4 && i != s.selected) [s setSelected:i animated:YES];
    }];
}
@end

// ---- 聊天顶栏:7 种样式(标题胶囊 / Pins 胶囊 / 仿TIM / 名签胶囊 / 名签竖线 / 头像居中 / 昵称横线) ----
@interface WGTopBar : UIView
@property (nonatomic) NSInteger style;
@property (nonatomic, copy) void (^onBack)(void);
@property (nonatomic, copy) void (^onInfo)(void);
@property (nonatomic, copy) void (^onMenu)(void);
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *customLeft;
@property (nonatomic, copy) NSString *customRight;
@property (nonatomic, copy) NSString *backText;
@property (nonatomic, strong) UIColor *coverColor;
@property (nonatomic, strong) UIImage *avatar;
- (void)refreshTexts;
@end

@implementation WGTopBar {
    UIView *_cover, *_seg, *_vbar, *_av;
    UIVisualEffectView *_g1, *_g2, *_g3, *_g4;
    UIImageView *_chev, *_ic1, *_ic2, *_dd, *_avImg;
    UILabel *_back, *_t1, *_t2, *_avL;
    UIButton *_bBack, *_bTitle, *_bSeg2, *_bR1, *_bR2, *_bAv;
    NSInteger _idx;
}

- (UIButton *)btn:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (UIImageView *)iconView {
    UIImageView *v = [UIImageView new];
    v.tintColor = UIColor.labelColor;
    v.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:v];
    return v;
}

- (UILabel *)label {
    UILabel *l = [UILabel new];
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:l];
    return l;
}

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.clipsToBounds = NO;
    _cover = [UIView new];
    [self addSubview:_cover];
    _g1 = WGBlur(21.5, NO); _g2 = WGBlur(21.5, NO); _g3 = WGBlur(21.5, NO); _g4 = WGBlur(21.5, NO);
    for (UIView *g in @[_g1, _g2, _g3, _g4]) [self addSubview:g];
    _seg = [UIView new];
    _seg.backgroundColor = WGDyn([UIColor colorWithWhite:1 alpha:0.6], [UIColor colorWithWhite:1 alpha:0.16]);
    [self addSubview:_seg];
    _vbar = [UIView new];
    _vbar.backgroundColor = UIColor.labelColor;
    [self addSubview:_vbar];
    _av = [UIView new];
    _av.backgroundColor = [UIColor colorWithRed:0.93 green:0.56 blue:0.43 alpha:1];
    _av.clipsToBounds = YES;
    _avImg = [UIImageView new]; _avImg.contentMode = UIViewContentModeScaleAspectFill; [_av addSubview:_avImg];
    _avL = [UILabel new]; _avL.textColor = UIColor.whiteColor; _avL.textAlignment = NSTextAlignmentCenter;
    _avL.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [_av addSubview:_avL];
    [self addSubview:_av];
    _chev = [self iconView]; _ic1 = [self iconView]; _ic2 = [self iconView]; _dd = [self iconView];
    _dd.tintColor = UIColor.secondaryLabelColor;
    _back = [self label]; _t1 = [self label]; _t2 = [self label];
    _back.textColor = UIColor.labelColor;
    _bBack = [self btn:@selector(tapBack)];
    _bTitle = [self btn:@selector(tapInfo)];
    _bSeg2 = [self btn:@selector(tapSeg2)];
    _bR1 = [self btn:@selector(tapMenu)];
    _bR2 = [self btn:@selector(tapBack)];
    _bAv = [self btn:@selector(tapMenu)];
    return self;
}

- (void)setStyle:(NSInteger)s {
    _style = s;
    [self refreshTexts];
    [self setNeedsLayout];
}
- (void)setTitle:(NSString *)t { _title = [t copy]; [self refreshTexts]; }
- (void)setCoverColor:(UIColor *)c { _coverColor = c; _cover.backgroundColor = c; }
- (void)setAvatar:(UIImage *)a { _avatar = a; _avImg.image = a; _avL.hidden = a != nil; }

- (void)refreshTexts {
    NSString *main = self.customLeft.length ? self.customLeft : (self.title.length ? self.title : WGL(@"聊天", @"Chat"));
    _t1.text = main;
    _t2.text = _style == 2 ? (self.customRight.length ? self.customRight : WGL(@"详情", @"Info")) : (self.customRight ?: @"");
    _back.text = _style == 3 ? (self.backText ?: @"") : WGL(@"返回", @"Back");
    _avL.text = main.length ? [main substringWithRange:[main rangeOfComposedCharacterSequenceAtIndex:0]] : @"";
    _avL.hidden = _avatar != nil;
}

- (void)updateSeg {
    _t1.textColor = _idx == 0 ? UIColor.labelColor : UIColor.secondaryLabelColor;
    _t2.textColor = _idx == 1 ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _cover.frame = self.bounds;
    NSArray *all = @[_g1, _g2, _g3, _g4, _seg, _vbar, _av, _chev, _ic1, _ic2, _dd, _back, _t1, _t2, _bBack, _bTitle, _bSeg2, _bR1, _bR2, _bAv];
    for (UIView *v in all) v.hidden = YES;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, h = 43, y = (H - h) / 2, m = 16, mid = H / 2;
    void (^P)(UIView *, CGRect) = ^(UIView *v, CGRect f) { v.hidden = NO; v.frame = f; };
    UIImageSymbolConfiguration *c17 = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold];
    UIImageSymbolConfiguration *c20 = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    UIImageSymbolConfiguration *c15 = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    UIImageSymbolConfiguration *c9 = [UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightBold];
    _chev.image = [UIImage systemImageNamed:@"chevron.left" withConfiguration:c17];
    _dd.image = [UIImage systemImageNamed:@"chevron.down" withConfiguration:c9];
    _t1.textColor = UIColor.labelColor;
    _t2.textColor = UIColor.secondaryLabelColor;
    _t2.font = [UIFont systemFontOfSize:11];
    _t1.textAlignment = NSTextAlignmentCenter;
    _t2.textAlignment = NSTextAlignmentCenter;
    BOOL hasSub = _style != 2 && _t2.text.length > 0;

    switch (_style) {
        case 1: {   // 标题胶囊
            P(_g1, CGRectMake(m, y, h, h));
            P(_chev, CGRectMake(m + (h - 14) / 2 - 1, mid - 10, 14, 20));
            P(_bBack, _g1.frame);
            _t1.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
            [_t1 sizeToFit];
            CGFloat tw = MIN(150, _t1.bounds.size.width);
            CGFloat cw = MAX(110, tw + 46), ch = hasSub ? 50 : h;
            P(_g2, CGRectMake((W - cw) / 2, (H - ch) / 2, cw, ch));
            P(_t1, CGRectMake(_g2.frame.origin.x + 8, _g2.frame.origin.y + (hasSub ? 7 : (ch - 20) / 2), cw - 28, 20));
            P(_dd, CGRectMake(CGRectGetMaxX(_g2.frame) - 22, CGRectGetMidY(_t1.frame) - 5, 10, 10));
            if (hasSub) P(_t2, CGRectMake(_g2.frame.origin.x + 8, _g2.frame.origin.y + 28, cw - 16, 14));
            P(_av, CGRectMake(W - m - h, y, h, h));
            P(_bAv, _av.frame);
            P(_bTitle, _g2.frame);
        } break;
        case 2: {   // Pins 胶囊
            P(_g1, CGRectMake(m, y, 78, h));
            P(_chev, CGRectMake(m + 13, mid - 10, 14, 20));
            _back.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            P(_back, CGRectMake(m + 33, y, 42, h));
            P(_bBack, _g1.frame);
            CGFloat cw = 157, sw = (cw - 8) / 2, cx = (W - cw) / 2;
            P(_g2, CGRectMake(cx, y, cw, h));
            P(_seg, CGRectMake(cx + 4 + _idx * sw, y + 4, sw, h - 8));
            _seg.layer.cornerRadius = (h - 8) / 2;
            _t1.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            _t2.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            P(_t1, CGRectMake(cx + 8, y, sw - 8, h));
            P(_t2, CGRectMake(cx + 4 + sw, y, sw - 12, h));
            P(_dd, CGRectMake(cx + cw - 17, mid - 5, 10, 10));
            P(_g3, CGRectMake(W - m - h, y, h, h));
            _ic1.image = [UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:c20];
            P(_ic1, CGRectMake(W - m - h + (h - 22) / 2, y + (h - 22) / 2, 22, 22));
            P(_bR1, _g3.frame);
            P(_bTitle, CGRectMake(cx + 4, y, sw, h));
            P(_bSeg2, CGRectMake(cx + 4 + sw, y, sw, h));
            [self updateSeg];
        } break;
        case 3: {   // 仿 TIM
            _back.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
            [_back sizeToFit];
            CGFloat bw = _back.text.length ? 32 + _back.bounds.size.width + 12 : 46;
            P(_g1, CGRectMake(m, y, bw, h));
            P(_chev, CGRectMake(m + 13, mid - 10, 14, 20));
            if (_back.text.length) P(_back, CGRectMake(m + 32, y, bw - 40, h));
            P(_bBack, _g1.frame);
            _t1.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
            [_t1 sizeToFit];
            CGFloat tw = MIN(150, _t1.bounds.size.width);
            CGFloat cw = MAX(100, tw + 36), ch = hasSub ? 50 : h;
            P(_g2, CGRectMake((W - cw) / 2, (H - ch) / 2, cw, ch));
            P(_t1, CGRectMake(_g2.frame.origin.x + 8, _g2.frame.origin.y + (hasSub ? 7 : (ch - 20) / 2), cw - 16, 20));
            if (hasSub) P(_t2, CGRectMake(_g2.frame.origin.x + 8, _g2.frame.origin.y + 28, cw - 16, 14));
            P(_g3, CGRectMake(W - m - h, y, h, h));
            _ic1.image = [UIImage systemImageNamed:@"ellipsis" withConfiguration:c20];
            P(_ic1, CGRectMake(W - m - h + (h - 22) / 2, y + (h - 22) / 2, 22, 22));
            P(_bR1, _g3.frame);
            P(_bTitle, _g2.frame);
        } break;
        case 4: {   // 名签胶囊
            _t1.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
            [_t1 sizeToFit];
            CGFloat tw = MIN(W * 0.45, _t1.bounds.size.width), gw = tw + 34;
            P(_g1, CGRectMake(m, y, gw, h));
            P(_t1, CGRectMake(m + 17, y, gw - 34, h));
            P(_bTitle, _g1.frame);
            P(_g4, CGRectMake(W - m - h, y, h, h));
            _ic2.image = [UIImage systemImageNamed:@"xmark" withConfiguration:c15];
            P(_ic2, CGRectMake(W - m - h + (h - 18) / 2, y + (h - 18) / 2, 18, 18));
            P(_bR2, _g4.frame);
            P(_g3, CGRectMake(W - m - h * 2 - 8, y, h, h));
            _ic1.image = [UIImage systemImageNamed:@"ellipsis" withConfiguration:c20];
            P(_ic1, CGRectMake(CGRectGetMinX(_g3.frame) + (h - 22) / 2, y + (h - 22) / 2, 22, 22));
            P(_bR1, _g3.frame);
        } break;
        case 5: {   // 名签竖线
            P(_vbar, CGRectMake(m, y + 3, 3, h - 6));
            _t1.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
            _t1.textAlignment = NSTextAlignmentLeft;
            P(_t1, CGRectMake(m + 12, y + (hasSub ? 1 : (h - 22) / 2), W * 0.5, 22));
            if (hasSub) {
                _t2.font = [UIFont systemFontOfSize:12];
                _t2.textAlignment = NSTextAlignmentLeft;
                P(_t2, CGRectMake(m + 12, y + 23, W * 0.5, 16));
            }
            _ic2.image = [UIImage systemImageNamed:@"xmark" withConfiguration:c17];
            P(_ic2, CGRectMake(W - m - 24, mid - 10, 20, 20));
            P(_bR2, CGRectMake(W - m - 44, y, 44, h));
            _ic1.image = [UIImage systemImageNamed:@"ellipsis" withConfiguration:c20];
            P(_ic1, CGRectMake(W - m - 68, mid - 11, 22, 22));
            P(_bR1, CGRectMake(W - m - 88, y, 44, h));
            P(_bTitle, CGRectMake(m, y, W * 0.55, h));
        } break;
        case 6: {   // 头像居中
            P(_chev, CGRectMake(m, mid - 12, 16, 24));
            P(_bBack, CGRectMake(m - 8, y, 48, h));
            P(_av, CGRectMake(W / 2 - 28, mid - 30, 56, 56));
            P(_bAv, _av.frame);
            _t1.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
            P(_t1, CGRectMake(W / 2 - 70, CGRectGetMaxY(_av.frame) + 2, 140, 14));
            _ic1.image = [UIImage systemImageNamed:@"ellipsis" withConfiguration:c20];
            P(_ic1, CGRectMake(W - m - 24, mid - 11, 22, 22));
            P(_bR1, CGRectMake(W - m - 44, y, 44, h));
        } break;
        case 7: {   // 昵称横线
            P(_chev, CGRectMake(m, mid - 12, 16, 24));
            P(_bBack, CGRectMake(m - 8, y, 48, h));
            _t1.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
            _t1.textAlignment = NSTextAlignmentLeft;
            P(_t1, CGRectMake(m + 28, y, W - m - 28 - 100, h));
            P(_bTitle, _t1.frame);
            P(_g3, CGRectMake(W - m - 76, y, 76, h));
            _ic1.image = [UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold]];
            P(_ic1, CGRectMake(W - m - 76 + 25, y + (h - 26) / 2, 26, 26));
            P(_bR1, _g3.frame);
        } break;
        default: break;
    }
    for (UIView *g in @[_g1, _g2, _g3, _g4]) if (!g.hidden) WGRound(g);
    if (!_av.hidden) {
        _av.layer.cornerRadius = _av.bounds.size.width / 2;
        _avImg.frame = _av.bounds;
        _avL.frame = _av.bounds;
    }
}

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    for (UIButton *b in @[_bBack, _bTitle, _bSeg2, _bR1, _bR2, _bAv])
        if (!b.hidden && CGRectContainsPoint(b.frame, p)) return YES;
    return NO;
}

- (void)moveSeg:(NSInteger)i {
    _idx = i;
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3 options:0 animations:^{
        CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
        CGFloat sw = (157 - 8) / 2, cx = (W - 157) / 2, y = (H - 43) / 2;
        self->_seg.frame = CGRectMake(cx + 4 + i * sw, y + 4, sw, 35);
        [self updateSeg];
    } completion:nil];
}
- (void)tapBack { if (self.onBack) self.onBack(); }
- (void)tapMenu { if (self.onMenu) self.onMenu(); }
- (void)tapInfo {
    if (_style == 2) { [self moveSeg:0]; return; }
    if (self.onInfo) self.onInfo();
}
- (void)tapSeg2 {
    [self moveSeg:1];
    if (self.onInfo) self.onInfo();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self moveSeg:0]; });
}
@end

#pragma mark - 诊断

static NSString *WGChain(id obj) {
    NSMutableArray *a = [NSMutableArray array];
    Class c = [obj class];
    while (c && a.count < 6) { [a addObject:NSStringFromClass(c)]; c = class_getSuperclass(c); }
    return [a componentsJoinedByString:@" > "];
}

static UIViewController *WGTopVC(void) {
    UIViewController *v = WGWindow().rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

static UIViewController *WGVisibleVC(void) {
    UIViewController *v = WGWindow().rootViewController;
    for (int i = 0; i < 12 && v; i++) {
        if (v.presentedViewController) { v = v.presentedViewController; continue; }
        if ([v isKindOfClass:UINavigationController.class]) {
            UIViewController *t = ((UINavigationController *)v).topViewController;
            if (!t) break;
            v = t; continue;
        }
        if ([v respondsToSelector:NSSelectorFromString(@"selectedViewController")]) {
            id sel = nil;
            @try { sel = [v valueForKey:@"selectedViewController"]; } @catch (__unused NSException *e) {}
            if ([sel isKindOfClass:UIViewController.class]) { v = sel; continue; }
        }
        UIViewController *nx = nil;
        for (UIViewController *c in v.childViewControllers) if ([c isKindOfClass:UINavigationController.class]) nx = c;
        if (nx) { v = nx; continue; }
        break;
    }
    return v;
}

static void WGDumpCapped(UIView *v, int depth, NSMutableString *out) {
    if (out.length > 40000 || depth > 9) return;
    [out appendFormat:@"%@%@ %@\n", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
        NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
    for (UIView *s in v.subviews) WGDumpCapped(s, depth + 1, out);
}

static void WGBottomViews(UIView *root, UIView *v, int depth, NSMutableString *s, int *n) {
    if (depth > 7 || *n > 14) return;
    CGRect f = [root convertRect:v.bounds fromView:v];
    if (v != root && f.size.width > root.bounds.size.width * 0.8 && f.size.height >= 30 && f.size.height < 260 &&
        CGRectGetMaxY(f) > root.bounds.size.height - 300) {
        [s appendFormat:@"  %@ %@\n", NSStringFromClass(v.class), NSStringFromCGRect(f)];
        (*n)++;
    }
    for (UIView *x in v.subviews) WGBottomViews(root, x, depth + 1, s, n);
}

static NSString *WGDiagnose(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"钩子: chat=%d tab=%d setting=%d\n", gHookChat, gHookTab, gHookSet];
    [s appendFormat:@"触发次数: chat=%d tab=%d\n", gCntChat, gCntTab];
    [s appendFormat:@"%@\n", gTopInfo ?: @"顶栏: 还没执行过"];
    [s appendFormat:@"同类插件: %@\n", WGOtherTweaks().length ? WGOtherTweaks() : @"未检测到"];
    [s appendFormat:@"侧边栏手势: 触发%d次 最近结果=%@ 在首页=%d 找到TabVC=%d 窗口=%d\n", gCntEdge, gEdgeWhy ?: @"无", WGHomeVisible(), gTab != nil, gOverlay != nil];
    [s appendFormat:@"类存在: MMTabBarController=%d BaseMsgContent=%d\n",
        NSClassFromString(@"MMTabBarController") != nil, NSClassFromString(@"BaseMsgContentViewController") != nil];
    UIWindow *w = WGWindow();
    [s appendFormat:@"root: %@\n", w.rootViewController ? WGChain(w.rootViewController) : @"nil"];
    if (gTab) {
        [s appendFormat:@"tabVC: %@\n", WGChain(gTab)];
        UIView *b = gTabBar;
        if (b) {
            [s appendFormat:@"底栏视图: %@ hidden=%d %@\n", NSStringFromClass(b.class), b.hidden, NSStringFromCGRect(b.frame)];
            NSMutableArray *names = [NSMutableArray array];
            for (UIView *v in b.subviews) [names addObject:NSStringFromClass(v.class)];
            [s appendFormat:@"底栏子视图: %@\n", [names componentsJoinedByString:@", "]];
        } else [s appendString:@"底栏视图: 没找到\n"];
    } else {
        [s appendString:@"gTab=nil (底栏钩子没触发)\n"];
    }
    NSMutableArray *kids = [NSMutableArray array];
    for (UIViewController *c in w.rootViewController.childViewControllers) [kids addObject:NSStringFromClass(c.class)];
    [s appendFormat:@"root子VC: %@\n", [kids componentsJoinedByString:@", "]];
    {
        [s appendString:@"窗口底部大视图:\n"];
        int n = 0;
        if (w) WGBottomViews(w, w, 0, s, &n);
    }
    UIViewController *top = WGVisibleVC();
    [s appendFormat:@"当前页VC: %@\n", top ? WGChain(top) : @"nil"];
    if (top.isViewLoaded) {
        UIView *bar = WGFindInputBar(top.view);
        [s appendFormat:@"识别到输入栏: %@\n", bar ? NSStringFromClass(bar.class) : @"无"];
        [s appendString:@"底部大视图:\n"];
        int n = 0;
        WGBottomViews(top.view, top.view, 0, s, &n);
        UINavigationBar *nb = top.navigationController.navigationBar;
        if (nb) [s appendFormat:@"navBar: %@ hidden=%d %@\n", NSStringFromClass(nb.class), nb.hidden, NSStringFromCGRect(nb.frame)];
    }
    NSMutableString *full = [s mutableCopy];
    [full appendString:@"\n---- 视图层级 ----\n"];
    if (w) WGDumpCapped(w, 0, full);
    UIPasteboard.generalPasteboard.string = full;
    return s;
}

static void WGShowDiag(void) {
    NSString *s = WGDiagnose();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"诊断(完整信息已复制)" message:s preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [WGTopVC() presentViewController:a animated:YES completion:nil];
}

#pragma mark - 插件面板

static void WGRefreshAll(void) {
    UIView *root = gTab.view;
    [[root viewWithTag:TAG_GLASS_TAB] removeFromSuperview];
    [[root viewWithTag:TAG_TAB_PLUS] removeFromSuperview];
    [gTopBar removeFromSuperview];
    gTopBar = nil;
    [root setNeedsLayout];
    [root layoutIfNeeded];
}

static NSArray<NSString *> *WGTopNames(void) {
    return @[@"原生", @"标题胶囊", @"Pins 胶囊", @"仿TIM", @"名签胶囊", @"名签竖线", @"头像居中", @"昵称横线"];
}
static NSArray<NSString *> *WGBotNames(void) {
    return @[@"经典", @"胶囊", @"文字胶囊", @"滑杆", @"双层分组", @"展开胶囊"];
}

#pragma mark - 样式预览卡片

static UIView *WGBox(UIView *p, CGRect r, UIColor *c, CGFloat rad, CGFloat s) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s)];
    v.backgroundColor = c;
    v.layer.cornerRadius = rad * s;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    [p addSubview:v];
    return v;
}
static UILabel *WGTxt(UIView *p, NSString *t, CGRect r, CGFloat fs, UIFontWeight w, UIColor *c, NSTextAlignment al, CGFloat s) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s)];
    l.text = t; l.font = [UIFont systemFontOfSize:fs * s weight:w]; l.textColor = c; l.textAlignment = al;
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.6;
    [p addSubview:l];
    return l;
}
static UIImageView *WGSym(UIView *p, NSString *n, CGRect r, CGFloat pt, UIColor *c, CGFloat s) {
    UIImage *img = [UIImage systemImageNamed:n withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pt * s weight:UIImageSymbolWeightSemibold]];
    UIImageView *v = [[UIImageView alloc] initWithImage:img];
    v.frame = CGRectMake(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s);
    v.contentMode = UIViewContentModeScaleAspectFit;
    v.tintColor = c;
    [p addSubview:v];
    return v;
}

#define PB(x, y, w, h, col, r) WGBox(v, CGRectMake(x, y, w, h), col, r, s)
#define PT(t, x, y, w, h, fs, wt, col, al) WGTxt(v, t, CGRectMake(x, y, w, h), fs, wt, col, al, s)
#define PS(n, x, y, w, h, pt, col) WGSym(v, n, CGRectMake(x, y, w, h), pt, col, s)

// kind 0 = 顶栏预览, 1 = 底栏预览;坐标按 200x118 的画布书写
static UIView *WGMakePreview(NSInteger kind, NSInteger st, CGSize sz) {
    CGFloat s = sz.width / 200.0;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sz.width, sz.height)];
    v.backgroundColor = WGDyn([UIColor colorWithWhite:0.93 alpha:1], [UIColor colorWithWhite:0.17 alpha:1]);
    v.layer.cornerRadius = 22;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.clipsToBounds = YES;
    UIColor *W1 = WGDyn(UIColor.whiteColor, [UIColor colorWithWhite:0.3 alpha:1]);
    UIColor *W5 = WGDyn([UIColor colorWithWhite:1 alpha:0.5], [UIColor colorWithWhite:0.3 alpha:0.5]);
    UIColor *L = UIColor.labelColor, *S = UIColor.secondaryLabelColor, *G = WGGreen();
    UIColor *orange = [UIColor colorWithRed:0.93 green:0.58 blue:0.45 alpha:1];
    UIColor *blue = [UIColor colorWithRed:0.35 green:0.55 blue:0.9 alpha:1];
    UIColor *lgreen = [UIColor colorWithRed:0.66 green:0.9 blue:0.45 alpha:1];
    UIColor *purple = [UIColor colorWithRed:0.6 green:0.45 blue:0.9 alpha:1];
    UIColor *grn2 = [UIColor colorWithRed:0.45 green:0.75 blue:0.5 alpha:1];
    UIColor *bar = WGDyn([UIColor colorWithWhite:0.86 alpha:1], [UIColor colorWithWhite:0.3 alpha:1]);

    if (kind == 0) {
        PB(8, 52, 18, 18, orange, 4);
        PB(30, 49, 58, 24, W1, 6);
        PT(@"今天下雨了", 30, 49, 58, 24, 9.5, UIFontWeightRegular, L, NSTextAlignmentCenter);
        PB(112, 86, 50, 24, lgreen, 6);
        PT(@"带伞了", 112, 86, 50, 24, 9.5, UIFontWeightRegular, L, NSTextAlignmentCenter);
        PB(168, 86, 18, 18, blue, 4);
        switch (st) {
            case 0:
                PB(0, 0, 200, 40, W5, 0);
                PS(@"chevron.left", 8, 14, 10, 12, 9, L);
                PT(@"李四", 70, 12, 60, 16, 10, UIFontWeightBold, L, NSTextAlignmentCenter);
                PT(@"···", 164, 10, 28, 16, 12, UIFontWeightBold, L, NSTextAlignmentCenter);
                break;
            case 1:
                PB(8, 9, 24, 24, W1, 12);
                PS(@"chevron.left", 14, 14, 12, 14, 9, L);
                PB(66, 5, 70, 32, W1, 16);
                PT(@"Chat", 70, 8, 50, 14, 10, UIFontWeightBold, L, NSTextAlignmentCenter);
                PS(@"chevron.down", 120, 11, 8, 8, 6, S);
                PT(@"在忙，晚点回", 66, 22, 70, 10, 6.5, UIFontWeightRegular, S, NSTextAlignmentCenter);
                PB(166, 8, 26, 26, orange, 13);
                break;
            case 2:
                PB(8, 11, 50, 22, W1, 11);
                PS(@"chevron.left", 13, 15, 8, 13, 8, L);
                PT(@"Back", 24, 11, 32, 22, 9.5, UIFontWeightBold, L, NSTextAlignmentLeft);
                PB(62, 11, 88, 22, W5, 11);
                PB(65, 13, 38, 18, W1, 9);
                PT(@"Chat", 65, 13, 38, 18, 9.5, UIFontWeightBold, L, NSTextAlignmentCenter);
                PT(@"Pins", 106, 11, 30, 22, 9.5, UIFontWeightBold, L, NSTextAlignmentCenter);
                PS(@"chevron.down", 135, 19, 8, 6, 6, L);
                PB(166, 11, 24, 22, W1, 11);
                PS(@"line.3.horizontal", 171, 15, 14, 14, 9, L);
                break;
            case 3:
                PB(8, 9, 46, 26, W1, 13);
                PS(@"chevron.left", 14, 14, 8, 14, 8, L);
                PT(@"12", 25, 9, 26, 26, 10, UIFontWeightBold, L, NSTextAlignmentLeft);
                PB(74, 5, 54, 34, W1, 16);
                PT(@"Chat", 74, 9, 54, 14, 10, UIFontWeightBold, L, NSTextAlignmentCenter);
                PT(@"在线", 74, 23, 54, 10, 6.5, UIFontWeightRegular, S, NSTextAlignmentCenter);
                PB(162, 10, 28, 24, W1, 12);
                PT(@"···", 162, 10, 28, 24, 11, UIFontWeightBold, L, NSTextAlignmentCenter);
                break;
            case 4:
                PB(8, 9, 40, 26, W1, 13);
                PT(@"李四", 8, 9, 40, 26, 9.5, UIFontWeightBold, L, NSTextAlignmentCenter);
                PB(142, 9, 24, 24, W1, 12);
                PT(@"···", 142, 9, 24, 24, 11, UIFontWeightBold, L, NSTextAlignmentCenter);
                PB(170, 9, 24, 24, W1, 12);
                PS(@"xmark", 176, 15, 12, 12, 8, L);
                break;
            case 5:
                PB(9, 9, 2, 24, L, 1);
                PT(@"李四", 16, 8, 50, 14, 10, UIFontWeightBold, L, NSTextAlignmentLeft);
                PT(@"在线", 16, 22, 50, 10, 7, UIFontWeightRegular, S, NSTextAlignmentLeft);
                PT(@"···", 146, 10, 28, 16, 12, UIFontWeightBold, L, NSTextAlignmentCenter);
                PS(@"xmark", 178, 13, 10, 10, 8, L);
                break;
            case 6:
                PS(@"chevron.left", 10, 14, 8, 14, 9, L);
                PB(84, 3, 32, 32, orange, 16);
                PT(@"李四", 70, 37, 60, 10, 7, UIFontWeightBold, L, NSTextAlignmentCenter);
                PT(@"···", 164, 12, 28, 16, 12, UIFontWeightBold, L, NSTextAlignmentCenter);
                break;
            default:
                PS(@"chevron.left", 10, 14, 8, 14, 9, L);
                PT(@"家人群 (6)", 24, 12, 70, 16, 9.5, UIFontWeightBold, L, NSTextAlignmentLeft);
                PS(@"speaker.slash", 90, 15, 10, 10, 7, S);
                PB(160, 8, 34, 26, W1, 13);
                PS(@"line.3.horizontal", 167, 13, 20, 16, 11, L);
                break;
        }
    } else {
        PB(10, 10, 24, 24, orange, 7);  PB(42, 14, 62, 5, bar, 2.5);  PB(42, 24, 96, 5, bar, 2.5);
        PB(10, 40, 24, 24, grn2, 7);    PB(42, 44, 62, 5, bar, 2.5);  PB(42, 54, 96, 5, bar, 2.5);
        PB(10, 70, 24, 24, purple, 7);  PB(42, 74, 62, 5, bar, 2.5);
        NSArray *icons = @[@"bubble.fill", @"person.2.fill", @"safari.fill", @"person.fill"];
        NSArray *names = @[@"微信", @"通讯录", @"发现", @"我"];
        switch (st) {
            case 0:
                PB(10, 72, 180, 38, W1, 19);
                for (int i = 0; i < 4; i++) {
                    UIColor *c = i == 0 ? G : S;
                    PS(icons[i], 10 + i * 45 + 14, 76, 17, 14, 10, c);
                    PT(names[i], 10 + i * 45, 92, 45, 10, 6, UIFontWeightMedium, c, NSTextAlignmentCenter);
                }
                break;
            case 1:
                PB(10, 74, 132, 34, W1, 17);
                for (int i = 0; i < 4; i++) {
                    if (i == 0) PB(10 + 4, 76, 30, 30, W5, 15);
                    PS(icons[i], 10 + i * 33 + 8, 82, 16, 16, 9, i == 0 ? L : S);
                }
                PB(148, 74, 42, 34, [UIColor colorWithWhite:0.07 alpha:1], 17);
                PS(@"plus", 160, 82, 18, 18, 11, UIColor.whiteColor);
                break;
            case 2:
                PB(10, 76, 128, 32, W1, 16);
                PB(14, 79, 32, 26, W5, 13);
                for (int i = 0; i < 4; i++)
                    PT(names[i], 14 + i * 31, 79, 32, 26, 7.5, i == 0 ? UIFontWeightBold : UIFontWeightMedium, i == 0 ? L : S, NSTextAlignmentCenter);
                PB(146, 76, 32, 32, W1, 16);
                PS(@"plus", 154, 84, 16, 16, 10, L);
                break;
            case 3:
                PB(10, 78, 180, 28, WGDyn([UIColor colorWithWhite:0.86 alpha:1], [UIColor colorWithWhite:0.3 alpha:1]), 14);
                PB(10, 78, 70, 28, [UIColor colorWithWhite:0.13 alpha:1], 14);
                PB(52, 80, 24, 24, UIColor.whiteColor, 12);
                PS(@"bubble.fill", 57, 85, 14, 14, 8, [UIColor blackColor]);
                break;
            case 4:
                PB(10, 54, 180, 56, W1, 20);
                PB(26, 60, 28, 14, L, 7);
                PT(@"全部", 26, 60, 28, 14, 7, UIFontWeightMedium, UIColor.systemBackgroundColor, NSTextAlignmentCenter);
                PT(@"未读", 62, 60, 28, 14, 7, UIFontWeightMedium, S, NSTextAlignmentCenter);
                PT(@"群聊", 98, 60, 28, 14, 7, UIFontWeightMedium, S, NSTextAlignmentCenter);
                PT(@"工作", 134, 60, 28, 14, 7, UIFontWeightMedium, S, NSTextAlignmentCenter);
                for (int i = 0; i < 4; i++) PS(icons[i], 10 + i * 45 + 14, 84, 17, 16, 10, i == 0 ? G : S);
                break;
            default:
                PB(10, 74, 180, 34, W1, 17);
                PB(14, 77, 60, 28, [UIColor colorWithWhite:0.07 alpha:1], 14);
                PS(@"bubble.fill", 22, 83, 14, 14, 8, UIColor.whiteColor);
                PT(@"微信", 38, 77, 32, 28, 8, UIFontWeightBold, UIColor.whiteColor, NSTextAlignmentLeft);
                for (int i = 1; i < 4; i++) PS(icons[i], 62 + i * 33 + 8, 82, 16, 16, 9, S);
                break;
        }
    }
    return v;
}

#pragma mark - 样式选择页(像参考图:点卡片即切换)

@interface WGStylePickerVC : UIViewController
- (instancetype)initWithKind:(NSInteger)kind;
@end

@implementation WGStylePickerVC {
    NSInteger _kind;
    UIScrollView *_sv;
    CGFloat _builtW;
    NSMutableArray<UIControl *> *_cards;
    NSMutableArray<UIImageView *> *_radios;
}

- (instancetype)initWithKind:(NSInteger)kind {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _kind = kind;
    return self;
}

- (NSString *)key { return _kind == 0 ? @"topStyle" : @"botStyle"; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _kind == 0 ? @"顶栏样式" : @"底栏样式";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _sv = [UIScrollView new];
    _sv.alwaysBounceVertical = YES;
    [self.view addSubview:_sv];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _sv.frame = self.view.bounds;
    if (fabs(_builtW - self.view.bounds.size.width) > 0.5) [self rebuild];
}

- (void)rebuild {
    _builtW = self.view.bounds.size.width;
    for (UIView *v in [_sv.subviews copy]) [v removeFromSuperview];
    _cards = [NSMutableArray array]; _radios = [NSMutableArray array];
    CGFloat W = _builtW, m = 16, gap = 12, cw = floor((W - m * 2 - gap) / 2), ph = round(cw * 0.59);
    CGFloat y = 16;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(m + 4, y, W - m * 2, 22)];
    hint.text = @"点一张卡片就换成那个样式";
    hint.font = [UIFont systemFontOfSize:15];
    hint.textColor = UIColor.secondaryLabelColor;
    [_sv addSubview:hint];
    y += 34;

    if (_kind == 1) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(m, y, W - m * 2, 48)];
        row.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        row.layer.cornerRadius = 12;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, W - 120, 48)];
        l.text = @"使用悬浮底栏(关闭=微信原版)";
        l.font = [UIFont systemFontOfSize:15];
        [row addSubview:l];
        UISwitch *sw = [UISwitch new];
        sw.on = [WGD() boolForKey:@"botOn"];
        sw.center = CGPointMake(row.bounds.size.width - 14 - sw.bounds.size.width / 2, 24);
        [sw addTarget:self action:@selector(botSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];
        [_sv addSubview:row];
        y += 62;
    }

    NSArray *names = _kind == 0 ? WGTopNames() : WGBotNames();
    NSInteger cur = [WGD() integerForKey:[self key]];
    for (NSUInteger i = 0; i < names.count; i++) {
        CGFloat x = m + (i % 2) * (cw + gap), cy = y + (i / 2) * (ph + 54);
        UIControl *card = [[UIControl alloc] initWithFrame:CGRectMake(x, cy, cw, ph)];
        card.tag = (NSInteger)i;
        card.layer.cornerRadius = 22;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        card.layer.borderColor = WGGreen().CGColor;
        UIView *pv = WGMakePreview(_kind, (NSInteger)i, CGSizeMake(cw, ph));
        pv.userInteractionEnabled = NO;
        [card addSubview:pv];
        [card addTarget:self action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_sv addSubview:card];
        [_cards addObject:card];

        UIImageView *rd = [[UIImageView alloc] initWithFrame:CGRectMake(x + 6, cy + ph + 10, 26, 26)];
        rd.contentMode = UIViewContentModeScaleAspectFit;
        [_sv addSubview:rd];
        [_radios addObject:rd];
        UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(x + 40, cy + ph + 8, cw - 44, 30)];
        nm.text = names[i];
        nm.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        [_sv addSubview:nm];
    }
    y += ((names.count + 1) / 2) * (ph + 54);

    UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(m + 4, y + 4, W - m * 2 - 8, 10)];
    note.numberOfLines = 0;
    note.font = [UIFont systemFontOfSize:13];
    note.textColor = UIColor.secondaryLabelColor;
    note.text = _kind == 0
        ? @"右上角的三横杠 / 「···」会打开对方的个人资料(群聊时打开聊天详情)。\n顶栏背景默认透明;名称可以在设置面板的「聊天顶栏文字」里修改。\n材质(液态玻璃 / 毛玻璃 / 叠加)在设置面板的「玻璃材质」里选。"
        : @"点底栏图标或在底栏上滑动都可以切换页面。\n「双层分组」上方的分组标签目前只是外观,不会过滤会话。\n材质(液态玻璃 / 毛玻璃 / 叠加)在设置面板的「玻璃材质」里选。";
    [note sizeToFit];
    CGRect nf = note.frame; nf.size.width = W - m * 2 - 8; note.frame = nf;
    CGSize ns = [note sizeThatFits:CGSizeMake(W - m * 2 - 8, CGFLOAT_MAX)];
    note.frame = CGRectMake(m + 4, y + 4, W - m * 2 - 8, ns.height);
    [_sv addSubview:note];
    _sv.contentSize = CGSizeMake(W, y + ns.height + 60);
    [self refreshSel];
    (void)cur;
}

- (void)refreshSel {
    NSInteger cur = [WGD() integerForKey:[self key]];
    for (NSUInteger i = 0; i < _cards.count; i++) {
        BOOL on = (NSInteger)i == cur;
        _cards[i].layer.borderWidth = on ? 3 : 0;
        UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
        _radios[i].image = [UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle" withConfiguration:c];
        _radios[i].tintColor = on ? WGGreen() : UIColor.tertiaryLabelColor;
    }
}

- (void)cardTapped:(UIControl *)c {
    [WGD() setInteger:c.tag forKey:[self key]];
    [self refreshSel];
    WGRefreshAll();
}

- (void)botSwitch:(UISwitch *)s {
    [WGD() setBool:s.on forKey:@"botOn"];
    WGRefreshAll();
}
@end

#pragma mark - 设置面板

@interface WGPanelVC : UITableViewController <UITextFieldDelegate>
@end

@implementation WGPanelVC {
    NSArray<NSDictionary *> *_secs;
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"WCGlass";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _secs = @[
        @{@"h": @"与 LiquidUI 等插件共存", @"f": @"原则:同一项功能只让一个插件负责,其余不冲突的功能可以一起用。例如 WCGlass 负责「聊天顶栏」和「首页底栏」时,到 LiquidUI 里把它的「聊天顶栏」「首页底栏」关掉或选原版。LiquidUI 的液态外观、磨砂化、页面渐隐、动效、个性化、首页顶栏、会话分组和 WCGlass 不重叠,可以继续用。", @"rows": @[
            @{@"t": @"检测状态", @"y": @"st"},
            @{@"t": @"手动标记:我在用 LiquidUI", @"k": @"liquidManual", @"y": @"sw"}]},
        @{@"h": @"由 WCGlass 负责的功能", @"f": @"关掉的功能 WCGlass 完全不碰(不改视图、不遮盖),交给别的插件。", @"rows": @[
            @{@"t": @"聊天顶栏", @"k": @"topOn", @"y": @"sw"},
            @{@"t": @"首页底栏", @"k": @"botOn", @"y": @"sw"},
            @{@"t": @"输入框玻璃", @"k": @"glassInput", @"y": @"sw"},
            @{@"t": @"侧滑侧边栏", @"k": @"drawer", @"y": @"sw"}]},
        @{@"h": @"一键分工", @"f": @"选一个预设,上面「由 WCGlass 负责的功能」的开关会自动对应。没负责的功能请在 LiquidUI 里自己开启。", @"rows": @[
            @{@"t": @"全部由 WCGlass 负责", @"y": @"p0"},
            @{@"t": @"侧边栏 + 顶栏 + 输入框一起用(底栏交给 LiquidUI)", @"y": @"p2"},
            @{@"t": @"只做底栏 + 侧边栏(顶栏、输入框交给 LiquidUI)", @"y": @"p1"},
            @{@"t": @"只做顶栏 + 输入框(底栏、侧边栏不用)", @"y": @"p4"},
            @{@"t": @"WCGlass 全部暂停(全交给 LiquidUI)", @"y": @"p3"}]},
        @{@"h": @"样式", @"rows": @[
            @{@"t": @"聊天顶栏样式", @"y": @"nt"},
            @{@"t": @"首页底栏样式", @"y": @"nb"}]},
        @{@"h": @"聊天顶栏文字", @"f": @"主名称留空=显示聊天对象名。第二文字:Pins 胶囊里是右侧分段(默认「详情」),标题胶囊 / 仿TIM / 名签竖线里是副标题(留空不显示)。", @"rows": @[
            @{@"t": @"主名称", @"k": @"segLeft", @"y": @"tx", @"p": @"留空=聊天对象名"},
            @{@"t": @"第二文字", @"k": @"segRight", @"y": @"tx", @"p": @"留空=默认"}]},
        @{@"h": @"顶栏底板", @"f": @"顶栏默认透明底;如果原来的顶栏还透出来,打开「顶栏显示底板」。", @"rows": @[
            @{@"t": @"顶栏显示底板", @"k": @"topCover", @"y": @"sw"}]},
        @{@"h": @"玻璃材质", @"f": @"液态玻璃需要 iOS 26,系统不支持时自动用毛玻璃。「叠加」是毛玻璃上再叠一层液态玻璃。白度只对毛玻璃和叠加生效。", @"rows": @[
            @{@"t": @"材质", @"k": @"glassMode", @"y": @"sg", @"o": @[@"液态", @"毛玻璃", @"叠加"]},
            @{@"t": @"白度", @"k": @"tint", @"y": @"sl"}]},
        @{@"h": @"通用", @"rows": @[
            @{@"t": @"语言(侧边栏/底栏)", @"k": @"lang", @"y": @"sg", @"o": @[@"中文", @"English"]},
            @{@"t": @"主题", @"k": @"theme", @"y": @"sg", @"o": @[@"系统", @"浅色", @"深色"]}]},
        @{@"h": @"工具", @"rows": @[
            @{@"t": @"立即打开侧边栏(测试)", @"y": @"b3"},
            @{@"t": @"立即诊断(复制到剪贴板)", @"y": @"b0"},
            @{@"t": @"8秒后诊断(切到聊天页用)", @"y": @"b1"},
            @{@"t": @"恢复默认设置", @"y": @"b2"}]}];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _secs.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return [_secs[s][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return _secs[s][@"h"]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s { return _secs[s][@"f"]; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *d = _secs[ip.section][@"rows"][ip.row];
    NSString *y = d[@"y"], *k = d[@"k"];
    BOOL nav = [y isEqualToString:@"nt"] || [y isEqualToString:@"nb"];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:nav ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault reuseIdentifier:nil];
    c.textLabel.text = d[@"t"];
    c.textLabel.numberOfLines = 2;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (nav) {
        BOOL top = [y isEqualToString:@"nt"];
        NSArray *names = top ? WGTopNames() : WGBotNames();
        NSInteger i = [WGD() integerForKey:top ? @"topStyle" : @"botStyle"];
        c.detailTextLabel.text = (i >= 0 && i < (NSInteger)names.count) ? names[i] : @"";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if ([y isEqualToString:@"st"]) {
        NSString *o = WGOtherTweaks();
        c.textLabel.text = o.length ? [NSString stringWithFormat:@"已检测到:%@", o] : @"没检测到 LiquidUI 等插件(如已安装,请手动标记)";
        c.textLabel.font = [UIFont systemFontOfSize:14];
        c.textLabel.textColor = o.length ? WGGreen() : UIColor.secondaryLabelColor;
    } else if ([y isEqualToString:@"sw"]) {
        UISwitch *sw = [UISwitch new];
        sw.on = [WGD() boolForKey:k];
        sw.accessibilityIdentifier = k;
        [sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else if ([y isEqualToString:@"sg"]) {
        NSArray *o = d[@"o"];
        UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:o];
        sc.frame = CGRectMake(0, 0, MAX(130, o.count * 62), 30);
        sc.selectedSegmentIndex = [WGD() integerForKey:k];
        sc.accessibilityIdentifier = k;
        [sc addTarget:self action:@selector(sgChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sc;
    } else if ([y isEqualToString:@"sl"]) {
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
        sl.minimumValue = 0; sl.maximumValue = 0.8;
        sl.value = [WGD() floatForKey:k];
        sl.continuous = NO;
        sl.accessibilityIdentifier = k;
        [sl addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sl;
    } else if ([y isEqualToString:@"tx"]) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 170, 34)];
        tf.placeholder = d[@"p"];
        tf.text = [WGD() stringForKey:k];
        tf.textAlignment = NSTextAlignmentRight;
        tf.returnKeyType = UIReturnKeyDone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.delegate = self;
        tf.accessibilityIdentifier = k;
        [tf addTarget:self action:@selector(txDone:) forControlEvents:UIControlEventEditingDidEnd];
        c.accessoryView = tf;
    } else {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.textLabel.textColor = [y isEqualToString:@"b2"] ? UIColor.systemRedColor : UIColor.labelColor;
    }
    return c;
}

- (void)swChanged:(UISwitch *)s { [WGD() setBool:s.on forKey:s.accessibilityIdentifier]; WGRefreshAll(); }
- (void)sgChanged:(UISegmentedControl *)s {
    [WGD() setInteger:s.selectedSegmentIndex forKey:s.accessibilityIdentifier];
    if ([s.accessibilityIdentifier isEqualToString:@"theme"]) WGWindow().overrideUserInterfaceStyle = (UIUserInterfaceStyle)s.selectedSegmentIndex;
    WGRefreshAll();
}
- (void)slChanged:(UISlider *)s { [WGD() setFloat:s.value forKey:s.accessibilityIdentifier]; WGRefreshAll(); }
- (void)txDone:(UITextField *)t { [WGD() setObject:(t.text ?: @"") forKey:t.accessibilityIdentifier]; }
- (BOOL)textFieldShouldReturn:(UITextField *)t { [t resignFirstResponder]; return YES; }

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSString *y = _secs[ip.section][@"rows"][ip.row][@"y"];
    if ([y isEqualToString:@"nt"]) {
        [self.navigationController pushViewController:[[WGStylePickerVC alloc] initWithKind:0] animated:YES];
    } else if ([y isEqualToString:@"nb"]) {
        [self.navigationController pushViewController:[[WGStylePickerVC alloc] initWithKind:1] animated:YES];
    } else if ([y hasPrefix:@"p"] && y.length == 2) {
        // 顺序: 聊天顶栏, 首页底栏, 输入框, 侧边栏
        static const BOOL presets[5][4] = {{1, 1, 1, 1}, {0, 1, 0, 1}, {1, 0, 1, 1}, {0, 0, 0, 0}, {1, 0, 1, 0}};
        int idx = [[y substringFromIndex:1] intValue];
        NSArray *keys = @[@"topOn", @"botOn", @"glassInput", @"drawer"];
        for (int i = 0; i < 4; i++) [WGD() setBool:presets[idx][i] forKey:keys[i]];
        [t reloadData];
        WGRefreshAll();
    } else if ([y isEqualToString:@"b3"]) {
        gEdgeWhy = nil;
        [WGHelper.shared openDrawer];
        if (![gOverlay.rootViewController.view viewWithTag:TAG_DRAWER]) {
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"没能打开侧边栏"
                message:gEdgeWhy ?: @"未知原因(请再点一次「立即诊断」截图发我)" preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
        }
    } else if ([y isEqualToString:@"b0"]) {
        WGShowDiag();
    } else if ([y isEqualToString:@"b1"]) {
        [t cellForRowAtIndexPath:ip].textLabel.text = @"计时中…请在8秒内切到目标页面";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ WGShowDiag(); });
    } else if ([y isEqualToString:@"b2"]) {
        for (NSString *k in @[@"topStyle", @"topOn", @"liquidManual", @"botStyle", @"botOn", @"glassInput", @"drawer", @"theme", @"lang", @"glassMode", @"tint", @"topCover", @"segLeft", @"segRight", @"chipSel"])
            [WGD() removeObjectForKey:k];
        [t reloadData];
        WGRefreshAll();
    }
}
@end

// 不依赖钩子:直接从窗口里找微信的主 TabBar 控制器
static UIViewController *WGFindTabController(void) {
    UIViewController *root = WGWindow().rootViewController;
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    if (root) [queue addObject:root];
    for (NSUInteger i = 0; i < queue.count && i < 40; i++) {
        UIViewController *v = queue[i];
        NSString *n = NSStringFromClass(v.class);
        if (![v isKindOfClass:UINavigationController.class] && [n containsString:@"TabBarController"]) return v;
        if (![v isKindOfClass:UINavigationController.class] && [n containsString:@"TabBarViewController"]) return v;
        if (v.presentedViewController) [queue addObject:v.presentedViewController];
        [queue addObjectsFromArray:v.childViewControllers];
    }
    return nil;
}

// 当前是不是停在首页(没有二级页面被推入)。用于判断要不要响应侧边栏手势
static BOOL WGHomeVisible(void) {
    if (!gTab) gTab = WGFindTabController();
    UIViewController *tc = gTab;
    if (!tc.isViewLoaded || !tc.view.window) return NO;
    UIView *bar = gTabBar;
    if (bar && bar.hidden) return NO;
    NSInteger idx = WGCurrentIndex(tc, bar ? WGItemsOf(bar) : @[]);
    NSArray<UIViewController *> *kids = tc.childViewControllers;
    if (idx >= 0 && idx < (NSInteger)kids.count && [kids[idx] isKindOfClass:UINavigationController.class])
        return ((UINavigationController *)kids[idx]).viewControllers.count <= 1;
    for (UIViewController *c in kids) {
        if ([c isKindOfClass:UINavigationController.class] && c.isViewLoaded && c.view.window && !c.view.hidden && c.view.alpha > 0.01
            && ((UINavigationController *)c).viewControllers.count > 1) return NO;
    }
    return YES;
}

// 侧边栏放在自己的窗口里,层级高于其他插件加的视图
static UIView *WGDrawerHost(void) {
    if (!gOverlay) {
        UIWindowScene *sc = WGWindow().windowScene;
        if (!sc) for (UIScene *x in UIApplication.sharedApplication.connectedScenes)
            if ([x isKindOfClass:UIWindowScene.class]) { sc = (UIWindowScene *)x; break; }
        gOverlay = sc ? [[UIWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gOverlay.windowLevel = UIWindowLevelAlert + 100;
        gOverlay.backgroundColor = UIColor.clearColor;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        gOverlay.rootViewController = vc;
    }
    gOverlay.hidden = NO;
    gOverlay.rootViewController.view.frame = gOverlay.bounds;
    return gOverlay.rootViewController.view;
}

#pragma mark - Helper(侧边栏 / 按钮事件)


@implementation WGHelper
+ (instancetype)shared { static WGHelper *h; static dispatch_once_t t; dispatch_once(&t, ^{ h = [WGHelper new]; }); return h; }

- (void)openPanel {
    [self closeDrawer];
    [WGNav() pushViewController:[WGPanelVC new] animated:YES];
}

- (void)plusTapped {
    // 复用微信首页右上角 "+" 按钮的 action
    UINavigationController *nav = WGNav();
    UIViewController *vc = nav.viewControllers.firstObject;
    UIBarButtonItem *b = vc.navigationItem.rightBarButtonItem ?: vc.navigationItem.rightBarButtonItems.lastObject;
    if (b && b.target && b.action) {
        ((void(*)(id, SEL, id))objc_msgSend)(b.target, b.action, b);
    }
}

- (void)handleEdge:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateChanged) return;
    if ([g translationInView:g.view].x <= 40) return;
    gCntEdge++;
    if ([gOverlay.rootViewController.view viewWithTag:TAG_DRAWER]) return;
    if (![WGD() boolForKey:@"drawer"]) { gEdgeWhy = @"侧边栏开关是关的"; return; }
    if (!WGHomeVisible()) { gEdgeWhy = @"当前不在首页"; return; }
    gEdgeWhy = @"已打开";
    [self openDrawer];
}
- (void)edgePan:(UIScreenEdgePanGestureRecognizer *)g { [self handleEdge:g]; }
- (void)edgePan2:(UIPanGestureRecognizer *)g { [self handleEdge:g]; }

// 窗口级手势:只接收从屏幕最左边缘开始的触摸,和别的插件的手势同时识别,互不抢占
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if (![g isKindOfClass:UIScreenEdgePanGestureRecognizer.class] && [g isKindOfClass:UIPanGestureRecognizer.class])
        return [WGD() boolForKey:@"drawer"] && [t locationInView:g.view].x < 28;
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (![g isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:g.view];
    return v.x > 0 && fabs(v.x) >= fabs(v.y) * 0.8;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }

- (void)openDrawer { [self openDrawerAnimated:YES]; }

- (UIControl *)rowIn:(UIView *)c y:(CGFloat)y w:(CGFloat)w icon:(NSString *)sym title:(NSString *)title tag:(NSInteger)tag {
    UIControl *r = [[UIControl alloc] initWithFrame:CGRectMake(0, y, w, 48)];
    r.tag = tag;
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular]]];
    iv.tintColor = UIColor.labelColor;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.frame = CGRectMake(24, 10, 26, 28);
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(62, 0, w - 80, 48)];
    l.text = title;
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [r addSubview:iv]; [r addSubview:l];
    [r addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:r];
    return r;
}

- (void)openDrawerAnimated:(BOOL)anim {
    if (!gTab) gTab = WGFindTabController();
    UIView *host = WGDrawerHost();
    if ([host viewWithTag:TAG_DRAWER]) { gEdgeWhy = @"侧边栏已经在显示"; return; }
    UIWindow *mw = gTab.view.window ?: WGWindow();
    CGFloat W = host.bounds.size.width, H = host.bounds.size.height, dw = floor(W * 0.77);
    CGFloat top = mw.safeAreaInsets.top, bottom = mw.safeAreaInsets.bottom;
    if (top < 1) top = 47;

    UIView *dim = [[UIView alloc] initWithFrame:host.bounds];
    dim.tag = TAG_DIM;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeDrawer)]];
    [host addSubview:dim];

    UIView *dr = [[UIView alloc] initWithFrame:CGRectMake(-dw, 0, dw, H)];
    dr.tag = TAG_DRAWER;
    dr.backgroundColor = UIColor.systemBackgroundColor;
    dr.layer.shadowColor = UIColor.blackColor.CGColor;
    dr.layer.shadowOpacity = 0.18;
    dr.layer.shadowRadius = 16;
    [dr addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drawerPan:)]];
    [host addSubview:dr];

    // 头像 + 昵称 + 机型/系统
    UIImageView *av = [[UIImageView alloc] initWithFrame:CGRectMake(16, top + 14, 66, 66)];
    av.backgroundColor = UIColor.tertiarySystemFillColor;
    av.contentMode = UIViewContentModeScaleAspectFill;
    av.layer.cornerRadius = 3;
    av.layer.shadowColor = UIColor.blackColor.CGColor;
    av.layer.shadowOpacity = 0.25; av.layer.shadowRadius = 5; av.layer.shadowOffset = CGSizeMake(0, 2);
    [dr addSubview:av];
    UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(96, top + 22, dw - 96 - 64, 28)];
    nm.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    nm.text = @"微信";
    [dr addSubview:nm];
    struct utsname u; uname(&u);
    UILabel *info = [[UILabel alloc] initWithFrame:CGRectMake(96, top + 52, dw - 96 - 50, 20)];
    info.font = [UIFont systemFontOfSize:11.5];
    info.textColor = UIColor.secondaryLabelColor;
    info.text = [NSString stringWithFormat:@"%s · iOS %@", u.machine, UIDevice.currentDevice.systemVersion];
    [dr addSubview:info];
    @try {
        id center = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("MMServiceCenter"), NSSelectorFromString(@"defaultCenter"));
        id mgr = ((id(*)(id, SEL, Class))objc_msgSend)(center, NSSelectorFromString(@"getService:"), objc_getClass("CContactMgr"));
        id me = ((id(*)(id, SEL))objc_msgSend)(mgr, NSSelectorFromString(@"getSelfContact"));
        NSString *nick = [me valueForKey:@"m_nsNickName"];
        NSString *head = [me valueForKey:@"m_nsHeadImgUrl"];
        if (nick.length) nm.text = nick;
        if (head.length) {
            [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:head] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                UIImage *img = d ? [UIImage imageWithData:d] : nil;
                if (img) dispatch_async(dispatch_get_main_queue(), ^{ av.image = img; });
            }] resume];
        }
    } @catch (__unused NSException *e) {}

    // 中英文切换按钮(头像行右侧,和参考图的地球图标一致)
    UIButton *lang = [UIButton buttonWithType:UIButtonTypeSystem];
    lang.frame = CGRectMake(dw - 16 - 34, top + 30, 34, 34);
    lang.tintColor = UIColor.labelColor;
    [lang setImage:[UIImage systemImageNamed:@"globe" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightLight]] forState:UIControlStateNormal];
    [lang addTarget:self action:@selector(toggleLang) forControlEvents:UIControlEventTouchUpInside];
    [dr addSubview:lang];

    // 菜单
    NSArray *tabs = @[@[WGL(@"聊天", @"Chats"), @"bubble.left", @0], @[WGL(@"通讯录", @"Contacts"), @"person.2", @1],
                      @[WGL(@"发现", @"Discover"), @"safari", @2], @[WGL(@"我", @"Me"), @"person", @3]];
    CGFloat y = top + 110;
    for (NSArray *r in tabs) { [self rowIn:dr y:y w:dw icon:r[1] title:r[0] tag:[r[2] integerValue]]; y += 56; }

    CGFloat segY = H - bottom - 52;
    [self rowIn:dr y:segY - 96 w:dw icon:@"square.grid.2x2" title:WGL(@"插件入口", @"Plugins") tag:11];
    [self rowIn:dr y:segY - 48 w:dw icon:@"gearshape" title:WGL(@"设置", @"Settings") tag:10];

    // 主题切换:黑色选中胶囊
    UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:@[WGL(@"跟随系统", @"System"), WGL(@"浅色", @"Light"), WGL(@"深色", @"Dark")]];
    sc.frame = CGRectMake(18, segY, dw - 36, 38);
    sc.selectedSegmentIndex = [WGD() integerForKey:@"theme"];
    sc.selectedSegmentTintColor = UIColor.labelColor;
    sc.backgroundColor = UIColor.tertiarySystemFillColor;
    sc.layer.cornerRadius = 19;
    sc.clipsToBounds = YES;
    [sc setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.systemBackgroundColor, NSFontAttributeName: [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium]} forState:UIControlStateSelected];
    [sc setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.labelColor, NSFontAttributeName: [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    [sc addTarget:self action:@selector(themeChanged:) forControlEvents:UIControlEventValueChanged];
    [dr addSubview:sc];

    void (^show)(void) = ^{
        dr.frame = CGRectMake(0, 0, dw, H);
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    };
    if (anim) [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:show completion:nil];
    else show();
}

- (void)toggleLang {
    [WGD() setInteger:([WGD() integerForKey:@"lang"] == 1 ? 0 : 1) forKey:@"lang"];
    UIView *host = gOverlay.rootViewController.view;
    [[host viewWithTag:TAG_DRAWER] removeFromSuperview];
    [[host viewWithTag:TAG_DIM] removeFromSuperview];
    [(WGTabView *)[gTab.view viewWithTag:TAG_GLASS_TAB] refreshTitles];
    [self openDrawerAnimated:NO];
}

- (void)closeDrawer {
    UIView *host = gOverlay.rootViewController.view;
    UIView *dr = [host viewWithTag:TAG_DRAWER], *dim = [host viewWithTag:TAG_DIM];
    if (!dr) return;
    [UIView animateWithDuration:0.24 animations:^{
        dr.frame = CGRectMake(-dr.bounds.size.width, 0, dr.bounds.size.width, dr.bounds.size.height);
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0];
    } completion:^(BOOL f) { [dr removeFromSuperview]; [dim removeFromSuperview]; gOverlay.hidden = YES; }];
}

- (void)drawerPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded && [g translationInView:g.view].x < -40) [self closeDrawer];
}

- (void)rowTapped:(UIControl *)b {
    NSInteger t = b.tag;
    if (t <= 3) { WGSelectIndex(gTab, t, WGItemsOf(gTabBar)); [(WGTabView *)[gTab.view viewWithTag:TAG_GLASS_TAB] setSelected:t animated:YES]; [self closeDrawer]; }
    else if (t == 10) {
        [self closeDrawer];
        @try {
            UIViewController *s = [[NSClassFromString(@"NewSettingViewController") alloc] init];
            if (s) [WGNav() pushViewController:s animated:YES];
        } @catch (__unused NSException *e) {}
    } else if (t == 11) [self openPanel];
}

- (void)themeChanged:(UISegmentedControl *)s {
    [WGD() setInteger:s.selectedSegmentIndex forKey:@"theme"];
    WGWindow().overrideUserInterfaceStyle = (UIUserInterfaceStyle)s.selectedSegmentIndex; // 0 系统 / 1 浅 / 2 深
}
@end

#pragma mark - 聊天页:顶栏毛玻璃 + 输入框玻璃

static UIView *WGFindInputBar(UIView *root) {
    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;
    NSArray *keys = @[@"InputToolView", @"ChatToolView", @"InputToolBar", @"InputBar", @"InputView"];
    return WGFind(root, ^BOOL(UIView *v) {
        NSString *n = NSStringFromClass(v.class);
        if ([n hasPrefix:@"UI"] || [n hasPrefix:@"_UI"]) return NO;
        BOOL hit = NO;
        for (NSString *k in keys) if ([n containsString:k]) { hit = YES; break; }
        if (!hit) return NO;
        CGRect f = [root convertRect:v.bounds fromView:v];
        return f.size.width > W * 0.8 && f.size.height >= 40 && f.size.height < 220 && CGRectGetMaxY(f) > H - 280;
    });
}

static void WGCleanupChatTop(UIViewController *vc) {
    UIView *tb = gTopBar;
    if (!tb) return;
    [tb removeFromSuperview];
    gTopBar = nil;
    UINavigationBar *nb = vc.navigationController.navigationBar;
    nb.alpha = 1;
    for (UIView *sv in nb.subviews) sv.alpha = 1;
}

static void WGTriggerRight(UIViewController *vc) {
    UINavigationBar *nb = vc.navigationController.navigationBar;
    UIBarButtonItem *b = vc.navigationItem.rightBarButtonItem ?: vc.navigationItem.rightBarButtonItems.lastObject;
    if (b.target && b.action) { ((void(*)(id, SEL, id))objc_msgSend)(b.target, b.action, b); return; }
    if ([b.customView isKindOfClass:UIControl.class]) { [(UIControl *)b.customView sendActionsForControlEvents:UIControlEventTouchUpInside]; return; }
    __block UIControl *best = nil;
    __block CGFloat bestX = -1;
    WGFind(nb, ^BOOL(UIView *v) {
        if ([v isKindOfClass:UIControl.class]) {
            CGRect f = [nb convertRect:v.bounds fromView:v];
            if (f.origin.x > nb.bounds.size.width * 0.6 && f.origin.x > bestX) { best = (UIControl *)v; bestX = f.origin.x; }
        }
        return NO;
    });
    [best sendActionsForControlEvents:UIControlEventTouchUpInside];
}

static id WGContactOf(UIViewController *vc) {
    id contact = nil;
    for (NSString *k in @[@"m_contact", @"m_oContact", @"contact"]) {
        @try { contact = [vc valueForKey:k]; } @catch (__unused NSException *e) {}
        if (contact) return contact;
    }
    for (NSString *n in @[@"GetContact", @"getContact"]) {
        SEL sel = NSSelectorFromString(n);
        if ([vc respondsToSelector:sel]) { contact = ((id(*)(id, SEL))objc_msgSend)(vc, sel); if (contact) return contact; }
    }
    NSString *un = nil;
    for (NSString *k in @[@"m_nsUsrName", @"m_chatName", @"m_nsChatName", @"chatName"]) {
        @try { id v = [vc valueForKey:k]; if ([v isKindOfClass:NSString.class] && [v length]) { un = v; break; } } @catch (__unused NSException *e) {}
    }
    if (un.length) {
        @try {
            id center = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("MMServiceCenter"), NSSelectorFromString(@"defaultCenter"));
            id mgr = ((id(*)(id, SEL, Class))objc_msgSend)(center, NSSelectorFromString(@"getService:"), objc_getClass("CContactMgr"));
            contact = ((id(*)(id, SEL, id))objc_msgSend)(mgr, NSSelectorFromString(@"getContactByName:"), un);
        } @catch (__unused NSException *e) {}
    }
    return contact;
}

static void WGLoadAvatar(UIViewController *vc, WGTopBar *tb) {
    id contact = WGContactOf(vc);
    NSString *url = nil;
    @try { url = [contact valueForKey:@"m_nsHeadImgUrl"]; } @catch (__unused NSException *e) {}
    if (![url isKindOfClass:NSString.class] || !url.length) return;
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    __weak WGTopBar *w = tb;
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        UIImage *img = d ? [UIImage imageWithData:d] : nil;
        if (img) dispatch_async(dispatch_get_main_queue(), ^{ w.avatar = img; });
    }] resume];
}

static void WGOpenProfile(UIViewController *vc) {
    id contact = WGContactOf(vc);
    NSString *uname = nil;
    @try { uname = [contact valueForKey:@"m_nsUsrName"]; } @catch (__unused NSException *e) {}
    BOOL isRoom = [uname hasSuffix:@"@chatroom"];
    Class ic = NSClassFromString(@"ContactInfoViewController");
    if (contact && !isRoom && ic) {
        @try {
            id info = [[ic alloc] init];
            SEL set = NSSelectorFromString(@"setM_contact:");
            if ([info respondsToSelector:set]) ((void(*)(id, SEL, id))objc_msgSend)(info, set, contact);
            else [info setValue:contact forKey:@"m_contact"];
            [vc.navigationController pushViewController:info animated:YES];
            return;
        } @catch (__unused NSException *e) {}
    }
    WGTriggerRight(vc);   // 群聊或拿不到联系人时,退回原来的右上角按钮(聊天详情)
}

static void WGApplyChat(UIViewController *vc) {
    if (!vc.isViewLoaded) return;
    UIView *root = vc.view;

    // ---- 顶栏(挂在 window 最上层,不受微信导航栏层级影响) ----
    NSInteger ts = [WGD() integerForKey:@"topStyle"];
    UINavigationBar *nb = vc.navigationController.navigationBar;
    UIWindow *win = vc.view.window;
    BOOL wantTop = ts > 0 && [WGD() boolForKey:@"topOn"];
    BOOL onTop = vc.navigationController.topViewController == vc;
    gTopInfo = [NSString stringWithFormat:@"顶栏: style=%ld nb=%@ win=%d onTop=%d", (long)ts, nb ? NSStringFromClass(nb.class) : @"nil", win != nil, onTop];
    if (wantTop && nb && win && onTop && !nb.hidden) {
        NSString *title = vc.navigationItem.title ?: vc.title;
        if (!title.length) {
            // 取导航栏里最靠中间的文字(避免取到左侧返回按钮上的文字)
            __block UILabel *best = nil;
            __block CGFloat bd = 1e9;
            WGFind(nb, ^BOOL(UIView *v) {
                if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length > 0) {
                    CGRect f = [nb convertRect:v.bounds fromView:v];
                    CGFloat d = fabs(CGRectGetMidX(f) - nb.bounds.size.width / 2);
                    if (d < bd) { bd = d; best = (UILabel *)v; }
                }
                return NO;
            });
            title = best.text;
        }
        NSString *unread = nil;
        if (ts == 3) {   // 仿 TIM:返回键旁显示未读数(取原导航栏左侧的数字)
            __block NSString *cnt = nil;
            WGFind(nb, ^BOOL(UIView *v) {
                if ([v isKindOfClass:UILabel.class]) {
                    NSString *t = ((UILabel *)v).text;
                    if (t.length > 0 && t.length <= 5 && [nb convertRect:v.bounds fromView:v].origin.x < nb.bounds.size.width * 0.4) {
                        NSString *d = [[t componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet] componentsJoinedByString:@""];
                        if (d.length > 0) cnt = d;
                    }
                }
                return NO;
            });
            unread = cnt;
        }
        WGTopBar *tb = (WGTopBar *)gTopBar;
        if (!tb) {
            tb = [WGTopBar new];
            __weak UIViewController *wvc = vc;
            tb.onBack = ^{ [wvc.navigationController popViewControllerAnimated:YES]; };
            tb.onInfo = ^{ WGTriggerRight(wvc); };
            tb.onMenu = ^{ WGOpenProfile(wvc); };
            gTopBar = tb;
            WGLoadAvatar(vc, tb);
        }
        if (tb.superview != win) [win addSubview:tb];
        tb.customLeft = [WGD() stringForKey:@"segLeft"];
        tb.customRight = [WGD() stringForKey:@"segRight"];
        tb.backText = unread;
        if (title.length) tb.title = title;
        tb.style = ts;
        if ([WGD() boolForKey:@"topCover"]) {
            UIColor *bg = vc.view.backgroundColor;
            if (!bg || CGColorGetAlpha(bg.CGColor) < 0.5) bg = UIColor.systemBackgroundColor;
            tb.coverColor = bg;
        } else {
            tb.coverColor = nil;   // 透明底
        }
        tb.frame = [win convertRect:nb.bounds fromView:nb];
        [win bringSubviewToFront:tb];
        nb.backgroundColor = UIColor.clearColor;
        nb.alpha = 0;
        for (UIView *sv in nb.subviews) sv.alpha = 0;
        gTopInfo = [gTopInfo stringByAppendingFormat:@" tb=%@", NSStringFromCGRect(tb.frame)];
    } else {
        WGCleanupChatTop(vc);
    }

    // ---- 输入框玻璃 ----
    UIView *bar = WGFindInputBar(root);
    if (!bar) return;
    UIView *pill = [bar viewWithTag:TAG_GLASS_INPUT];
    if (![WGD() boolForKey:@"glassInput"]) { [pill removeFromSuperview]; return; }

    if (!pill) {
        pill = WGBlur(20, NO);
        pill.tag = TAG_GLASS_INPUT;
        pill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [bar insertSubview:pill atIndex:0];
    }
    CGRect b = CGRectInset(bar.bounds, 10, 6);
    pill.frame = b;
    pill.layer.cornerRadius = b.size.height / 2;
    bar.backgroundColor = UIColor.clearColor;
    // 去掉微信自带的整条背景(容器上的全宽毛玻璃 / 背景图 / 分割线)
    for (UIView *host in @[bar, bar.superview ?: bar]) {
        for (UIView *sv in host.subviews) {
            if (sv == pill || sv == bar) continue;
            BOOL wide = sv.bounds.size.width >= root.bounds.size.width * 0.9;
            BOOL plain = sv.subviews.count == 0 && ![sv isKindOfClass:UIControl.class] && ![sv isKindOfClass:UILabel.class];
            if (wide && (plain || [sv isKindOfClass:UIVisualEffectView.class])) sv.alpha = 0;
        }
    }
    UIView *tv = WGFind(bar, ^BOOL(UIView *v) { return [v isKindOfClass:UITextView.class]; });
    if (tv) {
        UIView *box = tv.superview != bar ? tv.superview : tv;
        box.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.14];
        box.layer.cornerRadius = MIN(18, box.bounds.size.height / 2);
        box.clipsToBounds = YES;
        tv.backgroundColor = UIColor.clearColor;
    }
}

static IMP o_chatLayout, o_chatAppear, o_chatDisappear;
static void n_chatDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    ((void(*)(id, SEL, BOOL))o_chatDisappear)(self, _cmd, animated);
    WGCleanupChatTop(self);
}
static void n_chatLayout(UIViewController *self, SEL _cmd) {
    ((void(*)(id, SEL))o_chatLayout)(self, _cmd);
    gCntChat++;
    WGApplyChat(self);
}
static void n_chatAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    ((void(*)(id, SEL, BOOL))o_chatAppear)(self, _cmd, animated);
    WGApplyChat(self);
}

#pragma mark - 首页底栏(微信用的是自定义 WCTabBarController,不是 UITabBarController)

static UIView *WGFindTabBar(UIView *root) {
    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;
    BOOL (^ok)(UIView *) = ^BOOL(UIView *v) {
        if (v.tag >= TAG_GLASS_TOP && v.tag <= TAG_DIM) return NO;
        NSString *n = NSStringFromClass(v.class);
        if ([n hasPrefix:@"UI"] || [n hasPrefix:@"_UI"]) return NO;
        CGRect f = [root convertRect:v.bounds fromView:v];
        return f.size.width > W * 0.8 && f.size.height >= 40 && f.size.height < 170 && CGRectGetMaxY(f) > H - 130;
    };
    UIView *hit = WGFind(root, ^BOOL(UIView *v) {
        return [NSStringFromClass(v.class) localizedCaseInsensitiveContainsString:@"tabbar"] && ok(v);
    });
    if (hit) return hit;
    for (UIView *v in root.subviews) if (ok(v) && v.subviews.count >= 3) return v;
    return nil;
}

static void WGInstallWindowPan(UIWindow *hw) {
    static char kWinPan;
    if (!hw || hw == gOverlay || objc_getAssociatedObject(hw, &kWinPan)) return;
    NSString *cn = NSStringFromClass(hw.class);
    if ([cn containsString:@"Keyboard"] || [cn hasPrefix:@"UIText"] || [cn containsString:@"Remote"]) return;
    UIPanGestureRecognizer *wp = [[UIPanGestureRecognizer alloc] initWithTarget:WGHelper.shared action:@selector(edgePan2:)];
    wp.delegate = WGHelper.shared;
    wp.cancelsTouchesInView = NO;
    wp.delaysTouchesBegan = NO;
    wp.delaysTouchesEnded = NO;
    wp.maximumNumberOfTouches = 1;
    [hw addGestureRecognizer:wp];
    objc_setAssociatedObject(hw, &kWinPan, wp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WGApplyTab(UIViewController *tc) {
    gTab = tc;
    UIView *root = tc.view;

    static char kEdge;
    if (!objc_getAssociatedObject(tc, &kEdge)) {
        UIScreenEdgePanGestureRecognizer *e = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:WGHelper.shared action:@selector(edgePan:)];
        e.edges = UIRectEdgeLeft;
        e.delegate = WGHelper.shared;
        e.cancelsTouchesInView = NO;
        [root addGestureRecognizer:e];
        objc_setAssociatedObject(tc, &kEdge, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    WGInstallWindowPan(root.window);
    static dispatch_once_t themeOnce;   // 主题只在启动时应用一次,之后只在你手动切换时改,避免和其他插件互相抢
    dispatch_once(&themeOnce, ^{
        NSInteger theme = [WGD() integerForKey:@"theme"];
        if (theme != 0 && root.window) root.window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)theme;
    });

    BOOL on = [WGD() boolForKey:@"botOn"];
    NSInteger st = MAX(0, MIN(5, [WGD() integerForKey:@"botStyle"]));
    UIView *bar = gTabBar;
    if (!bar || ![bar isDescendantOfView:root]) { bar = WGFindTabBar(root); gTabBar = bar; }

    WGTabView *tv = (WGTabView *)[root viewWithTag:TAG_GLASS_TAB];
    UIButton *plus = (UIButton *)[root viewWithTag:TAG_TAB_PLUS];

    if (!on || !bar) {
        [tv removeFromSuperview]; [plus removeFromSuperview];
        if (gBarTouched && bar) { for (UIView *sv in bar.subviews) sv.alpha = 1; gBarTouched = NO; }
        return;
    }
    BOOL gone = bar.hidden || bar.alpha < 0.01 || !bar.window;
    tv.hidden = gone; plus.hidden = gone;
    if (gone) return;

    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;
    CGFloat h = [WGTabView heightForStyle:st], m = 14, plusSize = 56;
    BOOL hasPlus = (st == 1 || st == 2);
    CGFloat y = H - MAX(root.safeAreaInsets.bottom, 10) - h;
    CGFloat cw = hasPlus ? W - m * 3 - plusSize : W - m * 2;

    if (!tv) {
        tv = [WGTabView new];
        tv.tag = TAG_GLASS_TAB;
        [root addSubview:tv];
        __weak UIViewController *wtc = tc;
        tv.onSelect = ^(NSInteger i) {
            UIViewController *t = wtc;
            if (t) WGSelectIndex(t, i, WGItemsOf(gTabBar));
        };
        tv.indexProvider = ^NSInteger {
            UIViewController *t = wtc; UIView *b = gTabBar;
            if (!t || !b) return -1;
            for (UIView *sv in b.subviews) sv.alpha = 0;   // 保持原底栏隐藏
            return WGCurrentIndex(t, WGItemsOf(b));
        };
        [tv setSelected:MAX(WGCurrentIndex(tc, WGItemsOf(bar)), 0) animated:NO];
    }
    tv.style = st;
    [root bringSubviewToFront:tv];
    tv.frame = CGRectMake(m, y, cw, h);

    // 原底栏保留(用于切换/角标逻辑),只是看不见
    bar.backgroundColor = UIColor.clearColor;
    for (UIView *sv in bar.subviews) sv.alpha = 0;
    gBarTouched = YES;

    if (hasPlus) {
        if (!plus) {
            plus = [UIButton buttonWithType:UIButtonTypeSystem];
            plus.tag = TAG_TAB_PLUS;
            [plus addTarget:WGHelper.shared action:@selector(plusTapped) forControlEvents:UIControlEventTouchUpInside];
        }
        plus.backgroundColor = st == 1 ? UIColor.blackColor : WGDyn([UIColor colorWithWhite:1 alpha:0.95], [UIColor colorWithWhite:1 alpha:0.2]);
        plus.tintColor = st == 1 ? UIColor.whiteColor : UIColor.labelColor;
        [plus setImage:[UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
        if (plus.superview != root) [root addSubview:plus];
        [root bringSubviewToFront:plus];
        plus.frame = CGRectMake(W - m - plusSize, y + (h - plusSize) / 2, plusSize, plusSize);
        plus.layer.cornerRadius = plusSize / 2;
        plus.layer.shadowColor = UIColor.blackColor.CGColor;
        plus.layer.shadowOpacity = 0.2;
        plus.layer.shadowRadius = 8;
        plus.layer.shadowOffset = CGSizeMake(0, 3);
    } else {
        [plus removeFromSuperview];
    }
}

static IMP o_tabLayout;
static void n_tabLayout(UIViewController *self, SEL _cmd) {
    ((void(*)(id, SEL))o_tabLayout)(self, _cmd);
    gCntTab++;
    WGApplyTab(self);
}

#pragma mark - 微信设置页入口

static IMP o_settingReload;
static void n_settingReload(id self, SEL _cmd) {
    ((void(*)(id, SEL))o_settingReload)(self, _cmd);
    @try {
        id mgr = [self valueForKey:@"m_tableViewMgr"];
        Class SecC = NSClassFromString(@"WCTableViewSectionManager");
        Class CellC = NSClassFromString(@"WCTableViewNormalCellManager");
        id section = ((id(*)(Class, SEL))objc_msgSend)(SecC, NSSelectorFromString(@"defaultSection"));
        id cell = ((id(*)(Class, SEL, SEL, id, id, id, long long))objc_msgSend)(
            CellC, NSSelectorFromString(@"normalCellForSel:target:title:rightValue:accessoryType:"),
            NSSelectorFromString(@"wg_openPanel"), self, @"WCGlass 插件", @"", 1LL);
        ((void(*)(id, SEL, id))objc_msgSend)(section, NSSelectorFromString(@"addCell:"), cell);
        ((void(*)(id, SEL, id, long long))objc_msgSend)(mgr, NSSelectorFromString(@"insertSection:At:"), section, 0LL);
        id tv = ((id(*)(id, SEL))objc_msgSend)(mgr, NSSelectorFromString(@"getTableView"));
        [tv reloadData];
    } @catch (__unused NSException *e) {}
}
static void n_openPanel(UIViewController *self, SEL _cmd) {
    [self.navigationController pushViewController:[WGPanelVC new] animated:YES];
}

#pragma mark - 入口

__attribute__((constructor)) static void WGInit(void) {
    if (!objc_getClass("MMServiceCenter")) return; // 只在微信进程生效(不依赖 bundle id,重签名后也可用)

    // 聊天页
    for (NSString *n in @[@"BaseMsgContentViewController"]) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        o_chatLayout = WGHook(c, @selector(viewDidLayoutSubviews), (IMP)n_chatLayout);
        o_chatAppear = WGHook(c, @selector(viewWillAppear:), (IMP)n_chatAppear);
        o_chatDisappear = WGHook(c, @selector(viewWillDisappear:), (IMP)n_chatDisappear);
    }
    // 首页 TabBarController
    Class tcc = nil;
    for (NSString *n in @[@"NewMainTabBarViewController", @"WCTabBarController", @"MMTabBarController"]) {
        tcc = NSClassFromString(n);
        if (tcc) break;
    }
    if (!tcc) tcc = UITabBarController.class;
    o_tabLayout = WGHook(tcc, @selector(viewDidLayoutSubviews), (IMP)n_tabLayout);

    gHookChat = o_chatLayout != NULL;
    gHookTab = o_tabLayout != NULL;

    // 侧边栏手势不依赖底栏钩子:窗口出现时就装上
    void (^inst)(NSNotification *) = ^(NSNotification *n) {
        UIWindow *w = [n.object isKindOfClass:UIWindow.class] ? n.object : WGWindow();
        WGInstallWindowPan(w);
    };
    for (NSNotificationName nm in @[UIWindowDidBecomeVisibleNotification, UIWindowDidBecomeKeyNotification, UIApplicationDidBecomeActiveNotification])
        [[NSNotificationCenter defaultCenter] addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:inst];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ WGInstallWindowPan(WGWindow()); });

    // 微信设置页入口
    Class st = NSClassFromString(@"NewSettingViewController");
    if (st) {
        o_settingReload = WGHook(st, NSSelectorFromString(@"reloadTableData"), (IMP)n_settingReload);
        class_addMethod(st, NSSelectorFromString(@"wg_openPanel"), (IMP)n_openPanel, "v@:");
        gHookSet = o_settingReload != NULL;
    }
}
