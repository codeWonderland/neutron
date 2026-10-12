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
#   winemac-gl-context-attribs.patch winemac.so creates OpenGL contexts that Windows drivers grant:
#                                    WGL_CONTEXT_OPENGL_NO_ERROR_ARB is ignored (CGL has no such
#                                    mode) and 3.2+ core profiles don't need the forward-compatible
#                                    bit (Idle Colony asserted on a null 3.3 core context).
#
#   opengl32-glsl-version.patch      opengl32.dll (32- and 64-bit): in a 3.2+ core context, GLSL
#                                    #version 130/140 is raised to 150, which macOS accepts and
#                                    Windows core contexts don't need (Dear ImGui's OpenGL3 backend).
#
#   winemac-remote-metal.patch       DXMT can present into another process's window (Chromium's
#                                    GPU process: Steam's UI) through winemac's remote-layer
#                                    swapchain. Pairs with tools/dxmt-patch/cross-process-swapchain.
#                                    Released layers linger 250 ms so resizes don't flash black.
#   d3dx9-check-version-debug.patch  d3dx9_24..43.dll (32- and 64-bit) accept the D3D_DEBUG_INFO
#                                    SDK version (32 | 0x80000000) in D3DXCheckVersion. Unreal 3
#                                    games built with it (Dungeon Defenders 2) crash at startup.
#   faudio-wma-bytes-requested.patch xaudio2_*.dll and xactengine*.dll (32- and 64-bit): upstream
#                                    FAudio ee018363, no divide by zero for xWMA voices with an
#                                    OnVoiceProcessingPassStart callback (Skyrim SE crashed).
#   bcrypt-des.patch                 bcrypt.dll (32- and 64-bit): DES and 3DES encryption (ECB/CBC/CFB,
#                                    via the bundled SymCrypt), which .NET's DES class needs
#                                    (Resonite stopped at world setup).
#
#   tools/wine-dxmt/build.sh <wine-root> <output-dir>
#
# <wine-root> is a Wine build containing bin/wine, e.g. Gcenx's
# "Wine Devel.app/Contents/Resources/wine". The output is an APFS clone of it with the
# patched files; register it with `neutron runtime add wine <output-dir>`.
# The source matching the build's version is downloaded from dl.winehq.org.
#
# Needs: Xcode command line tools, Homebrew bison and flex, mingw-w64
# (brew install bison flex mingw-w64; it has the i686 compiler for 32-bit DLLs). Tested with Wine 11.18.
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
command -v x86_64-w64-mingw32-gcc >/dev/null && command -v i686-w64-mingw32-gcc >/dev/null || { echo "error: missing mingw-w64 (brew install mingw-w64)" >&2; exit 1; }

# "wine-11.18" or "wine-11.18 (Staging)" → 11.18
version=$("$wine_root/bin/wine" --version | sed -n 's/^wine-\([0-9][0-9.]*\).*/\1/p')
[ -n "$version" ] || { echo "error: could not read the Wine version" >&2; exit 1; }
major=${version%%.*}
case "$version" in *.0) series="$major.0" ;; *) series="$major.x" ;; esac
echo "Wine $version"

mkdir -p "$work"
src="$work/wine-$version"
# .neutron-patches lists the patches applied to the tree. Overlapping patches can't be
# detected by reverse-applying, so a tree without the list is extracted again.
applied="$src/.neutron-patches"
if [ -d "$src" ] && [ ! -f "$applied" ]; then
  echo "Re-extracting the Wine $version source (no record of its patches)…"
  rm -rf "$src"
fi
if [ ! -d "$src" ]; then
  if [ ! -f "$work/wine-$version.tar.xz" ]; then
    echo "Downloading Wine $version source…"
    curl -sSfL -o "$work/wine-$version.tar.xz" "https://dl.winehq.org/wine/source/$series/wine-$version.tar.xz"
  fi
  tar -xJf "$work/wine-$version.tar.xz" -C "$work"
  : > "$applied"
fi
# Apply each patch once; a source tree from an earlier run may lack newer ones.
for p in "$here"/*.patch; do
  name=$(basename "$p")
  grep -qx "$name" "$applied" && continue
  (cd "$src" && patch -p1 --forward --quiet < "$p") || { echo "error: $name does not apply" >&2; exit 1; }
  echo "$name" >> "$applied"
done

build="$work/build-$version"
mkdir -p "$build"
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=10.15
# Trees configured before the 32-bit d3dx9 DLLs were added lack i386; configure again.
if [ ! -f "$build/Makefile" ] || ! grep -q "^PE_ARCHS = *i386" "$build/Makefile"; then
  echo "Configuring (i386, x86_64)…"
  (cd "$build" && "$src/configure" CC="clang -arch x86_64" OBJC="clang -arch x86_64" \
    --host=x86_64-apple-darwin --enable-archs=i386,x86_64 --disable-tests \
    --without-x --without-freetype --without-gstreamer --without-sdl --without-gnutls \
    --without-cups --without-sane --without-gphoto --without-ffmpeg --without-krb5 \
    --without-netapi --without-pcap --without-usb --without-inotify --without-capi \
    --without-v4l2 --without-wayland > configure.log 2>&1) \
    || { echo "error: configure failed; see $build/configure.log" >&2; exit 1; }
fi
# Windows-side DLLs rebuilt for both architectures.
pe_dlls=$(cd "$src/dlls" && ls -d d3dx9_* xaudio2_* xactengine* bcrypt opengl32)
pe_targets=""
for n in $pe_dlls; do
  pe_targets="$pe_targets dlls/$n/i386-windows/$n.dll dlls/$n/x86_64-windows/$n.dll"
done
echo "Building winemac.so, mfreadwrite.dll, d3dx9_*, xaudio2_*, xactengine*, bcrypt and opengl32…"
make -C "$build" -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so dlls/mfreadwrite/x86_64-windows/mfreadwrite.dll $pe_targets \
  > "$build/make.log" 2>&1 || { echo "error: build failed; see $build/make.log" >&2; exit 1; }
nm -gU "$build/dlls/winemac.drv/winemac.so" | grep -q " _macdrv_functions$" \
  || { echo "error: macdrv_functions is not exported" >&2; exit 1; }

cp -c -R "$wine_root" "$output"
cp "$build/dlls/winemac.drv/winemac.so" "$output/lib/wine/x86_64-unix/winemac.so"
x86_64-w64-mingw32-strip -o "$output/lib/wine/x86_64-windows/mfreadwrite.dll" \
  "$build/dlls/mfreadwrite/x86_64-windows/mfreadwrite.dll"
for n in $pe_dlls; do
  i686-w64-mingw32-strip -o "$output/lib/wine/i386-windows/$n.dll" "$build/dlls/$n/i386-windows/$n.dll"
  x86_64-w64-mingw32-strip -o "$output/lib/wine/x86_64-windows/$n.dll" "$build/dlls/$n/x86_64-windows/$n.dll"
done
echo "Done: $output"
echo "Register it with: neutron runtime add wine \"$output\" --version wine-$version-dxmt"
