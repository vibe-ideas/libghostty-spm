#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"
METAL_ZIG="$SOURCE_DIR/src/renderer/Metal.zig"
DEVICE_ZIG="$SOURCE_DIR/src/renderer/metal/Device.zig"
if [ ! -f "$DEVICE_ZIG" ]; then
    DEVICE_ZIG="$METAL_ZIG"
fi

if [ ! -f "$METAL_ZIG" ]; then
    echo "[-] Metal.zig not found"
    exit 1
fi

if grep -q 'LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH' "$DEVICE_ZIG"; then
    echo "[+] Metal texture storage already patched"
    exit 0
fi

python3 - "$DEVICE_ZIG" "$METAL_ZIG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()
metal = Path(sys.argv[2])

replacements = [
    (
        """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
        """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The default storage mode to use for MTLTexture resources.
default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
    ),
    (
        """    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );
""",
        """    // LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH
    // MTLStorageModeShared is valid for textures on Apple GPUs, while Intel
    // and AMD macOS GPUs require managed textures even when hasUnifiedMemory is
    // true. Keep buffer storage unchanged, but choose texture storage from the
    // Metal GPU family as Apple recommends for CPU-updated textures.
    const default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.os.tag) {
        .ios => .shared,
        .macos => if (device.msgSend(
            bool,
            objc.sel("supportsFamily:"),
            .{mtl.MTLGPUFamily.apple1},
        )) .shared else .managed,
        else => default_storage_mode,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} default_texture_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, default_texture_storage_mode, max_texture_size },
    );
""",
    ),
    (
        """        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
""",
        """        .default_storage_mode = default_storage_mode,
        .default_texture_storage_mode = default_texture_storage_mode,
        .max_texture_size = max_texture_size,
""",
    ),
]

for old, new in replacements:
    if old not in src:
        print("[-] Metal.zig structure block not found")
        sys.exit(1)
    src = src.replace(old, new, 1)

render_src = src if path == metal else metal.read_text()
owner = "self" if path == metal else "self.device"
old_mode = f".storage_mode = {owner}.default_storage_mode"
new_mode = f".storage_mode = {owner}.default_texture_storage_mode"
old_count = render_src.count(old_mode)
if old_count < 4:
    print("[-] expected texture storage call sites not found")
    sys.exit(1)

render_src = render_src.replace(old_mode, new_mode)

buffer_marker = """pub inline fn bufferOptions(self: Metal) bufferpkg.Options {"""
buffer_start = render_src.find(buffer_marker)
if buffer_start == -1:
    print("[-] bufferOptions not found")
    sys.exit(1)

render_src = render_src[:buffer_start] + render_src[buffer_start:].replace(new_mode, old_mode, 1)

if path != metal:
    path.write_text(src)
metal.write_text(render_src)
print("[+] patched Metal.zig: split buffer and texture storage modes")
PY
