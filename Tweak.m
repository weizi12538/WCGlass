// WCGlass - 微信毛玻璃 UI 插件
// 纯 ObjC runtime 方法替换,不依赖 CydiaSubstrate,越狱 / lcsign 注入均可用
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>

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
static UIViewController *WGVisibleVC(void);
static int gCntChat, gCntTab;
static BOOL gHookChat, gHookTab, gHookSet;
static UIView *WGFindInputBar(UIView *root);

#pragma mark - 配置

static NSUserDefaults *WGD(void) {
    static NSUserDefaults *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:WG_SUITE];
        [d registerDefaults:@{@"glassTop": @YES, @"glassInput": @YES,
                              @"tabStyle": @1, @"drawer": @YES, @"theme": @0, @"lang": @0}];
    });
    return d;
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

static UIVisualEffectView *WGBlur(CGFloat radius, BOOL glass) {
    UIVisualEffect *eff = nil;
    Class g = NSClassFromString(@"UIGlassEffect"); // iOS 26 液态玻璃
    if (glass && g) eff = [[g alloc] init];
    if (!eff) eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:eff];
    v.contentView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.06]
                                                                : [UIColor colorWithWhite:1 alpha:0.38];
    }];
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    if (radius > 0) { v.layer.borderWidth = 0.6; v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor; }
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

// ---- 底栏:选中项展开成带文字的胶囊,切换时弹性滑动 ----
@interface WGTabView : UIView
@property (nonatomic) NSInteger selected;
@property (nonatomic, copy) void (^onSelect)(NSInteger);
@property (nonatomic, copy) NSInteger (^indexProvider)(void);
- (void)setSelected:(NSInteger)i animated:(BOOL)a;
- (void)refreshTitles;
@end

@implementation WGTabView {
    UIVisualEffectView *_glass;
    UIView *_pill;
    NSMutableArray<UIImageView *> *_icons;
    NSMutableArray<UILabel *> *_labels;
    NSMutableArray<NSValue *> *_cells;
    NSTimer *_timer;
}

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _glass = WGBlur(32, NO);
    [self addSubview:_glass];
    _pill = [UIView new];
    _pill.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.16] : [UIColor colorWithWhite:0 alpha:0.09];
    }];
    [self addSubview:_pill];
    NSArray *syms = @[@"bubble.fill", @"person.2.fill", @"safari.fill", @"person.fill"];
    NSArray *fallback = @[@"message.fill", @"person.2.fill", @"safari", @"person.fill"];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    _icons = [NSMutableArray array]; _labels = [NSMutableArray array]; _cells = [NSMutableArray array];
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
    }
    [self refreshTitles];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)]];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [self addGestureRecognizer:pan];
    return self;
}

- (void)refreshTitles {
    NSArray *t = [WGD() integerForKey:@"lang"] == 1 ? @[@"Chats", @"Contacts", @"Discover", @"Me"] : @[@"微信", @"通讯录", @"发现", @"我"];
    for (int i = 0; i < 4; i++) _labels[i].text = t[i];
    [self setNeedsLayout];
}

- (void)layoutForSelected:(NSInteger)sel {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 6;
    CGFloat unit = (W - pad * 2) / (1.8 + 3), x = pad;
    [_cells removeAllObjects];
    for (NSInteger i = 0; i < 4; i++) {
        CGFloat cw = (i == sel ? 1.8 : 1.0) * unit;
        CGRect cell = CGRectMake(x, pad, cw, H - pad * 2);
        [_cells addObject:[NSValue valueWithCGRect:cell]];
        UIImageView *iv = _icons[i]; UILabel *lb = _labels[i];
        [lb sizeToFit];
        CGFloat midY = CGRectGetMidY(cell);
        if (i == sel) {
            CGFloat total = 26 + 6 + lb.bounds.size.width;
            CGFloat sx = cell.origin.x + (cw - total) / 2;
            iv.center = CGPointMake(sx + 13, midY);
            lb.frame = CGRectMake(sx + 32, midY - lb.bounds.size.height / 2, lb.bounds.size.width, lb.bounds.size.height);
            lb.alpha = 1;
            iv.tintColor = UIColor.labelColor;
            _pill.frame = cell;
            _pill.layer.cornerRadius = cell.size.height / 2;
        } else {
            iv.center = CGPointMake(CGRectGetMidX(cell), midY);
            lb.center = iv.center;
            lb.alpha = 0;
            iv.tintColor = UIColor.secondaryLabelColor;
        }
        x += cw;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _glass.frame = self.bounds;
    _glass.layer.cornerRadius = self.bounds.size.height / 2;
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

- (void)pick:(NSInteger)i {
    if (i < 0 || i == _selected) return;
    [self setSelected:i animated:YES];
    if (self.onSelect) self.onSelect(i);
}
- (void)tap:(UITapGestureRecognizer *)g { [self pick:[self indexAtX:[g locationInView:self].x]]; }
- (void)pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) [self pick:[self indexAtX:[g locationInView:self].x]];
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

// ---- 聊天顶栏:左「返回」胶囊 + 中间分段胶囊 + 右侧圆形菜单 ----
@interface WGTopBar : UIView
@property (nonatomic, copy) void (^onBack)(void);
@property (nonatomic, copy) void (^onInfo)(void);
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) UIColor *coverColor;
@end

