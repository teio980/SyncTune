# SyncTune 计划符合性审查（最终复核）

日期：2026-10-07

本轮审查覆盖 `lib/app/`、`lib/infrastructure/composition/`、
`lib/infrastructure/runtime/`、`lib/main.dart` 及其正式测试。app/composition
修复由本轮负责；core/data/platform 的最终测试和构建证据由 root 线程独立提供，
本轮没有修改这些目录。审查只做文件和测试验证，没有启动应用、模拟器或设备，
也没有进行 ADB、安装运行、证书、系统修改或外部消息发送。

## 已符合或已有实现证据

- 应用层按 shell、音乐、同步、设置和 ViewModel 拆分，Material 3 主题使用
  `#4F46E5` seed，并提供 light/dark/system（默认 system）。
- 统一 spacing、圆角和最小交互尺寸 token 已集中定义；主题现在显式为
  FilledButton、OutlinedButton、TextButton 和 IconButton 提供 48px 命中区。
  正式 widget 回归覆盖 Windows 与 Android target platform，并覆盖 200% 文本
  和 320/599/600/999/1000px 布局。
- 生产组合绑定真实 Drift 数据库、catalog UUID、favorites Lamport/device 状态、
  WebDAV 客户端租约、凭据 broker、PlanStore、JournalStore 和 baseline。
- WebDAV 密码只写入平台凭据 broker；数据库只保存非 secret 字段、版本化
  credential pointer 和 epoch。保存失败保留旧 pointer/secret。
- slow `load()` 在较新的 save 后不会回写旧 namespace/credential epoch；显式空
  pointer 不会再回退读取 legacy secret。正式 composition tests 覆盖这两项。
- 配置 client 在显式清空凭据后 fail-closed；缺失 pointer 的 legacy 记录仍能恢复。
  queued save 中每次实际 DB commit 都会发布对应 namespace/credential epoch，后续
  保存失败不会隐藏已经 durable 的配置。composition remote wrapper 透传
  `RemotePlanRecovery`，在 recovery await 返回前后都检查 root、generation、namespace
  和 credential epoch；delayed remote request 中途切换这三类 target 的正式回归均
  拒绝 stale recovery。
- credential cleanup 失败不会回滚已提交的 DB pointer，并通过 settings warning
  port 对用户显示“当前设置仍已生效”的清理警告。
- root、config epoch 和 credential epoch 会参与 runtime target identity；变化会
  取消旧运行。runtime 支持 startup、resume、manual、retry 和前台 15 分钟调度，
  手动请求合并且不会重叠，dispose 会等待 in-flight run/check 收尾。
- 初始化错误现在由 composition 传入 shell，在界面顶部可见；这避免数据库或同步
  服务初始化失败时只留下静默的 disabled state。
- recovery helper、favorite-stall 路径和 WebDAV formal recovery 已由 core/data
  方向完成；正式 `test/webdav_recovery_test.dart` 的 13 个故障恢复 cases 通过。

## 当前仍不符合或未完成

- 生产同步 gate 默认保持关闭，只有真实 runtime evidence、native capability 和
  WebDAV PROPFIND/探测全部通过才会开放；本轮没有用注入的 fake gate 解锁生产路径。
- Android 的 conditional create/replace/delete 仍标记为 unsupported SAF provider；
  Windows 的 conditional replace/delete 仍标记为 unsupported AppContainer provider。
  因此不能以 capability 字符串或单次 PROPFIND 结果伪造可用。
- Windows AppContainer 的真实 runtime evidence 尚未完成验证；本轮没有启动设备或
  应用进行复验。Android APK、Windows Release 和 unsigned MSIX 仅完成构建/打包，
  没有安装或运行，因此不能视为平台 runtime 验收结果。
- 外部普通 WebDAV 文件的 adoption/reconcile 用户流程尚未完成；当前适配器要求
  SyncTune identity metadata，未授权的普通文件不会被后台扫描隐式采用。

## 本轮验证

最终监督日志显示：`build/review/resumed-final-flutter-analysis.log` 为
`No issues found!`；`build/review/resumed-final-flutter-tests.log` 为
`+112 All tests passed!`；`build/review/resumed-final-core-analysis.log` 无问题，
`build/review/resumed-final-core-tests.log` 为 `+32 All tests passed!`。当前
`test/webdav_recovery_test.dart` 独立正式回归为 `+13 All tests passed!`；本轮
composition/runtime/settings/UI 与 race/atomicity targeted 集合（含新增
post-await guard cases）为 `+39 All tests passed!`，desktop Windows 48px audit
为 `+1`。

平台构建日志也均以 exit 0 完成：
`build/review/resumed-final-android-build.log` 生成 56.4MB Release APK；
`build/review/resumed-final-windows-build.log` 生成 Windows Release executable；
`build/review/resumed-final-msix-build.log` 成功生成 unsigned MSIX。三者都只
证明 build/package，没有安装或运行证据。本轮没有启动应用、模拟器或设备，cloud
CI 尚未运行。

这些结果证明当前源码的静态分析、正式 Flutter/core tests、恢复回归和构建链路
通过，但不表示完整计划已经符合：生产 gate/CAS 条件仍关闭，平台真实 runtime
evidence、普通 WebDAV adoption/reconcile UI、Git history cleanup 和 cloud CI 仍
待完成。

```text
flutter test test/composition_test.dart \
  test/foreground_sync_runtime_test.dart \
  test/settings_view_model_test.dart \
  test/responsive_ui_test.dart \
  build/review/settings_load_race_audit_test.dart \
  build/review/settings_atomicity_review_test.dart
```

