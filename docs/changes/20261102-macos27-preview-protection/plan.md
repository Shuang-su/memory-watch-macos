# 1.2.0 实施计划

## 采集和提醒

- 每 5 秒采样，分开记录 `ri_phys_footprint`、RSS 和 VSZ。footprint 是普通高占用和自动退出的依据；权限失败或实例消失按不可读取处理。
- 按物理内存 `R`（GiB）计算 `L = clamp(4 + (R - 16) × 16 / 496, 4, 20)` GiB。普通 warn 为 `L/2`、critical 为 `L`，预览保护为 `L`；宽松模式只把普通 warn/critical 加倍。
- 五类预览进程的 VSZ 增长提醒阈值独立计算为 `V = clamp(8 + (R - 16) × 72 / 496, 8, 80)` GiB，以同一 PID/启动时间实例的首次有效采样为基线；暂停后恢复以及 PID 重用/实例变化时重建。16 GiB 主机为 8 GiB，512 GiB 主机为 80 GiB。既有巨大 VSZ 不触发首次提醒，不基于 VSZ 发送信号。
- 系统压力连续两轮异常或系统 swap 使用在 60 秒内增长至少 1 GiB 时提醒。全局指标不归因某进程，也不单独触发退出。
- 保留 footprint 高占用、增长、冷却、严重程度提升及恢复提示；暂停覆盖全部检测与保护。

## 自动保护

- 精确允许 `HydraRenderingService`、`HydraQLThumbnailExtension`、`HydraQLPreviewExtension`、`SceneKitQLThumbnailExtension`、`SceneKitQLPreviewExtension` 五类系统可执行文件及当前用户。
- 发送 SIGKILL 前重新核对路径、UID、PID、启动时间和当前 footprint；任何身份变化、读取失败或占用回落都跳过。
- 保留信号结果、退出确认以及同一实例失败/未确认后至少 60 秒重试限制。
- 默认开启保护；迁移原 `autoExitSceneKit` 设置，旧版已关闭时仍保持关闭。用户可通过菜单保存开关选择。
- Python CLI 共用自适应默认阈值，保留显式参数覆盖；CLI 始终只提醒。

## 验证与交付

- 原生和 Python 测试覆盖公式两端与中间值、五类路径匹配、阈值边界、实例变化、权限失败、当前 footprint 回落、开关迁移和暂停。
- VSZ 测试覆盖首次大值不报、同实例增长、恢复/PID 重用重建；系统指标测试覆盖两轮压力、swap 时间窗口、不可读取及恢复。
- 构建 1.2.0 / build 3 arm64、macOS 13+ App，校验签名和安装配置；在本机 macOS 27.0 验证 snapshot、运行、日志和登录自启动。
- 使用一次性子进程验证真实信号与退出确认；不制造内存耗尽。真实 Hydra 处理是否发生以独立现场日志为准，不用自测冒充。
- 更新 README、Changelog、完成记录，通过 GitHub issue/PR 记录变更并发布 App 压缩包和校验值。
