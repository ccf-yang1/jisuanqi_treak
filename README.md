# AppMaskCalc

通用「计算器密码伪装」dylib。注入哪个 app，哪个 app 打开就变成一台计算器，只有算出正确密码才会露出真正的 app。

基于 [telegram-mask](https://t.me/iosrxwy)（MIT，作者 iOS宝藏）改造：移除了全部 method hook 与 Substrate 依赖，改为纯通知监听 + 顶层窗口覆盖，因此可以通过 TrollFools 注入任意 app，每个 app 独立生效。

## 解锁方式

输入表达式，计算结果等于当前密码即解锁（按 `=` 时判断）：

- 默认密码：当前时间 `HHmm`，24 小时制。例如 14:30 就要让结果等于 `1430`（如 `143*10`、`286*5`）
- 三指双击：设置/关闭自定义密码（需先验证当前密码），保存在该 app 自己的沙箱里，每个 app 独立
- 双指双击：收起弹窗菜单

## 使用（TrollFools 注入）

1. 在 [Releases](../../releases) 下载 `AppMaskCalc.dylib`（或从 Actions 的 artifact 下载）
2. 安装 [TrollFools](https://github.com/Lessica/TrollFools)（需 TrollStore 环境或对应支持范围）
3. 在 TrollFools 中选择目标 app（如「照片」）→ 注入 dylib → 选 `AppMaskCalc.dylib`
4. 打开该 app，看到计算器即成功

建议先用不重要的 app 测试（如「照片」）。银行、支付类 app（支付宝等）有风控和崩溃风险，注入前请自行评估。

## 行为说明

- 冷启动必上锁；`RELOCK_ON_FOREGROUND` 默认为 `1`（从后台回到前台重新上锁），改为 `0` 则仅冷启动上锁
- 解锁状态持续到进程被杀；上划杀掉 app 重开即恢复伪装
- iOS 18+ 自带 App Lock，无需本插件

## 本地构建

```bash
export THEOS=~/theos
make FINALPACKAGE=1
# 产物 .theos/obj/*.dylib
```

推送代码到 main 后 GitHub Actions 会自动构建，同时产出 artifact 和 Release。

## 致谢

- [telegram-mask](https://t.me/iosrxwy) — iOS宝藏，原版逻辑与界面
- [Theos](https://github.com/theos/theos) — 构建工具链
- [TrollFools](https://github.com/Lessica/TrollFools) — 注入工具

## 免责声明

仅供学习研究。时间密码为弱口令，请勿依赖本工具保护重要数据。对注入导致的任何 app 异常（包括风控、封号）概不负责。
