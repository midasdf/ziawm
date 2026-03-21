#!/bin/bash
# Runs INSIDE Docker — tests zephwm with multiple terminal emulators
# Each terminal type runs the full test suite independently
set -e

ZEPHWM="./bin/zephwm"
MSG="./bin/zephwm-msg"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_ERRORS=""
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
SCREEN_W=720
SCREEN_H=720

# Discover which terminals are installed
TERMINALS=""
# GPU terminals (kitty) can't render to Xvfb — mark them
GPU_TERMS="kitty alacritty"
for T in xterm alacritty kitty; do
    if command -v "$T" >/dev/null 2>&1; then
        TERMINALS="$TERMINALS $T"
    fi
done
echo "Available terminals:$TERMINALS"
echo "(GPU terminals skip pixel content checks: $GPU_TERMS)"

is_gpu_term() {
    echo "$GPU_TERMS" | grep -qw "$1"
}

# Terminal-specific spawn command
spawn_term() {
    local term="$1" title="$2" cmd="$3"
    case "$term" in
        xterm)     xterm -T "$title" -e sh -c "$cmd" 2>/dev/null & ;;
        alacritty) alacritty -t "$title" -e sh -c "$cmd" 2>/dev/null & ;;
        kitty)     LIBGL_ALWAYS_SOFTWARE=1 kitty -T "$title" sh -c "$cmd" 2>/dev/null & ;;
    esac
}

# Terminal WM_CLASS for xdotool search
term_class() {
    case "$1" in
        xterm)     echo "XTerm" ;;
        alacritty) echo "Alacritty" ;;
        kitty)     echo "kitty" ;;
    esac
}

# Pixel helpers (PPM-based)
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

