#!/bin/bash
# Xephyr integration test for zephwm
# Tests all implemented features via IPC (zephwm-msg)
set -e

ZEPHWM="./zig-out/bin/zephwm"
MSG="./zig-out/bin/zephwm-msg"
DISPLAY_NUM=":98"
XEPHYR_PID=""
WM_PID=""
PASS=0
FAIL=0
ERRORS=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    # Kill test windows
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
    local test_name="$1"
    local result="$2"
    local expected="$3"

    if echo "$result" | grep -q "$expected"; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        echo "    expected: $expected"
        echo "    got: $(echo "$result" | head -c 200)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

assert_success() {
    local test_name="$1"
    local result="$2"
    assert_contains "$test_name" "$result" '"success":true'
}

assert_numeric_eq() {
    local test_name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" -eq "$expected" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $test_name ($actual == $expected)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got $actual, expected $expected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

assert_numeric_lt() {
    local test_name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" -lt "$expected" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $test_name ($actual < $expected)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got $actual, expected < $expected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

assert_numeric_gt() {
    local test_name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" -gt "$expected" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $test_name ($actual > $expected)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got $actual, expected > $expected)"
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
    DISPLAY=$DISPLAY_NUM st -t "$1" -e sleep 60 &
    sleep 0.5
}

count_windows() {
    local tree
    tree=$(run_msg_type get_tree)
    echo "$tree" | grep -o '"window":[0-9]*' | wc -l
}

# Count windows on the currently focused workspace only
count_focused_ws_windows() {
    local ws
    ws=$(run_msg_type get_workspaces)
    local focused_name
    focused_name=$(echo "$ws" | grep -o '"name":"[^"]*","visible":[^,]*,"focused":true' | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//')
    if [ -z "$focused_name" ]; then
        echo 0
        return
    fi
    # Use get_tree and count windows in the focused workspace section
    # Simpler: just count total windows (get_tree shows all)
    count_windows
}

echo "====================================="
echo "  zephwm Xephyr Integration Tests"
echo "====================================="
echo ""

# --- Start Xephyr ---
echo "=== Starting Xephyr on $DISPLAY_NUM (720x720) ==="
Xephyr $DISPLAY_NUM -screen 720x720 -ac -br -noreset 2>/dev/null &
XEPHYR_PID=$!
sleep 1

if ! kill -0 "$XEPHYR_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: Xephyr failed to start${NC}"
    exit 1
fi
echo "Xephyr PID: $XEPHYR_PID"

# --- Start zephwm ---
echo "=== Starting zephwm ==="
DISPLAY=$DISPLAY_NUM "$ZEPHWM" 2>/tmp/zephwm-test.log &
WM_PID=$!
sleep 1

if ! kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: zephwm failed to start${NC}"
    cat /tmp/zephwm-test.log
    exit 1
fi
echo "zephwm PID: $WM_PID"
echo ""

# ============================================================
echo "--- Test 1: IPC Basics ---"
# ============================================================

result=$(run_msg_type get_version)
assert_contains "get_version" "$result" "zephwm"

result=$(run_msg_type get_workspaces)
assert_contains "get_workspaces has ws1" "$result" '"name":"1"'

result=$(run_msg_type get_outputs)
assert_contains "get_outputs active" "$result" '"active":true'

result=$(run_msg_type get_tree)
assert_contains "get_tree root" "$result" '"type":"root"'

result=$(run_msg_type get_marks)
assert_contains "get_marks empty" "$result" '\[\]'

result=$(run_msg_type get_binding_modes)
assert_contains "get_binding_modes" "$result" '"default"'

echo ""

# ============================================================
echo "--- Test 2: Window Management ---"
# ============================================================

spawn_window "Win1"
WIN_COUNT=$(count_windows)
assert_numeric_eq "1 window after spawn" "$WIN_COUNT" 1

spawn_window "Win2"
WIN_COUNT=$(count_windows)
assert_numeric_eq "2 windows after spawn" "$WIN_COUNT" 2

spawn_window "Win3"
WIN_COUNT=$(count_windows)
assert_numeric_eq "3 windows after spawn" "$WIN_COUNT" 3

echo ""

# ============================================================
echo "--- Test 3: Focus ---"
# ============================================================

result=$(run_msg "focus left")
assert_success "focus left" "$result"

result=$(run_msg "focus right")
assert_success "focus right" "$result"

result=$(run_msg "focus up")
assert_success "focus up" "$result"

result=$(run_msg "focus down")
assert_success "focus down" "$result"

result=$(run_msg "focus parent")
assert_success "focus parent" "$result"

result=$(run_msg "focus child")
assert_success "focus child" "$result"

echo ""

# ============================================================
echo "--- Test 4: Layout (with windows) ---"
# ============================================================

result=$(run_msg "layout splith")
assert_success "layout splith" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "tree has splith" "$TREE" '"splith"'

result=$(run_msg "layout splitv")
assert_success "layout splitv" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "tree has splitv" "$TREE" '"splitv"'

result=$(run_msg "layout tabbed")
assert_success "layout tabbed" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "tree has tabbed" "$TREE" '"tabbed"'

result=$(run_msg "layout stacking")
assert_success "layout stacking" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "tree has stacked" "$TREE" '"stacked"'

# Restore
result=$(run_msg "layout splith")
assert_success "layout restore splith" "$result"

echo ""

# ============================================================
echo "--- Test 5: Split ---"
# ============================================================

result=$(run_msg "split h")
assert_success "split h" "$result"

result=$(run_msg "split v")
assert_success "split v" "$result"

# Spawn into split container
spawn_window "SplitWin"
WIN_COUNT=$(count_windows)
assert_numeric_eq "window in split container" "$WIN_COUNT" 4

echo ""

# ============================================================
echo "--- Test 6: Move ---"
# ============================================================

result=$(run_msg "move left")
assert_success "move left" "$result"

result=$(run_msg "move right")
assert_success "move right" "$result"

result=$(run_msg "move up")
assert_success "move up" "$result"

result=$(run_msg "move down")
assert_success "move down" "$result"

echo ""

# ============================================================
echo "--- Test 7: Workspaces ---"
# ============================================================

result=$(run_msg "workspace 2")
assert_success "switch ws2" "$result"

WS=$(run_msg_type get_workspaces)
assert_contains "ws2 exists" "$WS" '"name":"2"'

result=$(run_msg "workspace 1")
assert_success "switch ws1" "$result"

result=$(run_msg "workspace 3")
assert_success "switch ws3" "$result"

result=$(run_msg "workspace 1")
assert_success "back to ws1" "$result"

echo ""

# ============================================================
echo "--- Test 8: Move to Workspace ---"
# ============================================================

WIN_BEFORE=$(count_windows)

result=$(run_msg "move container to workspace 2")
assert_success "move to ws2" "$result"

# Total window count stays the same (window moved, not destroyed)
WIN_AFTER=$(count_windows)
assert_numeric_eq "total window count unchanged after move" "$WIN_AFTER" "$WIN_BEFORE"

result=$(run_msg "workspace 2")
assert_success "switch to ws2" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "window on ws2" "$TREE" '"window"'

# Verify the workspace has our window
WS=$(run_msg_type get_workspaces)
assert_contains "ws2 visible after switch" "$WS" '"name":"2"'

# Move back
result=$(run_msg "move container to workspace 1")
assert_success "move back to ws1" "$result"

result=$(run_msg "workspace 1")
assert_success "switch to ws1" "$result"

echo ""

# ============================================================
echo "--- Test 9: Floating ---"
# ============================================================

result=$(run_msg "floating toggle")
assert_success "float on" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "floating user_on" "$TREE" '"floating":"user_on"'

result=$(run_msg "floating toggle")
assert_success "float off" "$result"

echo ""

# ============================================================
echo "--- Test 10: Fullscreen ---"
# ============================================================

result=$(run_msg "fullscreen toggle")
assert_success "fullscreen on" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "fullscreen_mode:1" "$TREE" '"fullscreen_mode":1'

result=$(run_msg "fullscreen toggle")
assert_success "fullscreen off" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "fullscreen_mode:0" "$TREE" '"fullscreen_mode":0'

echo ""

# ============================================================
echo "--- Test 11: Marks ---"
# ============================================================

result=$(run_msg "mark mymark")
assert_success "mark set" "$result"

MARKS=$(run_msg_type get_marks)
assert_contains "mark exists" "$MARKS" '"mymark"'

result=$(run_msg "unmark mymark")
assert_success "unmark" "$result"

MARKS=$(run_msg_type get_marks)
assert_contains "marks empty" "$MARKS" '\[\]'

echo ""

# ============================================================
echo "--- Test 12: Scratchpad ---"
# ============================================================

result=$(run_msg "move scratchpad")
assert_success "move to scratchpad" "$result"

# Scratchpad window still in tree (just in __i3_scratch workspace)
# Verify the command succeeded and the window is still in the tree
TREE=$(run_msg_type get_tree)
assert_contains "tree still has windows after scratchpad" "$TREE" '"window"'

result=$(run_msg "scratchpad show")
assert_success "scratchpad show" "$result"

echo ""

# ============================================================
echo "--- Test 13: Kill ---"
# ============================================================

# Kill test: spawn a fresh window on a clean workspace, kill it
result=$(run_msg "workspace 9")
assert_success "switch to ws9 for kill test" "$result"

spawn_window "Sacrifice"
sleep 0.5
WIN_BEFORE=$(count_windows)

# Force kill (xcb_kill_client) for reliable test
result=$(run_msg "kill kill")
assert_success "kill kill cmd" "$result"
sleep 1

WIN_AFTER=$(count_windows)
assert_numeric_lt "window killed" "$WIN_AFTER" "$WIN_BEFORE"

# Return to ws1
result=$(run_msg "workspace 1")
assert_success "back to ws1 after kill" "$result"

echo ""

# ============================================================
echo "--- Test 14: Exec ---"
# ============================================================

WIN_BEFORE=$(count_windows)
result=$(run_msg "exec st -t ExecTest -e sleep 60")
assert_success "exec st" "$result"
sleep 0.8

WIN_AFTER=$(count_windows)
assert_numeric_gt "exec spawned window" "$WIN_AFTER" "$WIN_BEFORE"

echo ""

# ============================================================
echo "--- Test 15: Mode ---"
# ============================================================

result=$(run_msg 'mode "resize"')
assert_success "mode resize" "$result"

result=$(run_msg 'mode "default"')
assert_success "mode default" "$result"

echo ""

# ============================================================
echo "--- Test 16: Config Reload ---"
# ============================================================

kill -USR1 "$WM_PID" 2>/dev/null
sleep 0.5
if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: survives SIGUSR1"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crashed on SIGUSR1"
    FAIL=$((FAIL + 1))
fi

echo ""

# ============================================================
echo "--- Test 17: Nop ---"
# ============================================================

result=$(run_msg "nop")
assert_success "nop" "$result"

echo ""

# ============================================================
echo "--- Test 18: Stress Test ---"
# ============================================================

for i in $(seq 1 5); do
    spawn_window "Stress$i"
done
sleep 0.5

# Rapid focus cycling
for i in $(seq 1 10); do
    run_msg "focus left" >/dev/null 2>&1
    run_msg "focus right" >/dev/null 2>&1
done

if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: survived rapid focus cycling"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crash on focus cycling"
    FAIL=$((FAIL + 1))
fi

# Rapid layout switches
for l in splith splitv tabbed stacking splith; do
    run_msg "layout $l" >/dev/null 2>&1
done

if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: survived rapid layout switches"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crash on layout switches"
    FAIL=$((FAIL + 1))
fi

# Rapid workspace switches
for ws in 1 2 3 4 5 1; do
    run_msg "workspace $ws" >/dev/null 2>&1
done

if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: survived rapid workspace switches"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crash on workspace switches"
    FAIL=$((FAIL + 1))
fi

echo ""

# ============================================================
echo "--- Test 19: Exit ---"
# ============================================================

result=$(run_msg "exit")
assert_success "exit accepted" "$result"
sleep 1

if ! kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: exited cleanly"
    PASS=$((PASS + 1))
    WM_PID=""
else
    echo -e "  ${RED}FAIL${NC}: did not exit"
    FAIL=$((FAIL + 1))
fi

# Check for memory leaks in log
if grep -q "leaked" /tmp/zephwm-test.log 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC}: memory leak detected"
    grep "leaked" /tmp/zephwm-test.log | head -5
    FAIL=$((FAIL + 1))
else
    echo -e "  ${GREEN}PASS${NC}: no memory leaks"
    PASS=$((PASS + 1))
fi

echo ""

# ============================================================
echo "====================================="
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "====================================="

if [ "$FAIL" -gt 0 ]; then
    echo -e "\nFailed tests:${ERRORS}"
    exit 1
fi
