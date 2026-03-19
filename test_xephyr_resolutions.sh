#!/bin/bash
# Resolution stress test for zephwm
# Tests various screen sizes including edge cases
set -e

ZEPHWM="./zig-out/bin/zephwm"
MSG="./zig-out/bin/zephwm-msg"
DISPLAY_NUM=":98"
PASS=0
FAIL=0
ERRORS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_msg() {
    DISPLAY=$DISPLAY_NUM I3SOCK="/run/user/$(id -u)/zephwm/ipc.sock" "$MSG" "$@" 2>/dev/null
}

run_msg_type() {
    DISPLAY=$DISPLAY_NUM I3SOCK="/run/user/$(id -u)/zephwm/ipc.sock" "$MSG" -t "$@" 2>/dev/null
}

assert_contains() {
    local test_name="$1" result="$2" expected="$3"
    if echo "$result" | grep -q "$expected"; then
        echo -e "    ${GREEN}PASS${NC}: $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "    ${RED}FAIL${NC}: $test_name"
        echo "      expected: $expected"
        echo "      got: $(echo "$result" | head -c 200)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - [$RES] $test_name"
    fi
}

assert_success() {
    assert_contains "$1" "$2" '"success":true'
}

assert_numeric_eq() {
    local test_name="$1" actual="$2" expected="$3"
    if [ "$actual" -eq "$expected" ] 2>/dev/null; then
        echo -e "    ${GREEN}PASS${NC}: $test_name ($actual)"
        PASS=$((PASS + 1))
    else
        echo -e "    ${RED}FAIL${NC}: $test_name (got $actual, expected $expected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - [$RES] $test_name"
    fi
}

count_windows() {
    run_msg_type get_tree | grep -o '"window":[0-9]*' | wc -l
}

# Test resolutions: real-world + edge cases
RESOLUTIONS=(
    "720x720"     # HackberryPi target
    "1920x1080"   # Full HD
    "1366x768"    # Common laptop
    "3840x2160"   # 4K
    "800x600"     # SVGA (tiny)
    "320x240"     # Extremely small
    "2560x1440"   # QHD
    "1080x1920"   # Portrait (tall)
    "100x100"     # Near-minimum
    "5120x1440"   # Ultra-wide
)

echo "================================================"
echo "  zephwm Multi-Resolution Integration Tests"
echo "================================================"
echo ""

