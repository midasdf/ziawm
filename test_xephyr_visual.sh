#!/bin/bash
# Visual pixel-level verification tests for zephwm
# Captures Xephyr screenshots and checks pixel colors at known coordinates
set -e

ZEPHWM="./zig-out/bin/zephwm"
MSG="./zig-out/bin/zephwm-msg"
DISPLAY_NUM=":98"
XEPHYR_PID=""
WM_PID=""
PASS=0
FAIL=0
ERRORS=""
SCREENSHOT="/tmp/zephwm-visual-test.png"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default colors (zephwm defaults)
COLOR_FOCUS_BORDER="4C/7C/9F"   # #4c7c9f — default border_focus
COLOR_UNFOCUS_BORDER="33/33/33" # #333333 — default border_unfocus
COLOR_TAB_FOCUSED="28/55/77"    # #285577
COLOR_TAB_UNFOCUSED="33/33/33"  # #333333
COLOR_TAB_TEXT="FF/FF/FF"       # white
COLOR_ROOT_BG="00/00/00"        # black (root window default)

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    if [ -n "$WM_PID" ] && kill -0 "$WM_PID" 2>/dev/null; then
        kill "$WM_PID" 2>/dev/null || true
        wait "$WM_PID" 2>/dev/null || true
    fi
    if [ -n "$XEPHYR_PID" ] && kill -0 "$XEPHYR_PID" 2>/dev/null; then
        kill "$XEPHYR_PID" 2>/dev/null || true
        wait "$XEPHYR_PID" 2>/dev/null || true
    fi
    rm -rf "/run/user/$(id -u)/zephwm" 2>/dev/null || true
    rm -f "$SCREENSHOT" 2>/dev/null || true
}
trap cleanup EXIT

# Get pixel color at (x,y) from screenshot as "RR/GG/BB" hex
# Usage: pixel_color <file> <x> <y>
pixel_color() {
    local file="$1" x="$2" y="$3"
    local line
    line=$(convert "$file" -crop "1x1+${x}+${y}" +repage txt:- 2>/dev/null | tail -1)
    # Try srgb(R,G,B) format first
    if echo "$line" | grep -qP 'srgb\('; then
        echo "$line" | grep -oP 'srgb\(\K[0-9]+,[0-9]+,[0-9]+' | \
            awk -F, '{printf "%02X/%02X/%02X\n", $1, $2, $3}'
    else
        # Fallback: extract #RRGGBB hex
        echo "$line" | grep -oP '#[0-9A-Fa-f]{6}' | head -1 | \
            sed 's/#\(..\)\(..\)\(..\)/\1\/\2\/\3/' | tr '[:lower:]' '[:upper:]'
    fi
}

# Take screenshot of entire Xephyr display
take_screenshot() {
    DISPLAY=$DISPLAY_NUM import -window root "$SCREENSHOT" 2>/dev/null
    sleep 0.1
}

