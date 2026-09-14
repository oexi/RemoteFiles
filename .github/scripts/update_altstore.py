#!/usr/bin/env python3
"""Update the RemoteFiles entry in an AltStore source file."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


def semantic_version_key(value: str) -> tuple[Any, ...]:
    match = SEMVER_RE.fullmatch(value)
    if match is None:
        raise ValueError(f"unsupported semantic version: {value}")

    core = tuple(int(match.group(index)) for index in range(1, 4))
    prerelease = match.group(4)
    if prerelease is None:
        return (*core, (1,))

    identifiers: list[tuple[int, int | str]] = []
    for identifier in prerelease.split("."):
        if identifier.isdigit():
            if len(identifier) > 1 and identifier.startswith("0"):
                raise ValueError(f"unsupported semantic version: {value}")
            identifiers.append((0, int(identifier)))
        else:
            identifiers.append((1, identifier))
    return (*core, (0, tuple(identifiers)))


def compare_release(
    version: str,
    build: int,
    other_version: str,
    other_build: int | None,
) -> int:
    current_key = semantic_version_key(version)
    other_key = semantic_version_key(other_version)
    if current_key < other_key:
        return -1
    if current_key > other_key:
        return 1
    if other_build is None:
        return 0
    return (build > other_build) - (build < other_build)


def concise_description(value: str) -> str:
    value = " ".join(value.split())
    if len(value) > 160:
        value = value[:157].rstrip() + "..."
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", type=Path, default=Path("altstore.json"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--description", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--size", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.date.strip():
        raise SystemExit("release date cannot be empty")
    args.description = concise_description(args.description)
    if not args.description:
        raise SystemExit("release description cannot be empty")
    if not args.download_url.strip():
        raise SystemExit("download URL cannot be empty")
    if args.size <= 0:
        raise SystemExit("release asset size must be positive")
    if not args.build.isdigit():
        raise SystemExit(f"release build must be numeric: {args.build}")
    try:
        semantic_version_key(args.version)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    build = int(args.build)

    original = args.path.read_text(encoding="utf-8")
    data = json.loads(original)
    apps = data.get("apps")
    if not isinstance(apps, list):
        raise SystemExit("altstore source has no apps array")

    app = next(
        (
            item
            for item in apps
            if isinstance(item, dict)
            and item.get("bundleIdentifier") == "com.oexi.RemoteFiles"
        ),
        None,
    )
    if app is None:
        raise SystemExit("RemoteFiles app entry is missing from the AltStore source")

    versions = app.get("versions")
    if not isinstance(versions, list):
        raise SystemExit("RemoteFiles app has no versions array")

    current_version = str(app.get("version", "")).strip()
    current_build: int | None = None
    if current_version:
        try:
            semantic_version_key(current_version)
        except ValueError as error:
            raise SystemExit(f"current AltStore version is invalid: {error}") from error
        builds = [
            int(entry["buildVersion"])
            for entry in versions
            if isinstance(entry, dict)
            and str(entry.get("version")) == current_version
            and str(entry.get("buildVersion", "")).isdigit()
        ]
        if builds:
            current_build = max(builds)

        if compare_release(args.version, build, current_version, current_build) < 0:
            print(
                f"Skipping older release {args.version} build {build}; "
                f"AltStore already points to {current_version}"
                + (f" build {current_build}" if current_build is not None else "")
            )
            return 0

    min_os_version = next(
        (
            entry.get("minOSVersion")
            for entry in versions
            if isinstance(entry, dict) and entry.get("minOSVersion")
        ),
        "17.0",
    )
    new_version = {
        "version": args.version,
        "buildVersion": args.build,
        "date": args.date,
        "localizedDescription": args.description,
        "downloadURL": args.download_url,
        "size": args.size,
        "minOSVersion": min_os_version,
    }

    versions = [
        entry
        for entry in versions
        if not (
            isinstance(entry, dict)
            and str(entry.get("version")) == args.version
            and str(entry.get("buildVersion")) == args.build
        )
    ]
    app["version"] = args.version
    app["versionDate"] = args.date
    app["versionDescription"] = args.description
    app["downloadURL"] = args.download_url
    app["size"] = args.size
    app["versions"] = [new_version, *versions]

    updated = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if updated == original:
        print(f"AltStore already contains {args.version} build {args.build}")
        return 0
    args.path.write_text(updated, encoding="utf-8")
    print(f"Updated AltStore metadata for {args.version} build {args.build}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
