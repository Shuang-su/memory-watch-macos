# Memory Watch · 内存提醒

轻量 macOS 顶栏内存监控工具。**平时只有一个小图标，进程内存异常时变红，并发送系统通知。** 支持登录自启动，不需要一直开着终端。

## 下载与使用

从 [Releases](https://github.com/Shuang-su/memory-watch-macos/releases/latest) 下载 App 压缩包，解压后将 `Memory Watch.app` 放入“应用程序”并打开。

- 允许通知，点击顶栏图标 → **发送测试通知**。
- 在菜单中勾选 **登录时自动启动**。
- 点击进程或通知可打开活动监视器；菜单也提供暂停、阈值切换和告警日志。
- 取消自启动后退出 App，即可停止后续自动运行。

当前下载包为 **Apple Silicon（arm64）版，要求 macOS 13 或更新版本**；1.2.0 补充 macOS 27 的 Hydra 三维预览进程适配。App 使用本地 ad-hoc 签名，未经过 Apple 公证，首次打开可能需要在系统“隐私与安全性”中确认。

## 提醒规则

每 5 秒检查一次，使用 macOS `ri_phys_footprint` 读取进程的实际内存计账（footprint），包含压缩、交换内存。RSS（常驻内存）和 VSZ（虚拟地址空间大小）分别显示，不能互相替代。

1.2.0 按本机物理内存自动设置阈值。令 `R` 为物理内存 GiB，footprint 基准 `L = clamp(4 + (R - 16) × 16 / 496, 4, 20)` GiB，VSZ 增长基准独立计算为 `V = clamp(8 + (R - 16) × 72 / 496, 8, 80)` GiB。两者均在 16–512 GiB 物理内存间连续线性变化，在区间外保持端点值。

| 条件 | 默认阈值 |
|---|---|
| 持续高占用 | footprint 连续两次 ≥ L / 2 |
| 严重高占用 | footprint ≥ L，当轮提醒 |
| 快速增长 | 最近最多 60 秒增长 ≥ 512 MiB，且当前 ≥ 1 GiB；至少观察 10 秒 |
| 虚拟地址空间增长 | 下述五类预览进程同一实例的 VSZ 比首次有效采样增长 ≥ V；只提醒 |
| 系统内存压力 | 连续两轮处于异常压力状态；只提醒 |
| 交换内存快速增长 | 60 秒内系统 swap 使用增长 ≥ 1 GiB；只提醒 |
| 重复提醒 | 同一进程每 5 分钟最多一次，严重程度提升可立即提醒 |

例如，16 GiB Mac 的提醒/严重/预览保护阈值为 2 / 4 / 4 GiB，VSZ 增长提醒为 8 GiB；512 GiB Mac 对应 10 / 20 / 20 GiB，VSZ 增长提醒为 80 GiB。菜单可切换宽松提醒模式，将普通 footprint 提醒阈值加倍；预览保护阈值保持 L，VSZ 增长阈值保持 V。

VSZ 基线只属于同一 PID 和启动时间对应的实例，恢复监控及进程重启/PID 重用后重新建立；不会对首次采样已有的巨大地址空间立即告警。系统压力和 swap 是全局指标，不会归因到单个进程，也不会单独触发自动退出。异常持续时保持红色，恢复正常后自动还原。工具不上传数据。

## 三维预览自动保护

1.2.0 默认会在以下当前用户的系统进程 **footprint ≥ L** 时，自动发送 `SIGKILL` 强制退出，并记录、通知处理结果：

- `HydraRenderingService`
- `HydraQLThumbnailExtension`
- `HydraQLPreviewExtension`
- `SceneKitQLThumbnailExtension`
- `SceneKitQLPreviewExtension`

Hydra 规则覆盖三维渲染服务、缩略图和预览扩展，同时保留旧 SceneKit 兼容。本机 macOS 27 的 Hydra 预览/缩略图扩展均声明支持 PLY、USD、OBJ、STL 等格式。Hydra 并非 macOS 27 才出现；Apple 在 [WWDC21 的三维工作流介绍](https://developer.apple.com/videos/play/wwdc2021/10077/)中已介绍 Quick Look/Preview 的 Hydra 渲染。

- 仅匹配上述名称对应的准确系统可执行文件路径，并只处理当前用户进程；其他进程保持只提醒。
- 终止前重新核对 PID、启动时间、路径、所属用户和当前 footprint。进程已退出、PID 被重用、不可读取或占用已经回落时不执行。
- 每 5 秒采样，首次采样达到保护阈值也会处理；保护阈值独立于普通提醒的宽松模式。
- 菜单中的预览自动保护开关可关闭或重新开启，选择会保存。升级保留旧版已关闭的选择；暂停监控同时暂停所有检测和自动处理。
- 发送信号后检查进程是否退出，分别报告已退出、失败或尚未确认；同一实例处理失败/未退出时至少隔 60 秒重试。新启动的实例会重新检查。

强制退出会中止当前三维预览或缩略图任务；访达再次请求时，系统仍可能重新启动相关进程。此规则不能替代关闭大型模型目录的自动预览。

**VSZ 不等于交换文件使用量。** 2026-11-02 本机 macOS 27 核查中，HydraRenderingService 的 VSZ 约 492 GiB、footprint 约 23.9 GiB；`vmmap` 显示 385 GiB Guard 区域没有常驻或交换页，该进程当时交换页为 0，系统 swap 使用仅约 11.75 MiB。因此不按 VSZ 总量自动退出，也不把它当作 SSD 写入量。参见 Apple 对[虚拟内存区域](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/VMPages.html)及 [footprint、压缩和交换内存](https://developer.apple.com/videos/play/wwdc2022/10106/)的说明。

部分系统进程受权限限制无法读取，菜单会显示覆盖数量。按单个进程统计，不合并一个 App 的所有 Helper；正常的大型任务也可能触发提醒。系统完全卡死或专注模式阻止横幅时，无法保证及时看到通知。

## 从源码构建

需要 Xcode Command Line Tools；App 本身运行不依赖 Python 或第三方库。

```sh
git clone https://github.com/Shuang-su/memory-watch-macos.git
cd memory-watch-macos
zsh scripts/build-app.sh
```

构建脚本会执行原生检测逻辑自测，然后生成 `.codex-work/memory-watch-build/Memory Watch.zip` 和对应的 `Memory Watch.zip.sha256`。源码构建使用本机架构；Intel 构建未在本次发布的本机环境验证。

本地安装并开启当前用户登录自启动（需要 Python 3）：

```sh
python3 scripts/install_app.py
```

安装位置为 `~/Applications/Memory Watch.app`；自启动项为 `~/Library/LaunchAgents/local.shuangsu.memory-watch.plist`。日志位于 `~/Library/Logs/Memory Watch/`，两个日志文件总量约 512 KiB。

## 测试与命令行版本

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
python3 cli/memory_watch.py --once
python3 cli/memory_watch.py --match Hydra
```

独立 Python 脚本仅依赖标准库，默认使用相同的按物理内存自适应阈值，支持自定义阈值、PID/名称过滤和重复提醒限流。CLI 对 footprint、VSZ 增长、系统压力和 swap 增长均保持只提醒；自动退出功能仅位于原生 App。用 `python3 cli/memory_watch.py --help` 查看参数。通常选择 App 或脚本其中一个运行。

可对 App 内的 `Contents/MacOS/MemoryWatch` 运行 `--self-test`、`--snapshot` 或 `--test-notification` 进行诊断。自测包含对一次性子进程的真实信号与退出验证，不通过分配大量内存或终止真实预览进程测试。1.2.0 的现场证据、测试和部署结果见[完成记录](docs/changes/20261102-macos27-preview-protection/completion.md)。
