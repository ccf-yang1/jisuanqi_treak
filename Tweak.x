
// AppMaskCalc — 通用计算器密码伪装（TrollFools per-app 注入版）
// 通用化改造：移除全部 method hook 与 Substrate 依赖，任意 app 注入即生效。
//
// 解锁方式：输入表达式，计算结果等于当前密码即解锁。
//   默认密码 = 当前时间 HHmm（24 小时制，如 14:30 → 1430）
//   三指双击 → 可设置自定义密码（存于本 app 沙箱 NSUserDefaults，每个 app 独立）
//   0123456789 → 打开设置（免锁时长、链接 App）
//   8888 → 解锁并跳转到链接 App（本 App 本身仍保持锁定）
//
// 免锁规则（v1.2）：
//   只有「密码解锁」（时间密码 / 自定义密码）才进入免锁状态；
//   之后切到后台（Home/上划回桌面）再回来，离开时长不超过「后台免锁时长」（默认 10 分钟，可配置）才直接进入。
//   8888 / 0123456789 不进入免锁状态 —— 每次回到本 App 仍然重新上锁。
//   免锁状态只保存在进程内存里：上划杀掉 App（或进程被系统回收）后重新打开，一律重新上锁。
//
// 构建：macOS 上 `xcrun -sdk iphoneos clang` 直接编译（见 .github/workflows/build.yml）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSString * const kCustomPasswordKey = @"customPassword";
static NSString * const kGracePeriodKey = @"com.ccifang.appmaskcalc.gracePeriodMinutes";
static NSString * const kLinkedAppsKey = @"com.ccifang.appmaskcalc.linkedApps";

static const NSInteger kDefaultGracePeriodMinutes = 10;

// 保留指令
static NSString * const kSettingsCode = @"0123456789";
static NSString * const kLinkedAppCode = @"8888";

static UIWindow *maskWindow = nil;
// 解锁状态与离开后台时刻只放内存：进程一旦结束（用户上划强杀 / 系统回收），
// 这两个变量随进程消失，下次启动必然重新上锁。
static BOOL gUnlocked = NO;
static NSDate *gLastBackgroundAt = nil;

#pragma mark - Settings Storage

static NSUserDefaults *SharedDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

static NSInteger GracePeriodMinutes(void) {
    NSUserDefaults *defaults = SharedDefaults();
    if ([defaults objectForKey:kGracePeriodKey] == nil) return kDefaultGracePeriodMinutes;
    NSInteger minutes = [defaults integerForKey:kGracePeriodKey];
    return minutes < 0 ? 0 : minutes;
}

static void SetGracePeriodMinutes(NSInteger minutes) {
    NSUserDefaults *defaults = SharedDefaults();
    [defaults setInteger:(minutes < 0 ? 0 : minutes) forKey:kGracePeriodKey];
    [defaults synchronize];
}

static NSArray *LinkedAppEntries(void) {
    id value = [SharedDefaults() objectForKey:kLinkedAppsKey];
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : @[];
}

static void SetLinkedAppEntries(NSArray *entries) {
    [SharedDefaults() setObject:(entries ?: @[]) forKey:kLinkedAppsKey];
    [SharedDefaults() synchronize];
}

// 只有密码解锁（时间密码 / 自定义密码）才会置位内存里的解锁标记。
static void MarkUnlockedWithPassword(void) {
    gUnlocked = YES;
    // 清掉上一次的离开时刻，确保免锁窗口只从「这次解锁后真正切到后台」开始计时
    gLastBackgroundAt = nil;
}

static void MarkLocked(void) {
    gUnlocked = NO;
    gLastBackgroundAt = nil;
}

static void RecordBackgroundTime(void) {
    gLastBackgroundAt = [NSDate date];
}

// 回前台时判断是否仍在免锁窗口内（仅同一进程内有效）：
//   必须已密码解锁，并且有离开后台时刻，且离开时长 <= 免锁时长。
// 进程重启后 gUnlocked 为 NO，因此「上划关闭 App 再打开」一定会重新上锁。
static BOOL CanSkipLock(void) {
    if (!gUnlocked) return NO;
    if (gLastBackgroundAt == nil) return NO;

    NSTimeInterval gap = [[NSDate date] timeIntervalSinceDate:gLastBackgroundAt];
    if (gap < 0) return NO;
    return gap <= (NSTimeInterval)GracePeriodMinutes() * 60.0;
}

#pragma mark - Launch Services Helpers

// 不同 iOS 版本里 LSApplicationWorkspace 所在的 framework 路径不一样，
// 逐个尝试加载（都在 dyld 共享缓存里，dlopen 是安全的）。
static Class LoadPrivateClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls != Nil) return cls;

    static const char *paths[] = {
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices",
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
        "/System/Library/Frameworks/LaunchServices.framework/LaunchServices",
    };
    size_t count = sizeof(paths) / sizeof(paths[0]);
    for (size_t i = 0; i < count; i++) {
        dlopen(paths[i], RTLD_LAZY);
        cls = NSClassFromString(className);
        if (cls != Nil) return cls;
    }
    return Nil;
}

static Class LSApplicationWorkspaceClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = LoadPrivateClass(@"LSApplicationWorkspace");
    });
    return cls;
}

static Class LSApplicationProxyClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = LoadPrivateClass(@"LSApplicationProxy");
    });
    return cls;
}

