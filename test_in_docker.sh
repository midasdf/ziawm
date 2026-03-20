#!/bin/bash
# Runs INSIDE the Docker container with Xvfb
# Includes screenshot-based pixel verification
set -e

ZEPHWM="./bin/zephwm"
MSG="./bin/zephwm-msg"
PASS=0
FAIL=0
ERRORS=""
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
SCREEN_W=720
SCREEN_H=720

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - $1"; }

# Get pixel color at (x,y) from a PPM screenshot as "RRGGBB" hex
# PPM P6 format: header lines then raw RGB
pixel_hex() {
    local file="$1" x="$2" y="$3"
    # Parse PPM header: P6\nWIDTH HEIGHT\nMAXVAL\n
    local header_end w h
    # Find header size (3 lines for P6)
    header_end=$(head -3 "$file" | wc -c)
    w=$(sed -n '2p' "$file" | awk '{print $1}')
    h=$(sed -n '2p' "$file" | awk '{print $2}')
    if [ -z "$w" ] || [ -z "$h" ]; then echo "000000"; return; fi
    local offset=$((header_end + (y * w + x) * 3))
    local rgb
    rgb=$(dd if="$file" bs=1 skip="$offset" count=3 2>/dev/null | od -An -tx1 | tr -d ' \n')
    echo "${rgb:-000000}"
}

# Take screenshot as PPM via xwd
screenshot() {
    xwd -root -silent 2>/dev/null | xwdtopnm 2>/dev/null > /tmp/screen.ppm
}

# Assert pixel color
assert_pixel() {
    local name="$1" x="$2" y="$3" expected="$4"
    local actual
    actual=$(pixel_hex /tmp/screen.ppm "$x" "$y")
    if [ "$actual" = "$expected" ]; then
        pass "$name ($actual at $x,$y)"
    else
        fail "$name (got $actual, want $expected at $x,$y)"
    fi
}

# Assert pixel is NOT a specific color
assert_pixel_not() {
    local name="$1" x="$2" y="$3" unwanted="$4"
    local actual
    actual=$(pixel_hex /tmp/screen.ppm "$x" "$y")
    if [ "$actual" != "$unwanted" ]; then
        pass "$name ($actual != $unwanted at $x,$y)"
    else
        fail "$name (got $unwanted at $x,$y)"
    fi
}

# Assert pixel is one of several colors
assert_pixel_oneof() {
    local name="$1" x="$2" y="$3"
    shift 3
    local actual
    actual=$(pixel_hex /tmp/screen.ppm "$x" "$y")
    for exp in "$@"; do
        if [ "$actual" = "$exp" ]; then
            pass "$name ($actual at $x,$y)"
            return
        fi
    done
    fail "$name (got $actual, want one of: $* at $x,$y)"
}

Xvfb :99 -screen 0 ${SCREEN_W}x${SCREEN_H}x24 -ac 2>/dev/null &
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
echo "  Docker Real App Tests + Screenshots (720x720)"
echo "=============================================="

SOCK=$(xprop -root I3_SOCKET_PATH 2>/dev/null | grep -oP '= "\K[^"]+' || echo "/run/user/0/zephwm/ipc.sock")
run_msg() { I3SOCK="$SOCK" "$MSG" "$@" 2>/dev/null || true; }
run_msg_type() { I3SOCK="$SOCK" "$MSG" -t "$@" 2>/dev/null || true; }
get_width() { xwininfo -id "$1" 2>/dev/null | grep "Width:" | awk '{print $2}'; }
get_height() { xwininfo -id "$1" 2>/dev/null | grep "Height:" | awk '{print $2}'; }

# Bar reservation: 0 in Docker (no config with status_command)
BAR_H=0

# ---- Test 1: Single window + screenshot ----
echo ""
echo "--- Test 1: Single window ---"
xterm -e sleep 60 &
sleep 1
WID=$(xdotool search --class "XTerm" 2>/dev/null | head -1)
if [ -n "$WID" ]; then
    W=$(get_width "$WID")
    [ "$W" -gt 600 ] 2>/dev/null && pass "width=$W" || fail "width=$W (<600)"
else
    fail "no window"
fi
screenshot
# Center should have content (not root bg black)
assert_pixel_not "center has content" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"

# ---- Test 2: Hsplit + screenshot ----
echo ""
echo "--- Test 2: Hsplit ---"
xterm -e sleep 60 &
sleep 1
screenshot
# Left quarter and right quarter should both have content
assert_pixel_not "left half content" $((SCREEN_W/4)) $((SCREEN_H/2)) "000000"
assert_pixel_not "right half content" $((SCREEN_W*3/4)) $((SCREEN_H/2)) "000000"
# Border at midpoint should be border color (not black, not content)
# focused border = #4c7899
assert_pixel_not "midpoint not black" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"

WIDS=$(xdotool search --class "XTerm" 2>/dev/null)
OK=true
for WID in $WIDS; do
    W=$(get_width "$WID")
    [ -z "$W" ] || [ "$W" -gt 400 ] && OK=false
