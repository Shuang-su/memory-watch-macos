#!/usr/bin/env python3
"""Low-overhead macOS process-footprint alerts; Python standard library only."""
from __future__ import annotations
import argparse
import ctypes
from collections import deque
from dataclasses import dataclass, field
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import subprocess
import sys
import time

GIB = 1024 ** 3
MIB = 1024 ** 2
DEFAULT_STATE = Path(__file__).resolve().parents[1] / '.codex-work' / 'memory-watch'
PREVIEW_PATHS = frozenset([
    '/System/Library/Frameworks/SceneKit.framework/PlugIns/'
    f'{name}.appex/Contents/MacOS/{name}'
    for name in ('SceneKitQLThumbnailExtension', 'SceneKitQLPreviewExtension')
] + [
    '/System/Library/PrivateFrameworks/Hydra.framework/Plugins/'
    f'{name}.appex/Contents/MacOS/{name}'
    for name in ('HydraQLThumbnailExtension', 'HydraQLPreviewExtension')
] + [
    '/System/Library/PrivateFrameworks/Hydra.framework/Versions/C/XPCServices/'
    'HydraRenderingService.xpc/Contents/MacOS/HydraRenderingService'
])


def adaptive_limits(memory_bytes):
    """Linear interpolation between the 16 and 512 GiB host policies."""
    ram = memory_bytes / GIB if memory_bytes is not None else 16
    position = min(1, max(0, (ram - 16) / 496))
    return (4 + position * 16) * GIB, (8 + position * 72) * GIB


def resolve_thresholds(memory_bytes, warn_gib=None, critical_gib=None):
    limit, virtual_growth = adaptive_limits(memory_bytes)
    warn = limit / 2 if warn_gib is None else warn_gib * GIB
    critical = limit if critical_gib is None else critical_gib * GIB
    if critical <= warn:
        raise ValueError('critical-gib 必须大于 warn-gib')
    return warn, critical, virtual_growth


class Usage(ctypes.Structure):
    # SDK sys/resource.h: struct rusage_info_v0. RSS alone misses compression.
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins',
            'wired', 'resident', 'footprint', 'started', 'exited')]


class TaskInfo(ctypes.Structure):
    # SDK sys/proc_info.h: struct proc_taskinfo / PROC_PIDTASKINFO = 4.
    _fields_ = [(name, ctypes.c_uint64) for name in (
        'virtual_size', 'resident_size', 'total_user', 'total_system',
        'threads_user', 'threads_system')] + [
        (name, ctypes.c_int32) for name in (
            'policy', 'faults', 'pageins', 'cow_faults', 'messages_sent',
            'messages_received', 'syscalls_mach', 'syscalls_unix', 'csw',
            'threadnum', 'numrunning', 'priority')]


class SwapUsage(ctypes.Structure):
    _fields_ = [('total', ctypes.c_uint64), ('available', ctypes.c_uint64),
                ('used', ctypes.c_uint64), ('pagesize', ctypes.c_uint32),
                ('encrypted', ctypes.c_int32)]


class SystemReader:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.lib.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                                         ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.sysctlbyname.restype = ctypes.c_int

    def read(self, name, kind):
        value = kind()
        size = ctypes.c_size_t(ctypes.sizeof(value))
        if self.lib.sysctlbyname(name.encode(), ctypes.byref(value),
                                 ctypes.byref(size), None, 0) != 0:
            return None
        return value if size.value == ctypes.sizeof(value) else None

    def physical_memory(self):
        value = self.read('hw.memsize', ctypes.c_uint64)
        return value.value if value is not None and value.value > 0 else None

    def snapshot(self):
        swap = self.read('vm.swapusage', SwapUsage)
        pressure = self.read('kern.memorystatus_vm_pressure_level', ctypes.c_int32)
        # Unknown values and unavailable sysctls are not a healthy reading.
        level = pressure.value if pressure is not None and pressure.value in (1, 2, 4) else None
        return SystemSample(swap.used if swap is not None else None, level)


@dataclass
class SystemSample:
    swap_bytes: int | None = None
    pressure: int | None = None


@dataclass
class Sample:
    pid: int
    started: int
    name: str
    memory: int
    rss_bytes: int | None = None
    virtual_bytes: int | None = None
    executable_path: str = ''


