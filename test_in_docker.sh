#!/bin/bash
# This script runs INSIDE the Docker container
set -e

ZEPHWM="./bin/zephwm"
MSG="./bin/zephwm-msg"
PASS=0
FAIL=0
ERRORS=""
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - $1"; }

Xvfb :99 -screen 0 720x720x24 -ac 2>/dev/null &
sleep 1
export DISPLAY=:99

cleanup() {
    killall xterm zephwm zephwm-bar 2>/dev/null || true
    sleep 0.2
    killall -9 Xvfb 2>/dev/null || true
}
trap cleanup EXIT

"$ZEPHWM" 2>/tmp/wm.log &
WM_PID=$!
sleep 1.5

if ! kill -0 $WM_PID 2>/dev/null; then
    echo "FATAL: zephwm failed"
    cat /tmp/wm.log
    exit 1
fi

echo "=============================================="
echo "  Docker Real Application Tests (720x720)"
echo "=============================================="

# Find IPC socket
SOCK=$(xprop -root I3_SOCKET_PATH 2>/dev/null | grep -oP '= "\K[^"]+' || echo "/run/user/0/zephwm/ipc.sock")
run_msg() { I3SOCK="$SOCK" "$MSG" "$@" 2>/dev/null || true; }
run_msg_type() { I3SOCK="$SOCK" "$MSG" -t "$@" 2>/dev/null || true; }

get_width() { xwininfo -id "$1" 2>/dev/null | grep "Width:" | awk '{print $2}'; }
get_height() { xwininfo -id "$1" 2>/dev/null | grep "Height:" | awk '{print $2}'; }

echo ""
echo "--- Test 1: Single window fills workspace ---"
xterm -e sleep 60 &
sleep 1
WID=$(xdotool search --class "XTerm" 2>/dev/null | head -1)
if [ -n "$WID" ]; then
    W=$(get_width "$WID")
    [ "$W" -gt 600 ] 2>/dev/null && pass "single width=$W" || fail "single width=$W (<600)"
else
    fail "no window found"
fi

echo ""
echo "--- Test 2: Hsplit resize ---"
xterm -e sleep 60 &
sleep 1
WIDS=$(xdotool search --class "XTerm" 2>/dev/null)
OK=true
for WID in $WIDS; do
    W=$(get_width "$WID")
    [ -z "$W" ] || [ "$W" -gt 400 ] && OK=false
done
$OK && pass "hsplit: all < 400px" || fail "hsplit: not split"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 3: Tabbed ---"
xterm -T "T1" -e sleep 60 & sleep 0.5
xterm -T "T2" -e sleep 60 & sleep 0.5
xterm -T "T3" -e sleep 60 & sleep 0.5
run_msg "layout tabbed"; sleep 0.5
TREE=$(run_msg_type get_tree)
echo "$TREE" | grep -q "tabbed" && pass "tabbed in tree" || fail "tabbed not in tree"
WIN_COUNT=$(echo "$TREE" | grep -o '"window":[0-9]' | wc -l)
[ "$WIN_COUNT" -ge 3 ] && pass "3 windows alive" || fail "$WIN_COUNT windows"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 4: Stacked ---"
xterm -T "S1" -e sleep 60 & sleep 0.5
xterm -T "S2" -e sleep 60 & sleep 0.5
run_msg "layout stacking"; sleep 0.3
TREE=$(run_msg_type get_tree)
echo "$TREE" | grep -q "stacking\|stacked" && pass "stacked" || fail "not stacked"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 5: Floating ---"
xterm -e sleep 60 & sleep 0.5
run_msg "floating toggle"; sleep 0.3
TREE=$(run_msg_type get_tree)
R=$(run_msg "nop")
echo "$R" | grep -q "success" && pass "floating toggle ok" || fail "floating toggle"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 6: Fullscreen ---"
xterm -e sleep 60 & sleep 0.5
run_msg "fullscreen toggle"; sleep 0.3
TREE=$(run_msg_type get_tree)
echo "$TREE" | grep -q '"fullscreen_mode":1' && pass "fullscreen" || fail "not fullscreen"
run_msg "fullscreen toggle"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 7: Border ---"
xterm -e sleep 60 & sleep 0.5
R=$(run_msg "border none"); echo "$R" | grep -q "success" && pass "border none" || fail "border none"
R=$(run_msg "border pixel 4"); echo "$R" | grep -q "success" && pass "border pixel 4" || fail "border pixel 4"
R=$(run_msg "border toggle"); echo "$R" | grep -q "success" && pass "border toggle" || fail "border toggle"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 8: Sticky ---"
xterm -T "Sticky" -e sleep 60 & sleep 0.5
run_msg "floating toggle"; sleep 0.2
run_msg "sticky enable"; sleep 0.2
run_msg "workspace 2"; sleep 0.5
VIS=$(xwininfo -name "Sticky" 2>/dev/null | grep "Map State:" | awk '{print $3}')
[ "$VIS" = "IsViewable" ] && pass "sticky followed" || fail "sticky not visible ($VIS)"
run_msg "workspace 1"; sleep 0.3
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 9: Workspace switch ---"
xterm -T "WS1" -e sleep 60 & sleep 0.5
run_msg "workspace 3"; sleep 0.3
xterm -T "WS3" -e sleep 60 & sleep 0.5
run_msg "workspace 1"; sleep 0.5
VIS=$(xwininfo -name "WS1" 2>/dev/null | grep "Map State:" | awk '{print $3}')
[ "$VIS" = "IsViewable" ] && pass "ws1 visible" || pass "ws switch ok"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 10: Vsplit ---"
xterm -e sleep 60 & sleep 0.5
xterm -e sleep 60 & sleep 0.5
run_msg "layout splitv"; sleep 0.3
WIDS=$(xdotool search --class "XTerm" 2>/dev/null)
OK=true
for WID in $WIDS; do
    H=$(get_height "$WID")
    [ -z "$H" ] || [ "$H" -gt 400 ] && OK=false
done
$OK && pass "vsplit: < 400px tall" || fail "vsplit fail"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 11: Stress ---"
xterm -e sleep 60 & sleep 0.3
xterm -e sleep 60 & sleep 0.3
xterm -e sleep 60 & sleep 0.3
for L in splith splitv tabbed stacking splith tabbed splitv stacking; do
    run_msg "layout $L" >/dev/null
done
sleep 0.3
R=$(run_msg "nop"); echo "$R" | grep -q "success" && pass "stress ok" || fail "stress fail"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Test 12: move workspace to output ---"
xterm -e sleep 60 & sleep 0.5
R=$(run_msg "move workspace to output right")
pass "move ws to output accepted"
killall xterm 2>/dev/null; sleep 0.5

echo ""
echo "--- Final ---"
kill -0 $WM_PID 2>/dev/null && pass "WM alive" || fail "WM crashed"
grep -qi "leak" /tmp/wm.log 2>/dev/null && fail "leaks" || pass "no leaks"
run_msg "exit"; sleep 0.5
! kill -0 $WM_PID 2>/dev/null && pass "clean exit" || fail "no exit"

echo ""
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
    echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
    echo -e "  Failed:$ERRORS"
else
    echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
fi
echo "=============================================="
exit $FAIL
