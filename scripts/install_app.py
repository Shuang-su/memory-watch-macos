#!/usr/bin/env python3
"""Install the locally built menu-bar app and the current user's login agent."""
from datetime import datetime
from pathlib import Path
import plistlib
import shutil
import subprocess
import os
import tempfile
import signal
import time

root = Path(__file__).resolve().parents[1]
source = root / '.codex-work/memory-watch-build/Memory Watch.zip'
destination = Path.home() / 'Applications/Memory Watch.app'
agent = Path.home() / 'Library/LaunchAgents/local.shuangsu.memory-watch.plist'
label = 'local.shuangsu.memory-watch'
domain = f'gui/{os.getuid()}'


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def running_pids():
    executable = str(destination / 'Contents/MacOS/MemoryWatch')
    listing = run('/bin/ps', '-axo', 'pid=,comm=').stdout
    return [int(parts[0]) for line in listing.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable]


def stop_app():
    for process_id in running_pids():
        try:
            os.kill(process_id, signal.SIGTERM)
            for _ in range(30):
                try:
                    os.kill(process_id, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('The previous app has not exited; refusing to replace it.')
        except ProcessLookupError:
            pass


def wait_for_app(timeout=10):
    """Confirm an exact-path app process remains alive for at least one second."""
    deadline = time.monotonic() + timeout
    seen = {}
    while time.monotonic() < deadline:
        now = time.monotonic()
        current = set(running_pids())
        seen = {pid: seen.get(pid, now) for pid in current}
        stable = [pid for pid, started in seen.items() if now - started >= 1]
        if stable:
            return stable
        time.sleep(0.25)
    raise RuntimeError('Login agent loaded, but the installed app did not remain running within 10 seconds.')


def write_agent(data, mode=0o644):
    agent.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.memory-watch-agent-', dir=agent.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, agent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    expected = ['/usr/bin/open', '-g', '-a', str(destination)]
    # Check ownership of both destinations before stopping the existing app.
    if destination.exists():
        info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != label:
            raise SystemExit('Destination belongs to another application; refusing to overwrite.')
    previous_agent = agent.read_bytes() if agent.exists() else None
    previous_agent_mode = agent.stat().st_mode & 0o777 if previous_agent is not None else 0o644
    if previous_agent is not None:
        info = plistlib.loads(previous_agent)
        if info.get('Label') != label or info.get('ProgramArguments') != expected:
            raise SystemExit('Existing launch agent does not match this app; refusing to overwrite.')

    destination.parent.mkdir(parents=True, exist_ok=True)
    # Keep old and new bundles on the destination volume so replacements are atomic.
    staging = Path(tempfile.mkdtemp(prefix='.memory-watch-install-', dir=destination.parent))
    clean_source = staging / destination.name
    previous_app = staging / 'previous.app'
    backup = root / '.codex-work/memory-watch-backups' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    changed = False
    installed = False
    preserve_staging = False
    was_running = False
    agent_loaded = False
    try:
        # Documents can be managed by a file provider that re-adds FinderInfo.
        run('/usr/bin/ditto', '-x', '-k', '--noextattr', '--norsrc', str(source), str(staging))
        info = plistlib.loads((clean_source / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != label or info.get('CFBundleExecutable') != 'MemoryWatch':
            raise RuntimeError('Build archive does not contain the expected application.')
        run('/usr/bin/codesign', '--verify', '--strict', str(clean_source))
        run(str(clean_source / 'Contents/MacOS/MemoryWatch'), '--self-test')
        if destination.exists() or previous_agent is not None:
            backup.mkdir(parents=True)
        if destination.exists():
            run('/usr/bin/ditto', '--noextattr', '--norsrc', str(destination), str(backup / destination.name))
        if previous_agent is not None:
            shutil.copy2(agent, backup / agent.name)
        was_running = bool(running_pids())
        agent_loaded = run('/bin/launchctl', 'print', f'{domain}/{label}', check=False).returncode == 0
        # Any failure from here restores the previous app and launch configuration.
        changed = True
        if agent_loaded:
            run('/bin/launchctl', 'bootout', f'{domain}/{label}')
        stop_app()
        if destination.exists():
            os.replace(destination, previous_app)
        os.replace(clean_source, destination)
        installed = True
        run('/usr/bin/codesign', '--verify', '--strict', str(destination))
        write_agent(plistlib.dumps({'Label': label, 'ProgramArguments': expected, 'RunAtLoad': True}))
        run('/bin/launchctl', 'enable', f'{domain}/{label}')
        run('/bin/launchctl', 'bootstrap', domain, str(agent))
        app_pids = wait_for_app()
        state = run('/bin/launchctl', 'print', f'{domain}/{label}').stdout
    except BaseException as failure:
        if changed:
            try:
                run('/bin/launchctl', 'bootout', f'{domain}/{label}', check=False)
                if installed:
                    stop_app()
                    shutil.rmtree(destination)
                if previous_app.exists():
                    os.replace(previous_app, destination)
                if previous_agent is not None:
                    write_agent(previous_agent, previous_agent_mode)
                    if agent_loaded:
                        run('/bin/launchctl', 'bootstrap', domain, str(agent))
                else:
                    agent.unlink(missing_ok=True)
                if was_running and not agent_loaded:
                    run('/usr/bin/open', '-g', '-a', str(destination))
            except BaseException as rollback_failure:
                preserve_staging = True
                raise RuntimeError(f'Install failed: {failure}; rollback also failed: {rollback_failure}. '
                                   f'Recovery files: {staging}; backup: {backup}') from failure
        raise
    finally:
        if not preserve_staging:
            shutil.rmtree(staging)
    print(f'Installed: {destination}\nLogin agent: {agent}\nRunning app PID: {", ".join(map(str, app_pids))}')
    if backup.exists():
        print(f'Previous version backup: {backup}')
    print(state)


if __name__ == '__main__':
    main()
