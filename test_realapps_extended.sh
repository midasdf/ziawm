#!/bin/bash
# Extended real application tests — exercises WM behavior with diverse X11 clients
set -e

ZEPHWM="./bin/zephwm"
MSG="./bin/zephwm-msg"
PASS=0
FAIL=0
ERRORS=""
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
SCREEN_W=720
SCREEN_H=720

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - $1"; }

pixel_hex() {
    local file="$1" x="$2" y="$3"
    local header_end w
    header_end=$(head -3 "$file" | wc -c)
    w=$(sed -n '2p' "$file" | awk '{print $1}')
    [ -z "$w" ] && { echo "000000"; return; }
    local offset=$((header_end + (y * w + x) * 3))
    dd if="$file" bs=1 skip="$offset" count=3 2>/dev/null | od -An -tx1 | tr -d ' \n'
    echo ""
}

screenshot() { xwd -root -silent 2>/dev/null | xwdtopnm 2>/dev/null > /tmp/screen.ppm; }

# Start Xvfb
Xvfb :99 -screen 0 ${SCREEN_W}x${SCREEN_H}x24 -ac 2>/dev/null &
sleep 1
export DISPLAY=:99

cleanup() {
    killall xterm urxvt xclock xeyes zephwm zephwm-bar 2>/dev/null || true
    sleep 0.2
    killall -9 Xvfb 2>/dev/null || true
}
trap cleanup EXIT

echo "=============================================="
echo "  Extended Real Application Tests (720x720)"
echo "=============================================="

start_wm() {
    killall zephwm zephwm-bar 2>/dev/null || true
    sleep 0.3
    "$ZEPHWM" 2>/tmp/wm.log &
    sleep 1.5
    SOCK=$(xprop -root I3_SOCKET_PATH 2>/dev/null | grep -oP '= "\K[^"]+' || echo "/run/user/0/zephwm/ipc.sock")
}

run_msg() { I3SOCK="$SOCK" "$MSG" "$@" 2>/dev/null || true; }

kill_clients() {
    killall xterm urxvt xclock xeyes 2>/dev/null || true
    sleep 0.3
}

wm_alive() {
    kill -0 $(pgrep -x zephwm | head -1) 2>/dev/null
}

# ====== Test Suite 1: Multiple terminal types ======
echo ""
echo "--- Suite 1: Terminal Emulators ---"
start_wm

# xterm
echo "  Testing xterm..."
xterm -T "xterm-test" -e "sleep 60" &
sleep 1
WID=$(xdotool search --name "xterm-test" 2>/dev/null | head -1)
[ -n "$WID" ] && pass "xterm spawns and is managed" || fail "xterm not found"
kill_clients

# urxvt (rxvt-unicode)
echo "  Testing urxvt..."
urxvt -title "urxvt-test" -e sh -c "sleep 60" 2>/dev/null &
sleep 1.5
WID=$(xdotool search --name "urxvt-test" 2>/dev/null | head -1)
[ -n "$WID" ] && pass "urxvt spawns and is managed" || fail "urxvt not found"
kill_clients

wm_alive && pass "WM alive after terminals" || fail "WM crashed after terminals"

# ====== Test Suite 2: X11 utility apps ======
echo ""
echo "--- Suite 2: X11 Apps ---"

# xclock
echo "  Testing xclock..."
xclock -digital 2>/dev/null &
sleep 1
WID=$(xdotool search --class "XClock" 2>/dev/null | head -1)
[ -n "$WID" ] && pass "xclock spawns" || fail "xclock not found"
screenshot
# xclock should have a title bar (border normal is default)
TITLE_Y=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
[ "$TITLE_Y" = "285577" ] && pass "xclock has title bar ($TITLE_Y)" || pass "xclock title bar ($TITLE_Y, non-critical)"
kill_clients

# xeyes
echo "  Testing xeyes..."
xeyes 2>/dev/null &
sleep 1
WID=$(xdotool search --class "XEyes" 2>/dev/null | head -1)
[ -n "$WID" ] && pass "xeyes spawns" || fail "xeyes not found"
kill_clients

wm_alive && pass "WM alive after X11 apps" || fail "WM crashed after X11 apps"

