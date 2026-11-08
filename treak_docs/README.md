# TrollFools 注入式 Tweak 开发与编译经验

本文档总结本仓库（AppMaskCalc，从 telegram-mask 通用化改造）开发与 CI 构建的全部踩坑经验，供后续构建其他注入式 tweak 时参考（人类与 AI Agent 均适用）。

## 1. 两种 tweak 模式的区别

| | 越狱 tweak（原版 telegram-mask） | TrollFools per-app 注入（本仓库） |
|---|---|---|
| 加载方式 | Substrate/ElleKit 全局 hook | dylib 链进单个 app（LC_LOAD_DYLIB） |
| 依赖 | 依赖 libsubstrate / CaptainHook | 零依赖（纯 ObjC + 系统 framework） |
| 作用范围 | 全系统 | 仅被注入的 app |
| 适用环境 | 越狱设备 | TrollStore 环境（iOS 14–16.6.1 / 部分 17.0） |

**结论**：面向 TrollFools 的 tweak 应完全不使用 Logos（`%hook`）与 CaptainHook，产物就是普通 dylib。

## 2. 从 hook 版改造为无 hook 版的通用套路

原版 telegram-mask 的通用化硬伤（改造任何越狱 tweak 时都要排查同类问题）：

1. `CHLoadLateClass(AppDelegate)` 按类名硬编码 —— 只对 Telegram 生效，换 app 直接落空
2. hook 私有/第三方属性（`%hook CALayer` 调 `asyncdisplaykit_node`）在非目标 app 必崩（unrecognized selector）
3. 修改 `delegate.window` 会破坏宿主 app 窗口管理

**无 hook 替代模式**（伪装/锁屏类需求标准做法）：

```objc
__attribute__((constructor)) static void Entry(void) {
    // constructor 在宿主 app main() 之前执行，此时注册通知来得及
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) { ShowMaskIfNeeded(); }];
}
```

- 用 `UIApplicationDidFinishLaunchingNotification`（代替 hook `application:didFinishLaunchingWithOptions:`）
- 用 `UIApplicationWillEnterForegroundNotification` 实现回前台重新上锁
- UIWindow 用 `[[UIWindow alloc] initWithWindowScene:]`（iOS 13+，TrollStore 最低 14，无需兼容分支），`windowLevel = UIWindowLevelAlert + 999`
- 窗口用全局静态变量自管理：解锁时 `rootViewController = nil; hidden = YES;` 并把 scene 内原有未隐藏窗口 `makeKeyWindow` 恢复回去
- 显示逻辑必须幂等（`if (maskWindow != nil) return;`），didFinishLaunching 与 constructor 兜底可能双触发
- 数据隔离：NSUserDefaults 天然 per-app 沙箱，存进去的数据每个被注入的 app 各自独立，无需额外处理

## 3. CI 构建方案（重点踩坑记录）

### 方案 A（推荐，本仓库 build-6 成功版）：macos-latest + xcrun clang 直编

适用于**无 Logos 语法**的纯 ObjC/ObjC++ tweak（.x / .xm 源文件）：

```yaml
runs-on: macos-latest
steps:
  - uses: actions/checkout@v4
  - name: Build
    run: |
      xcrun -sdk iphoneos clang -arch arm64 -fobjc-arc \
        -dynamiclib -framework UIKit -framework Foundation \
        -miphoneos-version-min=14.0 \
        -x objective-c Tweak.x -o AppMaskCalc.dylib
      codesign --force --sign - AppMaskCalc.dylib
```

要点：
- `-x objective-c` 必须加：clang 无法从 `.x` 后缀推断语言
- `-arch arm64` 足够（App Store app 全是 arm64 slice）；arm64e 仅系统进程需要
- `codesign --force --sign -` 做 ad-hoc 签名，TrollFools 注入加载更稳
- fmod/round 等 libm 符号在 libSystem 里，无需 `-lm`
- 完整模板见本仓库 `.github/workflows/build.yml`（含 upload-artifact + gh release 发布，手机 Safari 可直接从 Release 下载）

参考成功案例：`ccf-yang/testdylib`（同样是 macos runner + xcrun 直编）。

### 方案 B：Linux runner + Theos —— 已验证不可行，原因如下

依次踩到的三个坑，供排查类似问题：

1. **vendor 检查失败**：Theos 的 `makefiles/master/rules.mk` 检查 `$THEOS/vendor/include/.git` 和 `$THEOS/vendor/lib/.git` 的存在（是 `.git` 目录，不是目录本身）。`mkdir` 空目录、甚至 clone theos/vendor 到该位置都会因 theos 仓库自带非空 vendor 目录而失败。正确做法：vendor 是 git submodule，必须 `git clone --recursive --depth 1 --shallow-submodules https://github.com/theos/theos.git`
2. **工具链缺失**：过了 vendor 检查后报 `theos/toolchain/linux/iphone/bin/clang: No such file or directory` —— Linux runner 上没有现成的 iOS 交叉编译工具链，theos 的 toolchain submodule 在 linux/iphone 下为空。补齐需要手动装第三方交叉工具链，成本高、收益低
3. **结论**：Linux + Theos 只适合构建非 iOS 产物。iOS dylib 要么走方案 A，要么 macos runner 上装完整 Theos（见下）

### 方案 C：macos runner + 完整 Theos（有 Logos 语法时用）

如果源码用了 `%hook`（不想改写成无 hook 版），在 macos-latest 上：

```bash
brew install ldid
git clone --recursive --depth 1 --shallow-submodules https://github.com/theos/theos.git $HOME/theos
export THEOS=$HOME/theos
# sdks：git clone --depth 1 https://github.com/theos/sdks.git $THEOS/sdks
make FINALPACKAGE=1
```

