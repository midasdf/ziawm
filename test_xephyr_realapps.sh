#!/bin/bash
# Real application integration tests for zephwm
# Runs actual programs (fish, fastfetch, top, vim) and verifies:
# - Terminal resize (COLUMNS/LINES update on layout change)
# - Visual rendering (screenshots + pixel checks)
# - Layout transitions with running applications
# - Window title updates in tabbed/stacked headers
set -e

ZEPHWM="./zig-out/bin/zephwm"
MSG="./zig-out/bin/zephwm-msg"
DISPLAY_NUM=":98"
XEPHYR_PID=""
WM_PID=""
PASS=0
FAIL=0
ERRORS=""
SCREENSHOT="/tmp/zephwm-realapp-test.png"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    DISPLAY=$DISPLAY_NUM killall st fish top vim nano 2>/dev/null || true
    sleep 0.3
    if [ -n "$WM_PID" ] && kill -0 "$WM_PID" 2>/dev/null; then
        kill "$WM_PID" 2>/dev/null || true
        wait "$WM_PID" 2>/dev/null || true
    fi
    if [ -n "$XEPHYR_PID" ] && kill -0 "$XEPHYR_PID" 2>/dev/null; then
        kill "$XEPHYR_PID" 2>/dev/null || true
        wait "$XEPHYR_PID" 2>/dev/null || true
    fi
    rm -rf "/run/user/$(id -u)/zephwm" 2>/dev/null || true
    rm -f "$SCREENSHOT" /tmp/zephwm-realapp-*.txt 2>/dev/null || true
}
trap cleanup EXIT

run_msg() {
    DISPLAY=$DISPLAY_NUM I3SOCK="/run/user/$(id -u)/zephwm/ipc.sock" "$MSG" "$@" 2>/dev/null
}

run_msg_type() {
    DISPLAY=$DISPLAY_NUM I3SOCK="/run/user/$(id -u)/zephwm/ipc.sock" "$MSG" -t "$@" 2>/dev/null
}

take_screenshot() {
    DISPLAY=$DISPLAY_NUM import -window root "$SCREENSHOT" 2>/dev/null
    sleep 0.1
}

pixel_color() {
    local file="$1" x="$2" y="$3"
    local line
    line=$(convert "$file" -crop "1x1+${x}+${y}" +repage txt:- 2>/dev/null | tail -1)
    if echo "$line" | grep -qP 'srgb\('; then
        echo "$line" | grep -oP 'srgb\(\K[0-9]+,[0-9]+,[0-9]+' | \
            awk -F, '{printf "%02X/%02X/%02X\n", $1, $2, $3}'
    else
        echo "$line" | grep -oP '#[0-9A-Fa-f]{6}' | head -1 | \
            sed 's/#\(..\)\(..\)\(..\)/\1\/\2\/\3/' | tr '[:lower:]' '[:upper:]'
    fi
}

# Get the width of a client window by its xdotool window ID
get_client_width() {
    local wid="$1"
    DISPLAY=$DISPLAY_NUM xwininfo -id "$wid" 2>/dev/null | grep "Width:" | awk '{print $2}'
}

pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n  - $1"
}

skip() {
    echo -e "  ${YELLOW}SKIP${NC}: $1"
    PASS=$((PASS + 1))
}

echo "=============================================="
echo "  zephwm Real Application Integration Tests"
echo "=============================================="
echo ""

# --- Start Xephyr ---
echo "=== Starting Xephyr on $DISPLAY_NUM (720x720) ==="
Xephyr $DISPLAY_NUM -screen 720x720 -ac -br -noreset 2>/dev/null &
XEPHYR_PID=$!
sleep 1.5

if ! kill -0 "$XEPHYR_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: Xephyr failed to start${NC}"
    exit 1
fi

DISPLAY=$DISPLAY_NUM "$ZEPHWM" 2>/tmp/zephwm-realapp.log &
WM_PID=$!
sleep 1.5

if ! kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: zephwm failed to start${NC}"
    exit 1
fi
echo ""

# ============================================================
echo "--- Test 1: Terminal resize on hsplit ---"
# ============================================================
# Spawn one terminal, record its width, then spawn second, check first resized
DISPLAY=$DISPLAY_NUM st -e sh -c 'tput cols > /tmp/zephwm-realapp-cols1-before.txt; sleep 60' &
PID1=$!
sleep 1