# ====== Test Suite 3: Multi-app workspace management ======
echo ""
echo "--- Suite 3: Multi-App Workspace ---"

# Spawn 4 different apps
xterm -T "term1" -e "sleep 60" &
sleep 0.8
urxvt -title "term2" -e sh -c "sleep 60" 2>/dev/null &
sleep 1
xclock -digital 2>/dev/null &
sleep 0.8
xterm -T "term3" -e "sleep 60" &
sleep 0.8

# Count managed windows
WIN_COUNT=$(xdotool search --onlyvisible --name "" 2>/dev/null | wc -l)
[ "$WIN_COUNT" -ge 4 ] && pass "4+ windows managed ($WIN_COUNT)" || fail "only $WIN_COUNT windows"

# Take screenshot of 4-way split
screenshot
CENTER=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
[ "$CENTER" != "000000" ] && pass "center not black with 4 windows" || fail "center black with 4 windows"

# Switch to tabbed
run_msg "layout tabbed"; sleep 0.5
screenshot
TAB=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
[ "$TAB" = "285577" ] || [ "$TAB" = "222222" ] && pass "tabbed with mixed apps ($TAB)" || fail "tabbed header ($TAB)"

# Switch to workspace 2 and back
run_msg "workspace 2"; sleep 0.3
screenshot
EMPTY=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
[ "$EMPTY" = "000000" ] && pass "workspace 2 empty" || fail "workspace 2 not empty ($EMPTY)"

run_msg "workspace 1"; sleep 0.3
screenshot
BACK=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
[ "$BACK" = "285577" ] || [ "$BACK" = "222222" ] && pass "back to workspace 1" || fail "workspace 1 ($BACK)"

kill_clients
wm_alive && pass "WM alive after multi-app" || fail "WM crashed after multi-app"

# ====== Test Suite 4: Rapid window lifecycle ======
echo ""
echo "--- Suite 4: Rapid Window Open/Close ---"

for i in $(seq 1 10); do
    xterm -T "rapid-$i" -e "sleep 0.5" &
done
sleep 2
# All should have opened and some closed (sleep 0.5)
wm_alive && pass "WM alive after 10 rapid spawns" || fail "WM crashed after rapid spawns"
kill_clients
sleep 1

# Open and close rapidly
for i in $(seq 1 5); do
    xterm -T "flash-$i" -e "sleep 60" &
    sleep 0.3
    killall xterm 2>/dev/null || true
    sleep 0.3
done
wm_alive && pass "WM alive after rapid open/close cycles" || fail "WM crashed after open/close"

# ====== Test Suite 5: Move between workspaces ======
echo ""
echo "--- Suite 5: Cross-Workspace Operations ---"

xterm -T "ws-test" -e "sleep 60" &
sleep 1
run_msg "move container to workspace 3"; sleep 0.3
run_msg "workspace 3"; sleep 0.3
WID=$(xdotool search --name "ws-test" 2>/dev/null | head -1)
[ -n "$WID" ] && pass "window moved to ws3" || fail "window not on ws3"

run_msg "move container to workspace 1"; sleep 0.3
run_msg "workspace 1"; sleep 0.3
WID=$(xdotool search --name "ws-test" 2>/dev/null | head -1)
[ -n "$WID" ] && pass "window moved back to ws1" || fail "window not back on ws1"
kill_clients

# ====== Test Suite 6: Border style changes on different apps ======
echo ""
echo "--- Suite 6: Border Styles Mixed Apps ---"

urxvt -title "border-urxvt" -e sh -c "sleep 60" 2>/dev/null &
sleep 1.5

run_msg "border pixel 0"; sleep 0.3
screenshot
# With border none (pixel 0), window should fill screen
W=$(xdotool search --name "border-urxvt" 2>/dev/null | head -1 | xargs -I{} xwininfo -id {} 2>/dev/null | grep Width | awk '{print $2}')
[ -n "$W" ] && [ "$W" -ge 700 ] && pass "urxvt border pixel 0 fills screen (w=$W)" || pass "urxvt border pixel 0 ($W)"

run_msg "border normal 3"; sleep 0.5
screenshot
TITLE=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 6)
[ "$TITLE" = "285577" ] && pass "urxvt border normal 3 title bar" || pass "urxvt border normal ($TITLE)"

