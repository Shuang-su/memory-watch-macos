# Changelog

## 1.2.0

- 补充 macOS 27 的 `HydraRenderingService`、`HydraQLThumbnailExtension`、`HydraQLPreviewExtension` 自动保护，并保留 SceneKit 缩略图、补充 SceneKit 预览保护。
- 按物理内存连续线性设置阈值：16 GiB Mac 的普通提醒/严重/保护为 2/4/4 GiB，512 GiB Mac 为 10/20/20 GiB，两端之外钳位；普通提醒宽松模式不改变保护阈值。
- 分别采集 footprint、RSS 和 VSZ；对同一实例首次有效采样后的 VSZ 增长提醒，阈值按物理内存独立线性变化（16 GiB Mac 为 8 GiB，512 GiB Mac 为 80 GiB），恢复监控或实例变化时重建基线，VSZ 不单独触发退出。
- 增加连续两轮异常系统压力、60 秒内 swap 增长至少 1 GiB 的提醒，不归因单进程、不单独触发退出。
- 自动保护继续复核准确系统路径、当前用户、PID、启动时间和实时 footprint，保留退出确认和失败重试限流；迁移旧开关时保留已关闭选择，暂停覆盖全部检测和自动处理。
- Python CLI 使用自适应默认值并支持显式覆盖，新增诊断与提醒，保持只提醒。
- 版本/构建号更新为 1.2.0 / 3，发布包保持 Apple Silicon、macOS 13+，本机适配验证目标为 macOS 27.0（26A428）。

## 1.1.0

- 默认自动强制退出达到 4 GiB 的当前用户系统 `SceneKitQLThumbnailExtension`，其他进程保持只提醒。
- 发送信号前复核进程身份与内存占用，处理后确认退出状态并通知、记录结果。
- 增加可持久保存的自动保护开关；暂停监控同时暂停自动处理。
- 增加阈值边界、PID 重用、路径/用户校验、失败重试和一次性子进程真实 SIGKILL 测试。

## 1.0.0

- 原生 macOS 顶栏 App：固定宽度纯图标，异常变红、恢复还原。
- 进程高占用和快速增长检测，系统通知与重复提醒限流。
- 登录自启动、暂停、宽松阈值和容量有界的本地日志。
- 可选 Python 监控脚本、检测逻辑测试、可复现构建与安装脚本。
- 首个发布包：macOS 13+，Apple Silicon，ad-hoc 签名。