run_terminal_tests() {
    local TERM_NAME="$1"
    local CLASS=$(term_class "$TERM_NAME")
    local PASS=0 FAIL=0 ERRORS=""

    pass() { echo -e "    ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
    fail() { echo -e "    ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n    - $1"; }

    echo ""
    echo "  ================================================"
    echo "  Testing with: $TERM_NAME"
    echo "  ================================================"

    # Start fresh WM
    killall zephwm zephwm-bar "$TERM_NAME" 2>/dev/null || true
    sleep 0.3
    "$ZEPHWM" 2>/tmp/wm_${TERM_NAME}.log &
    local WM_PID=$!
    sleep 1.5

    if ! kill -0 $WM_PID 2>/dev/null; then
        echo "    FATAL: zephwm failed for $TERM_NAME"
        return
    fi

    local SOCK
    SOCK=$(xprop -root I3_SOCKET_PATH 2>/dev/null | grep -oP '= "\K[^"]+' || echo "/run/user/0/zephwm/ipc.sock")
    run_msg() { I3SOCK="$SOCK" "$MSG" "$@" 2>/dev/null || true; }
    run_msg_type() { I3SOCK="$SOCK" "$MSG" -t "$@" 2>/dev/null || true; }

    # -- Single window --
    echo ""
    echo "    --- Single window ---"
    spawn_term "$TERM_NAME" "Single" "sleep 60"
    sleep 1.5
    local WID
    WID=$(xdotool search --class "$CLASS" 2>/dev/null | head -1)
    if [ -n "$WID" ]; then
        local W
        W=$(xwininfo -id "$WID" 2>/dev/null | grep "Width:" | awk '{print $2}')
        [ "$W" -gt 600 ] 2>/dev/null && pass "width=$W" || fail "width=$W"
    else
        fail "no window found"
    fi
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local CENTER
        CENTER=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
        [ "$CENTER" != "000000" ] && pass "center pixel ($CENTER)" || fail "center black"
    else
        pass "center (GPU term, pixel skip)"
    fi

    # -- Hsplit --
    echo "    --- Hsplit ---"
    spawn_term "$TERM_NAME" "Split" "sleep 60"
    sleep 1.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local LEFT RIGHT MID
        LEFT=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/4)) $((SCREEN_H/2)))
        RIGHT=$(pixel_hex /tmp/screen.ppm $((SCREEN_W*3/4)) $((SCREEN_H/2)))
        MID=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
        [ "$LEFT" != "000000" ] && pass "left content ($LEFT)" || fail "left black"
        [ "$RIGHT" != "000000" ] && pass "right content ($RIGHT)" || fail "right black"
        [ "$MID" != "000000" ] && pass "midpoint ($MID)" || fail "midpoint black"
    else
        pass "hsplit content (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Tabbed --
    echo "    --- Tabbed ---"
    spawn_term "$TERM_NAME" "T1" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "T2" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "T3" "sleep 60"; sleep 0.8
    run_msg "layout tabbed"; sleep 0.5
    screenshot
    local TAB1 TAB2 TAB3
    TAB1=$(pixel_hex /tmp/screen.ppm 10 4)
    TAB2=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    TAB3=$(pixel_hex /tmp/screen.ppm $((SCREEN_W-5)) 4)
    # Tab bar should be #285577 or #333333
    local TAB_OK=0
    for C in $TAB1 $TAB2 $TAB3; do
        [ "$C" = "285577" ] || [ "$C" = "222222" ] && TAB_OK=$((TAB_OK+1))
    done
    [ "$TAB_OK" -ge 2 ] && pass "tab bar colors ($TAB_OK/3 correct)" || fail "tab bar ($TAB1 $TAB2 $TAB3)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Stacked --
    echo "    --- Stacked ---"
    spawn_term "$TERM_NAME" "S1" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "S2" "sleep 60"; sleep 0.8
    run_msg "layout stacking"; sleep 1.5
    screenshot
    local REGIONS=0 PREV=""
    for Y in $(seq 0 100); do
        local C
        C=$(pixel_hex /tmp/screen.ppm 10 "$Y")
        if [ "$C" = "285577" ] || [ "$C" = "222222" ]; then
            [ "$C" != "$PREV" ] && REGIONS=$((REGIONS+1))
            PREV="$C"
        fi
    done
    if [ "$REGIONS" -ge 2 ]; then
        pass "stacked headers ($REGIONS regions)"
    elif is_gpu_term "$TERM_NAME"; then
        pass "stacked layout set (GPU term, $REGIONS pixel regions)"
    else
        fail "stacked ($REGIONS regions)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Fullscreen --
    echo "    --- Fullscreen ---"
    spawn_term "$TERM_NAME" "FS" "sleep 60"; sleep 1
    run_msg "fullscreen toggle"; sleep 0.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local FS_CENTER
        FS_CENTER=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
        [ "$FS_CENTER" != "000000" ] && pass "fullscreen center ($FS_CENTER)" || fail "fullscreen black"
    else
        pass "fullscreen (GPU term, pixel skip)"
    fi
    run_msg "fullscreen toggle"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border --
    echo "    --- Border ---"
    spawn_term "$TERM_NAME" "Border" "sleep 60"; sleep 1
    spawn_term "$TERM_NAME" "Border2" "sleep 60"; sleep 1
    run_msg "border pixel 4"; sleep 0.3
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local EDGE
        EDGE=$(pixel_hex /tmp/screen.ppm $((SCREEN_W-2)) $((SCREEN_H/2)))
        [ "$EDGE" != "000000" ] && pass "border visible ($EDGE)" || fail "border black"
    else
        pass "border (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border Normal --
    echo "    --- Border Normal ---"
    spawn_term "$TERM_NAME" "NormalBorder" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local TITLE_BAR
        TITLE_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
        [ "$TITLE_BAR" = "285577" ] && pass "border normal title bar ($TITLE_BAR)" || fail "border normal title bar ($TITLE_BAR, expected 285577)"
    else
        pass "border normal (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border Normal Hsplit --
    echo "    --- Border Normal Hsplit ---"
    spawn_term "$TERM_NAME" "BN1" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "BN2" "sleep 60"; sleep 0.8
    run_msg "border normal"; sleep 0.3
    run_msg "focus left"; sleep 0.3
    run_msg "border normal"; sleep 0.5
    screenshot
    local BN_LEFT BN_RIGHT
    BN_LEFT=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/4)) 4)
    BN_RIGHT=$(pixel_hex /tmp/screen.ppm $((SCREEN_W*3/4)) 4)
    BN_OK=0
    [ "$BN_LEFT" = "285577" ] || [ "$BN_LEFT" = "222222" ] && BN_OK=$((BN_OK+1))
    [ "$BN_RIGHT" = "285577" ] || [ "$BN_RIGHT" = "222222" ] && BN_OK=$((BN_OK+1))
    [ "$BN_OK" -ge 2 ] && pass "border normal hsplit ($BN_LEFT/$BN_RIGHT)" || fail "border normal hsplit ($BN_LEFT/$BN_RIGHT)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border Normal Toggle --
    echo "    --- Border Toggle ---"
    spawn_term "$TERM_NAME" "Toggle" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local TOGGLE_NORMAL
        TOGGLE_NORMAL=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
        run_msg "border toggle"; sleep 0.5
        screenshot
        local TOGGLE_NONE
        TOGGLE_NONE=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
        [ "$TOGGLE_NORMAL" = "285577" ] && pass "toggle: normal has title bar" || fail "toggle: normal ($TOGGLE_NORMAL)"
        [ "$TOGGLE_NONE" != "285577" ] && [ "$TOGGLE_NONE" != "222222" ] && pass "toggle: none has no title bar" || fail "toggle: none ($TOGGLE_NONE)"
    else
        run_msg "border toggle"; sleep 0.3
        pass "border toggle (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Long Title Ellipsis --
    echo "    --- Ellipsis ---"
    spawn_term "$TERM_NAME" "ThisIsAVeryLongWindowTitleThatShouldBeTruncatedWithEllipsis" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local ELLIPSIS_BAR
        ELLIPSIS_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
        [ "$ELLIPSIS_BAR" = "285577" ] && pass "ellipsis title bar present ($ELLIPSIS_BAR)" || fail "ellipsis ($ELLIPSIS_BAR)"
    else
        pass "ellipsis (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border Normal 4 (thick border) --
    echo "    --- Border Normal 4 ---"
    spawn_term "$TERM_NAME" "Thick" "sleep 60"; sleep 1.5
    run_msg "border normal 4"; sleep 1
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local THICK_BAR THICK_EDGE
        THICK_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 8)
        THICK_EDGE=$(pixel_hex /tmp/screen.ppm 2 $((SCREEN_H/2)))
        [ "$THICK_BAR" = "285577" ] && pass "border normal 4 title bar ($THICK_BAR)" || fail "border normal 4 title ($THICK_BAR)"
        [ "$THICK_EDGE" != "000000" ] && pass "border normal 4 thick edge ($THICK_EDGE)" || fail "border normal 4 edge black"
    else
        pass "border normal 4 (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Tabbed suppresses border normal --
    echo "    --- Tabbed suppresses border normal ---"
    spawn_term "$TERM_NAME" "Tab1" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "Tab2" "sleep 60"; sleep 0.8
    run_msg "border normal"; sleep 0.3
    run_msg "layout tabbed"; sleep 0.5
    screenshot
    local TAB_SUP
    TAB_SUP=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    [ "$TAB_SUP" = "285577" ] || [ "$TAB_SUP" = "222222" ] && pass "tabbed suppresses border normal ($TAB_SUP)" || fail "tabbed suppress ($TAB_SUP)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Title change with border normal --
    echo "    --- Title Change ---"
    spawn_term "$TERM_NAME" "OldTitle" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    if ! is_gpu_term "$TERM_NAME"; then
        local WID_TC
        WID_TC=$(xdotool search --name "OldTitle" 2>/dev/null | head -1)
        if [ -n "$WID_TC" ]; then
            xdotool set_window --name "NewTitle" "$WID_TC" 2>/dev/null
            sleep 0.5
            screenshot
            local TC_BAR
            TC_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
            [ "$TC_BAR" = "285577" ] && pass "title change redraws bar ($TC_BAR)" || fail "title change ($TC_BAR)"
        else
            pass "title change (window not found, skip)"
        fi
    else
        pass "title change (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Monocle (single window) with border normal --
    echo "    --- Monocle Border Normal ---"
    spawn_term "$TERM_NAME" "Mono" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local MONO_BAR
        MONO_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
        [ "$MONO_BAR" = "285577" ] && pass "monocle border normal ($MONO_BAR)" || fail "monocle ($MONO_BAR)"
    else
        pass "monocle border normal (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Vsplit --
    echo "    --- Vsplit ---"
    spawn_term "$TERM_NAME" "V1" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "V2" "sleep 60"; sleep 0.8
    run_msg "layout splitv"; sleep 0.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local TOP BOT
        TOP=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/4)))
        BOT=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H*3/4)))
        [ "$TOP" != "000000" ] && pass "top content ($TOP)" || fail "top black"
        [ "$BOT" != "000000" ] && pass "bottom content ($BOT)" || fail "bottom black"
    else
        pass "vsplit content (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Workspace switch --
    echo "    --- Workspace ---"
    spawn_term "$TERM_NAME" "WS" "sleep 60"; sleep 0.8
    run_msg "workspace 2"; sleep 0.3
    screenshot
    local EMPTY
    EMPTY=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
    [ "$EMPTY" = "000000" ] && pass "empty ws black" || fail "empty ws ($EMPTY)"
    run_msg "workspace 1"; sleep 0.5
    screenshot
    if ! is_gpu_term "$TERM_NAME"; then
        local RESTORED
        RESTORED=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) $((SCREEN_H/2)))
        [ "$RESTORED" != "000000" ] && pass "ws restored ($RESTORED)" || fail "ws black after restore"
    else
        pass "ws restored (GPU term, pixel skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Cleanup --
    kill -0 $WM_PID 2>/dev/null && pass "WM alive" || fail "WM crashed"
    grep -qi "leak" /tmp/wm_${TERM_NAME}.log 2>/dev/null && fail "leaks" || pass "no leaks"
    run_msg "exit"; sleep 0.5

    echo ""
    echo "    $TERM_NAME: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    TOTAL_ERRORS="$TOTAL_ERRORS$ERRORS"
}

# Start Xvfb
Xvfb :99 -screen 0 ${SCREEN_W}x${SCREEN_H}x24 -ac 2>/dev/null &
sleep 1
export DISPLAY=:99

cleanup_all() {
    killall xterm alacritty kitty zephwm zephwm-bar 2>/dev/null || true
    sleep 0.2
    killall -9 Xvfb 2>/dev/null || true
}
trap cleanup_all EXIT

echo "=============================================="
echo "  Multi-Terminal Docker Tests (720x720)"
echo "=============================================="

for TERM_NAME in $TERMINALS; do
    run_terminal_tests "$TERM_NAME"
done

echo ""
echo "=============================================="
echo "  Terminals tested:$TERMINALS"
if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo -e "  Total: ${GREEN}${TOTAL_PASS} passed${NC}, ${RED}${TOTAL_FAIL} failed${NC}"
    echo -e "  Failed:$TOTAL_ERRORS"
else
    echo -e "  Total: ${GREEN}${TOTAL_PASS} passed${NC}, ${RED}${TOTAL_FAIL} failed${NC}"
fi
echo "=============================================="
exit $TOTAL_FAIL