static id LSDefaultWorkspace(void) {
    Class cls = LSApplicationWorkspaceClass();
    SEL sel = NSSelectorFromString(@"defaultWorkspace");
    if (cls == Nil || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static id LSProxyForBundleID(NSString *bundleID) {
    Class proxyClass = LSApplicationProxyClass();
    SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass == Nil || ![proxyClass respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, sel, bundleID);
}

static NSString *ProxyStringValue(id proxy, NSString *key) {
    if (proxy == nil) return nil;

    id value = nil;
    @try { value = [proxy valueForKey:key]; } @catch (NSException *exception) { (void)exception; }

    // 个别系统上 KVC 会抛异常，退回直接发消息再取一次
    if (![value isKindOfClass:[NSString class]]) {
        SEL sel = NSSelectorFromString(key);
        if ([proxy respondsToSelector:sel]) {
            @try { value = ((id (*)(id, SEL))objc_msgSend)(proxy, sel); } @catch (NSException *exception) { (void)exception; }
        }
    }
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSString *ProxyDisplayName(id proxy) {
    NSString *name = ProxyStringValue(proxy, @"localizedName");
    if (name.length == 0) name = ProxyStringValue(proxy, @"displayName");
    if (name.length == 0) name = ProxyStringValue(proxy, @"itemName");
    return name.length > 0 ? name : nil;
}

// 支持三种写法：完整 URL（twitter://...）、URL scheme（twitter://）、bundle id（com.xx.xx）
static BOOL IsBundleIdentifier(NSString *text) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$" options:0 error:nil];
    });
    NSRange range = NSMakeRange(0, text.length);
    return [regex firstMatchInString:text options:0 range:range] != nil;
}

// 兜底：部分环境会限制 openApplicationWithBundleID:，
// 此时改从 LSApplicationProxy 取该 App 的 URL scheme 再打开
static BOOL OpenBundleIdentifierViaScheme(NSString *bundleID) {
    id proxy = LSProxyForBundleID(bundleID);
    if (proxy == nil) return NO;

    NSArray *schemes = nil;
    @try { schemes = [proxy valueForKey:@"URLSchemes"]; } @catch (NSException *exception) { (void)exception; }
    if (![schemes isKindOfClass:[NSArray class]]) {
        @try { schemes = [proxy valueForKey:@"_boundURLSchemes"]; } @catch (NSException *exception) { (void)exception; }
    }
    if (![schemes isKindOfClass:[NSArray class]]) return NO;

    for (NSString *scheme in schemes) {
        if (![scheme isKindOfClass:[NSString class]] || scheme.length == 0) continue;
        NSString *urlString = [scheme rangeOfString:@"://"].location == NSNotFound
            ? [NSString stringWithFormat:@"%@://", scheme]
            : scheme;
        NSURL *url = [NSURL URLWithString:urlString];
        if (url != nil) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return YES;
        }
    }
    return NO;
}

static BOOL OpenBundleIdentifier(NSString *bundleID) {
    id workspace = LSDefaultWorkspace();
    if (workspace != nil) {
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([workspace respondsToSelector:openSel]) {
            if (((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bundleID)) return YES;
        }
    }
    return OpenBundleIdentifierViaScheme(bundleID);
}

static BOOL OpenTargetApp(NSString *target) {
    if (target.length == 0) return NO;
    NSString *trimmed = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;

    if ([trimmed rangeOfString:@"://"].location != NSNotFound) {
        NSURL *url = [NSURL URLWithString:trimmed];
        if (url != nil) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return YES;
        }
    }

    // bundle id 只走 LaunchServices，不再退化成 xxx:// 去猜 scheme，
    // 这样目标不存在时能如实报错，而不是"假装打开了"
    if (IsBundleIdentifier(trimmed)) {
        return OpenBundleIdentifier(trimmed);
    }

    NSString *urlString = [NSString stringWithFormat:@"%@://", trimmed];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url != nil) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return YES;
    }
    return NO;
}

#pragma mark - Installed Apps Enumeration

// 上次枚举的原始数量，枚举为空时显示在界面上，便于定位是哪条路被系统拦了
static NSString *gInstalledAppsDiagnostics = nil;

// 1) LSApplicationWorkspace 枚举。部分注入环境没有 LaunchServices 私有 entitlement，
//    这一步会返回空，所以后面还有别的兜底来源。
static NSArray *WorkspaceAppProxies(void) {
    id workspace = LSDefaultWorkspace();
    if (workspace == nil) return @[];

    NSArray<NSString *> *selectorNames = @[
        @"allInstalledApplications",
        @"installedApplications",
        @"allApplications"
    ];
    for (NSString *selectorName in selectorNames) {
        SEL sel = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:sel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(workspace, sel);
        if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 0) {
            return (NSArray *)value;
        }
        if ([value isKindOfClass:[NSSet class]] && [(NSSet *)value count] > 0) {
            return [(NSSet *)value allObjects];
        }
    }

    SEL enumerateSel = NSSelectorFromString(@"enumerateInstalledApplications:");
    if ([workspace respondsToSelector:enumerateSel]) {
        NSMutableArray *proxies = [NSMutableArray array];
        void (^handler)(id, BOOL *) = ^(id proxy, BOOL *stop) {
            if (proxy != nil) [proxies addObject:proxy];
        };
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(workspace, enumerateSel, handler);
        } @catch (NSException *exception) {
            (void)exception;
        }
        if (proxies.count > 0) return proxies;
    }
    return @[];
}