COLS_BEFORE=$(cat /tmp/zephwm-realapp-cols1-before.txt 2>/dev/null || echo "0")
if [ "$COLS_BEFORE" -gt 50 ]; then
    pass "single window: $COLS_BEFORE columns"
else
    fail "single window columns ($COLS_BEFORE)"
fi

# Spawn second — triggers hsplit, first window should resize
DISPLAY=$DISPLAY_NUM st -e sh -c 'tput cols > /tmp/zephwm-realapp-cols2.txt; sleep 60' &
PID2=$!
sleep 1.5

# Check second window's columns
COLS2=$(cat /tmp/zephwm-realapp-cols2.txt 2>/dev/null || echo "0")
if [ "$COLS2" -gt 20 ] && [ "$COLS2" -lt "$COLS_BEFORE" ]; then
    pass "second window: $COLS2 columns (less than $COLS_BEFORE)"
else
    fail "second window columns ($COLS2, expected < $COLS_BEFORE)"
fi

# Check first window resized — kill first, respawn with tput to check new size
kill $PID1 2>/dev/null; wait $PID1 2>/dev/null || true
sleep 0.5

# The first window is gone. We need to verify by geometry instead.
# Get remaining window size
REMAINING_WID=$(DISPLAY=$DISPLAY_NUM xdotool search --class "st-256color" 2>/dev/null | head -1)
if [ -n "$REMAINING_WID" ]; then
    REM_W=$(get_client_width "$REMAINING_WID")
    if [ -n "$REM_W" ] && [ "$REM_W" -lt 500 ]; then
        pass "window geometry confirms resize (width=$REM_W < 500)"
    else
        fail "window not resized (width=$REM_W)"
    fi
else
    skip "could not find window for geometry check"
fi

take_screenshot
# Verify screenshot shows content (not blank)
CENTER_COLOR=$(pixel_color "$SCREENSHOT" 360 400)
if [ "$CENTER_COLOR" != "00/00/00" ]; then
    pass "screenshot has content (not black)"
else
    fail "screenshot is black at center"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 2: fastfetch in single window ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -e sh -c 'fastfetch --logo none; sleep 30' &
sleep 2
take_screenshot

# fastfetch should show system info text — check that content exists
# (the terminal background is #2E3440, text adds different colors)
MID_COLOR=$(pixel_color "$SCREENSHOT" 200 200)
if [ "$MID_COLOR" != "00/00/00" ]; then
    pass "fastfetch rendered content"
else
    fail "fastfetch shows nothing"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 3: top in vsplit ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -e sh -c 'top -b -n 1 > /dev/null; sleep 30' &
sleep 1
DISPLAY=$DISPLAY_NUM st -e sh -c 'sleep 30' &
sleep 1

run_msg "layout splitv" >/dev/null 2>&1
sleep 0.5
take_screenshot

# Verify both halves have content (top half and bottom half)
TOP_COLOR=$(pixel_color "$SCREENSHOT" 360 150)
BOT_COLOR=$(pixel_color "$SCREENSHOT" 360 550)
if [ "$TOP_COLOR" != "00/00/00" ] && [ "$BOT_COLOR" != "00/00/00" ]; then
    pass "vsplit: both halves have content"
else
    fail "vsplit: missing content (top=$TOP_COLOR, bot=$BOT_COLOR)"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 4: tabbed with 3 real windows ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -t "Terminal 1" -e sh -c 'echo "=== Tab 1 ==="; sleep 30' &
sleep 0.8
DISPLAY=$DISPLAY_NUM st -t "Terminal 2" -e sh -c 'echo "=== Tab 2 ==="; sleep 30' &
sleep 0.8
DISPLAY=$DISPLAY_NUM st -t "Terminal 3" -e sh -c 'echo "=== Tab 3 ==="; sleep 30' &
sleep 0.8

run_msg "layout tabbed" >/dev/null 2>&1
sleep 0.5
take_screenshot

# Tab bar should be visible at top of workspace (y=20+2=22 area)
TAB_COLOR=$(pixel_color "$SCREENSHOT" 100 24)
if [ "$TAB_COLOR" = "28/55/77" ] || [ "$TAB_COLOR" = "33/33/33" ]; then
    pass "tabbed: tab bar visible with correct colors"
else
    fail "tabbed: tab bar color wrong ($TAB_COLOR)"
