#!/usr/bin/env python3
r"""Set the code version this repository displays, in one pass.

The repo has two *code* places that must agree:

  * ``control`` — ``Version:`` is what the .deb package and both IPA workflows
    read at build time (``grep -E '^Version:' control``);
  * ``Sources/EeveeSpotify/Tweak.x.swift`` — the runtime ``version`` constant
    (the settings page and the startup log show it).

There is no build number in the code: the settings page shows only the
version, and the startup log prints only the version.

README.md is deliberately **not** touched: its version references are
maintained by hand.

This script is run by ``.github/workflows/bump-version.yml``
(Actions → "Bump version"), but it also works locally:

    python3 Scripts/bump-version.py --version 6.6.9
    python3 Scripts/bump-version.py --version v2.0.0-beta
    python3 Scripts/bump-version.py --version 2.0.0-beta --dry-run

A leading ``v`` is accepted and stripped: the settings view renders
``"v\(EeveeSpotify.version)"``, and the Debian ``Version:`` field does not
use the prefix. A pre-release suffix (``-beta``, ``-beta.1``, ``-rc.1``) is
written into both files as-is.

The ``.deb`` filename/version is *derived* from ``control`` by the build
scripts, so it can never drift from it.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CONTROL = ROOT / "control"
TWEAK = ROOT / "Sources" / "EeveeSpotify" / "Tweak.x.swift"

# X.Y.Z, optionally followed by -beta / -beta.1 / -rc.1, optionally prefixed
# with v (normalized away). The settings view parses the same shape and adds
# its own "v".
VERSION_RE = re.compile(
    r"^[vV]?(\d+\.\d+\.\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


class BumpError(RuntimeError):
    pass


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise BumpError(f"cannot read {path.relative_to(ROOT)}: {exc}") from exc


def _replace_once(text: str, pattern: str, replacement: str, where: str, flags: int = 0) -> str:
    new, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise BumpError(f"{where}: expected exactly one match for {pattern!r}, found {count}")
    return new


def _write_if_changed(path: Path, before: str, after: str, dry_run: bool) -> bool:
    if after == before:
        return False
    if not dry_run:
        path.write_text(after, encoding="utf-8", newline="")
    rel = path.relative_to(ROOT)
    print(f"  {rel}: updated")
    return True


def _bump_control(version: str, dry_run: bool) -> bool:
    text = _read(CONTROL)
    new = _replace_once(
        text,
        r"^Version:\s*\S+.*$",
        f"Version: {version}",
        "control",
        flags=re.MULTILINE,
    )
    return _write_if_changed(CONTROL, text, new, dry_run)


def _bump_tweak(version: str, dry_run: bool) -> bool:
    text = _read(TWEAK)
    new = _replace_once(
        text,
        r'(static let version = ")[^"]*(")',
        rf"\g<1>{version}\g<2>",
        "Tweak.x.swift static let version",
    )
    return _write_if_changed(TWEAK, text, new, dry_run)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Set the code version shown by control and Tweak.x.swift."
    )
    parser.add_argument(
        "--version",
        required=True,
        help="new version: X.Y.Z or X.Y.Z-beta (leading v accepted and stripped)",
    )
    parser.add_argument("--dry-run", action="store_true", help="print changes without writing them")
    args = parser.parse_args(argv)

    match = VERSION_RE.match(args.version.strip())
    if not match:
        print(
            "error: --version must look like X.Y.Z or X.Y.Z-beta "
            f"(a leading v is allowed), got {args.version!r}",
            file=sys.stderr,
        )
        return 2
    version = match.group(1) + (f"-{match.group(2)}" if match.group(2) else "")
    if args.version.strip() != version:
        print(f"normalized version: {args.version.strip()} -> {version}")

    print(f"Bumping to {version}" + (" [dry-run]" if args.dry_run else ""))
    changed = False
    try:
        changed |= _bump_control(version, args.dry_run)
        changed |= _bump_tweak(version, args.dry_run)
    except BumpError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not changed:
        print("Nothing to do — control and Tweak.x.swift already have that version.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