class Sampler:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                         ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int

    def snapshot(self, match='', pid=None):
        result = subprocess.run(
            ['/bin/ps', '-axo', 'pid=,comm='], capture_output=True,
            text=True, check=True, timeout=5)
        samples, skipped = [], 0
        for line in result.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2:
                continue
            process_id, path = int(parts[0]), parts[1]
            if process_id == os.getpid() or (pid is not None and process_id != pid):
                continue
            if match.casefold() not in path.casefold():
                continue
            usage = Usage()
            if self.lib.proc_pid_rusage(process_id, 0, ctypes.byref(usage)):
                skipped += 1  # Process exited or access denied; never request sudo.
                continue
            info = TaskInfo()
            count = self.lib.proc_pidinfo(process_id, 4, 0, ctypes.byref(info), ctypes.sizeof(info))
            virtual = info.virtual_size if count == ctypes.sizeof(info) else None
            verified = Usage()
            if (self.lib.proc_pid_rusage(process_id, 0, ctypes.byref(verified))
                    or verified.started != usage.started):
                skipped += 1  # Do not combine metrics across an exit/PID reuse race.
                continue
            samples.append(Sample(process_id, verified.started, Path(path).name, verified.footprint,
                                  verified.resident, virtual, path))
        return samples, skipped


@dataclass
class Track:
    history: deque = field(default_factory=deque)
    high_samples: int = 0
    last_alert: float = -math.inf
    last_level: int = 0
    virtual_baseline: int | None = None
    last_virtual_alert: float = -math.inf


class Detector:
    def __init__(self, warn=2*GIB, critical=4*GIB, growth=512*MIB,
                 window=60, cooldown=300, interval=5, virtual_growth=8*GIB):
        self.warn, self.critical, self.growth = warn, critical, growth
        self.window, self.cooldown, self.interval = window, cooldown, interval
        self.virtual_growth = virtual_growth
        self.tracks = {}

    def update(self, samples, now):
        live, alerts = set(), []
        for sample in samples:
            key = (sample.pid, sample.started)  # PID reuse must reset history.
            live.add(key)
            track = self.tracks.setdefault(key, Track())
            while track.history and now - track.history[0][0] > self.window:
                track.history.popleft()
            track.history.append((now, sample.memory))
            elapsed = now - track.history[0][0]
            growth = sample.memory - track.history[0][1]
            track.high_samples = track.high_samples + 1 if sample.memory >= self.warn else 0
            level, reason = 0, ''
            if sample.memory >= self.critical:
                level, reason = 3, '占用达到严重阈值'
            elif track.high_samples >= 2:
                level, reason = 2, '连续两次超过高占用阈值'
            elif (sample.memory >= GIB and elapsed >= 2*self.interval
                  and growth >= self.growth):
                level, reason = 1, f'{elapsed:.0f} 秒内增长 {growth/MIB:.0f} MiB'
            emit_footprint = level and (now-track.last_alert >= self.cooldown or level > track.last_level)
            if emit_footprint:
                track.last_alert, track.last_level = now, level
            virtual_reason = ''
            if sample.executable_path in PREVIEW_PATHS and sample.virtual_bytes is not None:
                if track.virtual_baseline is None:
                    track.virtual_baseline = sample.virtual_bytes
                increase = max(0, sample.virtual_bytes - track.virtual_baseline)
                if increase >= self.virtual_growth and now-track.last_virtual_alert >= self.cooldown:
                    virtual_reason = (f'虚拟地址空间较首次有效采样增长 {increase/GIB:.2f} GiB'
                                      f'（阈值 {self.virtual_growth/GIB:.2f} GiB）；仅提醒，不代表交换占用')
                    track.last_virtual_alert = now
            if emit_footprint or virtual_reason:
                reasons = [reason] if emit_footprint else []
                if virtual_reason:
                    reasons.append(virtual_reason)
                alerts.append((sample, level if emit_footprint else 1, '；'.join(reasons)))
        self.tracks = {key: value for key, value in self.tracks.items() if key in live}
        return sorted(alerts, key=lambda item: (item[1], item[0].memory), reverse=True)