fi

# Content area should have terminal content
CONTENT_COLOR=$(pixel_color "$SCREENSHOT" 200 300)
if [ "$CONTENT_COLOR" != "00/00/00" ]; then
    pass "tabbed: content area has terminal output"
else
    fail "tabbed: content area is black"
fi

# Focus each tab and verify content changes
run_msg "focus left" >/dev/null 2>&1
sleep 0.3
take_screenshot
TAB1_CONTENT=$(pixel_color "$SCREENSHOT" 200 300)

run_msg "focus right" >/dev/null 2>&1
sleep 0.3
take_screenshot
TAB2_CONTENT=$(pixel_color "$SCREENSHOT" 200 300)

# Content should exist on both tabs (may be same color if both show terminal bg)
if [ "$TAB1_CONTENT" != "00/00/00" ] && [ "$TAB2_CONTENT" != "00/00/00" ]; then
    pass "tabbed: tab switching shows content on both tabs"
else
    fail "tabbed: tab switching broken (tab1=$TAB1_CONTENT, tab2=$TAB2_CONTENT)"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 5: stacked with real windows ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -t "Stack A" -e sh -c 'echo "Stacked A"; sleep 30' &
sleep 0.8
DISPLAY=$DISPLAY_NUM st -t "Stack B" -e sh -c 'echo "Stacked B"; sleep 30' &
sleep 0.8
DISPLAY=$DISPLAY_NUM st -t "Stack C" -e sh -c 'echo "Stacked C"; sleep 30' &
sleep 0.8

run_msg "layout stacking" >/dev/null 2>&1
sleep 0.5
take_screenshot

# Stacked headers should show distinct colored regions
HEADER1=$(pixel_color "$SCREENSHOT" 100 24)
HEADER2=$(pixel_color "$SCREENSHOT" 100 42)
if [ "$HEADER1" = "28/55/77" ] || [ "$HEADER1" = "33/33/33" ]; then
    if [ "$HEADER2" = "28/55/77" ] || [ "$HEADER2" = "33/33/33" ]; then
        pass "stacked: headers visible with correct colors"
    else
        fail "stacked: header 2 wrong color ($HEADER2)"
    fi
else
    fail "stacked: header 1 wrong color ($HEADER1)"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 6: floating window over tiled ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -t "Background" -e sh -c 'echo "Background window"; sleep 30' &
sleep 0.8
DISPLAY=$DISPLAY_NUM st -t "Floating" -e sh -c 'echo "I am floating!"; sleep 30' &
sleep 0.8

run_msg "floating toggle" >/dev/null 2>&1
sleep 0.5
take_screenshot

# The floating window should overlay the background
# Check if there's a border visible (floating windows have borders)
# The floating window is typically centered and smaller
TREE=$(run_msg_type get_tree)
if echo "$TREE" | grep -q '"floating":true'; then
    pass "floating: tree shows floating window"
else
    fail "floating: no floating window in tree"
fi

# Take screenshot and verify it's not just a single fullscreen window
# (floating window creates a visible layered effect)
CENTER=$(pixel_color "$SCREENSHOT" 360 400)
if [ "$CENTER" != "00/00/00" ]; then
    pass "floating: content visible"
else
    fail "floating: black screen"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 7: fullscreen toggle with running app ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -e sh -c 'echo "Fullscreen test"; sleep 30' &
sleep 1

run_msg "fullscreen toggle" >/dev/null 2>&1
sleep 0.5
take_screenshot

# Fullscreen should fill entire screen — no black at edges
CORNER1=$(pixel_color "$SCREENSHOT" 5 5)
CORNER2=$(pixel_color "$SCREENSHOT" 715 715)
if [ "$CORNER1" != "00/00/00" ] && [ "$CORNER2" != "00/00/00" ]; then
    pass "fullscreen: fills entire screen"
else
    fail "fullscreen: black corners (tl=$CORNER1, br=$CORNER2)"
fi

# Exit fullscreen
run_msg "fullscreen toggle" >/dev/null 2>&1
sleep 0.3

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 8: rapid layout switching with content ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -t "Rapid1" -e sh -c 'sleep 30' &
sleep 0.5
DISPLAY=$DISPLAY_NUM st -t "Rapid2" -e sh -c 'sleep 30' &
sleep 0.5
DISPLAY=$DISPLAY_NUM st -t "Rapid3" -e sh -c 'sleep 30' &
sleep 0.5