// 2) MobileInstallationLookup：老牌私有 C 接口，返回 {bundleID: info}
static NSDictionary *MobileInstallationLookupCompat(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
    });
    if (handle == NULL) return nil;

    typedef NSDictionary *(*LookupFunc)(NSDictionary *);
    LookupFunc lookup = (LookupFunc)dlsym(handle, "MobileInstallationLookup");
    if (lookup == NULL) return nil;

    NSDictionary *options = @{
        @"ApplicationType": @"Any",
        @"ReturnAttributes": @[@"CFBundleIdentifier", @"CFBundleDisplayName", @"CFBundleName"]
    };
    id result = nil;
    @try { result = lookup(options); } @catch (NSException *exception) { (void)exception; }
    return [result isKindOfClass:[NSDictionary class]] ? (NSDictionary *)result : nil;
}

// 3) SBSCopyDisplayIdentifiers：只返回 bundle id 列表（拿不到名称，之后用 LSProxy 补）
static NSArray *SBSDisplayIdentifiers(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    });
    if (handle == NULL) return @[];

    typedef NSArray *(*CopyIdentifiersFunc)(void);
    CopyIdentifiersFunc copyIdentifiers = (CopyIdentifiersFunc)dlsym(handle, "SBSCopyDisplayIdentifiers");
    if (copyIdentifiers == NULL) return @[];

    id identifiers = nil;
    @try { identifiers = copyIdentifiers(); } @catch (NSException *exception) { (void)exception; }
    if ([identifiers isKindOfClass:[NSArray class]]) return (NSArray *)identifiers;
    if ([identifiers isKindOfClass:[NSSet class]]) return [(NSSet *)identifiers allObjects];
    return @[];
}

// SpringBoard 的本地化名称查询，给只有 bundle id 没有名称的来源补名称
static NSString *SBSLocalizedNameForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return nil;

    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    });
    if (handle == NULL) return nil;

    typedef NSString *(*NameFunc)(NSString *);
    NameFunc nameFunc = (NameFunc)dlsym(handle, "SBSCopyLocalizedApplicationNameForDisplayIdentifier");
    if (nameFunc == NULL) return nil;

    id name = nil;
    @try { name = nameFunc(bundleID); } @catch (NSException *exception) { (void)exception; }
    return [name isKindOfClass:[NSString class]] ? (NSString *)name : nil;
}

// 4) 直接扫描 App bundle 目录。普通沙箱会被拒绝（返回 nil），
//    TrollStore / platform-application 一类的宽松环境可以成功，作为最后兜底。
static NSDictionary *AppEntryAtBundlePath(NSString *appPath) {
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    if (![info isKindOfClass:[NSDictionary class]]) return nil;

    NSString *bundleID = info[@"CFBundleIdentifier"];
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return nil;

    NSString *name = info[@"CFBundleDisplayName"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = info[@"CFBundleName"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bundleID;

    return @{@"name": name, @"target": bundleID};
}

static NSArray<NSDictionary *> *FilesystemAppEntries(void) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSFileManager *manager = [NSFileManager defaultManager];

    // 用户 App：/private/var/containers/Bundle/Application/<UUID>/<Name>.app
    NSArray<NSString *> *containerRoots = @[
        @"/private/var/containers/Bundle/Application",
        @"/var/containers/Bundle/Application"
    ];
    for (NSString *root in containerRoots) {
        NSArray<NSString *> *uuids = [manager contentsOfDirectoryAtPath:root error:nil];
        for (NSString *uuid in uuids) {
            NSString *uuidPath = [root stringByAppendingPathComponent:uuid];
            NSArray<NSString *> *bundles = [manager contentsOfDirectoryAtPath:uuidPath error:nil];
            for (NSString *bundle in bundles) {
                if (![bundle hasSuffix:@".app"]) continue;
                NSDictionary *entry = AppEntryAtBundlePath([uuidPath stringByAppendingPathComponent:bundle]);
                if (entry != nil) [result addObject:entry];
            }
        }
    }

    // 系统 App：/Applications/<Name>.app
    NSArray<NSString *> *systemBundles = [manager contentsOfDirectoryAtPath:@"/Applications" error:nil];
    for (NSString *bundle in systemBundles) {
        if (![bundle hasSuffix:@".app"]) continue;
        NSDictionary *entry = AppEntryAtBundlePath([@"/Applications" stringByAppendingPathComponent:bundle]);
        if (entry != nil) [result addObject:entry];
    }

    return result;
}

// 汇总多个来源，按 bundle id 去重，返回 [{name, target(bundle id)}]
static NSArray<NSDictionary *> *InstalledAppEntries(void) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *selfBundleID = [[NSBundle mainBundle] bundleIdentifier];

    void (^addEntry)(NSString *, NSString *) = ^(NSString *bundleID, NSString *name) {
        if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return;
        if (selfBundleID != nil && [bundleID isEqualToString:selfBundleID]) return;
        if ([seen containsObject:bundleID]) return;
        [seen addObject:bundleID];

        if (![name isKindOfClass:[NSString class]] || name.length == 0) {
            name = ProxyDisplayName(LSProxyForBundleID(bundleID));
        }
        if (![name isKindOfClass:[NSString class]] || name.length == 0) {
            name = SBSLocalizedNameForBundleID(bundleID);
        }
        if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bundleID;
        [result addObject:@{@"name": name, @"target": bundleID}];
    };

    // 来源 1：LSApplicationWorkspace（不同系统可能返回 proxy / 字符串 / 字典）
    NSArray *proxies = WorkspaceAppProxies();
    for (id app in proxies) {
        if ([app isKindOfClass:[NSString class]]) {
            addEntry((NSString *)app, nil);
            continue;
        }
        if ([app isKindOfClass:[NSDictionary class]]) {
            NSDictionary *infoDict = (NSDictionary *)app;
            NSString *bundleID = infoDict[@"CFBundleIdentifier"] ?: infoDict[@"bundleIdentifier"];
            NSString *name = infoDict[@"CFBundleDisplayName"] ?: infoDict[@"CFBundleName"];
            addEntry(bundleID, name);
            continue;
        }
        NSString *bundleID = ProxyStringValue(app, @"bundleIdentifier");
        addEntry(bundleID, ProxyDisplayName(app));
    }

    // 来源 2：MobileInstallationLookup
    NSDictionary *lookup = MobileInstallationLookupCompat();
    for (id key in lookup) {
        if (![key isKindOfClass:[NSString class]]) continue;
        NSString *name = nil;
        id info = lookup[key];
        if ([info isKindOfClass:[NSDictionary class]]) {
            NSDictionary *infoDict = (NSDictionary *)info;
            name = infoDict[@"CFBundleDisplayName"];
            if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                name = infoDict[@"CFBundleName"];
            }
        }
        addEntry((NSString *)key, name);
    }

    // 来源 3：SpringBoard 的 bundle id 列表
    NSArray *sbsIdentifiers = SBSDisplayIdentifiers();
    for (id bundleID in sbsIdentifiers) {
        if ([bundleID isKindOfClass:[NSString class]]) addEntry((NSString *)bundleID, nil);
    }

    // 来源 4：直接扫描 App bundle 目录（宽松沙箱环境下的最后兜底）
    NSArray<NSDictionary *> *filesystemApps = FilesystemAppEntries();
    for (NSDictionary *entry in filesystemApps) {
        addEntry(entry[@"target"], entry[@"name"]);
    }

    gInstalledAppsDiagnostics = [NSString stringWithFormat:@"LS=%lu MI=%lu SBS=%lu FS=%lu → %lu",
                                 (unsigned long)proxies.count,
                                 (unsigned long)lookup.count,
                                 (unsigned long)sbsIdentifiers.count,
                                 (unsigned long)filesystemApps.count,
                                 (unsigned long)result.count];

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return result;
}

