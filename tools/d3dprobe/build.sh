#!/bin/sh
# Builds d3dprobe for 64- and 32-bit Windows. Needs mingw-w64 (`brew install mingw-w64`).
# Output goes to .build/d3dprobe/ (git-ignored).
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../.build/d3dprobe"
mkdir -p "$out"
x86_64-w64-mingw32-gcc -O2 -o "$out/d3dprobe64.exe" "$here/d3dprobe.c" "$here/d3dprobe8.c" -ld3d11 -ld3d9 -ldxgi -ldxguid -lgdi32
i686-w64-mingw32-gcc -O2 -o "$out/d3dprobe32.exe" "$here/d3dprobe.c" "$here/d3dprobe8.c" -ld3d11 -ld3d9 -ldxgi -ldxguid -lgdi32
echo "Built $out/d3dprobe64.exe and $out/d3dprobe32.exe"