class SystemDetector:
    def __init__(self, cooldown=300):
        self.cooldown = cooldown
        self.swap_history = deque()
        self.swap_growth = None
        self.abnormal_samples = 0
        self.last_pressure_alert = -math.inf
        self.last_pressure_level = 0
        self.last_swap_alert = -math.inf

    def update(self, sample, now):
        alerts = []
        self.abnormal_samples = self.abnormal_samples + 1 if sample.pressure in (2, 4) else 0
        if self.abnormal_samples >= 2 and (now-self.last_pressure_alert >= self.cooldown
                                           or sample.pressure > self.last_pressure_level):
            label = '严重' if sample.pressure == 4 else '警告'
            alerts.append(f'系统内存压力连续两次异常（{label}）；全局指标，不能归因于单个进程')
            self.last_pressure_alert = now
            self.last_pressure_level = sample.pressure
        self.swap_growth = None
        if sample.swap_bytes is None:
            self.swap_history.clear()
        else:
            if self.swap_history and now-self.swap_history[-1][0] > 60:
                self.swap_history.clear()  # A long sleep/gap cannot establish a recent trend.
            self.swap_history.append((now, sample.swap_bytes))
            # Keep the observation immediately before the 60-second boundary.
            # Using only observations younger than 60s would fail under timer jitter.
            while len(self.swap_history) > 1 and self.swap_history[1][0] <= now-60:
                self.swap_history.popleft()
            elapsed = now-self.swap_history[0][0]
            if elapsed >= 60:
                self.swap_growth = max(0, sample.swap_bytes-self.swap_history[0][1])
                if self.swap_growth >= GIB and now-self.last_swap_alert >= self.cooldown:
                    alerts.append(f'系统交换占用最近 {elapsed:.0f} 秒净增长 {self.swap_growth/GIB:.2f} GiB'
                                  '（阈值 1 GiB）；全局指标，不能归因于单个进程')
                    self.last_swap_alert = now
        return alerts


def notify(message):
    # Pass data as argv, never interpolate process names into AppleScript source.
    script = '''on run argv
display notification (item 1 of argv) with title "进程内存提醒" sound name "Glass"
end run'''
    subprocess.run(['/usr/bin/osascript', '-', message], input=script,
                   text=True, capture_output=True, check=True, timeout=8)


def emit(alerts, dry_run, logger, system_alerts=()):
    if not alerts and not system_alerts:
        return
    lines = [f'{s.name} (PID {s.pid})：{s.memory/GIB:.2f} GiB；{reason}'
             for s, level, reason in alerts]
    lines.extend(system_alerts)
    for line in lines:
        logger.warning(line)
    # A single notification per scan avoids a burst when many apps cross a threshold.
    message = '\n'.join(lines[:2])
    if len(lines) > 2:
        message += f'\n另有 {len(lines)-2} 个进程，详情见日志。'
    if not dry_run:
        try:
            notify(message)
        except (OSError, subprocess.SubprocessError) as exc:
            logger.error('通知请求失败（异常类型 %s）；告警已记录在日志。', type(exc).__name__)


