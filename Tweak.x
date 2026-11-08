// AppMaskCalc — 通用计算器密码伪装（TrollFools per-app 注入版）
// 基于 telegram-mask（MIT License, Copyright (c) 2024 iOS宝藏 https://t.me/iosrxwy）
// 通用化改造：移除全部 method hook 与 Substrate 依赖，任意 app 注入即生效。
//
// 解锁方式：输入表达式，计算结果等于当前密码即解锁。
//   默认密码 = 当前时间 HHmm（24 小时制，如 14:30 → 1430）
//   三指双击 → 可设置自定义密码（存于本 app 沙箱 NSUserDefaults，每个 app 独立）
//   9999 → 打开设置（免锁时长、链接 App）
//   8888 → 解锁并跳转到链接 App
//
// 构建：macOS 上 `xcrun -sdk iphoneos clang` 直接编译（见 .github/workflows/build.yml）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

// app 从后台回到前台时是否重新上锁：1 = 重新锁（推荐），0 = 仅冷启动时上锁
#define RELOCK_ON_FOREGROUND 1

static NSString * const kCustomPasswordKey = @"customPassword";
static NSString * const kGracePeriodKey = @"com.ccifang.appmaskcalc.gracePeriodMinutes";
static NSString * const kLinkedAppsKey = @"com.ccifang.appmaskcalc.linkedApps";
static NSString * const kUnlockedKey = @"com.ccifang.appmaskcalc.unlocked";
static NSString * const kUnlockedAtKey = @"com.ccifang.appmaskcalc.unlockedAt";
static NSString * const kLastBackgroundKey = @"com.ccifang.appmaskcalc.lastBackgroundAt";

static UIWindow *maskWindow = nil;
static BOOL gUnlocked = NO;

#pragma mark - Settings Storage

static NSUserDefaults *SharedDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

static NSInteger GracePeriodMinutes(void) {
    NSUserDefaults *defaults = SharedDefaults();
    if ([defaults objectForKey:kGracePeriodKey] == nil) return 10;
    NSInteger minutes = [defaults integerForKey:kGracePeriodKey];
    return minutes < 0 ? 10 : minutes;
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

// 解锁状态与进入后台时刻需要跨进程保留：iOS 可能在后台回收本进程，
// 若只放在内存里，10 分钟内被系统杀进程后再进来会被误锁。
static void PersistUnlocked(BOOL unlocked) {
    gUnlocked = unlocked;
    NSUserDefaults *defaults = SharedDefaults();
    [defaults setBool:unlocked forKey:kUnlockedKey];
    if (unlocked) {
        [defaults setObject:[NSDate date] forKey:kUnlockedAtKey];
    } else {
        [defaults removeObjectForKey:kUnlockedAtKey];
        [defaults removeObjectForKey:kLastBackgroundKey];
    }
    [defaults synchronize];
}

static void PersistBackgroundTime(void) {
    [SharedDefaults() setObject:[NSDate date] forKey:kLastBackgroundKey];
    [SharedDefaults() synchronize];
}

// 回前台/冷启动时判断是否仍在免锁窗口内：
// 「已解锁」且（没有离开记录，或离开时长不超过免锁时长）。
// 离开时刻优先用进入后台时间，冷启动没有该记录时回退到解锁时刻，避免强杀后永久免锁。
static BOOL CanSkipLock(void) {
    NSUserDefaults *defaults = SharedDefaults();
    if (![defaults boolForKey:kUnlockedKey]) return NO;

    NSInteger grace = GracePeriodMinutes();
    NSTimeInterval limit = (NSTimeInterval)grace * 60.0;

    NSDate *reference = [defaults objectForKey:kLastBackgroundKey];
    if (![reference isKindOfClass:[NSDate class]]) {
        reference = [defaults objectForKey:kUnlockedAtKey];
    }
    if (![reference isKindOfClass:[NSDate class]]) return NO;

    NSTimeInterval gap = [[NSDate date] timeIntervalSinceDate:reference];
    if (gap < 0) return NO;
    return gap <= limit;
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

static BOOL OpenBundleIdentifier(NSString *bundleID) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass == nil) {
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }
    if (workspaceClass == nil) {
        dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }
    if (workspaceClass == nil) return NO;

    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    id workspace = nil;
    if ([workspaceClass respondsToSelector:defaultSel]) {
        workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSel);
    }
    if (workspace == nil) return NO;

    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if ([workspace respondsToSelector:openSel]) {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bundleID);
    }
    return NO;
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

    if (IsBundleIdentifier(trimmed)) {
        if (OpenBundleIdentifier(trimmed)) return YES;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@://", trimmed];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url != nil) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return YES;
    }
    return NO;
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
    window.windowLevel = UIWindowLevelAlert + 999.0;
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
        [self hideCalculatorView];
    }
}

