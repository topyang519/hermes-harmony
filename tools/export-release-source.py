#!/usr/bin/env python3
"""Export current product files without local state or prior Git history."""
from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

ROOT_FILES = {'.gitignore', '.dockerignore', 'README.md', 'BUILD-STATUS.md', 'LICENSE'}
PRODUCT_DIRS = {'app', 'bridge', 'deploy', 'docs', 'ios', 'tools', '.github'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='New empty output directory')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    output = args.destination.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('destination must be empty')
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=source).decode().split('\0')
    count = 0
    for name in sorted(set(names)):
        if not name:
            continue
        relative = Path(name)
        item = source / relative
        if not item.is_file():
            continue
        if relative.parts[0] not in PRODUCT_DIRS and name not in ROOT_FILES:
            continue
        if item.is_symlink():
            parser.error(f'product file cannot be a symlink: {name}')
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)
        count += 1
    subprocess.run(['python3', str(source / 'tools/check-release-privacy.py'), str(output)], check=True)
    print(f'Exported {count} product files. Initialize a fresh Git repository here for first publication.')


if __name__ == '__main__':
    main()