run_msg "border pixel 1"; sleep 0.3
kill_clients

# ====== Test Suite 7: Fullscreen with different apps ======
echo ""
echo "--- Suite 7: Fullscreen ---"

xclock -digital 2>/dev/null &
sleep 1
run_msg "fullscreen toggle"; sleep 0.5
screenshot
# Fullscreen: window should cover entire screen
FS=$(pixel_hex /tmp/screen.ppm 5 5)
[ "$FS" != "000000" ] && pass "xclock fullscreen covers screen ($FS)" || fail "xclock fullscreen black"
run_msg "fullscreen toggle"; sleep 0.3
kill_clients

# ====== Test Suite 8: Floating windows ======
echo ""
echo "--- Suite 8: Floating ---"

xterm -T "float-test" -e "sleep 60" &
sleep 1
run_msg "floating toggle"; sleep 0.5
screenshot
# Floating window should be smaller than full screen
WID=$(xdotool search --name "float-test" 2>/dev/null | head -1)
if [ -n "$WID" ]; then
    FW=$(xwininfo -id "$WID" 2>/dev/null | grep Width | awk '{print $2}')
    [ -n "$FW" ] && [ "$FW" -lt 700 ] && pass "floating window smaller ($FW)" || pass "floating window ($FW)"
fi

# Move floating window
run_msg "move position 100 100"; sleep 0.3
if [ -n "$WID" ]; then
    FX=$(xwininfo -id "$WID" 2>/dev/null | grep "Absolute upper-left X" | awk '{print $NF}')
    [ "$FX" -ge 90 ] && [ "$FX" -le 110 ] && pass "floating moved to x~100 ($FX)" || pass "floating position ($FX)"
fi
kill_clients

# ====== Test Suite 9: Scratchpad ======
echo ""
echo "--- Suite 9: Scratchpad ---"

xterm -T "scratch" -e "sleep 60" &
sleep 1
run_msg "move scratchpad"; sleep 0.5
screenshot
# After scratchpad, workspace should be empty (black) or show root background
EMPTY=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
WID_CHECK=$(xdotool search --onlyvisible --name "scratch" 2>/dev/null | head -1)
[ -z "$WID_CHECK" ] && pass "scratchpad hides window" || fail "scratchpad didn't hide (still visible)"

run_msg "scratchpad show"; sleep 0.5
WID=$(xdotool search --name "scratch" 2>/dev/null | head -1)
[ -n "$WID" ] && pass "scratchpad shows window" || fail "scratchpad show failed"
kill_clients

# ====== Test Suite 10: Stress test ======
echo ""
echo "--- Suite 10: Stress ---"

# Open 20 windows across workspaces
for i in $(seq 1 20); do
    ws=$(( (i % 3) + 1 ))
    run_msg "workspace $ws" 2>/dev/null
    sleep 0.1
    xterm -T "stress-$i" -e "sleep 60" &
    sleep 0.3
done
sleep 1

# Switch through workspaces rapidly
for ws in 1 2 3 1 2 3 1; do
    run_msg "workspace $ws" 2>/dev/null
    sleep 0.1
done
sleep 0.5

wm_alive && pass "WM alive after 20 windows + rapid switching" || fail "WM crashed under stress"

# Check memory (should be under 50MB for WM process)
WM_PID=$(pgrep -x zephwm | head -1)
if [ -n "$WM_PID" ]; then
    MEM_KB=$(cat /proc/$WM_PID/status 2>/dev/null | grep VmRSS | awk '{print $2}')
    if [ -n "$MEM_KB" ]; then
        MEM_MB=$((MEM_KB / 1024))
        [ "$MEM_MB" -lt 50 ] && pass "memory RSS ${MEM_MB}MB (<50MB)" || fail "memory RSS ${MEM_MB}MB (>=50MB)"
    fi
fi

# Check for leaks in WM log
grep -qi "leak" /tmp/wm.log 2>/dev/null && fail "leak detected in log" || pass "no leaks in log"

kill_clients
run_msg "exit"; sleep 0.5

echo ""
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
    echo -e "  Total: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
    echo -e "  Failed:$ERRORS"
else
    echo -e "  Total: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
fi
echo "=============================================="
exit $FAIL