@implementation WGTopBar {
    UIView *_cover;
    UIVisualEffectView *_l, *_c, *_r;
    UIImageView *_chev, *_menu;
    UILabel *_back, *_t1, *_t2;
    UIView *_seg;
    UIButton *_bl, *_b1, *_b2, *_br;
    NSInteger _idx;
}

- (UIButton *)btn:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _cover = [UIView new];
    [self addSubview:_cover];
    _l = WGBlur(21.5, NO); _c = WGBlur(21.5, NO); _r = WGBlur(21.5, NO);
    [self addSubview:_l]; [self addSubview:_c]; [self addSubview:_r];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold];
    _chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:cfg]];
    _chev.tintColor = UIColor.labelColor;
    _chev.contentMode = UIViewContentModeScaleAspectFit;
    [_l.contentView addSubview:_chev];
    _back = [UILabel new];
    _back.text = WGL(@"返回", @"Back");
    _back.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    _back.textColor = UIColor.labelColor;
    [_l.contentView addSubview:_back];

    _seg = [UIView new];
    _seg.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.14] : [UIColor colorWithWhite:1 alpha:0.55];
    }];
    [_c.contentView addSubview:_seg];
    _t1 = [UILabel new]; _t2 = [UILabel new];
    for (UILabel *t in @[_t1, _t2]) {
        t.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        t.textAlignment = NSTextAlignmentCenter;
        t.lineBreakMode = NSLineBreakByTruncatingTail;
        [_c.contentView addSubview:t];
    }
    _t1.text = WGL(@"聊天", @"Chat");
    _t2.text = WGL(@"详情", @"Info");

    _menu = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]]];
    _menu.tintColor = UIColor.labelColor;
    _menu.contentMode = UIViewContentModeScaleAspectFit;
    [_r.contentView addSubview:_menu];

    _bl = [self btn:@selector(tapBack)];
    _b1 = [self btn:@selector(tapChat)];
    _b2 = [self btn:@selector(tapInfo)];
    _br = [self btn:@selector(tapInfo)];
    [self updateSeg];
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _t1.text = title.length ? title : WGL(@"聊天", @"Chat");
}

- (void)setCoverColor:(UIColor *)c {
    _coverColor = c;
    _cover.backgroundColor = c;
}

- (void)updateSeg {
    _t1.textColor = _idx == 0 ? UIColor.labelColor : UIColor.secondaryLabelColor;
    _t2.textColor = _idx == 1 ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, h = 43, y = (H - h) / 2, m = 16, cw = 157;
    _cover.frame = self.bounds;
    _l.frame = CGRectMake(m, y, 78, h);
    _c.frame = CGRectMake((W - cw) / 2, y, cw, h);
    _r.frame = CGRectMake(W - m - h, y, h, h);
    for (UIView *v in @[_l, _c, _r]) v.layer.cornerRadius = h / 2;
    _chev.frame = CGRectMake(13, (h - 20) / 2, 14, 20);
    _back.frame = CGRectMake(33, 0, 42, h);
    CGFloat sw = (cw - 8) / 2;
    _seg.frame = CGRectMake(4 + _idx * sw, 4, sw, h - 8);
    _seg.layer.cornerRadius = (h - 8) / 2;
    _t1.frame = CGRectMake(8, 0, sw - 8, h);
    _t2.frame = CGRectMake(4 + sw, 0, sw, h);
    _menu.frame = CGRectMake((h - 22) / 2, (h - 22) / 2, 22, 22);
    _bl.frame = _l.frame;
    _b1.frame = CGRectMake(_c.frame.origin.x + 4, y, sw, h);
    _b2.frame = CGRectMake(_c.frame.origin.x + 4 + sw, y, sw, h);
    _br.frame = _r.frame;
}

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    return CGRectContainsPoint(_l.frame, p) || CGRectContainsPoint(_c.frame, p) || CGRectContainsPoint(_r.frame, p);
}

