// AppMaskCalc — 通用计算器密码伪装（TrollFools per-app 注入版）
// 基于 telegram-mask（MIT License, Copyright (c) 2024 iOS宝藏 https://t.me/iosrxwy）
// 通用化改造：移除全部 method hook 与 Substrate 依赖，任意 app 注入即生效。
//
// 解锁方式：输入表达式，计算结果等于当前密码即解锁。
//   默认密码 = 当前时间 HHmm（24 小时制，如 14:30 → 1430）
//   三指双击 → 可设置自定义密码（存于本 app 沙箱 NSUserDefaults，每个 app 独立）
//
// 构建：Theos (library.mk)，产物 .theos/obj/*.dylib

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// app 从后台回到前台时是否重新上锁：1 = 重新锁（推荐），0 = 仅冷启动时上锁
#define RELOCK_ON_FOREGROUND 1

static NSString * const kCustomPasswordKey = @"customPassword";

@class CalculatorViewController;

static UIWindow *maskWindow = nil;

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

// 幂等：已存在伪装窗口或找不到前台 scene 时直接返回
static void ShowMaskIfNeeded(void) {
    if (maskWindow != nil) return;

    UIWindowScene *scene = MaskForegroundScene();
    if (scene == nil) return;

    CalculatorViewController *calcVC = [[CalculatorViewController alloc] init];
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = [UIScreen mainScreen].bounds;
    window.rootViewController = calcVC;
    window.windowLevel = UIWindowLevelAlert + 999.0;
    [window makeKeyAndVisible];

    maskWindow = window;
}

#pragma mark - Calculator UI

@interface CalculatorViewController : UIViewController
@property (nonatomic, strong) UILabel *displayLabel;
@property (nonatomic, strong) UILabel *historyLabel;
@property (nonatomic, strong) NSMutableString *currentExpression;
@property (nonatomic, strong) NSMutableString *history;
@property (nonatomic, strong) NSString *customPassword;
@property (nonatomic, assign) BOOL isCustomPasswordEnabled;
@end

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
    }

    NSString *currentPassword = [self getCurrentPassword];
    if ([self.currentExpression isEqualToString:currentPassword]) {
        [self hideCalculatorView];
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
    UIWindow *window = maskWindow;
    if (window != nil) {
        maskWindow = nil;
        window.rootViewController = nil;
        window.hidden = YES;
    }

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
        if ([newPassword isEqualToString:confirmPassword]) {
            self.customPassword = newPassword;
            self.isCustomPasswordEnabled = YES;

            [[NSUserDefaults standardUserDefaults] setObject:self.customPassword forKey:kCustomPasswordKey];
            [[NSUserDefaults standardUserDefaults] synchronize];

            [self showSuccess:@"自定义密码已设置"];
        } else {
            [self showError:@"两次密码不一致"];
        }
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

#pragma mark - Entry

// 无 hook、无 Substrate：constructor 在宿主 app 的 main() 之前执行，
// 监听 UIApplication 生命周期通知，在 app 启动/回前台时盖上一层计算器伪装窗口。
__attribute__((constructor)) static void AppMaskCalcEntry(void) {
    void (^showMask)(NSNotification *) = ^(NSNotification *note) {
        ShowMaskIfNeeded();
    };

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil queue:nil usingBlock:showMask];
#if RELOCK_ON_FOREGROUND
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil queue:nil usingBlock:showMask];
#endif

    // 兜底：极少数时序下 didFinishLaunching 已错过，scene 就绪则直接显示（幂等）
    dispatch_async(dispatch_get_main_queue(), ^{
        ShowMaskIfNeeded();
    });
}