#pragma mark - Interfaces

@interface CalculatorViewController : UIViewController
@property (nonatomic, strong) UILabel *displayLabel;
@property (nonatomic, strong) UILabel *historyLabel;
@property (nonatomic, strong) NSMutableString *currentExpression;
@property (nonatomic, strong) NSMutableString *history;
@property (nonatomic, strong) NSString *customPassword;
@property (nonatomic, assign) BOOL isCustomPasswordEnabled;
@end

@interface SettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *apps;
@end

// 从已安装 App 列表里选择，点选后自动回填 bundle id
@interface AppPickerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, copy) void (^onSelect)(NSDictionary *entry);
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredApps;
@end

#pragma mark - Window Helpers

static UIWindowScene *MaskForegroundScene(void) {
    NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (fallback == nil) fallback = ws;
    }
    return fallback;
}

// 幂等：优先使用指定 scene（willConnect 时能更早盖上伪装层）
static void PresentMask(UIWindowScene *preferred, BOOL makeKey) {
    if (maskWindow != nil) {
        if (preferred != nil && maskWindow.windowScene != preferred) {
            UIWindow *old = maskWindow;
            maskWindow = nil;
            old.hidden = YES;
            old.rootViewController = nil;
            PresentMask(preferred, makeKey);
            return;
        }
        maskWindow.hidden = NO;
        if (makeKey) [maskWindow makeKeyAndVisible];
        return;
    }

    UIWindowScene *scene = preferred != nil ? preferred : MaskForegroundScene();
    if (scene == nil) return;

    CalculatorViewController *calcVC = [[CalculatorViewController alloc] init];
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = [UIScreen mainScreen].bounds;
    window.rootViewController = calcVC;
    // 只比宿主普通窗口高一级：既能盖住 app 内容，又不会把系统 alert 窗口
    //（UIAlertController / 键盘等位于 Alert / StatusBar 层级）压到伪装层下面，
    // 避免设置页里的弹窗"看不见、点不动"。
    window.windowLevel = UIWindowLevelNormal + 1.0;
    window.backgroundColor = [UIColor blackColor];
    window.hidden = NO;
    if (makeKey) [window makeKeyAndVisible];

    maskWindow = window;
}

static void ShowMaskIfNeeded(void) {
    PresentMask(nil, YES);
}

// 收起伪装窗口，并把宿主 app 原本的窗口恢复为 key window
static void HideMaskWindow(void) {
    UIWindow *window = maskWindow;
    if (window == nil) return;

    maskWindow = nil;
    UIViewController *root = window.rootViewController;
    if (root.presentedViewController != nil) {
        [root dismissViewControllerAnimated:NO completion:nil];
    }
    window.rootViewController = nil;
    window.hidden = YES;

    UIWindowScene *scene = MaskForegroundScene();
    if (scene != nil) {
        for (UIWindow *win in scene.windows) {
            if (!win.hidden) {
                [win makeKeyWindow];
                break;
            }
        }
    }
}

// 需要重新上锁时，把伪装窗口恢复成计算器（关掉可能还开着的设置页）
static void ResetMaskForLock(void) {
    UIWindow *window = maskWindow;
    if (window == nil) return;

    UIViewController *root = window.rootViewController;
    if (root.presentedViewController != nil) {
        [root dismissViewControllerAnimated:NO completion:nil];
    }
    window.hidden = NO;
    [window makeKeyAndVisible];
}