- (void)moveSeg:(NSInteger)i {
    _idx = i;
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3 options:0 animations:^{
        CGFloat sw = (157 - 8) / 2;
        self->_seg.frame = CGRectMake(4 + i * sw, 4, sw, 35);
        [self updateSeg];
    } completion:nil];
}
- (void)tapBack { if (self.onBack) self.onBack(); }
- (void)tapChat { [self moveSeg:0]; }
- (void)tapInfo {
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

@interface WGPanelVC : UITableViewController
@end

@implementation WGPanelVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"WCGlass"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return s == 0 ? 4 : 3; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return s == 0 ? @"外观" : @"工具"; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return s == 0 ? @"部分开关关闭后需重新进入聊天页或重启微信生效" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (ip.section == 0) {
        NSArray *titles = @[@"聊天顶栏毛玻璃", @"聊天输入框毛玻璃", @"首页底栏样式", @"首页侧滑侧边栏"];
        c.textLabel.text = titles[ip.row];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        if (ip.row == 2) {
            UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:@[@"原版", @"样式一", @"样式二"]];
            sc.frame = CGRectMake(0, 0, 190, 30);
            sc.selectedSegmentIndex = [WGD() integerForKey:@"tabStyle"];
            [sc addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sc;
        } else {
            NSString *key = ip.row == 0 ? @"glassTop" : (ip.row == 1 ? @"glassInput" : @"drawer");
            UISwitch *sw = [UISwitch new];
            sw.on = [WGD() boolForKey:key];
            sw.accessibilityIdentifier = key;
            [sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
    } else {
        NSArray *t2 = @[@"立即诊断(复制到剪贴板)", @"8秒后诊断(切到聊天页用)", @"恢复默认设置"];
        c.textLabel.text = t2[ip.row];
        c.textLabel.textColor = ip.row == 2 ? UIColor.systemRedColor : UIColor.labelColor;
    }
    return c;
}

- (void)swChanged:(UISwitch *)s { [WGD() setBool:s.on forKey:s.accessibilityIdentifier]; [gTab.view setNeedsLayout]; }
- (void)segChanged:(UISegmentedControl *)s { [WGD() setInteger:s.selectedSegmentIndex forKey:@"tabStyle"]; [gTab.view setNeedsLayout]; [gTab.view layoutIfNeeded]; }

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;
    if (ip.row == 0) {
        WGShowDiag();
    } else if (ip.row == 1) {
        [t cellForRowAtIndexPath:ip].textLabel.text = @"计时中…请在8秒内切到目标页面";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ WGShowDiag(); });
    } else {
        for (NSString *k in @[@"glassTop", @"glassInput", @"tabStyle", @"drawer", @"theme"]) [WGD() removeObjectForKey:k];
        [t reloadData];
        [gTab.view setNeedsLayout];
    }
}
@end

#pragma mark - Helper(侧边栏 / 按钮事件)

@interface WGHelper : NSObject
+ (instancetype)shared;
@end

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

- (void)edgePan:(UIScreenEdgePanGestureRecognizer *)g {
    if (![WGD() boolForKey:@"drawer"]) return;
    if (WGNav().viewControllers.count > 1) return;
    if (g.state == UIGestureRecognizerStateChanged && [g translationInView:g.view].x > 40) [self openDrawer];
}

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
    UIView *host = gTab.view;
    if (!host || [host viewWithTag:TAG_DRAWER]) return;
    CGFloat W = host.bounds.size.width, H = host.bounds.size.height, dw = floor(W * 0.77);
    CGFloat top = host.safeAreaInsets.top, bottom = host.safeAreaInsets.bottom;

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
    UIView *host = gTab.view;
    [[host viewWithTag:TAG_DRAWER] removeFromSuperview];
    [[host viewWithTag:TAG_DIM] removeFromSuperview];
    [(WGTabView *)[host viewWithTag:TAG_GLASS_TAB] refreshTitles];
    [self openDrawerAnimated:NO];
}

- (void)closeDrawer {
    UIView *host = gTab.view;
    UIView *dr = [host viewWithTag:TAG_DRAWER], *dim = [host viewWithTag:TAG_DIM];
    if (!dr) return;
    [UIView animateWithDuration:0.24 animations:^{
        dr.frame = CGRectMake(-dr.bounds.size.width, 0, dr.bounds.size.width, dr.bounds.size.height);
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0];
    } completion:^(BOOL f) { [dr removeFromSuperview]; [dim removeFromSuperview]; }];
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

