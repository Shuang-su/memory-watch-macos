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


# Documents may be managed by a file provider that re-adds FinderInfo after signing.
# Validate a clean copy in the destination volume before replacing anything.
destination.parent.mkdir(parents=True, exist_ok=True)
staging = tempfile.TemporaryDirectory(prefix='.memory-watch-install-', dir=destination.parent)
clean_source = Path(staging.name) / 'Memory Watch.app'
run('/usr/bin/ditto', '-x', '-k', '--noextattr', '--norsrc', str(source), staging.name)
run('/usr/bin/codesign', '--verify', '--strict', str(clean_source))
run(str(clean_source / 'Contents/MacOS/MemoryWatch'), '--self-test')
backup = root / '.codex-work/memory-watch-backups' / datetime.now().strftime('%Y%m%d-%H%M%S')
if destination.exists():
    info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != label:
        raise SystemExit('Destination belongs to another application; refusing to overwrite.')
    backup.mkdir(parents=True)
    shutil.copytree(destination, backup / destination.name)
    executable = str(destination / 'Contents/MacOS/MemoryWatch')
    listing = run('/bin/ps', '-axo', 'pid=,comm=').stdout
    for line in listing.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == executable:
            process_id = int(parts[0])
            try:
                os.kill(process_id, signal.SIGTERM)
                for _ in range(30):
                    try:
                        os.kill(process_id, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.1)
                else:
                    raise SystemExit('The previous app has not exited; refusing to replace it.')
            except ProcessLookupError:
                pass
if agent.exists():
    info = plistlib.loads(agent.read_bytes())
    expected = ['/usr/bin/open', '-g', '-a', str(destination)]
    if info.get('Label') != label or info.get('ProgramArguments') != expected:
        raise SystemExit('Existing launch agent does not match this app; refusing to overwrite.')
    backup.mkdir(parents=True, exist_ok=True)
    shutil.copy2(agent, backup / agent.name)
    run('/bin/launchctl', 'bootout', f'{domain}/{label}', check=False)
destination.parent.mkdir(parents=True, exist_ok=True)
run('/usr/bin/ditto', '--noextattr', '--norsrc', str(clean_source), str(destination))
run('/usr/bin/codesign', '--verify', '--strict', str(destination))
staging.cleanup()
agent.parent.mkdir(parents=True, exist_ok=True)
agent.write_bytes(plistlib.dumps({
    'Label': label,
    'ProgramArguments': ['/usr/bin/open', '-g', '-a', str(destination)],
    'RunAtLoad': True,
}))
agent.chmod(0o644)
run('/bin/launchctl', 'enable', f'{domain}/{label}')
run('/bin/launchctl', 'bootstrap', domain, str(agent))
print(f'Installed: {destination}\nLogin agent: {agent}')
print(run('/bin/launchctl', 'print', f'{domain}/{label}').stdout)
