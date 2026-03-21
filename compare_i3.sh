#!/bin/bash
# Compare zephwm vs i3 visual output side-by-side
# Runs both WMs through identical scenarios on Xvfb, captures screenshots
set -e

SCREEN_W=720
SCREEN_H=720
OUT="/screenshots"
mkdir -p "$OUT"

screenshot() {
    xwd -root -silent 2>/dev/null | xwdtopnm 2>/dev/null | pnmtopng 2>/dev/null > "$1"
}

wait_for_wm() { sleep 1.5; }
wait_for_win() { sleep 1; }
wait_for_cmd() { sleep 0.5; }

run_scenario() {
    local WM_NAME="$1"
    local WM_CMD="$2"
    local MSG_CMD="$3"
    local PREFIX="$OUT/${WM_NAME}"

    echo "=== Running scenarios with $WM_NAME ==="

    # Start Xvfb
    killall Xvfb 2>/dev/null || true; sleep 0.2
    Xvfb :99 -screen 0 ${SCREEN_W}x${SCREEN_H}x24 -ac 2>/dev/null &
    sleep 1
    export DISPLAY=:99

    # Start WM
    eval "$WM_CMD" &
    local WM_PID=$!
    wait_for_wm

    # Get IPC socket
    local SOCK
    SOCK=$(xprop -root I3_SOCKET_PATH 2>/dev/null | grep -oP '= "\K[^"]+' || echo "")

    run_msg() {
        if [ "$WM_NAME" = "i3" ]; then
            i3-msg "$@" 2>/dev/null || true
        else
            I3SOCK="$SOCK" ./bin/zephwm-msg "$@" 2>/dev/null || true
        fi
    }

    # --- Scenario 1: Single window (default border) ---
    echo "  1. Single window"
    xterm -T "Single Window" -e "sleep 60" &
    wait_for_win
    screenshot "${PREFIX}-01-single.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 2: Hsplit 2 windows ---
    echo "  2. Hsplit"
    xterm -T "Left" -e "sleep 60" &
    sleep 0.8
    xterm -T "Right" -e "sleep 60" &
    wait_for_win
    screenshot "${PREFIX}-02-hsplit.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 3: Tabbed 3 windows ---
    echo "  3. Tabbed"
    xterm -T "Tab One" -e "sleep 60" &
    sleep 0.8
    xterm -T "Tab Two" -e "sleep 60" &
    sleep 0.8
    xterm -T "Tab Three" -e "sleep 60" &
    sleep 0.8
    run_msg "layout tabbed"
    wait_for_cmd
    screenshot "${PREFIX}-03-tabbed.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 4: Stacked 3 windows ---
    echo "  4. Stacked"
    xterm -T "Stack One" -e "sleep 60" &
    sleep 0.8
    xterm -T "Stack Two" -e "sleep 60" &
    sleep 0.8
    xterm -T "Stack Three" -e "sleep 60" &
    sleep 0.8
    run_msg "layout stacking"
    wait_for_cmd
    screenshot "${PREFIX}-04-stacked.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 5: Border normal ---
    echo "  5. Border normal"
    xterm -T "Border Normal Window" -e "sleep 60" &
    wait_for_win
    run_msg "border normal"
    wait_for_cmd
    screenshot "${PREFIX}-05-border-normal.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 6: Border normal hsplit ---
    echo "  6. Border normal hsplit"
    xterm -T "Left Window" -e "sleep 60" &
    sleep 0.8
    xterm -T "Right Window" -e "sleep 60" &
    sleep 0.8
    run_msg "border normal"
    wait_for_cmd
    run_msg "focus left"
    sleep 0.3
    run_msg "border normal"
    wait_for_cmd
    screenshot "${PREFIX}-06-border-normal-hsplit.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 7: Vsplit ---
    echo "  7. Vsplit"
    xterm -T "Top" -e "sleep 60" &
    sleep 0.8
    xterm -T "Bottom" -e "sleep 60" &
    sleep 0.8
    run_msg "layout splitv"
    wait_for_cmd
    screenshot "${PREFIX}-07-vsplit.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 8: Border none ---
    echo "  8. Border none"
    xterm -T "No Border" -e "sleep 60" &
    wait_for_win
    run_msg "border none"
    wait_for_cmd
    screenshot "${PREFIX}-08-border-none.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 9: Border pixel 3 ---
    echo "  9. Border pixel 3"
    xterm -T "Thick Pixel" -e "sleep 60" &
    wait_for_win
    run_msg "border pixel 3"
    wait_for_cmd
    screenshot "${PREFIX}-09-border-pixel-3.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # --- Scenario 10: Border normal 3 ---
    echo "  10. Border normal 3"
    xterm -T "Thick Normal" -e "sleep 60" &
    wait_for_win
    run_msg "border normal 3"
    wait_for_cmd
    screenshot "${PREFIX}-10-border-normal-3.png"
    killall xterm 2>/dev/null || true; sleep 0.3

    # Stop WM
    if [ "$WM_NAME" = "i3" ]; then
        i3-msg exit 2>/dev/null || true
    else
        run_msg "exit"
    fi
    sleep 0.5
    kill $WM_PID 2>/dev/null || true
    killall Xvfb 2>/dev/null || true
    sleep 0.3

    echo "  Done ($WM_NAME)"
}

# i3 minimal config (default colors, no bar, no keybinds needed)
mkdir -p /tmp/i3config
cat > /tmp/i3config/config << 'CONF'
# Minimal i3 config for comparison
font pango:monospace 8
# Use default colors (no overrides)
CONF

# Run both WMs
run_scenario "i3" "i3 -c /tmp/i3config/config 2>/dev/null" "i3-msg"
run_scenario "zephwm" "./bin/zephwm 2>/dev/null" "zephwm-msg"

echo ""
echo "=== Screenshots saved to $OUT ==="
ls -la "$OUT"/*.png | awk '{print $NF}' | sort