#pragma mark - Calculator UI

@implementation CalculatorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.currentExpression = [NSMutableString stringWithString:@""];
    self.history = [NSMutableString stringWithString:@""];

    // 读取本 app 沙箱内保存的自定义密码（每个 app 独立）
    self.customPassword = [[NSUserDefaults standardUserDefaults] stringForKey:kCustomPasswordKey];
    self.isCustomPasswordEnabled = self.customPassword != nil;

    [self setNeedsStatusBarAppearanceUpdate];

    // 计算器历史记录标签
    self.historyLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, self.view.bounds.size.width - 40, 80)];
    self.historyLabel.text = @"";
    self.historyLabel.font = [UIFont systemFontOfSize:20];
    self.historyLabel.textColor = [UIColor lightGrayColor];
    self.historyLabel.numberOfLines = 0;
    [self.view addSubview:self.historyLabel];

    self.displayLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 250, self.view.bounds.size.width - 40, 80)];
    self.displayLabel.text = @"0";
    self.displayLabel.font = [UIFont systemFontOfSize:48];
    self.displayLabel.textAlignment = NSTextAlignmentRight;
    self.displayLabel.textColor = [UIColor whiteColor];
    [self.view addSubview:self.displayLabel];

    // 三指双击：管理自定义密码
    UITapGestureRecognizer *threeFingerDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showCustomPasswordMenu)];
    threeFingerDoubleTap.numberOfTapsRequired = 2;
    threeFingerDoubleTap.numberOfTouchesRequired = 3;
    [self.view addGestureRecognizer:threeFingerDoubleTap];

    // 双指双击：收起弹窗菜单
    UITapGestureRecognizer *twoFingerDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideCustomPasswordMenu)];
    twoFingerDoubleTap.numberOfTapsRequired = 2;
    twoFingerDoubleTap.numberOfTouchesRequired = 2;
    [self.view addGestureRecognizer:twoFingerDoubleTap];

    [self setupButtons];
}

