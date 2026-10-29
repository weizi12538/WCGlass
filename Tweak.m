// WCGlass - 微信毛玻璃 UI 插件
// 纯 ObjC runtime 方法替换,不依赖 CydiaSubstrate,越狱 / lcsign 注入均可用
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>

#define WG_SUITE @"com.wcglass.prefs"
#define TAG_GLASS_INPUT 0x57A02
#define TAG_GLASS_TAB   0x57A03
#define TAG_TAB_PILL    0x57A04
#define TAG_TAB_PLUS    0x57A05
#define TAG_DRAWER      0x57A06
#define TAG_DIM         0x57A07

static __weak UITabBarController *gTab;
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
                              @"tabStyle": @1, @"drawer": @YES, @"theme": @0}];
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

static void WGDump(UIView *v, int depth, NSMutableString *out) {
    [out appendFormat:@"%@%@ %@\n",
        [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
        NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
    for (UIView *s in v.subviews) WGDump(s, depth + 1, out);
}

static UIWindow *WGWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UINavigationController *WGNav(void) {
    UIViewController *sel = gTab.selectedViewController;
    if ([sel isKindOfClass:UINavigationController.class]) return (UINavigationController *)sel;
    return sel.navigationController;
}


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
    for (int i = 0; i < 10 && v; i++) {
        if (v.presentedViewController) v = v.presentedViewController;
        else if ([v isKindOfClass:UITabBarController.class]) v = ((UITabBarController *)v).selectedViewController;
        else if ([v isKindOfClass:UINavigationController.class]) v = ((UINavigationController *)v).topViewController;
        else break;
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
    [s appendFormat:@"类存在: MMTabBarController=%d BaseMsgContent=%d\n",
        NSClassFromString(@"MMTabBarController") != nil, NSClassFromString(@"BaseMsgContentViewController") != nil];
    UIWindow *w = WGWindow();
    [s appendFormat:@"root: %@\n", w.rootViewController ? WGChain(w.rootViewController) : @"nil"];
    if (gTab) {
        UITabBar *b = gTab.tabBar;
        [s appendFormat:@"tabVC: %@\ntabBar: %@ hidden=%d %@\n", WGChain(gTab), NSStringFromClass(b.class), b.hidden, NSStringFromCGRect(b.frame)];
        NSMutableArray *names = [NSMutableArray array];
        for (UIView *v in b.subviews) [names addObject:NSStringFromClass(v.class)];
        [s appendFormat:@"tabBar子视图: %@\n", [names componentsJoinedByString:@", "]];
    } else {
        [s appendString:@"gTab=nil (底栏钩子没触发)\n"];
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

- (void)openDrawer {
    UIView *host = gTab.view;
    if (!host || [host viewWithTag:TAG_DRAWER]) return;
    CGFloat W = host.bounds.size.width, H = host.bounds.size.height, dw = floor(W * 0.82);
    CGFloat top = host.safeAreaInsets.top, bottom = host.safeAreaInsets.bottom;

    UIView *dim = [[UIView alloc] initWithFrame:host.bounds];
    dim.tag = TAG_DIM;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeDrawer)]];
    [host addSubview:dim];

    UIVisualEffectView *dr = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    dr.tag = TAG_DRAWER;
    dr.frame = CGRectMake(-dw, 0, dw, H);
    dr.userInteractionEnabled = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drawerPan:)];
    [dr addGestureRecognizer:pan];
    [host addSubview:dr];
    UIView *c = dr.contentView;

    // 头像 + 昵称
    UIImageView *av = [[UIImageView alloc] initWithFrame:CGRectMake(20, top + 24, 72, 72)];
    av.backgroundColor = UIColor.tertiarySystemFillColor;
    av.contentMode = UIViewContentModeScaleAspectFill;
    av.clipsToBounds = YES;
    av.layer.cornerRadius = 8;
    [c addSubview:av];
    UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(108, top + 30, dw - 128, 28)];
    nm.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    nm.text = @"微信";
    [c addSubview:nm];
    struct utsname u; uname(&u);
    UILabel *info = [[UILabel alloc] initWithFrame:CGRectMake(108, top + 62, dw - 128, 20)];
    info.font = [UIFont systemFontOfSize:13];
    info.textColor = UIColor.secondaryLabelColor;
    info.text = [NSString stringWithFormat:@"%s · iOS %@", u.machine, UIDevice.currentDevice.systemVersion];
    [c addSubview:info];
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

    // 菜单
    NSArray *rows = @[@[@"聊天", @"bubble.left", @0], @[@"通讯录", @"person.2", @1],
                      @[@"发现", @"safari", @2], @[@"我", @"person", @3],
                      @[@"微信设置", @"gearshape", @10], @[@"插件入口", @"square.grid.2x2", @11]];
    CGFloat y = top + 130;
    for (NSArray *r in rows) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.title = r[0];
        cfg.image = [UIImage systemImageNamed:r[1]];
        cfg.imagePadding = 16;
        cfg.baseForegroundColor = UIColor.labelColor;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.configuration = cfg;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.frame = CGRectMake(24, y, dw - 48, 48);
        b.tag = [r[2] integerValue];
        [b addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [c addSubview:b];
        y += 52;
        if ([r[2] integerValue] == 3) y += 16;
    }

    // 主题切换
    UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:@[@"跟随系统", @"浅色", @"深色"]];
    sc.frame = CGRectMake(20, H - bottom - 56, dw - 40, 36);
    sc.selectedSegmentIndex = [WGD() integerForKey:@"theme"];
    [sc addTarget:self action:@selector(themeChanged:) forControlEvents:UIControlEventValueChanged];
    [c addSubview:sc];

    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        dr.frame = CGRectMake(0, 0, dw, H);
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    } completion:nil];
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

