# 请求

2026-11-02：部署 [memory-watch-macos](https://github.com/Shuang-su/memory-watch-macos)，提供 macOS 27 适配更新；用户观察到点云预览相关进程名称变化，且虚拟内存数字显著增大。

用户提供的活动监视器现场：`HydraRenderingService` PID 60749，实际内存约 23.88 GB，虚拟内存约 492.07 GB，路径位于系统 `Hydra.framework`。本机只读检查确认 macOS 27.0（26A428）、物理内存 512 GiB。

本次实现范围：

- 本机部署原生 App，发布 1.2.0 / build 3 更新，提供源码和可下载 arm64 App。
- 覆盖 Hydra 渲染、缩略图、预览以及旧 SceneKit 缩略图、预览五类系统进程；按真实 footprint 自动保护，保留用户关闭选择。
- 随物理内存连续调整阈值，监测 VSZ 增长、系统压力和 swap 增长；后面三类信号只提醒。
- 用户后续校正：VSZ 增长阈值独立设置，16 GiB 物理内存对应 8 GiB、512 GiB 对应 80 GiB，中间连续线性插值；不按 footprint 保护阈值的固定倍数计算。
- 保持其他进程和 Python CLI 只提醒，并完成测试、构建、安装及发布证据记录。

不将“Hydra 只在 macOS 27 改名出现”作为已证实事实，也不将 492 GiB VSZ 解释为 RAM、swap 或 SSD 写入占用。
