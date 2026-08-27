#!/usr/bin/env python3
"""Verify install-manifest pins against repository bytes."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "lib/gtnh_bees/install_manifest.lua"
ENTRY = re.compile(
    r'^\s*\["(?P<path>[^"]+)"\]=\{size=(?P<size>\d+),'
    r'sha256="(?P<sha>[0-9a-f]{64})"\},?\s*$'
)


def main() -> int:
    pins: dict[str, tuple[int, str]] = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        match = ENTRY.match(line)
        if not match:
            continue
        path = match.group("path")
        if path in pins:
            print(f"duplicate manifest pin: {path}", file=sys.stderr)
            return 1
        pins[path] = (int(match.group("size")), match.group("sha"))

    if not pins:
        print("install manifest contains no pins", file=sys.stderr)
        return 1

    failures: list[str] = []
    for relative, expected in sorted(pins.items()):
        source = ROOT / relative
        if not source.is_file():
            failures.append(f"missing source: {relative}")
            continue
        data = source.read_bytes()
        actual = (len(data), hashlib.sha256(data).hexdigest())
        if actual != expected:
            failures.append(
                f"pin mismatch: {relative}: expected {expected[0]}/{expected[1]}, "
                f"got {actual[0]}/{actual[1]}"
            )

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1

    print(f"install manifest pins verified: {len(pins)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