- (void)rowTapped:(UIButton *)b {
    NSInteger t = b.tag;
    if (t <= 3) { gTab.selectedIndex = t; [self closeDrawer]; }
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

static void WGApplyChat(UIViewController *vc) {
    if (!vc.isViewLoaded) return;

    if ([WGD() boolForKey:@"glassTop"]) {
        UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
        [ap configureWithTransparentBackground];
        ap.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        vc.navigationItem.standardAppearance = ap;
        vc.navigationItem.scrollEdgeAppearance = ap;
        vc.navigationItem.compactAppearance = ap;
    }

    UIView *root = vc.view;
    UIView *bar = WGFindInputBar(root);
    if (!bar) return;
    UIView *pill = [bar viewWithTag:TAG_GLASS_INPUT];
    if (![WGD() boolForKey:@"glassInput"]) { [pill removeFromSuperview]; return; }

    if (!pill) {
        pill = WGBlur(0, YES);
        pill.tag = TAG_GLASS_INPUT;
        pill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [bar insertSubview:pill atIndex:0];
    }
    CGRect b = CGRectInset(bar.bounds, 10, 6);
    pill.frame = b;
    pill.layer.cornerRadius = b.size.height / 2;
    bar.backgroundColor = UIColor.clearColor;
    for (UIView *sv in bar.subviews) {
        if (sv == pill) continue;
        if (sv.bounds.size.width >= bar.bounds.size.width * 0.9 && sv.subviews.count == 0 &&
            ![sv isKindOfClass:UIControl.class] && ![sv isKindOfClass:UILabel.class]) sv.alpha = 0; // 原背景 / 分割线
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

static IMP o_chatLayout, o_chatAppear;
static void n_chatLayout(UIViewController *self, SEL _cmd) {
    ((void(*)(id, SEL))o_chatLayout)(self, _cmd);
    gCntChat++;
    WGApplyChat(self);
}
static void n_chatAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    ((void(*)(id, SEL, BOOL))o_chatAppear)(self, _cmd, animated);
    WGApplyChat(self);
}

#pragma mark - 首页底栏

static void WGApplyTab(UITabBarController *tc) {
    gTab = tc;
    UIView *root = tc.view;
    UITabBar *bar = tc.tabBar;
    NSInteger style = [WGD() integerForKey:@"tabStyle"];
    UIView *glass = [root viewWithTag:TAG_GLASS_TAB];
    UIView *pill = [root viewWithTag:TAG_TAB_PILL];
    UIButton *plus = (UIButton *)[root viewWithTag:TAG_TAB_PLUS];

    // 手势只加一次
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

    UINavigationController *nav = [tc.selectedViewController isKindOfClass:UINavigationController.class] ? (UINavigationController *)tc.selectedViewController : nil;
    BOOL barGone = bar.isHidden || nav.topViewController.hidesBottomBarWhenPushed || nav.viewControllers.count > 1;

    if (style == 0) { [glass removeFromSuperview]; [pill removeFromSuperview]; [plus removeFromSuperview]; return; }
    glass.hidden = pill.hidden = plus.hidden = barGone;
    if (barGone) return;

    static char kAp;
    if (!objc_getAssociatedObject(bar, &kAp)) {
        UITabBarAppearance *ap = [UITabBarAppearance new];
        [ap configureWithTransparentBackground];
        bar.standardAppearance = ap;
        bar.scrollEdgeAppearance = ap;
        objc_setAssociatedObject(bar, &kAp, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;
    CGFloat h = 64, m = 14, y = H - MAX(root.safeAreaInsets.bottom, 10) - h;
    CGFloat plusSize = h;
    CGFloat cw = style == 1 ? W - m * 3 - plusSize : W - m * 2;
    CGRect cap = CGRectMake(m, y, cw, h);

    if (!glass) {
        glass = WGBlur(h / 2, YES);
        glass.tag = TAG_GLASS_TAB;
    }
    if (glass.superview != root) [root insertSubview:glass belowSubview:bar];
    glass.frame = cap;
    ((UIVisualEffectView *)glass).layer.cornerRadius = h / 2;
    bar.frame = cap;
    bar.backgroundColor = UIColor.clearColor;

    // 找到每个 tab 按钮
    NSMutableArray<UIView *> *btns = [NSMutableArray array];
    for (UIView *s in bar.subviews) if ([NSStringFromClass(s.class) containsString:@"TabBarButton"]) [btns addObject:s];
    [btns sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) { return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending; }];

    // 样式一:只显示图标
    for (UIView *b in btns)
        for (UIView *s in b.subviews)
            if ([NSStringFromClass(s.class) containsString:@"Label"]) s.hidden = (style == 1);

    // 样式二:选中项高亮胶囊
    if (style == 2 && btns.count) {
        NSInteger idx = MIN((NSInteger)btns.count - 1, MAX(0, tc.selectedIndex));
        UIView *sel = btns[idx];
        CGRect pf = CGRectInset(CGRectOffset(sel.frame, bar.frame.origin.x, bar.frame.origin.y), 2, 6);
        if (!pill) {
            pill = [UIView new];
            pill.tag = TAG_TAB_PILL;
            pill.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.22];
            pill.userInteractionEnabled = NO;
            pill.frame = pf;
        }
        if (pill.superview != root) [root insertSubview:pill belowSubview:bar];
        pill.layer.cornerRadius = pf.size.height / 2;
        [UIView animateWithDuration:0.25 animations:^{ pill.frame = pf; }];
    } else {
        [pill removeFromSuperview];
    }

    // 样式一:右侧黑色圆形 "+"
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
static void n_tabLayout(UITabBarController *self, SEL _cmd) {
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
    }
    // 首页 TabBarController
    Class tc = NSClassFromString(@"MMTabBarController") ?: UITabBarController.class;
    o_tabLayout = WGHook(tc, @selector(viewDidLayoutSubviews), (IMP)n_tabLayout);

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
