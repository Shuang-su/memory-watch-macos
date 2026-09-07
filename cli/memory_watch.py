#!/usr/bin/env python3
"""Low-overhead macOS process-footprint alerts; Python standard library only."""
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


class Usage(ctypes.Structure):
    # SDK sys/resource.h: struct rusage_info_v0. RSS alone misses compression.
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins',
            'wired', 'resident', 'footprint', 'started', 'exited')]


@dataclass
class Sample:
    pid: int
    started: int
    name: str
    memory: int


class Sampler:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int

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
            samples.append(Sample(process_id, usage.started, Path(path).name, usage.footprint))
        return samples, skipped


@dataclass
class Track:
    history: deque = field(default_factory=deque)
    high_samples: int = 0
    last_alert: float = -math.inf
    last_level: int = 0


class Detector:
    def __init__(self, warn=2*GIB, critical=4*GIB, growth=512*MIB,
                 window=60, cooldown=300, interval=5):
        self.warn, self.critical, self.growth = warn, critical, growth
        self.window, self.cooldown, self.interval = window, cooldown, interval
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
            if level and (now-track.last_alert >= self.cooldown or level > track.last_level):
                alerts.append((sample, level, reason))
                track.last_alert, track.last_level = now, level
        self.tracks = {key: value for key, value in self.tracks.items() if key in live}
        return sorted(alerts, key=lambda item: (item[1], item[0].memory), reverse=True)


def notify(message):
    # Pass data as argv, never interpolate process names into AppleScript source.
    script = '''on run argv
display notification (item 1 of argv) with title "进程内存提醒" sound name "Glass"
end run'''
    subprocess.run(['/usr/bin/osascript', '-', message], input=script,
                   text=True, capture_output=True, check=True, timeout=8)


def emit(alerts, dry_run, logger):
    if not alerts:
        return
    lines = [f'{s.name} (PID {s.pid})：{s.memory/GIB:.2f} GiB；{reason}'
             for s, level, reason in alerts]
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
    parser.add_argument('--warn-gib', type=positive, default=2)
    parser.add_argument('--critical-gib', type=positive, default=4)
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
    if args.critical_gib <= args.warn_gib:
        parser.error('critical-gib 必须大于 warn-gib')
    if args.pid is not None and args.pid <= 0:
        parser.error('PID 必须是正整数')
    if args.test_notification:
        notify('测试通知：内存监控可发送提醒；此消息不代表发生内存异常。')
        print('通知请求已提交；请确认通知中心实际显示。未显示时检查通知权限和专注模式。')
        return
    sampler = Sampler()
    if args.once:
        samples, skipped = sampler.snapshot(args.match, args.pid)
        print(json.dumps({'sampled': len(samples), 'unavailable': skipped, 'top': [
            {'pid': s.pid, 'name': s.name, 'footprint_gib': round(s.memory/GIB, 3)}
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
        detector = Detector(args.warn_gib*GIB, args.critical_gib*GIB,
                            args.growth_mib*MIB, args.window, args.cooldown, args.interval)
        logger.info('开始监控；每 %.0f 秒采样，阈值 %.1f/%.1f GiB；Ctrl+C 停止。',
                    args.interval, args.warn_gib, args.critical_gib)
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
                    emit(detector.update(samples, time.monotonic()), args.dry_run, logger)
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
