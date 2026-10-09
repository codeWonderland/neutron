#!/bin/sh
# Smoke test: launch a Windows program through Neutron, wait, capture its window, stop the
# prefix, and report PASS when a window shows something other than black and no Wine error
# dialog (assertion box, crash report, ...) is up. A window smaller than 640x360 is reported
# as SPLASH (a launcher splash that never gave way to the game), not PASS.
#
#   tools/smoke/smoke.sh <prefix> <exe> [seconds=45] [neutron run options...] [-- program args]
#
# Results (window.png, screen.png, run.log) go to $SMOKE_OUT (default .build/smoke/<exe>).
# Needs the Screen Recording permission for the terminal.
set -u
prefix=$1 exe=$2 secs=${3:-45}
shift 2; [ $# -gt 0 ] && shift
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
neutron=${NEUTRON:-$root/.build/release/neutron}
winshot=$root/.build/smoke/winshot
name=$(basename "$exe" .exe)
out=${SMOKE_OUT:-$root/.build/smoke/$name}
mkdir -p "$out" "$(dirname "$winshot")"
[ -x "$winshot" ] && [ "$winshot" -nt "$here/winshot.swift" ] || swiftc -O "$here/winshot.swift" -o "$winshot" || exit 2
[ -x "$neutron" ] || { echo "build Neutron first: swift build -c release" >&2; exit 2; }

"$neutron" run "$exe" -p "$prefix" "$@" > "$out/run.log" 2>&1 &
pid=$!
sleep "$secs"
# Splash screens fade in from black, so try a few captures before giving up.
result=FAIL
for attempt in 1 2 3 4; do
  shot=$("$winshot" "$out/window.png" 2>&1)
  state=$(kill -0 $pid 2>/dev/null && echo running || echo exited)
  lit=$(echo "$shot" | head -1 | awk '{print $2}')
  size=$(echo "$shot" | head -1 | awk '{print $3}')
  width=${size%x*} height=${size#*x}
  if echo "$shot" | grep -q "^dialog:"; then break; fi   # an error dialog is showing
  if [ "$state" = running ] && [ -n "$lit" ] && [ "$lit" -ge 5 ] 2>/dev/null; then
    if [ "$width" -lt 640 ] 2>/dev/null || [ "$height" -lt 360 ] 2>/dev/null; then result=SPLASH; else result=PASS; break; fi
  fi
  [ "$state" = exited ] && break
  sleep 5
done
screencapture -x "$out/screen.png" 2>/dev/null
"$neutron" kill -p "$prefix" > /dev/null 2>&1
echo "$result $name: $state after ${secs}s; window: $(echo "$shot" | tr '\n' ';' | sed 's/;$//')"
[ "$result" = PASS ]
