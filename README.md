# Memory Watch · 内存提醒

轻量 macOS 顶栏内存监控工具。**平时只有一个小图标，进程内存异常时变红，并发送系统通知。** 支持登录自启动，不需要一直开着终端。

## 下载与使用

从 [Releases](https://github.com/Shuang-su/memory-watch-macos/releases/latest) 下载 App 压缩包，解压后将 `Memory Watch.app` 放入“应用程序”并打开。

- 允许通知，点击顶栏图标 → **发送测试通知**。
- 在菜单中勾选 **登录时自动启动**。
- 点击进程或通知可打开活动监视器；菜单也提供暂停、阈值切换和告警日志。
- 取消自启动后退出 App，即可停止后续自动运行。

当前下载包为 **Apple Silicon（arm64）版，要求 macOS 13 或更新版本**。App 使用本地 ad-hoc 签名，未经过 Apple 公证，首次打开可能需要在系统“隐私与安全性”中确认。

## 提醒规则

每 5 秒检查一次，使用 macOS `ri_phys_footprint` 读取进程内存，包含压缩内存的计账。

| 条件 | 默认阈值 |
|---|---|
| 持续高占用 | 连续两次 ≥ 2 GiB |
| 严重高占用 | ≥ 4 GiB，当轮提醒 |
| 快速增长 | 最近最多 60 秒增长 ≥ 512 MiB，且当前 ≥ 1 GiB；至少观察 10 秒 |
| 重复提醒 | 同一进程每 5 分钟最多一次，严重程度提升可立即提醒 |

异常持续时保持红色，恢复正常后自动还原。菜单可切换为 4 / 8 GiB 的宽松提醒阈值。工具不上传数据。

## SceneKit 缩略图自动保护

从 1.1.0 起，App 默认会在系统的 **`SceneKitQLThumbnailExtension` 占用达到 4 GiB** 时，自动发送 `SIGKILL` 强制退出它，并记录、通知处理结果。终止前重新核对 PID、启动时间、系统可执行文件路径、所属用户和当前内存占用；进程已退出、PID 被重用或占用已经回落时不会执行。

- 仅处理当前用户的这个系统缩略图进程。`SceneKitQLPreviewExtension` 和其他进程仍然只提醒。
- 每 5 秒采样，首次采样达到阈值也会处理；4 GiB 自动退出阈值独立于普通提醒和宽松模式。
- 菜单中的 **“自动退出过大 SceneKit 缩略图（≥4 GiB）”** 可关闭或重新开启保护，选择会保存。暂停监控会同时暂停自动处理。
- 发送信号后检查进程是否退出，分别报告已退出、失败或尚未确认；同一实例处理失败/未退出时至少隔 60 秒重试。新启动的实例会重新检查。

强制退出会中止当前缩略图任务；访达再次请求缩略图时，系统仍可能重新启动该进程。此规则不能替代关闭大型模型目录的自动预览。

部分系统进程受权限限制无法读取，菜单会显示覆盖数量。按单个进程统计，不合并一个 App 的所有 Helper；正常的大型任务也可能触发提醒。系统完全卡死或专注模式阻止横幅时，无法保证及时看到通知。

## 从源码构建

需要 Xcode Command Line Tools；App 本身运行不依赖 Python 或第三方库。

```sh
git clone https://github.com/Shuang-su/memory-watch-macos.git
cd memory-watch-macos
zsh scripts/build-app.sh
```

构建脚本会执行原生检测逻辑自测，然后生成 `.codex-work/memory-watch-build/Memory Watch.zip`。源码构建使用本机架构；Intel 构建未在本次发布的本机环境验证。

本地安装并开启当前用户登录自启动（需要 Python 3）：

```sh
python3 scripts/install_app.py
```

安装位置为 `~/Applications/Memory Watch.app`；自启动项为 `~/Library/LaunchAgents/local.shuangsu.memory-watch.plist`。日志位于 `~/Library/Logs/Memory Watch/`，两个日志文件总量约 512 KiB。

## 测试与命令行版本

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
python3 cli/memory_watch.py --once
python3 cli/memory_watch.py --match SceneKit
```

独立 Python 脚本仅依赖标准库，支持自定义阈值、PID/名称过滤和重复提醒限流，保持只提醒行为；SceneKit 自动退出功能位于原生 App。通常选择 App 或脚本其中一个运行。可对 App 内的 `Contents/MacOS/MemoryWatch` 运行 `--self-test`、`--snapshot` 或 `--test-notification` 进行诊断。自测包含对一次性子进程的真实信号与退出验证，不通过分配大量内存或终止真实 SceneKit 进程测试。
