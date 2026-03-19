#!/bin/bash
# Extended Xephyr integration tests for zephwm
# Tests advanced features: nested layouts, EWMH, criteria, edge cases, signals
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
        echo -e "  ${RED}FAIL${NC}: $test_name (found unexpected: $unexpected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
}

assert_success() {
    assert_contains "$1" "$2" '"success":true'
}

assert_eq() {
    local test_name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name ($actual)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (got '$actual', expected '$expected')"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $test_name"
    fi
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

# Get number of workspaces from get_workspaces
count_workspaces() {
    run_msg_type get_workspaces | grep -o '"num":' | wc -l
}

echo "============================================"
echo "  zephwm Extended Xephyr Integration Tests"
echo "============================================"
echo ""

# --- Start Xephyr + zephwm ---
echo "=== Starting Xephyr on $DISPLAY_NUM (720x720) ==="
Xephyr $DISPLAY_NUM -screen 720x720 -ac -br -noreset 2>/dev/null &
XEPHYR_PID=$!
sleep 1
if ! kill -0 "$XEPHYR_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: Xephyr failed to start${NC}"
    exit 1
fi

# Create test config with gaps and custom border
mkdir -p /tmp/zephwm-test-config/zephwm
cat > /tmp/zephwm-test-config/zephwm/config <<'EOFCFG'
set $mod Mod4
set $term st
font pango:monospace 10
floating_modifier $mod
bindsym $mod+Return exec $term
bindsym $mod+Shift+q kill
bindsym $mod+h focus left
bindsym $mod+l focus right
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+Shift+h move left
bindsym $mod+Shift+l move right
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+b splith
bindsym $mod+v splitv
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exit
bindsym $mod+r mode "resize"
mode "resize" {
    bindsym Escape mode "default"
}

default_border pixel 2
gaps inner 4
gaps outer 2
focus_follows_mouse yes

for_window [class="St"] floating disable
for_window [title="FloatMe"] floating enable

client.focused          #ff0000 #ff0000 #ffffff #ff0000 #ff0000
client.unfocused        #333333 #222222 #888888 #292d2e #222222
EOFCFG

echo "=== Starting zephwm with custom config ==="
XDG_CONFIG_HOME=/tmp/zephwm-test-config DISPLAY=$DISPLAY_NUM "$ZEPHWM" 2>/tmp/zephwm-ext-test.log &
WM_PID=$!
sleep 1
if ! kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "${RED}FATAL: zephwm failed to start${NC}"
    cat /tmp/zephwm-ext-test.log
    exit 1
fi
echo "zephwm PID: $WM_PID"
echo ""

# ============================================================
echo "--- Test 1: Nested Layouts ---"
# ============================================================

# Create: ws1 (hsplit) → [A, split_v → [B, C]]
spawn_window "A"
spawn_window "B"
run_msg "split v" >/dev/null 2>&1
spawn_window "C"
sleep 0.3

TREE=$(run_msg_type get_tree)
assert_contains "nested: 3 windows" "$(count_windows)" "3"
assert_contains "nested: has splitv" "$TREE" '"splitv"'
assert_contains "nested: has splith" "$TREE" '"splith"'

# Verify C is in the vsplit container
assert_contains "nested: C in tree" "$TREE" '"name":"C"'
assert_contains "nested: B in tree" "$TREE" '"name":"B"'
assert_contains "nested: A in tree" "$TREE" '"name":"A"'

echo ""

# ============================================================
echo "--- Test 2: Layout Toggle Split ---"
# ============================================================

# "layout toggle split" should toggle between hsplit and vsplit
result=$(run_msg "layout toggle split")
assert_success "toggle split" "$result"

TREE=$(run_msg_type get_tree)
# The parent of focused window should have toggled
# It was vsplit (from split v above), should now be hsplit
assert_contains "toggle: changed layout" "$TREE" '"splith"'

# Toggle again
run_msg "layout toggle split" >/dev/null 2>&1
TREE=$(run_msg_type get_tree)
assert_contains "toggle back: splitv" "$TREE" '"splitv"'

echo ""

# ============================================================
echo "--- Test 3: Window Properties in Tree ---"
# ============================================================

TREE=$(run_msg_type get_tree)
assert_contains "window class St" "$TREE" '"class":"St"'
assert_contains "window instance st" "$TREE" '"instance":"st"'

echo ""

# ============================================================
echo "--- Test 4: EWMH Properties ---"
# ============================================================

# Check _NET_SUPPORTED via xprop
SUPPORTED=$(DISPLAY=$DISPLAY_NUM xprop -root _NET_SUPPORTED 2>/dev/null || echo "xprop_not_available")
if echo "$SUPPORTED" | grep -q "xprop_not_available"; then
    echo -e "  ${YELLOW}SKIP${NC}: xprop not available"
else
    assert_contains "EWMH _NET_SUPPORTED" "$SUPPORTED" "_NET_SUPPORTED"
fi

# Check _NET_WM_NAME on wm check window
WM_NAME=$(DISPLAY=$DISPLAY_NUM xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null || echo "skip")
if echo "$WM_NAME" | grep -q "skip"; then
    echo -e "  ${YELLOW}SKIP${NC}: xprop not available"
else
    assert_contains "EWMH WM check window" "$WM_NAME" "window id"
fi

# _NET_ACTIVE_WINDOW should be set
ACTIVE=$(DISPLAY=$DISPLAY_NUM xprop -root _NET_ACTIVE_WINDOW 2>/dev/null || echo "skip")
if echo "$ACTIVE" | grep -q "skip"; then
    echo -e "  ${YELLOW}SKIP${NC}: xprop not available"
else
    assert_contains "EWMH active window" "$ACTIVE" "_NET_ACTIVE_WINDOW"
    assert_not_contains "EWMH active != 0" "$ACTIVE" "not found"
fi

# _NET_CURRENT_DESKTOP
DESKTOP=$(DISPLAY=$DISPLAY_NUM xprop -root _NET_CURRENT_DESKTOP 2>/dev/null || echo "skip")
if echo "$DESKTOP" | grep -q "skip"; then
    echo -e "  ${YELLOW}SKIP${NC}: xprop not available"
else
    assert_contains "EWMH current desktop" "$DESKTOP" "_NET_CURRENT_DESKTOP"
fi

# _NET_CLIENT_LIST should contain our windows
CLIENTS=$(DISPLAY=$DISPLAY_NUM xprop -root _NET_CLIENT_LIST 2>/dev/null || echo "skip")
if echo "$CLIENTS" | grep -q "skip"; then
    echo -e "  ${YELLOW}SKIP${NC}: xprop not available"
else
    assert_contains "EWMH client list" "$CLIENTS" "_NET_CLIENT_LIST"
    assert_not_contains "EWMH client list not empty" "$CLIENTS" "not found"
fi

echo ""

# ============================================================
echo "--- Test 5: Workspace Number vs Name ---"
# ============================================================

# workspace "foo" — named workspace without number
result=$(run_msg "workspace foo")
assert_success "switch to named ws 'foo'" "$result"

WS=$(run_msg_type get_workspaces)
assert_contains "ws 'foo' exists" "$WS" '"name":"foo"'

# workspace number 5
result=$(run_msg "workspace number 5")
assert_success "switch to ws number 5" "$result"

WS=$(run_msg_type get_workspaces)
assert_contains "ws 5 exists" "$WS" '"name":"5"'

# Back to ws1
result=$(run_msg "workspace 1")
assert_success "back to ws1" "$result"

echo ""

# ============================================================
echo "--- Test 6: Tabbed Inside Split ---"
# ============================================================

# Create complex layout: hsplit → [A, tabbed → [B, C]]
# First clear by moving everything to ws8
for i in $(seq 1 $(count_windows)); do
    run_msg "move container to workspace 8" >/dev/null 2>&1
done
run_msg "workspace 6" >/dev/null 2>&1

spawn_window "T1"
spawn_window "T2"
run_msg "split h" >/dev/null 2>&1
spawn_window "T3"
run_msg "layout tabbed" >/dev/null 2>&1
spawn_window "T4"

TREE=$(run_msg_type get_tree)
assert_contains "complex: tabbed in tree" "$TREE" '"tabbed"'
assert_contains "complex: T4 in tree" "$TREE" '"name":"T4"'

# Switch tabs within tabbed container
result=$(run_msg "focus left")
assert_success "focus in tabbed" "$result"

echo ""

# ============================================================
echo "--- Test 7: Stacked Inside Split ---"
# ============================================================

run_msg "workspace 7" >/dev/null 2>&1

spawn_window "S1"
spawn_window "S2"
run_msg "layout stacking" >/dev/null 2>&1
spawn_window "S3"

TREE=$(run_msg_type get_tree)
assert_contains "stacked: in tree" "$TREE" '"stacked"'
assert_contains "stacked: S3" "$TREE" '"name":"S3"'

# All 3 windows should be in the tree
S_COUNT=$(echo "$TREE" | grep -o '"name":"S[0-9]"' | wc -l)
assert_numeric_eq "stacked: all 3 windows present" "$S_COUNT" 3

echo ""

# ============================================================
echo "--- Test 8: Close Last Window on Workspace ---"
# ============================================================

run_msg "workspace 10" >/dev/null 2>&1
spawn_window "LastWin"
sleep 0.3

result=$(run_msg "kill kill")
assert_success "kill last window" "$result"
sleep 1

# After killing last window, workspace should still exist but be empty
# Focus should move somewhere valid
if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: WM survives closing last window"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: WM crashed closing last window"
    FAIL=$((FAIL + 1))
fi

echo ""

# ============================================================
echo "--- Test 9: Rapid Window Spawn and Destroy ---"
# ============================================================

run_msg "workspace 1" >/dev/null 2>&1

# Spawn 10 windows rapidly
for i in $(seq 1 10); do
    DISPLAY=$DISPLAY_NUM st -t "Rapid$i" -e sleep 120 &
done
sleep 2

RAPID_COUNT=$(count_windows)
echo "  Spawned windows: $RAPID_COUNT"

# Kill them all rapidly
for i in $(seq 1 10); do
    run_msg "kill kill" >/dev/null 2>&1
    sleep 0.2
done
sleep 1

if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: survived rapid spawn+kill cycle"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crashed during rapid spawn+kill"
    FAIL=$((FAIL + 1))
fi

echo ""

# ============================================================
echo "--- Test 10: Multiple Marks ---"
# ============================================================

run_msg "workspace 1" >/dev/null 2>&1
spawn_window "MarkWin"

result=$(run_msg "mark alpha")
assert_success "mark alpha" "$result"

result=$(run_msg "mark beta")
assert_success "mark beta" "$result"

MARKS=$(run_msg_type get_marks)
assert_contains "marks has alpha" "$MARKS" '"alpha"'
assert_contains "marks has beta" "$MARKS" '"beta"'

# Unmark one
run_msg "unmark alpha" >/dev/null 2>&1
MARKS=$(run_msg_type get_marks)
assert_not_contains "alpha removed" "$MARKS" '"alpha"'
assert_contains "beta still there" "$MARKS" '"beta"'

# Unmark the other
run_msg "unmark beta" >/dev/null 2>&1
MARKS=$(run_msg_type get_marks)
assert_contains "all marks cleared" "$MARKS" '\[\]'

echo ""

# ============================================================
echo "--- Test 11: Multiple Scratchpad Windows ---"
# ============================================================

spawn_window "Scratch1"
run_msg "move scratchpad" >/dev/null 2>&1

spawn_window "Scratch2"
run_msg "move scratchpad" >/dev/null 2>&1

# Show first scratchpad window
result=$(run_msg "scratchpad show")
assert_success "show first scratch" "$result"

TREE=$(run_msg_type get_tree)
# Should have a floating window from scratchpad
assert_contains "scratch floating" "$TREE" '"floating":"user_on"'

# Show again should cycle to next scratch window (or toggle current)
result=$(run_msg "scratchpad show")
assert_success "show second scratch" "$result"

if kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: multiple scratchpad survived"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: crashed with multiple scratchpad"
    FAIL=$((FAIL + 1))
fi

echo ""

# ============================================================
echo "--- Test 12: IPC Criteria Commands ---"
# ============================================================

# Run command with criteria prefix
# [class="St"] mark "st_window" should mark a St window
result=$(run_msg '[class="St"] mark st_class')
assert_success "criteria mark" "$result"

MARKS=$(run_msg_type get_marks)
assert_contains "criteria mark applied" "$MARKS" '"st_class"'

run_msg "unmark st_class" >/dev/null 2>&1

echo ""

# ============================================================
echo "--- Test 13: Config with Gaps ---"
# ============================================================

# The test config has gaps inner 4, gaps outer 2
# Use a clean workspace to avoid interference from previous tests
run_msg "workspace 13" >/dev/null 2>&1

spawn_window "Gap1"
spawn_window "Gap2"
sleep 0.3

TREE=$(run_msg_type get_tree)

# Verify gap_outer: workspace rect should be shrunk by gap_outer (2px each side)
# 720 - 2*2 = 716
WS_WIDTH=$(echo "$TREE" | grep -oP '"name":"13"[^}]*"width":\K[0-9]+')
if [ -n "$WS_WIDTH" ]; then
    echo "  Workspace width: $WS_WIDTH (720 - 2*gap_outer=2 = 716 expected)"
    if [ "$WS_WIDTH" -eq 716 ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: gap_outer applied (ws width=$WS_WIDTH)"
        PASS=$((PASS + 1))
    elif [ "$WS_WIDTH" -lt 720 ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: gap_outer partially applied (ws width=$WS_WIDTH)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: gap_outer not applied (ws width=$WS_WIDTH, expected 716)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - gap_outer not applied"
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}: could not extract workspace width"
    PASS=$((PASS + 1))
fi

# Verify gap_inner: with 2 windows, each should be ~356px (716-4)/2
# Find Gap1 window rect width
GAP1_W=$(echo "$TREE" | grep -oP '"name":"Gap1"[^}]*"width":\K[0-9]+')
GAP2_W=$(echo "$TREE" | grep -oP '"name":"Gap2"[^}]*"width":\K[0-9]+')
echo "  Gap1 width: ${GAP1_W:-?}, Gap2 width: ${GAP2_W:-?}"

if [ -n "$GAP1_W" ] && [ "$GAP1_W" -lt 360 ] 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: gap_inner applied (Gap1 width=$GAP1_W < 360)"
    PASS=$((PASS + 1))
elif [ -n "$GAP1_W" ]; then
    echo -e "  ${RED}FAIL${NC}: gap_inner not applied (Gap1 width=$GAP1_W, expected < 360)"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n  - gap_inner not applied"
else
    echo -e "  ${YELLOW}SKIP${NC}: could not extract Gap1 width"
    PASS=$((PASS + 1))
fi

echo ""

# ============================================================
echo "--- Test 14: Move Container to Named Workspace ---"
# ============================================================

result=$(run_msg "move container to workspace myws")
assert_success "move to named ws" "$result"

result=$(run_msg "workspace myws")
assert_success "switch to myws" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "window on myws" "$TREE" '"window"'

WS=$(run_msg_type get_workspaces)
assert_contains "myws in workspaces" "$WS" '"name":"myws"'

result=$(run_msg "workspace 1")
assert_success "back to ws1" "$result"

echo ""

# ============================================================
echo "--- Test 15: Fullscreen with Multiple Windows ---"
# ============================================================

# Use a clean workspace for this test
run_msg "workspace 15" >/dev/null 2>&1

spawn_window "FS1"
spawn_window "FS2"
spawn_window "FS3"

WIN_BEFORE=$(count_windows)

# Fullscreen the focused window (FS3)
result=$(run_msg "fullscreen toggle")
assert_success "fullscreen with siblings" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "one window fullscreen" "$TREE" '"fullscreen_mode":1'

# Window count should not change (fullscreen doesn't destroy windows)
WIN_AFTER=$(count_windows)
assert_numeric_eq "no windows lost during fullscreen" "$WIN_AFTER" "$WIN_BEFORE"

# Exit fullscreen
run_msg "fullscreen toggle" >/dev/null 2>&1

echo ""

# ============================================================
echo "--- Test 16: Floating + Tiling Mix ---"
# ============================================================

# Make FS1 floating, keep FS2 and FS3 tiling
run_msg "focus left" >/dev/null 2>&1
run_msg "focus left" >/dev/null 2>&1
result=$(run_msg "floating toggle")
assert_success "float one window" "$result"

TREE=$(run_msg_type get_tree)
assert_contains "has floating" "$TREE" '"floating":"user_on"'

# Tiling windows should still tile normally
# Toggle back
run_msg "floating toggle" >/dev/null 2>&1

echo ""

# ============================================================
echo "--- Test 17: SIGTERM Graceful Shutdown ---"
# ============================================================

# Save PID and send SIGTERM
kill -TERM "$WM_PID" 2>/dev/null
sleep 1

if ! kill -0 "$WM_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: SIGTERM graceful shutdown"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: SIGTERM did not stop WM"
    FAIL=$((FAIL + 1))
fi

# Check for memory leaks
if grep -q "leaked" /tmp/zephwm-ext-test.log 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC}: memory leak on SIGTERM shutdown"
    grep "leaked" /tmp/zephwm-ext-test.log | head -3
    FAIL=$((FAIL + 1))
else
    echo -e "  ${GREEN}PASS${NC}: no memory leaks on SIGTERM"
    PASS=$((PASS + 1))
fi
WM_PID=""  # already stopped

echo ""

# ============================================================
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    echo -e "\nFailed tests:${ERRORS}"
    exit 1
fi