- (void)setupButtons {
    NSArray *buttons = @[
        @[@"C", @"(", @")", @"/"],
        @[@"7", @"8", @"9", @"*"],
        @[@"4", @"5", @"6", @"-"],
        @[@"1", @"2", @"3", @"+"],
        @[@"0", @".", @"="]
    ];

    CGFloat buttonWidth = (self.view.bounds.size.width - 100) / 4;
    CGFloat buttonHeight = 70;
    CGFloat yOffset = self.view.bounds.size.height - 5 * buttonHeight - 160;

    for (int row = 0; row < buttons.count; row++) {
        NSArray *rowButtons = buttons[row];
        for (int col = 0; col < rowButtons.count; col++) {
            NSString *title = rowButtons[col];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];

            if ([title isEqualToString:@"0"]) {
                button.frame = CGRectMake(20, yOffset + row * (buttonHeight + 20), buttonWidth * 2 + 20, buttonHeight);
                button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
                button.titleEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 0);
            } else if ([title isEqualToString:@"."]) {
                button.frame = CGRectMake(20 + 2 * (buttonWidth + 20), yOffset + row * (buttonHeight + 20), buttonWidth, buttonHeight);
            } else if ([title isEqualToString:@"="]) {
                button.frame = CGRectMake(20 + 3 * (buttonWidth + 20), yOffset + row * (buttonHeight + 20), buttonWidth, buttonHeight);
            } else {
                button.frame = CGRectMake(20 + col * (buttonWidth + 20), yOffset + row * (buttonHeight + 20), buttonWidth, buttonHeight);
            }

            [button setTitle:title forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:28];

            if ([title isEqualToString:@"="]) {
                button.backgroundColor = [UIColor systemRedColor];
                [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            } else if ([title isEqualToString:@"+"] || [title isEqualToString:@"-"] || [title isEqualToString:@"*"] || [title isEqualToString:@"/"]) {
                button.backgroundColor = [UIColor systemGreenColor];
                [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            } else {
                button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
                [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            }

            button.layer.cornerRadius = buttonHeight / 2;
            button.layer.masksToBounds = YES;
            [button addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:button];
        }
    }
}

- (void)buttonTapped:(UIButton *)sender {
    NSString *title = sender.titleLabel.text;

    if ([title isEqualToString:@"="]) {
        if (self.currentExpression.length == 0) {
            self.displayLabel.text = @"0";
            return;
        }

        NSString *result = [self calculateExpression:self.currentExpression];
        if ([result isEqualToString:@"无法计算"]) {
            self.displayLabel.font = [UIFont systemFontOfSize:18];
        } else {
            self.displayLabel.font = [UIFont systemFontOfSize:48];
        }

        self.displayLabel.text = result;

        NSString *historyEntry = [NSString stringWithFormat:@"%@ = %@", self.currentExpression, result];
        [self.history appendFormat:@"%@\n", historyEntry];
        self.historyLabel.text = self.history;
        self.currentExpression = [NSMutableString stringWithString:result];
    } else if ([title isEqualToString:@"C"]) {
        self.currentExpression = [NSMutableString stringWithString:@""];
        self.displayLabel.text = @"0";
        self.historyLabel.text = @"";
        self.displayLabel.font = [UIFont systemFontOfSize:48];
    } else {
        [self.currentExpression appendString:title];
        self.displayLabel.text = self.currentExpression;
        self.displayLabel.font = [UIFont systemFontOfSize:48];

        if ([self handleSpecialCommand]) return;
    }

    NSString *currentPassword = [self getCurrentPassword];
    if ([self.currentExpression isEqualToString:currentPassword]) {
        [self unlockWithPassword];
    }
}

- (void)resetExpression {
    self.currentExpression = [NSMutableString stringWithString:@""];
    self.displayLabel.text = @"0";
    self.displayLabel.font = [UIFont systemFontOfSize:48];
}

- (BOOL)handleSpecialCommand {
    if ([self.currentExpression isEqualToString:kSettingsCode]) {
        [self resetExpression];
        [self openSettings];
        return YES;
    }
    if ([self.currentExpression isEqualToString:kLinkedAppCode]) {
        [self resetExpression];
        [self handleLinkPassword];
        return YES;
    }
    return NO;
}

- (void)openSettings {
    if (self.presentedViewController != nil) return;
    SettingsViewController *settings = [[SettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)handleLinkPassword {
    NSArray *apps = LinkedAppEntries();
    if (apps.count == 0) {
        [self showError:[NSString stringWithFormat:@"未配置链接 App\n请先输入 %@ 进入设置添加", kSettingsCode]];
        return;
    }
    if (apps.count == 1) {
        [self launchLinkedApp:apps.firstObject];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择要打开的 App"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *info in apps) {
        NSString *name = info[@"name"] ?: info[@"target"];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self launchLinkedApp:info];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)launchLinkedApp:(NSDictionary *)info {
    NSString *target = info[@"target"];
    if (!OpenTargetApp(target)) {
        [self showError:@"无法打开目标 App\n请检查 bundle id 或 URL scheme"];
        return;
    }

    // 8888 只负责跳转，不进入免锁状态：回到本 App 时仍然需要重新解锁。
    // 故意不收起伪装窗口 —— 目标 App 打开后本 App 进入后台；
    // 若跳转被系统静默拦截，也不会把当前 App 暴露出来。
    MarkLocked();
}

- (NSString *)calculateExpression:(NSString *)expression {
    @try {
        NSString *floatExpression = [expression stringByReplacingOccurrencesOfString:@"/" withString:@".0/"];
        floatExpression = [floatExpression stringByReplacingOccurrencesOfString:@"*" withString:@".0*"];

        // 使用 NSExpression 进行运算
        NSExpression *exp = [NSExpression expressionWithFormat:floatExpression];
        id result = [exp expressionValueWithObject:nil context:nil];

        if ([result isKindOfClass:[NSNumber class]]) {
            NSNumber *numberResult = (NSNumber *)result;
            double doubleResult = numberResult.doubleValue;
            if (fmod(doubleResult, 1) == 0) {
                return [NSString stringWithFormat:@"%.0f", doubleResult];  // 整数
            } else {
                return [NSString stringWithFormat:@"%.2f", round(doubleResult * 100) / 100];  // 小数保留两位
            }
        }
        return [NSString stringWithFormat:@"%@", result];
    } @catch (NSException *exception) {
        return @"无法计算";
    }
}

- (NSString *)getCurrentPassword {
    if (self.isCustomPasswordEnabled && self.customPassword) {
        return self.customPassword;
    } else {
        return [self getCurrentTimePassword];
    }
}

- (NSString *)getCurrentTimePassword {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    [formatter setDateFormat:@"HHmm"];
    return [formatter stringFromDate:[NSDate date]];
}

// 密码解锁：置位内存免锁标记，收起伪装窗口
- (void)unlockWithPassword {
    MarkUnlockedWithPassword();
    HideMaskWindow();
}

// 三指双击：自定义密码管理菜单
- (void)showCustomPasswordMenu {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AppMaskCalc"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

    UIAlertAction *setCustomPasswordAction = [UIAlertAction actionWithTitle:@"自定义密码" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self verifyCurrentPasswordBeforeSetting];
    }];

    UIAlertAction *changePasswordAction = [UIAlertAction actionWithTitle:@"关闭自定义" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self verifyCurrentPasswordBeforeDisabling];
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:setCustomPasswordAction];
    [alert addAction:changePasswordAction];
    [alert addAction:cancelAction];

    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = self.view.bounds;

    [self presentViewController:alert animated:YES completion:nil];
}

// 先验证当前密码，然后设置新密码
- (void)verifyCurrentPasswordBeforeSetting {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请输入当前密码"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"当前密码";
        textField.secureTextEntry = YES;
    }];

    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *inputPassword = alert.textFields[0].text;
        if ([inputPassword isEqualToString:[self getCurrentPassword]]) {
            [self setCustomPassword];
        } else {
            [self showError:@"密码不正确"];
        }
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:confirmAction];
    [alert addAction:cancelAction];

    [self presentViewController:alert animated:YES completion:nil];
}

// 设置新密码并保存到 NSUserDefaults
- (void)setCustomPassword {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置自定义密码"
                                                                    message:@"请输入新密码"
                                                             preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"新密码";
        textField.secureTextEntry = YES;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"再次输入新密码";
        textField.secureTextEntry = YES;
    }];

    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newPassword = alert.textFields[0].text;
        NSString *confirmPassword = alert.textFields[1].text;
        if (![newPassword isEqualToString:confirmPassword]) {
            [self showError:@"两次密码不一致"];
            return;
        }
        if (newPassword.length == 0) {
            [self showError:@"密码不能为空"];
            return;
        }
        if ([newPassword isEqualToString:kSettingsCode] || [newPassword isEqualToString:kLinkedAppCode]) {
            [self showError:[NSString stringWithFormat:@"%@ / %@ 为保留指令，请换一个", kSettingsCode, kLinkedAppCode]];
            return;
        }

        self.customPassword = newPassword;
        self.isCustomPasswordEnabled = YES;

        [[NSUserDefaults standardUserDefaults] setObject:self.customPassword forKey:kCustomPasswordKey];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [self showSuccess:@"自定义密码已设置"];
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:confirmAction];
    [alert addAction:cancelAction];

    [self presentViewController:alert animated:YES completion:nil];
}