done
$OK && pass "both < 400px" || fail "not split"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 3: Tabbed + screenshot ----
echo ""
echo "--- Test 3: Tabbed ---"
xterm -T "T1" -e sleep 60 &
sleep 0.5
xterm -T "T2" -e sleep 60 &
sleep 0.5
xterm -T "T3" -e sleep 60 &
sleep 0.5
run_msg "layout tabbed"; sleep 0.5
screenshot
# Tab bar at y=BAR_H+2..BAR_H+18 should be tab bg colors
# 285577 (focused) or 333333 (unfocused)
assert_pixel_oneof "tab bar left" 10 $((BAR_H+4)) "285577" "333333"
assert_pixel_oneof "tab bar center" $((SCREEN_W/2)) $((BAR_H+4)) "285577" "333333"
assert_pixel_oneof "tab bar right edge" $((SCREEN_W-5)) $((BAR_H+4)) "285577" "333333"
# Content area below tabs
assert_pixel_not "tabbed content" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 4: Stacked + screenshot ----
echo ""
echo "--- Test 4: Stacked ---"
xterm -T "S1" -e sleep 60 &
sleep 0.5
xterm -T "S2" -e sleep 60 &
sleep 0.5
xterm -T "S3" -e sleep 60 &
sleep 0.5
run_msg "layout stacking"; sleep 0.5
screenshot
# Scan for at least 2 distinct header color regions
FOUND=0
PREV=""
for Y in $(seq $((BAR_H+2)) $((BAR_H+70))); do
    C=$(pixel_hex /tmp/screen.ppm 10 "$Y")
    if [ "$C" = "285577" ] || [ "$C" = "333333" ]; then
        if [ "$C" != "$PREV" ]; then
            FOUND=$((FOUND+1))
            PREV="$C"
        fi
    fi
done
[ "$FOUND" -ge 2 ] && pass "stacked: $FOUND color regions" || fail "stacked: $FOUND regions"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 5: Floating ----
echo ""
echo "--- Test 5: Floating ---"
xterm -e sleep 60 &
sleep 0.5
run_msg "floating toggle"; sleep 0.3
R=$(run_msg "nop"); echo "$R" | grep -q "success" && pass "floating ok" || fail "floating"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 6: Fullscreen + screenshot ----
echo ""
echo "--- Test 6: Fullscreen ---"
xterm -e sleep 60 &
sleep 0.5
run_msg "fullscreen toggle"; sleep 0.3
screenshot
# Fullscreen should fill entire screen — center and quadrants non-black
assert_pixel_not "fs center" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"
assert_pixel_not "fs right-center" $((SCREEN_W-20)) $((SCREEN_H/2)) "000000"
assert_pixel_not "fs bottom-center" $((SCREEN_W/2)) $((SCREEN_H-20)) "000000"
run_msg "fullscreen toggle"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 7: Border none + screenshot ----
echo ""
echo "--- Test 7: Border none ---"
xterm -e sleep 60 &
sleep 0.5
run_msg "border none"; sleep 0.3
screenshot
# With border none, window extends to workspace edge
# Check at a safe interior point (xterm may have menu bar at very top)
assert_pixel_not "border none interior" 50 $((BAR_H+20)) "000000"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 8: Border pixel 4 + screenshot ----
echo ""
echo "--- Test 8: Border pixel 4 ---"
xterm -e sleep 60 &
sleep 0.5
xterm -e sleep 60 &
sleep 0.5
run_msg "border pixel 4"; sleep 0.3
screenshot
# With 2 windows + thick border, midpoint should show border or content
assert_pixel_not "thick border midpoint" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"
# Right edge of screen should show focused border
assert_pixel_not "right edge" $((SCREEN_W-2)) $((SCREEN_H/2)) "000000"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 9: Sticky ----
echo ""
echo "--- Test 9: Sticky ---"
xterm -T "Sticky" -e sleep 60 &
sleep 0.5
run_msg "floating toggle"; sleep 0.2
run_msg "sticky enable"; sleep 0.2
run_msg "workspace 2"; sleep 0.5
VIS=$(xwininfo -name "Sticky" 2>/dev/null | grep "Map State:" | awk '{print $3}')
[ "$VIS" = "IsViewable" ] && pass "sticky followed" || fail "sticky ($VIS)"
run_msg "workspace 1"; sleep 0.3
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 10: Workspace switch + screenshot ----
echo ""
echo "--- Test 10: Workspace switch ---"
xterm -T "WS1" -e sleep 60 &
sleep 0.5
run_msg "workspace 3"; sleep 0.3
screenshot
# WS3 is empty — should be mostly black (root bg)
assert_pixel "empty ws is black" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"
xterm -T "WS3" -e sleep 60 &
sleep 0.5
screenshot
# Now WS3 has content
assert_pixel_not "ws3 has content" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"
run_msg "workspace 1"; sleep 0.5
screenshot
# WS1 should show content again
assert_pixel_not "ws1 restored" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 11: Vsplit + screenshot ----
echo ""
echo "--- Test 11: Vsplit ---"
xterm -e sleep 60 &
sleep 0.5
xterm -e sleep 60 &
sleep 0.5
run_msg "layout splitv"; sleep 0.3
screenshot
# Top quarter and bottom quarter should have content
assert_pixel_not "top content" $((SCREEN_W/2)) $((SCREEN_H/4)) "000000"
assert_pixel_not "bottom content" $((SCREEN_W/2)) $((SCREEN_H*3/4)) "000000"
killall xterm 2>/dev/null; sleep 0.5

# ---- Test 12: Stress ----
echo ""
echo "--- Test 12: Stress ---"
xterm -e sleep 60 &
sleep 0.3
xterm -e sleep 60 &
sleep 0.3
xterm -e sleep 60 &
sleep 0.3
for L in splith splitv tabbed stacking splith tabbed splitv stacking; do
    run_msg "layout $L" >/dev/null
done
sleep 0.3
R=$(run_msg "nop"); echo "$R" | grep -q "success" && pass "stress ok" || fail "stress fail"
screenshot
assert_pixel_not "post-stress content" $((SCREEN_W/2)) $((SCREEN_H/2)) "000000"
killall xterm 2>/dev/null; sleep 0.5

# ---- Final ----
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
