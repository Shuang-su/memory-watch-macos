# 1.2.0 完成记录

状态：核心实现、本机安装和测试已验证；界面复核及 GitHub PR/CI/Release 仍在进行，待完成项不能视为通过或已交付。

## 已核查的现场证据

- 2026-11-02 本机系统为 macOS 27.0（26A428），物理内存 549,755,813,888 B（512 GiB）。
- `HydraRenderingService` PID 60749 是 `com.apple.HydraRenderingService`，位于系统 Hydra.framework，签名链为 macOS Software Signing → Apple Code Signing Certification Authority → Apple Root CA。
- Hydra 预览和缩略图扩展的系统 Info.plist 均声明支持 `public.polygon-file-format`（PLY），同时支持 USD、OBJ、STL、Alembic 等格式。
- 约 15:02（Asia/Shanghai）采样：footprint 25,628,069,208 B（约 23.87 GiB），RSS 25,643,057,152 B（约 23.88 GiB），VSZ 约 492.07 GiB。
- `vmmap -summary 60749` 显示 385.0 GiB Guard 区域的 resident/dirty/swapped 均为 0；writable regions 写入约 23.8 GiB，swapped_out 为 0 KiB。全系统 `vm.swapusage` 使用 11.75 MiB。
- `proc_pid_rusage` 的 `RUSAGE_INFO_V0` 在当前用户 Hydra/QuickLook 进程可无 sudo 读取 footprint、RSS 和启动标识；PID 1 返回 EPERM，应作为不可读取处理。

上述数据说明 VSZ 不能等同于物理占用、swap 或 SSD 写入；也不足以证明某个已关闭的文件是该占用的唯一来源。

## 变更

- 五类系统预览进程自动保护，footprint 阈值按物理内存连续线性设置，迁移旧版开关时保留已关闭选择。
- VSZ 增长阈值独立线性设置为 8–80 GiB；连续系统压力和 60 秒内 swap 增长提醒保持只提醒。Python CLI 保持只提醒并兼容本机 Python 3.9.6。
- 文档已补充现场证据、指标解释、计划和兼容边界。

## 验证与部署

- 原生 App 本机构建成功，三组原生自测通过。
- Python 回归 23 项测试在实际 Python 3.9.6 环境全部通过；安装器 7 项隔离故障测试通过。
- 1.2.0 / build 3 已安装到 `~/Applications/Memory Watch.app`，安装位置的 `codesign --verify --strict` 通过。
- 当前用户 LaunchAgent 的 `RunAtLoad` 为 true，使用 `/usr/bin/open` 启动 App，最近退出状态为 0；安装后已核对准确安装路径对应的 App 进程运行（初次核对 PID 13106，重装后 PID 可变化）。
- 2026-11-02 16:12:41（Asia/Shanghai；08:12:41Z），现场自动保护日志记录向真实 `HydraRenderingService` PID 60749 发送 SIGKILL：footprint 23.867999 GiB，阈值 20 GiB，`errno=0`。500 ms 退出检查结果为 `unconfirmed`，日志没有把信号成功等同于已退出；后续 `ps` 和独立 CLI 检查均确认原 PID 60749 已消失。
- 通知最初被系统关闭；通过系统设置开启“内存提醒”通知后，`--test-notification` 返回 `authorized=true delivered=true`，退出码为 0。
- GitHub 跟踪 [Issue #1](https://github.com/Shuang-su/memory-watch-macos/issues/1) 已创建。
- 待完成：无窗口 App 的菜单/辅助功能界面复核和最终重新安装后的状态确认。
- 待完成：GitHub PR、CI、合并提交、Release、最终压缩包校验值。

## 边界

- footprint 可包括已压缩或交换的计账，RSS 只表示常驻页，VSZ 包含未使用的虚拟地址保留；三者不互相替代。
- 系统 swap/压力为全局信号，不能据此断定某进程的交换量或磁盘写入量。
- 采样间隔为 5 秒，无法保证捕捉所有瞬间增长；终止预览会中止当前预览/缩略图任务，系统可能重新启动新实例。
- 仅对准确路径和当前用户的允许目标发送信号；不可读取、身份变化和 footprint 回落均跳过。
- 本次支持实际验证平台为本机 macOS 27 arm64；macOS 13 最低目标与 Intel 源码构建不等于已做所有系统/架构实机验证。

参考：Apple [Quick Look/Preview 中的 Hydra](https://developer.apple.com/videos/play/wwdc2021/10077/)、[footprint 与虚拟分配](https://developer.apple.com/videos/play/wwdc2022/10106/)、[虚拟内存区域说明](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/VMPages.html)。