// 验证当前密码然后关闭自定义密码
- (void)verifyCurrentPasswordBeforeDisabling {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入当前密码"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"当前密码";
        textField.secureTextEntry = YES;
    }];

    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *inputPassword = alert.textFields[0].text;
        if ([inputPassword isEqualToString:[self getCurrentPassword]]) {
            self.isCustomPasswordEnabled = NO;
            self.customPassword = nil;

            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCustomPasswordKey];
            [[NSUserDefaults standardUserDefaults] synchronize];

            [self showSuccess:@"自定义密码已关闭"];
        } else {
            [self showError:@"密码不正确"];
        }
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:confirmAction];
    [alert addAction:cancelAction];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSuccess:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"成功"
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)errorMessage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
                                                                    message:errorMessage
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)hideCustomPasswordMenu {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Settings UI

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AppMaskCalc 设置";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.apps = [LinkedAppEntries() mutableCopy];
    if (self.apps == nil) self.apps = [NSMutableArray array];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(doneTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"锁定";
    if (section == 1) return @"链接 App（8888 解锁跳转）";
    return @"说明";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"仅「密码解锁」后回桌面再回来才计时；8888 / 0123456789 不享受免锁；上划关闭 App 后重开会重新上锁。";
    if (section == 1) return @"从已安装列表选择会自动填入 bundle id；也可手动填写 URL scheme。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return self.apps.count + 1;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    if (indexPath.section == 0) {
        cell.textLabel.text = @"后台免锁时长";
        cell.detailTextLabel.text = @"超过该时长才重新上锁";
        UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 90, 30)];
        valueLabel.text = [NSString stringWithFormat:@"%ld 分钟", (long)GracePeriodMinutes()];
        valueLabel.textAlignment = NSTextAlignmentRight;
        valueLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryView = valueLabel;
    } else if (indexPath.section == 1) {
        if (indexPath.row < (NSInteger)self.apps.count) {
            NSDictionary *info = self.apps[indexPath.row];
            cell.textLabel.text = info[@"name"] ?: @"(未命名)";
            cell.detailTextLabel.text = info[@"target"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"添加 App";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.detailTextLabel.text = @"点按从已安装列表选择，自动填入 bundle id";
        }
    } else {
        cell.textLabel.text = @"输入 0123456789 打开本设置\n输入 8888 解锁并跳转到链接 App（本 App 仍保持锁定）\n时间密码 HHmm 解锁当前 App；回桌面后不超过免锁时长再回来可直接进入\n上划关闭 App 后重新打开会重新上锁\n配置保存在各自 App 内，互不共享";
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self editGracePeriod];
    } else if (indexPath.section == 1) {
        if (indexPath.row < (NSInteger)self.apps.count) {
            [self presentActionsForAppAtIndex:indexPath.row];
        } else {
            [self presentAppPickerForIndex:-1];
        }
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 2) return 150;
    return UITableViewAutomaticDimension;
}