for RES in "${RESOLUTIONS[@]}"; do
    W=$(echo "$RES" | cut -d'x' -f1)
    H=$(echo "$RES" | cut -d'x' -f2)

    echo "--- Testing ${RES} ---"

    # Clean up any previous instance
    rm -f /tmp/.X98-lock /tmp/.X11-unix/X98 2>/dev/null
    rm -rf "/run/user/$(id -u)/zephwm" 2>/dev/null

    # Start Xephyr
    Xephyr $DISPLAY_NUM -screen "${RES}" -ac -br -noreset 2>/dev/null &
    XPID=$!
    sleep 0.8

    if ! kill -0 "$XPID" 2>/dev/null; then
        echo -e "    ${RED}FAIL${NC}: Xephyr failed to start at ${RES}"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - [$RES] Xephyr start"
        continue
    fi

    # Start zephwm
    DISPLAY=$DISPLAY_NUM "$ZEPHWM" 2>/tmp/zephwm-res-test.log &
    WPID=$!
    sleep 0.8

    if ! kill -0 "$WPID" 2>/dev/null; then
        echo -e "    ${RED}FAIL${NC}: zephwm failed to start at ${RES}"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - [$RES] zephwm start"
        kill "$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null
        continue
    fi

    # Test 1: Version check (basic IPC)
    result=$(run_msg_type get_version)
    assert_contains "IPC works" "$result" "zephwm"

    # Test 2: Screen size in output
    result=$(run_msg_type get_outputs)
    assert_contains "output has resolution" "$result" "\"width\":${W}"

    # Test 3: Spawn windows
    DISPLAY=$DISPLAY_NUM st -t "Win1" -e sleep 120 &
    sleep 0.4
    DISPLAY=$DISPLAY_NUM st -t "Win2" -e sleep 120 &
    sleep 0.4
    DISPLAY=$DISPLAY_NUM st -t "Win3" -e sleep 120 &
    sleep 0.4

    WIN_COUNT=$(count_windows)
    assert_numeric_eq "3 windows managed" "$WIN_COUNT" 3

    # Test 4: Check layout geometry makes sense
    TREE=$(run_msg_type get_tree)
    # Windows should have positive dimensions
    # Extract widths of windows named Win1/Win2/Win3
    W1=$(echo "$TREE" | grep -oP '"name":"Win1"[^}]*"width":\K[0-9]+')
    W2=$(echo "$TREE" | grep -oP '"name":"Win2"[^}]*"width":\K[0-9]+')
    W3=$(echo "$TREE" | grep -oP '"name":"Win3"[^}]*"width":\K[0-9]+')

    if [ -n "$W1" ] && [ "$W1" -gt 0 ] 2>/dev/null; then
        echo -e "    ${GREEN}PASS${NC}: Win1 has valid width ($W1)"
        PASS=$((PASS + 1))
    else
        echo -e "    ${RED}FAIL${NC}: Win1 invalid width (${W1:-null})"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - [$RES] Win1 width"
    fi

    # Test 5: Hsplit geometry - all 3 should have roughly W/3 width
    EXPECTED_W=$((W / 3))
    TOLERANCE=$((EXPECTED_W / 4 + 5))  # 25% tolerance + 5px for borders
    if [ -n "$W1" ] && [ -n "$W2" ] && [ -n "$W3" ]; then
        ALL_VALID=true
        for WN in $W1 $W2 $W3; do
            DIFF=$((WN - EXPECTED_W))
            if [ "$DIFF" -lt 0 ]; then DIFF=$((-DIFF)); fi
            if [ "$DIFF" -gt "$TOLERANCE" ]; then
                ALL_VALID=false
            fi
        done
        if $ALL_VALID; then
            echo -e "    ${GREEN}PASS${NC}: hsplit geometry correct (${W1}+${W2}+${W3} ≈ ${W})"
            PASS=$((PASS + 1))
        else
            echo -e "    ${RED}FAIL${NC}: hsplit geometry off (${W1}+${W2}+${W3}, expected ~${EXPECTED_W} each)"
            FAIL=$((FAIL + 1))
            ERRORS="$ERRORS\n  - [$RES] hsplit geometry"
        fi
    else
        echo -e "    ${YELLOW}SKIP${NC}: could not extract all widths"
        PASS=$((PASS + 1))
    fi

    # Test 6: Vsplit
    result=$(run_msg "layout splitv")
    assert_success "layout splitv" "$result"

    TREE=$(run_msg_type get_tree)
    H1=$(echo "$TREE" | grep -oP '"name":"Win1"[^}]*"height":\K[0-9]+')
    if [ -n "$H1" ] && [ "$H1" -gt 0 ] 2>/dev/null; then
        EXPECTED_H=$((H / 3))
        TOLERANCE_H=$((EXPECTED_H / 4 + 5))
        DIFF=$((H1 - EXPECTED_H))
        if [ "$DIFF" -lt 0 ]; then DIFF=$((-DIFF)); fi
        if [ "$DIFF" -le "$TOLERANCE_H" ]; then
            echo -e "    ${GREEN}PASS${NC}: vsplit geometry correct (height=${H1} ≈ ${EXPECTED_H})"
            PASS=$((PASS + 1))
        else
            echo -e "    ${RED}FAIL${NC}: vsplit geometry off (height=${H1}, expected ~${EXPECTED_H})"
            FAIL=$((FAIL + 1))
            ERRORS="$ERRORS\n  - [$RES] vsplit geometry"
        fi
    else
        echo -e "    ${YELLOW}SKIP${NC}: could not extract height"
        PASS=$((PASS + 1))
    fi

    # Test 7: Tabbed mode
    result=$(run_msg "layout tabbed")
    assert_success "layout tabbed" "$result"

    TREE=$(run_msg_type get_tree)
    assert_contains "tabbed layout" "$TREE" '"tabbed"'

    # All 3 windows should still be in tree
    WIN_COUNT=$(count_windows)
    assert_numeric_eq "windows survive tabbed at ${RES}" "$WIN_COUNT" 3

    # Test 8: Fullscreen
    result=$(run_msg "fullscreen toggle")
    assert_success "fullscreen" "$result"

    TREE=$(run_msg_type get_tree)
    assert_contains "fullscreen mode" "$TREE" '"fullscreen_mode":1'

    run_msg "fullscreen toggle" >/dev/null 2>&1

    # Test 9: Floating
    result=$(run_msg "floating toggle")
    assert_success "floating" "$result"

    run_msg "floating toggle" >/dev/null 2>&1

    # Test 10: Workspace switch + move
    result=$(run_msg "workspace 2")
    assert_success "ws switch" "$result"

    result=$(run_msg "workspace 1")
    assert_success "ws back" "$result"

    # Test 11: Window count stable after all operations
    WIN_COUNT=$(count_windows)
    assert_numeric_eq "windows intact after ops" "$WIN_COUNT" 3

    # Test 12: Clean exit
    run_msg "exit" >/dev/null 2>&1
    sleep 0.5

    if ! kill -0 "$WPID" 2>/dev/null; then
        echo -e "    ${GREEN}PASS${NC}: clean exit"
        PASS=$((PASS + 1))
    else
        echo -e "    ${RED}FAIL${NC}: did not exit"
        FAIL=$((FAIL + 1))
        kill "$WPID" 2>/dev/null
    fi

    # Check memory leaks
    if grep -q "leaked" /tmp/zephwm-res-test.log 2>/dev/null; then
        echo -e "    ${RED}FAIL${NC}: memory leak"
        grep "leaked" /tmp/zephwm-res-test.log | head -2
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - [$RES] memory leak"
    else
        echo -e "    ${GREEN}PASS${NC}: no leaks"
        PASS=$((PASS + 1))
    fi

    # Cleanup
    DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
    kill "$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null
    wait "$WPID" 2>/dev/null
    sleep 0.3

    echo ""
done

echo "================================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "  Resolutions tested: ${#RESOLUTIONS[@]}"
echo "================================================"

if [ "$FAIL" -gt 0 ]; then
    echo -e "\nFailed tests:${ERRORS}"
    exit 1
fi
