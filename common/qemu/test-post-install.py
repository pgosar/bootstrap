#!/usr/bin/env python3
"""Execute a repository test in a disposable, cloud-init-enabled installed VM."""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path, help='installed QCOW2 with cloud-init')
    parser.add_argument('test_script', type=Path, help='Bash test path relative to bootstrap repo')
    parser.add_argument('--timeout', type=int, default=600, help='maximum guest runtime in seconds')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    image = args.image.resolve(strict=True)
    script = (repo / args.test_script).resolve(strict=True)
    relative = script.relative_to(repo)
    if args.timeout <= 0 or not script.is_file():
        parser.error('positive timeout and regular test file required')
    for tool in ('git', 'qemu-img', 'qemu-system-x86_64', 'xorriso'):
        if not shutil.which(tool):
            parser.error(f'missing dependency: {tool}')
    work = Path(tempfile.mkdtemp(prefix='bootstrap-post-install-'))
    print(f'Artifacts: {work}', flush=True)
    # Stage tracked working-tree files, including edits, but no ignored secrets.
    stage = work / 'repo'
    stage.mkdir()
    tracked = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z']).split(b'\0')
    if os.fsencode(str(relative)) not in tracked:
        parser.error('test script must be tracked (git add it first)')
    for raw in filter(None, tracked):
        path = Path(os.fsdecode(raw))
        source = repo / path
        if source.is_file() and not source.is_symlink():
            target = stage / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    seed = work / 'seed'
    seed.mkdir()
    marker = 'BOOTSTRAP_RESULT_' + uuid.uuid4().hex
    # Test output and a unique completion marker are carried by the serial log.
    command = ('mkdir -p /repo; mount -o ro /dev/disk/by-label/BOOTSTRAP /repo '
               '&& cd /repo && bash ' + shlex.quote(str(relative)) +
               '; result=$?; printf "\\n' + marker + '=%s\\n" "$result"; poweroff')
    (seed / 'user-data').write_text('#cloud-config\n' + json.dumps({
        'runcmd': [['bash', '-c', command]],
        'output': {'all': '| tee -a /var/log/cloud-init-output.log /dev/ttyS0'},
    }) + '\n')
    (seed / 'meta-data').write_text('instance-id: ' + marker + '\nlocal-hostname: bootstrap-test\n')
    subprocess.run(['xorriso', '-as', 'mkisofs', '-quiet', '-o', str(work / 'seed.iso'),
                    '-V', 'cidata', '-J', '-r', str(seed)], check=True)
    subprocess.run(['xorriso', '-as', 'mkisofs', '-quiet', '-o', str(work / 'repo.iso'),
                    '-V', 'BOOTSTRAP', '-J', '-r', str(stage)], check=True)
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(image),
                    str(work / 'guest.qcow2')], check=True)
    shutil.copyfile('/usr/share/edk2/x64/OVMF_VARS.4m.fd', work / 'vars.fd')
    with (work / 'serial.log').open('wb') as log:
        process = subprocess.Popen([
            'qemu-system-x86_64', '-enable-kvm', '-cpu', 'host', '-m', '2048', '-smp', '2',
            '-drive', 'file=/usr/share/edk2/x64/OVMF_CODE.4m.fd,if=pflash,format=raw,readonly=on',
            '-drive', f'file={work}/vars.fd,if=pflash,format=raw',
            '-drive', f'file={work}/guest.qcow2,format=qcow2,if=virtio',
            '-drive', f'file={work}/seed.iso,format=raw,media=cdrom,readonly=on',
            '-drive', f'file={work}/repo.iso,format=raw,media=cdrom,readonly=on',
            '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0',
            '-nographic', '-no-reboot'], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            process.wait(timeout=args.timeout)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    output = (work / 'serial.log').read_text(errors='replace')
    if process.returncode != 0 or not re.search(r'(?:^|\s)' + marker + r'=0\s*$', output, re.M):
        raise SystemExit(f'FAIL: guest test failed or did not finish; inspect {work}/serial.log')
    print(f'PASS: {relative}; guest powered off. Log: {work}/serial.log')


if __name__ == '__main__':
    main()