- (void)editGracePeriod {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"后台免锁时长"
                                                                   message:@"单位：分钟。0 表示每次回前台都重新上锁"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"分钟";
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.text = [NSString stringWithFormat:@"%ld", (long)GracePeriodMinutes()];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *text = alert.textFields[0].text;
        NSInteger minutes = text.length > 0 ? [text integerValue] : kDefaultGracePeriodMinutes;
        SetGracePeriodMinutes(minutes);
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentActionsForAppAtIndex:(NSInteger)index {
    NSDictionary *info = self.apps[index];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:(info[@"name"] ?: info[@"target"])
                                                                   message:info[@"target"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"测试跳转" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (!OpenTargetApp(info[@"target"])) {
            UIAlertController *error = [UIAlertController alertControllerWithTitle:@"打开失败"
                                                                            message:@"请检查 bundle id 或 URL scheme 是否正确"
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:error animated:YES completion:nil];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"重新选择 App" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self presentAppPickerForIndex:index];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self.apps removeObjectAtIndex:index];
        SetLinkedAppEntries(self.apps);
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// 打开 App 选择器（push 到设置导航栈，避免多层 modal 导致首次点按异常）
- (void)presentAppPickerForIndex:(NSInteger)index {
    AppPickerViewController *picker = [[AppPickerViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    picker.onSelect = ^(NSDictionary *entry) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"name"] = entry[@"name"] ?: entry[@"target"];
        item[@"target"] = entry[@"target"];

        if (index >= 0 && index < (NSInteger)strongSelf.apps.count) {
            strongSelf.apps[index] = item;
        } else {
            [strongSelf.apps addObject:item];
        }
        SetLinkedAppEntries(strongSelf.apps);
        [strongSelf.tableView reloadData];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

@end

#pragma mark - App Picker

@implementation AppPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择 App";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.allApps = @[];
    self.filteredApps = @[];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"手动输入"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(manualInputTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 60;
    [self.view addSubview:self.tableView];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 52)];
    self.searchBar.placeholder = @"搜索名称或 bundle id";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0);
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    [self loadInstalledApps];
}

- (void)loadInstalledApps {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSDictionary *> *first = InstalledAppEntries();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;

            NSArray<NSDictionary *> *apps = first;
            if (apps.count == 0) {
                // 个别系统上 LaunchServices 查询依赖主线程 runloop，空结果时主线程再试一次
                NSArray<NSDictionary *> *retry = InstalledAppEntries();
                if (retry.count > 0) apps = retry;
            }

            strongSelf.allApps = apps;
            strongSelf.filteredApps = apps;
            [strongSelf.spinner stopAnimating];

            if (apps.count == 0) {
                UILabel *emptyLabel = [[UILabel alloc] initWithFrame:strongSelf.tableView.bounds];
                emptyLabel.text = [NSString stringWithFormat:
                    @"未获取到已安装 App\n诊断：%@\n可点右上角「手动输入」填写 bundle id 或 URL scheme",
                    gInstalledAppsDiagnostics ?: @"-"];
                emptyLabel.textAlignment = NSTextAlignmentCenter;
                emptyLabel.numberOfLines = 0;
                emptyLabel.textColor = [UIColor secondaryLabelColor];
                emptyLabel.font = [UIFont systemFontOfSize:15];
                strongSelf.tableView.backgroundView = emptyLabel;
            } else {
                strongSelf.tableView.backgroundView = nil;
            }
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"appCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    NSDictionary *app = self.filteredApps[indexPath.row];
    NSString *name = app[@"name"];
    NSString *target = app[@"target"];
    cell.textLabel.text = name;
    cell.detailTextLabel.text = [name isEqualToString:target] ? nil : target;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < (NSInteger)self.filteredApps.count) {
        [self finishWithEntry:self.filteredApps[indexPath.row]];
    }
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSString *keyword = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (keyword.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *app in self.allApps) {
            NSString *name = app[@"name"] ?: @"";
            NSString *target = app[@"target"] ?: @"";
            if ([name rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [target rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [matches addObject:app];
            }
        }
        self.filteredApps = matches;
    }
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)finishWithEntry:(NSDictionary *)entry {
    NSString *target = entry[@"target"];
    if (![target isKindOfClass:[NSString class]] || target.length == 0) return;

    NSString *name = entry[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = target;

    NSDictionary *item = @{@"name": name, @"target": target};
    void (^onSelect)(NSDictionary *) = self.onSelect;
    self.onSelect = nil;
    if (onSelect) onSelect(item);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)manualInputTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"手动输入"
                                                                   message:@"填 bundle id（com.xx.xx）或 URL scheme（如 twitter://）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"名称（可留空）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"com.xx.xx 或 twitter://";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        UIAlertController *strongAlert = weakAlert;
        if (strongSelf == nil || strongAlert == nil) return;

        NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSString *name = [strongAlert.textFields[0].text stringByTrimmingCharactersInSet:trimSet];
        NSString *target = [strongAlert.textFields[1].text stringByTrimmingCharactersInSet:trimSet];

        if (target.length == 0) {
            UIAlertController *error = [UIAlertController alertControllerWithTitle:@"错误"
                                                                            message:@"目标不能为空"
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:error animated:YES completion:nil];
            return;
        }
        if (name.length == 0) name = target;

        NSDictionary *entry = @{@"name": name, @"target": target};
        // 等当前 alert 收起后再 pop，避免同时 dismiss/pop 冲突
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf finishWithEntry:entry];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Entry

// 无 hook、无 Substrate：constructor 在宿主 app 的 main() 之前执行，
// 监听 UIApplication / UIScene 生命周期通知，尽早盖上计算器伪装窗口。
__attribute__((constructor)) static void AppMaskCalcEntry(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    // 冷启动一律视为锁定：免锁状态只存在内存里，进程没了就失效。
    // 这样「上划关闭 App 再打开」不会绕过锁屏；只有「Home 回桌面再回来」才享受免锁。
    gUnlocked = NO;
    gLastBackgroundAt = nil;

    // 统一入口：在免锁窗口内且此前已密码解锁，则保持解锁；否则上锁
    void (^evaluateLock)(void) = ^{
        if (CanSkipLock()) {
            gUnlocked = YES;
            HideMaskWindow();
            return;
        }
        MarkLocked();
        if (maskWindow != nil) {
            ResetMaskForLock();
        } else {
            ShowMaskIfNeeded();
        }
    };

    // scene 连接/激活时，仅在需要上锁时构建伪装窗口
    void (^sceneConnectHandler)(NSNotification *) = ^(NSNotification *note) {
        if (gUnlocked) return;
        UIWindowScene *ws = [note.object isKindOfClass:[UIWindowScene class]] ? (UIWindowScene *)note.object : nil;
        PresentMask(ws, NO);
    };
    void (^sceneActivateHandler)(NSNotification *) = ^(NSNotification *note) {
        if (gUnlocked) return;
        UIWindowScene *ws = [note.object isKindOfClass:[UIWindowScene class]] ? (UIWindowScene *)note.object : nil;
        PresentMask(ws, YES);
    };

    // 进入后台：记录离开时刻，供免锁判断使用（仅本进程内有效）
    void (^backgroundHandler)(NSNotification *) = ^(NSNotification *note) {
        RecordBackgroundTime();
    };

    [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        evaluateLock();
    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        evaluateLock();
    }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:backgroundHandler];
    [center addObserverForName:UISceneWillConnectNotification object:nil queue:nil usingBlock:sceneConnectHandler];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:nil usingBlock:sceneActivateHandler];

    // 兜底：极少数时序下 didFinishLaunching 已错过，依据持久化状态决定是否显示（幂等）
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gUnlocked && maskWindow == nil) ShowMaskIfNeeded();
    });
}