def positive(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError('必须是有限正数')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interval', type=positive, default=5, help='采样秒数，最小 2')
    parser.add_argument('--warn-gib', type=positive, help='覆盖按物理内存计算的提醒阈值')
    parser.add_argument('--critical-gib', type=positive, help='覆盖按物理内存计算的严重阈值')
    parser.add_argument('--growth-mib', type=positive, default=512)
    parser.add_argument('--window', type=positive, default=60)
    parser.add_argument('--cooldown', type=positive, default=300)
    parser.add_argument('--match', default='', help='进程路径/名称包含的文字，不区分大小写')
    parser.add_argument('--pid', type=int, help='只监控指定 PID；重启进程后需更新')
    parser.add_argument('--once', action='store_true', help='输出一次采样，不发送通知')
    parser.add_argument('--test-notification', action='store_true')
    parser.add_argument('--dry-run', action='store_true', help='仅终端和日志告警')
    parser.add_argument('--duration', type=positive, help='运行指定秒数后退出')
    parser.add_argument('--state-dir', type=Path, default=DEFAULT_STATE)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('本脚本仅支持 macOS')
    if args.interval < 2 or args.window < args.interval*2:
        parser.error('interval 至少为 2，window 至少为 interval 的两倍')
    if args.pid is not None and args.pid <= 0:
        parser.error('PID 必须是正整数')
    if args.test_notification:
        notify('测试通知：内存监控可发送提醒；此消息不代表发生内存异常。')
        print('通知请求已提交；请确认通知中心实际显示。未显示时检查通知权限和专注模式。')
        return
    system_reader = SystemReader()
    ram = system_reader.physical_memory()
    try:
        warn, critical, virtual_growth = resolve_thresholds(ram, args.warn_gib, args.critical_gib)
    except ValueError as exc:
        parser.error(str(exc))
    limit, _ = adaptive_limits(ram)
    sampler = Sampler()
    if args.once:
        samples, skipped = sampler.snapshot(args.match, args.pid)
        system_sample = system_reader.snapshot()
        def gib_or_none(value):
            return round(value/GIB, 3) if value is not None else None
        print(json.dumps({'sampled': len(samples), 'unavailable': skipped,
                         'physical_memory_gib': gib_or_none(ram),
                         'thresholds': {'warn_gib': gib_or_none(warn),
                                        'critical_gib': gib_or_none(critical),
                                        'adaptive_footprint_gib': gib_or_none(limit),
                                        'virtual_growth_gib': gib_or_none(virtual_growth),
                                        'system_swap_growth_gib': 1},
                         'system': {'swap_used_gib': gib_or_none(system_sample.swap_bytes),
                                    'swap_growth_60s_gib': None,
                                    'pressure_level': system_sample.pressure},
                         'virtual_growth_note': '首次有效采样建立基线，需持续监控才可比较；虚拟地址空间不等于交换占用',
                         'top': [
            {'pid': s.pid, 'name': s.name, 'footprint_gib': gib_or_none(s.memory),
             'rss_gib': gib_or_none(s.rss_bytes), 'vsz_gib': gib_or_none(s.virtual_bytes),
             'preview_service': s.executable_path in PREVIEW_PATHS}
            for s in sorted(samples, key=lambda s: s.memory, reverse=True)[:15]
        ]}, ensure_ascii=False, indent=2))
        return
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.state_dir / 'monitor.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.exit(1, '已有监控实例使用此目录；无需重复启动。\n')
        logger = logging.getLogger('memory-watch')
        logger.setLevel(logging.INFO)
        formatter = logging.Formatter('%(asctime)s %(levelname)s %(message)s')
        handlers = [logging.StreamHandler(sys.stdout), RotatingFileHandler(
            args.state_dir / 'events.log', maxBytes=256*1024, backupCount=2, encoding='utf-8')]
        for handler in handlers:
            handler.setFormatter(formatter)
            logger.addHandler(handler)
        detector = Detector(warn, critical, args.growth_mib*MIB, args.window,
                            args.cooldown, args.interval, virtual_growth)
        system_detector = SystemDetector(args.cooldown)
        logger.info('开始监控（仅提醒）；每 %.0f 秒采样，阈值 %.2f/%.2f GiB，'
                    '三维预览虚拟增长 %.2f GiB；Ctrl+C 停止。',
                    args.interval, warn/GIB, critical/GIB, virtual_growth/GIB)
        if ram is None:
            logger.warning('物理内存总量不可读；自适应默认值采用 16 GiB 规格下限。')
        start = time.monotonic()
        last_error = -math.inf
        first = True
        try:
            while args.duration is None or time.monotonic()-start < args.duration:
                tick = time.monotonic()
                try:
                    samples, skipped = sampler.snapshot(args.match, args.pid)
                    if first:
                        logger.info('采集到 %d 个进程，%d 个已退出或无权读取。', len(samples), skipped)
                        first = False
                    now = time.monotonic()
                    system_alerts = system_detector.update(system_reader.snapshot(), now)
                    emit(detector.update(samples, now), args.dry_run, logger, system_alerts)
                except (OSError, subprocess.SubprocessError) as exc:
                    if tick-last_error >= 60:
                        logger.error('本轮采样失败（%s），下一轮重试。', type(exc).__name__)
                        last_error = tick
                delay = max(0, args.interval-(time.monotonic()-tick))
                if args.duration is not None:
                    delay = min(delay, max(0, args.duration-(time.monotonic()-start)))
                time.sleep(delay)
        except KeyboardInterrupt:
            pass
        finally:
            logger.info('监控已停止。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.SubprocessError) as error:
        print(f'无法完成操作：{type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)