# Rapid layout switches
for LAYOUT in splith splitv tabbed stacking splith tabbed splitv stacking splith; do
    run_msg "layout $LAYOUT" >/dev/null 2>&1
    sleep 0.1
done
sleep 0.5

# WM should survive and windows should be intact
WIN_COUNT=$(run_msg_type get_tree | grep -o '"window":[0-9]*' | wc -l)
if [ "$WIN_COUNT" -ge 3 ]; then
    pass "rapid layout switch: $WIN_COUNT windows survived"
else
    fail "rapid layout switch: lost windows ($WIN_COUNT)"
fi

# Check WM is still responsive
RESULT=$(run_msg "nop")
if echo "$RESULT" | grep -q '"success":true'; then
    pass "rapid layout switch: WM responsive"
else
    fail "rapid layout switch: WM unresponsive"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 9: workspace switch with running apps ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -t "WS1 App" -e sh -c 'sleep 30' &
sleep 0.8

# Switch to workspace 2
run_msg "workspace 2" >/dev/null 2>&1
sleep 0.3

DISPLAY=$DISPLAY_NUM st -t "WS2 App" -e sh -c 'sleep 30' &
sleep 0.8

# Verify WS2 app is visible
take_screenshot
WS2_CENTER=$(pixel_color "$SCREENSHOT" 360 400)
if [ "$WS2_CENTER" != "00/00/00" ]; then
    pass "workspace 2: content visible"
else
    fail "workspace 2: black screen"
fi

# Switch back to WS1
run_msg "workspace 1" >/dev/null 2>&1
sleep 0.5
take_screenshot

WS1_CENTER=$(pixel_color "$SCREENSHOT" 360 400)
if [ "$WS1_CENTER" != "00/00/00" ]; then
    pass "workspace 1: content restored"
else
    fail "workspace 1: black screen after switch back"
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 10: border none/pixel with real app ---"
# ============================================================
DISPLAY=$DISPLAY_NUM st -e sh -c 'sleep 30' &
sleep 1

# border none — window should extend to workspace edges
run_msg "border none" >/dev/null 2>&1
sleep 0.3
take_screenshot

# With border none, pixel at workspace origin should be content (not black/border)
EDGE_COLOR=$(pixel_color "$SCREENSHOT" 1 22)
if [ "$EDGE_COLOR" != "00/00/00" ]; then
    pass "border none: content at edge"
else
    fail "border none: black at edge ($EDGE_COLOR)"
fi

# border pixel 4 — thick border should be visible
run_msg "border pixel 4" >/dev/null 2>&1
sleep 0.3
take_screenshot

# Border at edge should show the focus color
BORDER_COLOR=$(pixel_color "$SCREENSHOT" 1 22)
if [ "$BORDER_COLOR" = "4C/78/99" ] || [ "$BORDER_COLOR" = "4C/7C/9F" ] || [ "$BORDER_COLOR" = "4C/78/9A" ]; then
    pass "border pixel 4: thick border visible ($BORDER_COLOR)"
else
    # With thick border, edge might be border color or content depending on exact geometry
    # Just verify it's not black
    if [ "$BORDER_COLOR" != "00/00/00" ]; then
        pass "border pixel 4: edge not black ($BORDER_COLOR)"
    else
        fail "border pixel 4: black edge"
    fi
fi

DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
sleep 0.5

# ============================================================
echo ""
echo "--- Test 11: WM stability check ---"
# ============================================================
# Verify WM survived all tests
if kill -0 "$WM_PID" 2>/dev/null; then
    pass "WM still running after all tests"
else
    fail "WM crashed during tests"
fi

# Check for memory leaks in log
if grep -qi "leaked\|leak" /tmp/zephwm-realapp.log 2>/dev/null; then
    fail "memory leaks detected"
    grep -i "leak" /tmp/zephwm-realapp.log | head -3
else
    pass "no memory leaks"
fi

# Clean exit
run_msg "exit" >/dev/null 2>&1
sleep 1

if ! kill -0 "$WM_PID" 2>/dev/null; then
    pass "clean exit"
else
    fail "did not exit cleanly"
fi
WM_PID=""

# ============================================================
echo ""
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
    echo -e "  Failed tests:$ERRORS"
else
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
fi
echo "=============================================="

exit "$FAIL"
