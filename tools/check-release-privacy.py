#!/usr/bin/env python3
"""Scan a public source directory or release archive without printing secrets."""
from __future__ import annotations

import argparse
import io
import re
import subprocess
import tarfile
import zipfile
from pathlib import Path

FORBIDDEN_NAMES = {
    '.secrets', '.env', 'connection.json', 'bridge.toml', 'local.properties',
    'build-profile.json5', 'xcuserdata', '__pycache__', '.venv', 'venv',
    '.hvigor', '.idea', '.DS_Store', 'logs', 'state', '.pytest_cache',
}
FORBIDDEN_SUFFIXES = ('.pem', '.key', '.p12', '.pfx', '.p7b', '.keystore',
                      '.jks', '.db', '.sqlite', '.sqlite3', '.log', '.bak',
                      '.backup', '.old', '.pyc', '.mobileprovision')
PATTERNS = {
    'absolute user directory': re.compile(rb'(?:/Users/|/home/|[A-Za-z]:\\Users\\)[A-Za-z0-9_.-]+'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub credential': re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})'),
    'provider credential': re.compile(rb'(?:sk-[A-Za-z0-9_-]{24,}|AKIA[A-Z0-9]{16})'),
}
ALLOWED_IPV4 = {'127.0.0.1', '0.0.0.0'}
IP_PATTERN = re.compile(rb'(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w.])')


def entries(path: Path, tracked: bool):
    if path.is_dir():
        if tracked:
            names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=path).decode().split('\0')
            files = (path / name for name in sorted(set(names)) if name)
        else:
            files = path.rglob('*')
        for item in files:
            if item.is_file() and '.git' not in item.relative_to(path).parts:
                yield str(item.relative_to(path)), item.read_bytes()
    else:
        yield path.name, path.read_bytes()


def scan(name: str, data: bytes, issues: list[str], depth: int = 0):
    parts = Path(name).parts
    private_name = any(part in FORBIDDEN_NAMES for part in parts)
    if name.endswith('app/entry/build-profile.json5'):
        private_name = False  # Module build options contain no signing data.
    if private_name or name.endswith(FORBIDDEN_SUFFIXES):
        issues.append(f'{name}: excluded private/generated file')
    for label, pattern in PATTERNS.items():
        if pattern.search(data):
            issues.append(f'{name}: {label}')
    # Numeric SDK/build versions may have four components, so check only
    # strings directly used as network URL hosts for owner-specific addresses.
    for match in re.finditer(rb'(?:https?|wss?)://([0-9.]+)(?=[:/\s\"\'])', data):
        host = match.group(1).decode()
        if IP_PATTERN.fullmatch(match.group(1)) and host not in ALLOWED_IPV4:
            issues.append(f'{name}: literal network address')
    if re.search(rb'(?:https?|wss?)://[A-Za-z0-9.-]+\.sslip\.io', data):
        issues.append(f'{name}: owner-specific automatic DNS address')
    if depth >= 3:
        return
    stream = io.BytesIO(data)
    if zipfile.is_zipfile(stream):
        with zipfile.ZipFile(stream) as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    if member.file_size > 64 * 1024 * 1024:
                        issues.append(f'{name}!{member.filename}: member exceeds scan limit')
                    else:
                        scan(f'{name}!{member.filename}', archive.read(member), issues, depth + 1)
    elif name.endswith(('.tar.gz', '.tgz', '.tar')):
        with tarfile.open(fileobj=stream, mode='r:*') as archive:
            for member in archive.getmembers():
                if member.issym() or member.islnk():
                    issues.append(f'{name}!{member.name}: unexpected archive link')
                elif member.isfile():
                    if member.size > 64 * 1024 * 1024:
                        issues.append(f'{name}!{member.name}: member exceeds scan limit')
                    else:
                        extracted = archive.extractfile(member)
                        if extracted:
                            scan(f'{name}!{member.name}', extracted.read(), issues, depth + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', type=Path, nargs='+')
    parser.add_argument('--tracked', action='store_true', help='Scan only Git product files in directories')
    args = parser.parse_args()
    issues: list[str] = []
    count = 0
    for path in args.paths:
        for name, data in entries(path, args.tracked):
            count += 1
            scan(name, data, issues)
    if issues:
        print('\n'.join(sorted(set(issues))))
        raise SystemExit(1)
    print(f'Privacy scan passed: {count} input files; archive contents inspected.')


if __name__ == '__main__':
    main()
