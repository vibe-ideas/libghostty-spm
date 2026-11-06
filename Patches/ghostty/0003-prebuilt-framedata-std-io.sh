#!/bin/bash
set -euo pipefail

SOURCE_DIR=${1:?Usage: $0 <ghostty-source-dir>}
PATCH_DIR=$(cd "$(dirname "$0")" && pwd)
RESOURCE=src/build/framegen/framedata.compressed

# Reuse the exact prebuilt bytes in the existing patch. Only the generator's
# build API changed in Zig 0.17; the embedded animation resource did not.
if [ ! -f "$SOURCE_DIR/$RESOURCE" ]; then
    git -C "$SOURCE_DIR" apply --include="$RESOURCE" "$PATCH_DIR/0003-prebuilt-framedata.patch"
fi

python3 - "$SOURCE_DIR/src/build/GhosttyFrameData.zig" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
marker = '.generated = b.path("src/build/framegen/framedata.compressed")'
if marker not in source:
    start = source.index("pub fn distResources(b: *std.Build)")
    generator = source[start:]
    if "const compressed_file = run.addOutputFileArg" not in generator:
        raise SystemExit("unexpected Ghostty frame-data generator")
    source = source[:start] + '''pub fn distResources(b: *std.Build) struct {
    framedata: DistResource,
} {
    return .{
        .framedata = .{
            .dist = "src/build/framegen/framedata.compressed",
            .generated = b.path("src/build/framegen/framedata.compressed"),
        },
    };
}
'''
    source = source.replace('dist.framedata.path(b)', 'dist.framedata.generated', 1)
    path.write_text(source)
print("[+] prebuilt frame data ready for Zig 0.17")
PY