- (void)resetExpression {
    self.currentExpression = [NSMutableString stringWithString:@""];
    self.displayLabel.text = @"0";
    self.displayLabel.font = [UIFont systemFontOfSize:48];
}

- (BOOL)handleSpecialCommand {
    if ([self.currentExpression isEqualToString:@"9999"]) {
        [self resetExpression];
        [self openSettings];
        return YES;
    }
    if ([self.currentExpression isEqualToString:@"8888"]) {
        [self resetExpression];
        [self handleLinkPassword];
        return YES;
    }
    return NO;
}

- (void)openSettings {
    SettingsViewController *settings = [[SettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)handleLinkPassword {
    NSArray *apps = LinkedAppEntries();
    if (apps.count == 0) {
        [self showError:@"未配置链接 App\n请先输入 9999 进入设置添加"];
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
    if (OpenTargetApp(target)) {
        // 跳转成功后再收起伪装窗口；失败则保留计算器并提示，避免回到未解锁状态
        [self hideCalculatorView];
    } else {
        [self showError:@"无法打开目标 App\n请检查 bundle id 或 URL scheme"];
    }
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

// 解锁：收起伪装窗口，并把宿主 app 原本的窗口恢复为 key window
- (void)hideCalculatorView {
    HideMaskWindow();
    PersistUnlocked(YES);
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
        if ([newPassword isEqualToString:@"9999"] || [newPassword isEqualToString:@"8888"]) {
            [self showError:@"9999 / 8888 为保留指令，请换一个"];
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
            cell.detailTextLabel.text = @"填写 bundle id 或 URL scheme";
        }
    } else {
        cell.textLabel.text = @"输入 9999 打开本设置\n输入 8888 解锁并跳转到链接 App\n时间密码 HHmm 照常解锁当前 App\n配置保存在各自 App 内，互不共享";
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
            [self addOrEditAppAtIndex:-1];
        }
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 2) return 120;
    return UITableViewAutomaticDimension;
}

- (void)editGracePeriod {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"后台免锁时长"
                                                                   message:@"单位：分钟，0 表示每次回前台都重新上锁"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"分钟";
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.text = [NSString stringWithFormat:@"%ld", (long)GracePeriodMinutes()];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *text = alert.textFields[0].text;
        NSInteger minutes = text.length > 0 ? [text integerValue] : 10;
        if (minutes < 0) minutes = 0;
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
        OpenTargetApp(info[@"target"]);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"编辑" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self addOrEditAppAtIndex:index];
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

- (void)addOrEditAppAtIndex:(NSInteger)index {
    BOOL editing = index >= 0;
    NSDictionary *existing = editing ? self.apps[index] : nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(editing ? @"编辑链接 App" : @"添加链接 App")
                                                                   message:@"目标填 bundle id（com.xx.xx）或 URL scheme（如 twitter://）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"名称";
        textField.text = existing[@"name"];
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"com.xx.xx 或 twitter://";
        textField.text = existing[@"target"];
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *target = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (target.length == 0) return;
        if (name.length == 0) name = target;

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"name"] = name;
        item[@"target"] = target;

        if (editing) {
            self.apps[index] = item;
        } else {
            [self.apps addObject:item];
        }
        SetLinkedAppEntries(self.apps);
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Entry

// 无 hook、无 Substrate：constructor 在宿主 app 的 main() 之前执行，
// 监听 UIApplication / UIScene 生命周期通知，尽早盖上计算器伪装窗口。
__attribute__((constructor)) static void AppMaskCalcEntry(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    // 进程可能在后台被回收，constructor 执行时先按持久化状态恢复解锁标记
    gUnlocked = CanSkipLock();

    // 统一入口：在免锁窗口内且此前已解锁，则保持解锁；否则上锁
    void (^evaluateLock)(void) = ^{
        if (CanSkipLock()) {
            gUnlocked = YES;
            HideMaskWindow();
            return;
        }
        PersistUnlocked(NO);
        ShowMaskIfNeeded();
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

    // 进入后台：记录时刻，保留 unlocked 标记供免锁判断
    void (^backgroundHandler)(NSNotification *) = ^(NSNotification *note) {
        PersistBackgroundTime();
    };

    [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        evaluateLock();
    }];
#if RELOCK_ON_FOREGROUND
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        evaluateLock();
    }];
#endif
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:backgroundHandler];
    [center addObserverForName:UISceneWillConnectNotification object:nil queue:nil usingBlock:sceneConnectHandler];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:nil usingBlock:sceneActivateHandler];

    // 兜底：极少数时序下 didFinishLaunching 已错过，依据持久化状态决定是否显示（幂等）
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gUnlocked && maskWindow == nil) ShowMaskIfNeeded();
    });
}