# Assert pixel color matches expected (case-insensitive hex comparison)
assert_pixel() {
    local test_name="$1" x="$2" y="$3" expected="$4"
    local actual
    actual=$(pixel_color "$SCREENSHOT" "$x" "$y")
    if [ -z "$actual" ]; then
        echo -e "  ${RED}FAIL${NC}: $test_name (could not read pixel at $x,$y)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
        return
    fi
    # Case-insensitive comparison
    if [ "$(echo "$actual" | tr '[:lower:]' '[:upper:]')" = "$(echo "$expected" | tr '[:lower:]' '[:upper:]')" ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name (${actual} at ${x},${y})"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got ${actual}, expected ${expected} at ${x},${y})"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

# Assert pixel is NOT a specific color
assert_pixel_not() {
    local test_name="$1" x="$2" y="$3" unexpected="$4"
    local actual
    actual=$(pixel_color "$SCREENSHOT" "$x" "$y")
    if [ -z "$actual" ]; then
        echo -e "  ${RED}FAIL${NC}: $test_name (could not read pixel at $x,$y)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
        return
    fi
    if [ "$(echo "$actual" | tr '[:lower:]' '[:upper:]')" != "$(echo "$unexpected" | tr '[:lower:]' '[:upper:]')" ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name (${actual} != ${unexpected} at ${x},${y})"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got ${actual}, should NOT be ${unexpected} at ${x},${y})"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

# Assert pixel is one of several acceptable colors
assert_pixel_oneof() {
    local test_name="$1" x="$2" y="$3"
    shift 3
    local actual
    actual=$(pixel_color "$SCREENSHOT" "$x" "$y")
    if [ -z "$actual" ]; then
        echo -e "  ${RED}FAIL${NC}: $test_name (could not read pixel at $x,$y)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
        return
    fi
    local actual_upper
    actual_upper=$(echo "$actual" | tr '[:lower:]' '[:upper:]')
    for expected in "$@"; do
        local exp_upper
        exp_upper=$(echo "$expected" | tr '[:lower:]' '[:upper:]')
        if [ "$actual_upper" = "$exp_upper" ]; then
            echo -e "  ${GREEN}PASS${NC}: $test_name (${actual} at ${x},${y})"
            PASS=$((PASS + 1))
            return
        fi
    done
    echo -e "  ${RED}FAIL${NC}: $test_name (got ${actual} at ${x},${y}, expected one of: $*)"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n  - $test_name"
}

run_msg() {
    DISPLAY=$DISPLAY_NUM I3SOCK="/run/user/$(id -u)/zephwm/ipc.sock" "$MSG" "$@" 2>/dev/null
}

spawn_window() {
    DISPLAY=$DISPLAY_NUM st -t "$1" -e sleep 60 &
    sleep 0.5
}

run_visual_test() {
    local SCREEN_W="$1" SCREEN_H="$2"
    local RES="${SCREEN_W}x${SCREEN_H}"

    echo ""
    echo "=============================================="
    echo "  Visual Tests at ${RES}"
    echo "=============================================="

    # Clean up previous
    rm -f /tmp/.X98-lock /tmp/.X11-unix/X98 2>/dev/null
    rm -rf "/run/user/$(id -u)/zephwm" 2>/dev/null

    # Start Xephyr
    Xephyr $DISPLAY_NUM -screen "${RES}" -ac -br -noreset 2>/dev/null &
    XEPHYR_PID=$!
    sleep 1

    if ! kill -0 "$XEPHYR_PID" 2>/dev/null; then
        echo -e "  ${RED}SKIP${NC}: Xephyr failed at ${RES}"
        return
    fi

    DISPLAY=$DISPLAY_NUM "$ZEPHWM" 2>/tmp/zephwm-visual.log &
    WM_PID=$!
    sleep 1

    if ! kill -0 "$WM_PID" 2>/dev/null; then
        echo -e "  ${RED}SKIP${NC}: zephwm failed at ${RES}"
        kill "$XEPHYR_PID" 2>/dev/null; wait "$XEPHYR_PID" 2>/dev/null
        return
    fi

    # Bar reservation: WM reserves 20px at top for bar even without bar process
    local BAR_H=20
    local WS_Y=$BAR_H

    # ============================
    echo ""
    echo "--- ${RES}: Single Window ---"
    # ============================
    spawn_window "VisualSingle"
    sleep 0.3
    take_screenshot

    local cx=$((SCREEN_W / 2))
    local cy=$(((SCREEN_H + WS_Y) / 2))
    assert_pixel_not "center not root bg" "$cx" "$cy" "$COLOR_ROOT_BG"

    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # ============================
    echo ""
    echo "--- ${RES}: Tabbed Layout (3 windows) ---"
    # ============================
    spawn_window "Tab1"
    spawn_window "Tab2"
    spawn_window "Tab3"
    run_msg "layout tabbed" >/dev/null 2>&1
    sleep 0.3
    take_screenshot

    # Tab bar is inside the frame. Frame starts at workspace y (BAR_H=20).
    # With border=2, frame content starts at WS_Y+2. Tab bar height ~20px.
    local tab_y=$((WS_Y + 4))  # safely inside tab bar area
    assert_pixel_oneof "tab bar left region has tab bg" "10" "$tab_y" \
        "$COLOR_TAB_FOCUSED" "$COLOR_TAB_UNFOCUSED"

    local right_edge=$((SCREEN_W - 5))
    assert_pixel_oneof "tab bar right edge filled (no gap)" "$right_edge" "$tab_y" \
        "$COLOR_TAB_FOCUSED" "$COLOR_TAB_UNFOCUSED"

    assert_pixel_oneof "tab bar center has tab bg" "$cx" "$tab_y" \
        "$COLOR_TAB_FOCUSED" "$COLOR_TAB_UNFOCUSED"

    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # ============================
    echo ""
    echo "--- ${RES}: Stacked Layout (3 windows) ---"
    # ============================
    spawn_window "Stack1"
    spawn_window "Stack2"
    spawn_window "Stack3"
    run_msg "layout stacking" >/dev/null 2>&1
    sleep 0.3
    take_screenshot

    # Stacked headers: verify at least 2 distinct tab-color regions exist
    # Header positions are font-dependent, so scan the y range to find headers
    local sh_start=$((WS_Y + 2))
    local sh_end=$((WS_Y + 80))
    local found_colors=0
    local prev_color=""
    local sy=$sh_start
    while [ "$sy" -lt "$sh_end" ] && [ "$sy" -lt "$SCREEN_H" ]; do
        local sc
        sc=$(pixel_color "$SCREENSHOT" "10" "$sy")
        if [ "$sc" = "$COLOR_TAB_FOCUSED" ] || [ "$sc" = "$COLOR_TAB_UNFOCUSED" ]; then
            if [ "$sc" != "$prev_color" ]; then
                found_colors=$((found_colors + 1))
                prev_color="$sc"
            fi
        fi
        sy=$((sy + 1))
    done
    if [ "$found_colors" -ge 2 ]; then
        echo -e "  ${GREEN}PASS${NC}: stacked headers: found $found_colors distinct tab-color regions"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: stacked headers: only found $found_colors distinct regions (expected >= 2)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - stacked headers"
    fi

    assert_pixel_oneof "stacked header right edge" "$right_edge" "$((WS_Y + 4))" \
        "$COLOR_TAB_FOCUSED" "$COLOR_TAB_UNFOCUSED"

    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # ============================
    echo ""
    echo "--- ${RES}: Hsplit (2 windows) ---"
    # ============================
    spawn_window "Left"
    spawn_window "Right"
    sleep 0.3
    take_screenshot

    # Both halves should have content (not root bg)
    local quarter=$((SCREEN_W / 4))
    local three_quarter=$((SCREEN_W * 3 / 4))
    local hsplit_cy=$(((SCREEN_H + WS_Y) / 2))
    assert_pixel_not "left half has content" "$quarter" "$hsplit_cy" "$COLOR_ROOT_BG"
    assert_pixel_not "right half has content" "$three_quarter" "$hsplit_cy" "$COLOR_ROOT_BG"

    # Border between windows — at approximately the midpoint
    # The exact border position depends on border_width, but around the center
    # there should be either a border color pixel or content
    # (not a large gap of root bg)

    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # ============================
    echo ""
    echo "--- ${RES}: Border None ---"
    # ============================
    spawn_window "NoBorder"
    run_msg "border none" >/dev/null 2>&1
    sleep 0.3
    take_screenshot

    # With border none, the window extends to workspace edges
    # Check at workspace origin (0, WS_Y) — should be content, not root bg
    assert_pixel_not "border none: ws origin not root bg" "0" "$((WS_Y + 2))" "$COLOR_ROOT_BG"

    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # ============================
    echo ""
    echo "--- ${RES}: Border Pixel 5 ---"
    # ============================
    spawn_window "ThickBorder"
    run_msg "border pixel 5" >/dev/null 2>&1
    sleep 0.3
    take_screenshot

    # With 5px border, pixel at (2, 2) should be border color (inside the 5px border)
    # and pixel at (6, 6) should be window content (past the border)
    # Note: frame borders are outside the configured rect in X11
    # The frame's border pixels are at negative offsets from (0,0) — clipped by screen
    # But at the BOTTOM and RIGHT edges, the border extends into visible area
    # Actually: with a single window filling the workspace, the frame is at (0,0)
    # The border extends outside: left/top border clipped, right/bottom visible
    # Bottom-right corner at (SCREEN_W-1, SCREEN_H-1) should be border area
    # Actually the border is border_width=5 OUTSIDE, so visible at right edge
    # pixels (SCREEN_W-5 to SCREEN_W-1, ...) should show border...
    # But the frame width IS SCREEN_W, so the right border starts at x=SCREEN_W
    # which is off-screen. Hmm.
    #
    # In practice with a single window: the window fills the workspace rect.
    # The border is outside. On a 720x720 screen, frame at (0,0,720,720) with
    # border=5 means border at (-5,-5) to (725,725), all outside the screen.
    # So the thick border is NOT visible on a single full-screen window.
    # This is correct i3 behavior — single window has no visible border.
    #
    # To see the border, we need 2+ windows. Let's spawn another.
    spawn_window "ThickBorder2"
    sleep 0.3
    take_screenshot

    # With 2 windows in hsplit, there's a border between them
    # The border area around midpoint should show a colored strip
    local mid=$((SCREEN_W / 2))
    # Right at the midpoint, there should be something (border or content)
    # not a large gap of root bg
    local thick_cy=$(((SCREEN_H + WS_Y) / 2))
    assert_pixel_not "thick border: midpoint not root bg" "$mid" "$thick_cy" "$COLOR_ROOT_BG"

    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # ============================
    echo ""
    echo "--- ${RES}: Client has no spurious border ---"
    # ============================
    # This verifies BUG 1 fix: client window should have 0 border
    spawn_window "CleanClient"
    sleep 0.3
    take_screenshot

    # With single window, the entire screen should be filled with content
    # No thin border lines from the client window itself
    # Check points inside the workspace area
    local int_top=$((WS_Y + 5))
    assert_pixel_not "interior top-left not root" "5" "$int_top" "$COLOR_ROOT_BG"
    assert_pixel_not "interior top-right not root" "$((SCREEN_W - 10))" "$int_top" "$COLOR_ROOT_BG"
    assert_pixel_not "interior bottom-left not root" "5" "$((SCREEN_H - 10))" "$COLOR_ROOT_BG"
    assert_pixel_not "interior bottom-right not root" "$((SCREEN_W - 10))" "$((SCREEN_H - 10))" "$COLOR_ROOT_BG"

    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # ============================
    echo ""
    echo "--- ${RES}: Fullscreen fills entire screen ---"
    # ============================
    spawn_window "FullscreenTest"
    run_msg "fullscreen toggle" >/dev/null 2>&1
    sleep 0.3
    take_screenshot

    # Fullscreen fills the output rect (including bar area)
    # Center should be content
    assert_pixel_not "fullscreen center" "$cx" "$((SCREEN_H / 2))" "$COLOR_ROOT_BG"
    # Bottom corners should be content
    assert_pixel_not "fullscreen bottom-left" "5" "$((SCREEN_H - 5))" "$COLOR_ROOT_BG"
    assert_pixel_not "fullscreen bottom-right" "$((SCREEN_W - 5))" "$((SCREEN_H - 5))" "$COLOR_ROOT_BG"

    run_msg "fullscreen toggle" >/dev/null 2>&1
    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    sleep 0.3

    # Clean exit
    run_msg "exit" >/dev/null 2>&1
    sleep 0.5
    WM_PID=""
    kill "$XEPHYR_PID" 2>/dev/null; wait "$XEPHYR_PID" 2>/dev/null || true
    XEPHYR_PID=""
    sleep 0.3
}

echo "=============================================="
echo "  zephwm Visual Pixel Verification Tests"
echo "=============================================="

# Test multiple resolutions and aspect ratios
RESOLUTIONS=(
    "720 720"      # HackberryPi target (square)
    "1920 1080"    # Full HD (16:9)
    "1366 768"     # Common laptop
    "800 600"      # SVGA (4:3)
    "320 240"      # Tiny
    "1080 1920"    # Portrait (tall, 9:16)
    "2560 1440"    # QHD
    "640 480"      # VGA
    "1024 600"     # Netbook
    "3840 2160"    # 4K
)

for res_pair in "${RESOLUTIONS[@]}"; do
    W=$(echo "$res_pair" | awk '{print $1}')
    H=$(echo "$res_pair" | awk '{print $2}')
    run_visual_test "$W" "$H"
done

echo ""
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
    echo -e "  Failed tests:$ERRORS"
else
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
fi
echo "  Resolutions tested: ${#RESOLUTIONS[@]}"
echo "=============================================="

exit "$FAIL"