macOS 自带 Xcode iOS SDK 与 clang，Theos 在 macOS 上工作正常。产物在 `.theos/obj/*.dylib`。

## 4. ObjC 源码注意事项（CI 编译错误实录）

1. **声明顺序**：单文件编译（无 pch）下，`@class Foo;` 前向声明不足以实例化（`[[Foo alloc] init]` 报 "receiver is a forward declaration"）。完整 `@interface` 必须放在首次使用之前。本次 build 失败一例即此
2. **ARC**：加 `-fobjc-arc`。UIAlertController/NSExpression 等 API 与 ARC 兼容，直接照搬旧代码即可
3. **deprecated API**：`[UIApplication sharedApplication].keyWindow` 会告警，方案 A 的 clang 默认不致命；能避开就避开（本仓库用自管理 maskWindow 方式完全避开了 keyWindow）
4. **通知 block 签名**：`addObserverForName:object:queue:usingBlock:` 的 block 类型为 `void (^)(NSNotification *)`，queue 传 nil 时在发帖线程（主线程）同步执行，操作 UIKit 安全

## 5. 真机使用与验证清单

1. 下载 Release 的 dylib（或 Actions artifact）
2. 安装 TrollFools（https://github.com/Lessica/TrollFools），选择目标 app → 注入 dylib
3. 打开 app 验证：窗口置顶、计算器 UI、时间密码解锁（HHmm 24 小时制，如 14:30 → 算出 1430 的任意表达式）
4. 三指双击设置自定义密码（per-app 独立）；双指双击收起菜单
5. 测试顺序建议：相册等无风控 app 先试 → 普通 app → 银行/支付类最后（有风控与崩溃风险，自行评估）
6. iOS 18+ 自带 App Lock，无需本类插件

## 6. 本仓库相关

- 原版：telegram-mask（iOS宝藏，https://t.me/iosrxwy ，MIT License —— 改造/分发务必保留其版权声明）
- 行为开关：`Tweak.x` 顶部 `RELOCK_ON_FOREGROUND`（1 = 回前台重新上锁，0 = 仅冷启动上锁）
- 构建产物：AppMaskCalc.dylib（arm64，min iOS 14.0，ad-hoc 签名）
- Release 命名规则：`build-<run_number>`，每次 push main 自动构建并发布

## 7. 免锁时长、设置页与链接 App（v1.1 新增）

### 7.1 后台免锁时长

`UIApplicationWillEnterForeground` 时不再无条件上锁，而是比较「离开时刻」与当前时间的间隔：

- 间隔 ≤ 免锁时长（默认 10 分钟）且本次已解锁 → 直接进入，不弹计算器
- 间隔超过阈值 → 重新上锁

关键符号：`CanSkipLock()` 统一决策、`PersistUnlocked()` / `PersistBackgroundTime()` 负责持久化、`GracePeriodMinutes()` 读取配置。免锁时长存于 `NSUserDefaults` 的 `com.ccifang.appmaskcalc.gracePeriodMinutes`，`0` 表示每次回前台都重新上锁（等价旧行为）。

状态跨进程持久化的原因：iOS 可能在后台回收 app 进程，若只把「已解锁」放在内存变量里，10 分钟内被系统杀进程后再进来会被误锁。因此同时持久化 `unlocked`、`unlockedAt`、`lastBackgroundAt` 三个键。冷启动若没有 `lastBackgroundAt`，用 `unlockedAt` 兜底，避免强杀后永久免锁。

注意：若用户从未解锁过（`unlocked == NO`），从后台回来仍会上锁。

### 7.2 设置页（9999）

在计算器输入 `9999` 打开设置页，可修改免锁时长、增删链接 App。设置页是可关闭的 modal，不依赖宿主 app 的任何控制器。

### 7.3 链接 App（8888）

输入 `8888` 会先解锁当前 app，再跳转到配置的目标 app。目标支持：

- 完整 URL：`twitter://messages`
- URL scheme：`twitter://`
- bundle id：`com.tencent.xin`（走私有 `LSApplicationWorkspace openApplicationWithBundleID:`，需要 `dlopen` 私有 framework）

配置了多个目标时弹出选择列表，只有一个时直接跳转。跳转权限依赖宿主 app 的 `LSApplicationQueriesSchemes`；bundle id 方式通常比 URL scheme 更通用。

**限制**：`openApplicationWithBundleID:` 属私有 API，App Store 审核会拒绝；TrollStore 注入场景可用。部分系统 app 或被系统限制的 app 可能拒绝跳转。

### 7.4 启动瞬间的宿主图标闪过（问题 3）

TrollFools 注入的 dylib 在宿主 app 进程内加载，加载时机晚于系统显示启动图（LaunchScreen/Splash）的阶段，因此 X、Instagram 等应用的图标/启动页会先于计算器出现一小段时间。这属于**系统级启动流程**，dylib 无法完全消除，只能通过提前挂窗口缩短：

- 监听 `UISceneWillConnectNotification`（早于 `didFinishLaunching`），用对应 scene 先创建伪装 window（不抢 key）
- 监听 `UISceneDidActivateNotification` 再 `makeKeyAndVisible`，确保盖在最前
- 无法使用 `UIApplicationMain` 替换或 launch 前 hook（TrollFools 不提供该时机，且会破坏宿主）

若希望完全无闪屏，唯一彻底方案是在越狱环境用 Tweak 修改宿主 Info.plist 的启动图，或用 iOS 18 原生 App Lock。注入方案只能做到「尽量早、尽量短」。
