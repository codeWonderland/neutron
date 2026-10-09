#!/bin/sh
# Makes a DXMT-capable copy of a macOS Wine build by rebuilding only the files these
# patches touch:
#   winemac-dxmt.patch               winemac.so exports the `macdrv_functions` table DXMT
#                                    presents through.
#   mfreadwrite-shared-samples.patch mfreadwrite.dll (64-bit) hands out shareable video
#                                    textures, which Unity's video player needs under DXMT.
#   winemac-flush-deadlock.patch     winemac.so no longer deadlocks when a window is created
#                                    while another thread flushes a layered window (Unreal
#                                    splash screens: Deep Rock Galactic hung on its splash).
#
#   tools/wine-dxmt/build.sh <wine-root> <output-dir>
#
# <wine-root> is a Wine build containing bin/wine, e.g. Gcenx's
# "Wine Devel.app/Contents/Resources/wine". The output is an APFS clone of it with the
# patched winemac.so; register it with `neutron runtime add wine <output-dir>`.
# The source matching the build's version is downloaded from dl.winehq.org.
#
# Needs: Xcode command line tools, Homebrew bison and flex, mingw-w64
# (brew install bison flex mingw-w64). Tested with Wine 11.18.
set -eu

wine_root=${1:?usage: build.sh <wine-root> <output-dir>}
output=${2:?usage: build.sh <wine-root> <output-dir>}
here=$(cd "$(dirname "$0")" && pwd)
work=${NEUTRON_WINE_WORK:-$HOME/Library/Caches/Neutron/wine-dxmt}

[ -x "$wine_root/bin/wine" ] || { echo "error: $wine_root/bin/wine not found" >&2; exit 1; }
[ -e "$output" ] && { echo "error: $output already exists" >&2; exit 1; }
for tool in /opt/homebrew/opt/bison/bin/bison /opt/homebrew/opt/flex/bin/flex; do
  [ -x "$tool" ] || { echo "error: missing $tool (brew install bison flex)" >&2; exit 1; }
done
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "error: missing mingw-w64 (brew install mingw-w64)" >&2; exit 1; }

# "wine-11.18" or "wine-11.18 (Staging)" → 11.18
version=$("$wine_root/bin/wine" --version | sed -n 's/^wine-\([0-9][0-9.]*\).*/\1/p')
[ -n "$version" ] || { echo "error: could not read the Wine version" >&2; exit 1; }
major=${version%%.*}
case "$version" in *.0) series="$major.0" ;; *) series="$major.x" ;; esac
echo "Wine $version"

mkdir -p "$work"
src="$work/wine-$version"
if [ ! -d "$src" ]; then
  echo "Downloading Wine $version source…"
  curl -sSfL -o "$work/wine-$version.tar.xz" "https://dl.winehq.org/wine/source/$series/wine-$version.tar.xz"
  tar -xJf "$work/wine-$version.tar.xz" -C "$work"
fi
# Apply each patch once; a source tree from an earlier run may lack newer ones.
for p in "$here"/*.patch; do
  if ! (cd "$src" && patch -p1 -R --dry-run --force --quiet < "$p" >/dev/null 2>&1); then
    (cd "$src" && patch -p1 --forward --quiet < "$p") || { echo "error: $(basename "$p") does not apply" >&2; exit 1; }
  fi
done

build="$work/build-$version"
mkdir -p "$build"
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=10.15
if [ ! -f "$build/Makefile" ]; then
  echo "Configuring (x86_64)…"
  (cd "$build" && "$src/configure" CC="clang -arch x86_64" OBJC="clang -arch x86_64" \
    --host=x86_64-apple-darwin --enable-archs=x86_64 --disable-tests \
    --without-x --without-freetype --without-gstreamer --without-sdl --without-gnutls \
    --without-cups --without-sane --without-gphoto --without-ffmpeg --without-krb5 \
    --without-netapi --without-pcap --without-usb --without-inotify --without-capi \
    --without-v4l2 --without-wayland > configure.log 2>&1) \
    || { echo "error: configure failed; see $build/configure.log" >&2; exit 1; }
fi
echo "Building winemac.so and mfreadwrite.dll…"
make -C "$build" -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so dlls/mfreadwrite/x86_64-windows/mfreadwrite.dll \
  > "$build/make.log" 2>&1 || { echo "error: build failed; see $build/make.log" >&2; exit 1; }
nm -gU "$build/dlls/winemac.drv/winemac.so" | grep -q " _macdrv_functions$" \
  || { echo "error: macdrv_functions is not exported" >&2; exit 1; }

cp -c -R "$wine_root" "$output"
cp "$build/dlls/winemac.drv/winemac.so" "$output/lib/wine/x86_64-unix/winemac.so"
x86_64-w64-mingw32-strip -o "$output/lib/wine/x86_64-windows/mfreadwrite.dll" \
  "$build/dlls/mfreadwrite/x86_64-windows/mfreadwrite.dll"
echo "Done: $output"
echo "Register it with: neutron runtime add wine \"$output\" --version wine-$version-dxmt"
