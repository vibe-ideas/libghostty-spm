#!/usr/bin/env python3
"""Cache a pinned source archive without changing Zig's content hash."""
import argparse
import copy
import os
from pathlib import Path
import subprocess
import tarfile


def prepare(zig, cache, url, expected, archive=None):
    cache = cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    if archive is None:
        archive = cache / "downloads" / (expected + ".tar.gz")
        archive.parent.mkdir(exist_ok=True)
        if not archive.exists():
            temporary = archive.with_suffix(".download")
            # curl uses the host's proxy configuration, unlike Zig's fetcher.
            subprocess.run(["curl", "--fail", "--location", "--retry", "2",
                            "--max-time", "120", "--silent", "--show-error",
                            "--output", str(temporary), url], check=True)
            temporary.replace(archive)
    archive = archive.resolve()
    cached = cache / "p" / (expected + ".tar.gz")
    if not cached.exists():
        result = subprocess.run(
            [str(zig), "fetch", str(archive)], text=True, capture_output=True,
            env={**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache)}, check=True,
        )
        actual = result.stdout.strip().splitlines()[-1]
        if actual != expected:
            raise RuntimeError(f"Source integrity mismatch: expected {expected}, got {actual}")

    # Zig 0.17's `fetch` computes the correct hash, but can retain the source
    # tarball's outer directory when recompressing its package-cache archive.
    # A later build then sees that directory as package content and rejects
    # its hash. Strip only that extra directory; file bytes, modes and links
    # stay unchanged. The consuming Zig build verifies the original hash again.
    with tarfile.open(archive) as original:
        roots = {m.name.split("/")[0] for m in original.getmembers() if m.name not in ("", ".")}
    if len(roots) != 1:
        # Font bundles already have their files at the archive root.
        return
    outer = roots.pop()
    prefix = expected + "/" + outer + "/"
    with tarfile.open(cached) as package:
        files = [m for m in package.getmembers() if not m.isdir()]
        if not files or not all(m.name.startswith(prefix) for m in files):
            return
        temporary = cached.with_suffix(".normalized")
        with tarfile.open(temporary, "w:gz") as output:
            for member in package.getmembers():
                if not member.name.startswith(prefix):
                    continue
                normalized = copy.copy(member)
                normalized.name = expected + "/" + member.name[len(prefix):]
                output.addfile(normalized, package.extractfile(member) if member.isfile() else None)
    temporary.replace(cached)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--hash", dest="expected", required=True)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    prepare(args.zig.resolve(), args.cache, args.url, args.expected, args.archive)
    print("Verified source package: " + args.expected, flush=True)
