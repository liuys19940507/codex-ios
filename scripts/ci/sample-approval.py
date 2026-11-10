"""Sample only the owned simulator fixture; never signal the app process."""
import subprocess
import sys
import time
from pathlib import Path

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
for _ in range(240):
    listing = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    matches = [line.split(maxsplit=1) for line in listing.splitlines()
               if '/CodexRemote.app/CodexRemote' in line and '--ui-test-pending' in line]
    if matches:
        pid = matches[0][0]
        # First sample covers initial navigation; later samples cover the hang.
        for index, delay in enumerate([10, 15, 20]):
            time.sleep(delay)
            command = subprocess.run(['ps', '-p', pid, '-o', 'command='], capture_output=True, text=True).stdout
            if '/CodexRemote.app/CodexRemote' not in command or '--ui-test-pending' not in command:
                sys.exit('Fixture process exited before sampling')
            subprocess.run(['sample', pid, '3', '10', '-file', str(destination / f'app-{pid}-{index}.txt')],
                           timeout=25, check=True)
        sys.exit(0)
    time.sleep(2)
sys.exit('Approval fixture process was not found')
