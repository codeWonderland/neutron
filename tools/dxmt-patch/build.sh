#!/bin/sh
# Makes a patched copy of a DXMT release by rebuilding only its Windows-side DLLs (d3d11,
# dxgi, d3d10core) from the matching DXMT source with the patches in this folder:
#   timestamp-after-event.patch  a timestamp query's result is ready once the GPU has finished
#                                its work, as on Windows. Unreal Engine 5 calibrates its GPU
#                                clock that way and otherwise asserts at startup (Satisfactory:
#                                "unset TOptional<FTimestampCalibration>").
#
#   tools/dxmt-patch/build.sh <dxmt-release-dir> <output-dir>
#
# <dxmt-release-dir> is an extracted DXMT release (the folder with x86_64-windows/d3d11.dll,
# e.g. dxmt-v0.80/v0.80); its folder name is the git tag to build (override with DXMT_TAG).
# The output is an APFS clone of it with the rebuilt DLLs; winemetal and the unix side stay as
# released. Register it with `neutron runtime add dxmt <output-dir> --version <name>`.
#
# Needs: mingw-w64 (brew install mingw-w64), git, python3, and a Wine build tree from
# tools/wine-dxmt/build.sh (for Wine's import libraries; set NEUTRON_WINE_BUILD to use another).
set -eu

release=${1:?usage: build.sh <dxmt-release-dir> <output-dir>}
output=${2:?usage: build.sh <dxmt-release-dir> <output-dir>}
here=$(cd "$(dirname "$0")" && pwd)
work=${NEUTRON_DXMT_WORK:-$HOME/Library/Caches/Neutron/dxmt-patch}
tag=${DXMT_TAG:-$(basename "$release")}

[ -f "$release/x86_64-windows/d3d11.dll" ] || { echo "error: $release/x86_64-windows/d3d11.dll not found" >&2; exit 1; }
[ -e "$output" ] && { echo "error: $output already exists" >&2; exit 1; }
command -v x86_64-w64-mingw32-g++ >/dev/null || { echo "error: missing mingw-w64 (brew install mingw-w64)" >&2; exit 1; }

wine_build=${NEUTRON_WINE_BUILD:-$(ls -d "$HOME/Library/Caches/Neutron/wine-dxmt"/build-* 2>/dev/null | tail -1)}
[ -x "${wine_build:-/nonexistent}/tools/winebuild/winebuild" ] || {
  echo "error: no Wine build tree; run tools/wine-dxmt/build.sh first, or set NEUTRON_WINE_BUILD" >&2; exit 1; }

mkdir -p "$work"
if [ ! -x "$work/venv/bin/meson" ]; then
  echo "Installing meson and ninja (in $work/venv)…"
  python3 -m venv "$work/venv"
  "$work/venv/bin/pip" install -q --disable-pip-version-check meson ninja
fi
export PATH="$work/venv/bin:$PATH"

src="$work/dxmt-$tag"
if [ ! -d "$src" ]; then
  echo "Fetching DXMT ${tag}…"
  git clone -q --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules https://github.com/3Shain/dxmt.git "$src"
fi
for p in "$here"/*.patch; do
  if ! git -C "$src" apply --reverse --check "$p" 2>/dev/null; then
    git -C "$src" apply "$p" || { echo "error: $(basename "$p") does not apply to DXMT $tag" >&2; exit 1; }
  fi
done

echo "Building Wine import libraries…"
make -C "$wine_build" dlls/ntdll/x86_64-windows/libntdll.a dlls/dbghelp/x86_64-windows/libdbghelp.a \
  > "$work/wine-make.log" 2>&1 || { echo "error: see $work/wine-make.log" >&2; exit 1; }

build="$src/build-win64"
if [ ! -f "$build/build.ninja" ]; then
  # The Windows DLLs don't use LLVM (shader conversion is in the unix side), but configure wants
  # an LLVM include folder to exist. GCC's libstdc++ needs <iomanip> spelled out.
  mkdir -p "$work/no-llvm/include" "$work/no-llvm/lib"
  cp "$src/build-win64.txt" "$work/cross-win64.txt"
  printf "\n[built-in options]\ncpp_args = ['-include', 'iomanip', '-include', 'cstdint']\n" >> "$work/cross-win64.txt"
  echo "Configuring…"
  meson setup --cross-file "$work/cross-win64.txt" "$build" "$src" -Dwine_build_path="$wine_build" \
    -Dnative_llvm_path="$work/no-llvm" > "$work/configure.log" 2>&1 \
    || { echo "error: configure failed; see $work/configure.log" >&2; exit 1; }
fi
echo "Building d3d11.dll, dxgi.dll and d3d10core.dll…"
ninja -C "$build" src/d3d11/d3d11.dll src/dxgi/dxgi.dll src/d3d10/d3d10core.dll > "$work/make.log" 2>&1 \
  || { echo "error: build failed; see $work/make.log" >&2; exit 1; }

cp -c -R "$release" "$output"
for dll in d3d11/d3d11.dll dxgi/dxgi.dll d3d10/d3d10core.dll; do
  name=$(basename "$dll")
  x86_64-w64-mingw32-strip -o "$output/x86_64-windows/$name" "$build/src/$dll"
  # Mark it as a Wine builtin (the 17-byte signature at 0x40), as DXMT's install step does.
  printf 'Wine builtin DLL\0' | dd of="$output/x86_64-windows/$name" bs=1 seek=64 conv=notrunc 2>/dev/null
done
echo "Done: $output"
echo "Register it with: neutron runtime add dxmt \"$output\" --version dxmt-$tag-patched"
