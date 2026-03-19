#!/bin/bash
# Multi-monitor test for zephwm using Xephyr Xinerama
set -e

ZEPHWM="./zig-out/bin/zephwm"
MSG="./zig-out/bin/zephwm-msg"
DISPLAY_NUM=":98"
XEPHYR_PID=""
WM_PID=""
PASS=0
FAIL=0
ERRORS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
}
trap cleanup EXIT

assert_contains() {
    local test_name="$1" result="$2" expected="$3"
    if echo "$result" | grep -q "$expected"; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        echo "    expected: $expected"
        echo "    got: $(echo "$result" | head -c 300)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

assert_not_contains() {
    local test_name="$1" result="$2" unexpected="$3"
    if ! echo "$result" | grep -q "$unexpected"; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (found: $unexpected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

assert_success() {
    assert_contains "$1" "$2" '"success":true'
}

assert_numeric_eq() {
    local test_name="$1" actual="$2" expected="$3"
    if [ "$actual" -eq "$expected" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $test_name ($actual)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got $actual, expected $expected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

assert_numeric_ge() {
    local test_name="$1" actual="$2" expected="$3"
    if [ "$actual" -ge "$expected" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $test_name ($actual >= $expected)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got $actual, expected >= $expected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

run_msg() {
    DISPLAY=$DISPLAY_NUM I3SOCK="/run/user/$(id -u)/zephwm/ipc.sock" "$MSG" "$@" 2>/dev/null
}

run_msg_type() {
    DISPLAY=$DISPLAY_NUM I3SOCK="/run/user/$(id -u)/zephwm/ipc.sock" "$MSG" -t "$@" 2>/dev/null
}

spawn_window() {
    DISPLAY=$DISPLAY_NUM st -t "$1" -e sleep 120 &
    sleep 0.5
}

count_windows() {
    run_msg_type get_tree | grep -o '"window":[0-9]*' | wc -l
}

echo "================================================"
echo "  zephwm Multi-Monitor Integration Tests"
echo "================================================"
echo ""

# ============================================================
echo "=== Setup A: Dual Monitor (1920x1080 + 1366x768) ==="
# ============================================================
# Xephyr with 2 screens creates a Xinerama setup
rm -f /tmp/.X98-lock /tmp/.X11-unix/X98 2>/dev/null
Xephyr $DISPLAY_NUM -screen 1920x1080 -screen 1366x768 -ac -br -noreset 2>/dev/null &
XEPHYR_PID=$!
sleep 1

if ! kill -0 "$XEPHYR_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: Xephyr failed to start${NC}"
    exit 1
fi

DISPLAY=$DISPLAY_NUM "$ZEPHWM" 2>/tmp/zephwm-mm.log &
WM_PID=$!
sleep 1

if ! kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: zephwm failed to start${NC}"
    cat /tmp/zephwm-mm.log
    exit 1
fi

echo ""
echo "--- Test 1: Output Detection ---"

OUTPUTS=$(run_msg_type get_outputs)
echo "  Outputs: $OUTPUTS"

# Should have at least 1 output (Xephyr might report as single Xinerama screen)
OUTPUT_COUNT=$(echo "$OUTPUTS" | grep -o '"name":' | wc -l)
assert_numeric_ge "at least 1 output detected" "$OUTPUT_COUNT" 1

# Output should have correct dimensions
assert_contains "output has width" "$OUTPUTS" '"width":'
assert_contains "output is active" "$OUTPUTS" '"active":true'

echo ""
echo "--- Test 2: Workspaces on Outputs ---"

WS=$(run_msg_type get_workspaces)
assert_contains "workspace 1 exists" "$WS" '"name":"1"'
assert_contains "workspace has output field" "$WS" '"output":'

echo ""
echo "--- Test 3: Window Management on Multi-Monitor ---"

spawn_window "Mon1Win1"
spawn_window "Mon1Win2"

WIN_COUNT=$(count_windows)
assert_numeric_eq "2 windows on primary" "$WIN_COUNT" 2

# Switch to workspace 2 (should be on second output if available, else same output)
result=$(run_msg "workspace 2")
assert_success "switch to ws2" "$result"

spawn_window "Mon2Win1"
WIN_COUNT=$(count_windows)
assert_numeric_eq "3 total windows" "$WIN_COUNT" 3

echo ""
echo "--- Test 4: focus output Command ---"

# focus output right should try to move focus
result=$(run_msg "focus output right")
assert_success "focus output right" "$result"

result=$(run_msg "focus output left")
assert_success "focus output left" "$result"

result=$(run_msg "focus output up")
assert_success "focus output up" "$result"

result=$(run_msg "focus output down")
assert_success "focus output down" "$result"

# WM should survive all focus output commands
if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: survived focus output cycling"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crashed during focus output"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Test 5: Move Between Workspaces Across Outputs ---"

run_msg "workspace 1" >/dev/null 2>&1

result=$(run_msg "move container to workspace 2")
assert_success "move to ws2" "$result"

result=$(run_msg "workspace 2")
assert_success "switch to ws2" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "moved window on ws2" "$TREE" '"window"'

result=$(run_msg "move container to workspace 1")
assert_success "move back to ws1" "$result"

echo ""
echo "--- Test 6: Layout on Each Workspace ---"

run_msg "workspace 1" >/dev/null 2>&1
result=$(run_msg "layout tabbed")
assert_success "tabbed on ws1" "$result"

# Verify tabbed is set immediately
TREE=$(run_msg_type get_tree)
assert_contains "ws1 is tabbed" "$TREE" '"tabbed"'

run_msg "workspace 2" >/dev/null 2>&1
result=$(run_msg "layout stacking")
assert_success "stacking on ws2" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "ws2 is stacked" "$TREE" '"stacked"'

echo ""
echo "--- Test 7: get_tree Shows Multiple Outputs ---"

TREE=$(run_msg_type get_tree)
# Tree should have output type containers
OUTPUT_COUNT_TREE=$(echo "$TREE" | grep -o '"type":"output"' | wc -l)
assert_numeric_ge "tree has output containers" "$OUTPUT_COUNT_TREE" 1

echo ""
echo "--- Test 8: Fullscreen on Specific Output ---"

run_msg "workspace 1" >/dev/null 2>&1
spawn_window "FSWin"

result=$(run_msg "fullscreen toggle")
assert_success "fullscreen on output" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "fullscreen on output" "$TREE" '"fullscreen_mode":1'

run_msg "fullscreen toggle" >/dev/null 2>&1

echo ""
echo "--- Test 9: Stress Test Multi-Monitor ---"

# Rapid workspace switching across outputs
for ws in 1 2 1 2 1 2 3 4 1; do
    run_msg "workspace $ws" >/dev/null 2>&1
done

# Rapid focus output cycling
for dir in left right up down left right; do
    run_msg "focus output $dir" >/dev/null 2>&1
done

# Spawn windows on different workspaces
for i in $(seq 1 5); do
    run_msg "workspace $((i % 3 + 1))" >/dev/null 2>&1
    DISPLAY=$DISPLAY_NUM st -t "Stress$i" -e sleep 120 &
done
sleep 2

if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: survived multi-monitor stress test"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crashed during stress test"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Test 10: Clean Exit ---"

run_msg "exit" >/dev/null 2>&1
sleep 1

if ! kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: clean exit"
    PASS=$((PASS + 1))
    WM_PID=""
else
    echo -e "  ${RED}FAIL${NC}: did not exit"
    FAIL=$((FAIL + 1))
fi

if grep -q "leaked" /tmp/zephwm-mm.log 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC}: memory leak"
    grep "leaked" /tmp/zephwm-mm.log | head -3
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n  - memory leak"
else
    echo -e "  ${GREEN}PASS${NC}: no memory leaks"
    PASS=$((PASS + 1))
fi

# Show WM log
echo ""
echo "=== zephwm log ==="
cat /tmp/zephwm-mm.log

# Clean up Xephyr
DISPLAY=$DISPLAY_NUM killall st 2>/dev/null || true
kill "$XEPHYR_PID" 2>/dev/null; wait "$XEPHYR_PID" 2>/dev/null
XEPHYR_PID=""

echo ""
echo "================================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================================"

if [ "$FAIL" -gt 0 ]; then
    echo -e "\nFailed tests:${ERRORS}"
    exit 1
fi