static void WGApplyChat(UIViewController *vc) {
    if (!vc.isViewLoaded) return;
    UIView *root = vc.view;

    // ---- 顶栏:返回胶囊 + 分段胶囊 + 菜单圆钮(挂在 window 最上层,不受微信导航栏层级影响) ----
    UINavigationBar *nb = vc.navigationController.navigationBar;
    UIWindow *win = vc.view.window;
    BOOL wantTop = [WGD() boolForKey:@"glassTop"];
    BOOL onTop = vc.navigationController.topViewController == vc;
    gTopInfo = [NSString stringWithFormat:@"顶栏: on=%d nb=%@ win=%d onTop=%d", wantTop, nb ? NSStringFromClass(nb.class) : @"nil", win != nil, onTop];
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
        WGTopBar *tb = (WGTopBar *)gTopBar;
        if (!tb) {
            tb = [WGTopBar new];
            __weak UIViewController *wvc = vc;
            tb.onBack = ^{ [wvc.navigationController popViewControllerAnimated:YES]; };
            tb.onInfo = ^{ WGTriggerRight(wvc); };
            gTopBar = tb;
        }
        if (tb.superview != win) [win addSubview:tb];
        if (title.length) tb.title = title;
        UIColor *bg = vc.view.backgroundColor;
        if (!bg || CGColorGetAlpha(bg.CGColor) < 0.5) bg = UIColor.systemBackgroundColor;
        tb.coverColor = bg;
        tb.frame = [win convertRect:nb.bounds fromView:nb];
        [win bringSubviewToFront:tb];
        nb.backgroundColor = UIColor.clearColor;
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

static void WGApplyTab(UIViewController *tc) {
    gTab = tc;
    UIView *root = tc.view;

    static char kEdge;
    if (!objc_getAssociatedObject(tc, &kEdge)) {
        UIScreenEdgePanGestureRecognizer *e = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:WGHelper.shared action:@selector(edgePan:)];
        e.edges = UIRectEdgeLeft;
        [root addGestureRecognizer:e];
        objc_setAssociatedObject(tc, &kEdge, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSInteger theme = [WGD() integerForKey:@"theme"];
    if (root.window && (NSInteger)root.window.overrideUserInterfaceStyle != theme)
        root.window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)theme;

    NSInteger style = [WGD() integerForKey:@"tabStyle"];
    UIView *bar = gTabBar;
    if (!bar || ![bar isDescendantOfView:root]) { bar = WGFindTabBar(root); gTabBar = bar; }

    WGTabView *tv = (WGTabView *)[root viewWithTag:TAG_GLASS_TAB];
    UIButton *plus = (UIButton *)[root viewWithTag:TAG_TAB_PLUS];

    if (style == 0 || !bar) {
        [tv removeFromSuperview]; [plus removeFromSuperview];
        for (UIView *sv in bar.subviews) sv.alpha = 1;
        return;
    }
    BOOL gone = bar.hidden || bar.alpha < 0.01 || !bar.window;
    tv.hidden = gone; plus.hidden = gone;
    if (gone) return;

    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;
    CGFloat h = 64, m = 14, plusSize = h;
    CGFloat y = H - MAX(root.safeAreaInsets.bottom, 10) - h;
    CGFloat cw = style == 1 ? W - m * 3 - plusSize : W - m * 2;

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
    [root bringSubviewToFront:tv];
    tv.frame = CGRectMake(m, y, cw, h);

    // 原底栏保留(用于切换/角标逻辑),只是看不见
    bar.backgroundColor = UIColor.clearColor;
    for (UIView *sv in bar.subviews) sv.alpha = 0;

    if (style == 1) {
        if (!plus) {
            plus = [UIButton buttonWithType:UIButtonTypeSystem];
            plus.tag = TAG_TAB_PLUS;
            plus.backgroundColor = UIColor.blackColor;
            plus.tintColor = UIColor.whiteColor;
            [plus setImage:[UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
            [plus addTarget:WGHelper.shared action:@selector(plusTapped) forControlEvents:UIControlEventTouchUpInside];
        }
        if (plus.superview != root) [root addSubview:plus];
        [root bringSubviewToFront:plus];
        plus.frame = CGRectMake(W - m - plusSize, y, plusSize, plusSize);
        plus.layer.cornerRadius = plusSize / 2;
        plus.layer.shadowColor = UIColor.blackColor.CGColor;
        plus.layer.shadowOpacity = 0.25;
        plus.layer.shadowRadius = 10;
        plus.layer.shadowOffset = CGSizeMake(0, 4);
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

    // 微信设置页入口
    Class st = NSClassFromString(@"NewSettingViewController");
    if (st) {
        o_settingReload = WGHook(st, NSSelectorFromString(@"reloadTableData"), (IMP)n_settingReload);
        class_addMethod(st, NSSelectorFromString(@"wg_openPanel"), (IMP)n_openPanel, "v@:");
        gHookSet = o_settingReload != NULL;
    }
}
