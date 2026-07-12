#!/usr/bin/env bash
# =============================================================================
# PPSA - First Boot Progress Display
# =============================================================================
# Runs in foreground on /dev/tty1 via ppsa-firstboot.service.
# Shows live install progress, total completion %, and a welcome screen
# after install completes. Stays running until the user presses a key
# to "release" tty1 to the getty (autologin).
#
# This is a one-shot service (ConditionPathExists=!/opt/ppsa/.installed)
# so it never runs again after the first boot.
# =============================================================================

set -u

# Terminal control
CLEAR=$'\033[H\033[2J\033[3J'
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
HIDE_CURSOR=$'\033[?25l'
SHOW_CURSOR=$'\033[?25h'

LOG_FILE="/var/log/ppsa-install.log"
FLAG_FILE="/opt/ppsa/.installed"
PROGRESS_FILE="/run/ppsa-install.progress"  # written by install.sh
SERVICE_NAME="ppsa-install.service"

# Total steps in install.sh (must match).
TOTAL_STEPS=9
STEP_NAMES=(
    "Resizing root partition"
    "Starting Docker"
    "Configuring environment"
    "Deploying Docker stack"
    "Installing Wi-Fi onboarding"
    "Enrolling in NetBird network"
    "WireGuard (legacy)"
    "Configuring firewall"
    "Marking installation complete"
)

# --- Helpers ---
get_ip() {
    ip -4 addr show 2>/dev/null \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
        | grep -v '127.0.0.1' \
        | head -1 || true
}

is_install_done() {
    [[ -f "$FLAG_FILE" ]]
}

# Read the current step from the log (looks for [N/7] markers) or
# the progress file written by install.sh.
get_current_step() {
    if [[ -f "$PROGRESS_FILE" ]]; then
        cat "$PROGRESS_FILE" 2>/dev/null || echo 0
        return
    fi
    if [[ -f "$LOG_FILE" ]]; then
        # Look for the highest [N/9] marker (or [N/7] or [N/8] for older installs)
        grep -oP '\[\d/[789]\]' "$LOG_FILE" 2>/dev/null \
            | grep -oP '\d' \
            | sort -n \
            | tail -1 || echo 0
    else
        echo 0
    fi
}

# Get a one-line status from the last non-trivial log line
get_status_line() {
    if [[ -f "$LOG_FILE" ]]; then
        tail -20 "$LOG_FILE" 2>/dev/null \
            | grep -vE '^\[?\d/7\]|^\[STEP' \
            | grep -vE '^\s*$' \
            | tail -1 || echo "Starting..."
    else
        echo "Waiting for install to begin..."
    fi
}

# Build a horizontal progress bar (width = bar_width, filled = pct/100)
# Outputs: "[#######   ]" style.
progress_bar() {
    local pct=$1
    local width=40
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="#"; done
    for ((i=0; i<empty; i++)); do bar+=" "; done
    printf "[%s]" "$bar"
}

# Build the step list with current/done/pending markers
# Outputs "DONE|ACTIVE|PENDING" lines for each step.
render_steps() {
    local current=$1
    for ((i=0; i<TOTAL_STEPS; i++)); do
        local idx=$((i+1))
        local marker
        if (( idx < current )); then
            marker="${GREEN}[ DONE ]${RESET}"
        elif (( idx == current )); then
            marker="${YELLOW}[ ACTV ]${RESET}"
        else
            marker="${DIM}[ WAIT ]${RESET}"
        fi
        printf "  %b Step %d/%d: %s\n" "$marker" "$idx" "$TOTAL_STEPS" "${STEP_NAMES[$i]}"
    done
}

# Render the full screen at the current state.
render() {
    local current=$1
    local status=$2
    local ip=$3
    local pct=$(( current * 100 / TOTAL_STEPS ))

    # Move cursor to top-left and clear
    printf "%s" "$CLEAR"

    cat <<EOF
${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════╗
║           PPSA - Palworld Server Appliance v$(cat /opt/ppsa/VERSION 2>/dev/null || echo "?.?.?")           ║
║                      First Boot Setup                            ║
╚══════════════════════════════════════════════════════════════════╝${RESET}

${BOLD}Installation Progress${RESET}                                          ${BOLD}${pct}%%${RESET}

  ${BOLD}$(progress_bar "$pct")${RESET}
  Step ${current}/${TOTAL_STEPS} complete

${BOLD}Steps${RESET}
$(render_steps "$current")

${BOLD}Status${RESET}
  ${BLUE}${status}${RESET}

EOF

    if (( current >= TOTAL_STEPS )); then
        cat <<EOF
${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗
║                  Setup Complete!                                  ║
╚══════════════════════════════════════════════════════════════════╝${RESET}

EOF
        if [[ -n "$ip" ]]; then
            # NetBird is the primary overlay; read its assigned IP if enrolled.
            nb_ip=""
            [[ -r /run/ppsa-netbird-ip ]] && nb_ip=$(cat /run/ppsa-netbird-ip 2>/dev/null || true)
            # WireGuard is deprecated/off by default — only surfaced if enabled.
            wg_ip=""
            [[ -r /run/ppsa-wireguard-ip ]] && wg_ip=$(cat /run/ppsa-wireguard-ip 2>/dev/null || true)
            wg_enabled=false
            [[ -f /etc/ppsa/wireguard.json ]] && \
                grep -q '"enabled"[[:space:]]*:[[:space:]]*true' /etc/ppsa/wireguard.json 2>/dev/null && \
                wg_enabled=true

            cat <<EOF
  ${BOLD}Web UI:${RESET}       ${CYAN}http://${ip}:8080${RESET}            ${DIM}Login: admin / admin${RESET}
  ${BOLD}SSH:${RESET}          ${CYAN}ppsa@${ip}${RESET}                  ${DIM}Password: ppsa${RESET}
EOF
            if [[ -n "$nb_ip" ]]; then
                cat <<EOF
  ${BOLD}NetBird:${RESET}      ${CYAN}${nb_ip}${RESET}                    ${DIM}primary overlay — friends join via setup key${RESET}

EOF
            else
                cat <<EOF
  ${DIM}NetBird: enrolling (retries each boot until the control plane is reachable)${RESET}

EOF
            fi
            if [[ "$wg_enabled" == true ]]; then
                if [[ -n "$wg_ip" ]]; then
                    cat <<EOF
  ${BOLD}WireGuard:${RESET}    ${CYAN}${wg_ip}${RESET}                    ${DIM}legacy — wg-easy UI :10086${RESET}

EOF
                else
                    cat <<EOF
  ${DIM}WireGuard (legacy): registering with wg-easy (retries on next boot)${RESET}

EOF
                fi
            fi
        else
            cat <<EOF
  ${DIM}Waiting for network to come up...${RESET}

EOF
        fi
        cat <<EOF
  ${DIM}Press any key to drop to the shell.${RESET}

EOF
    else
        cat <<EOF
${DIM}  This screen updates automatically. Press Ctrl-C to drop to a shell
  (install will continue in the background).${RESET}

EOF
    fi
}

# --- Main loop ---
main() {
    # Ensure cursor is visible on exit
    trap 'printf "%s" "$SHOW_CURSOR"' EXIT
    printf "%s" "$HIDE_CURSOR"

    # Show initial state (step 0)
    render 0 "Waiting for install to begin..." ""

    # Poll loop
    local last_render_step=-1
    while ! is_install_done; do
        local current
        current=$(get_current_step)
        local status
        status=$(get_status_line)
        local ip
        ip=$(get_ip)

        if (( current != last_render_step )); then
            render "$current" "$status" "$ip"
            last_render_step=$current
        else
            # No step change — just refresh the status line area periodically
            # (every ~5s) by re-rendering with the same step.
            sleep 5
            render "$current" "$status" "$ip"
            last_render_step=$current
            continue
        fi

        sleep 1
    done

    # Install complete — render the final welcome screen
    local ip
    ip=$(get_ip)
    # Wait briefly for IP to settle if it just came up
    for _ in 1 2 3 4 5; do
        [[ -n "$ip" ]] && break
        sleep 1
        ip=$(get_ip)
    done

    # Wait up to 15s for the WG IP file. The register script writes it on
    # success and is synchronous in install.sh step 5. If the file isn't
    # there yet, the registration is either still in progress or failed.
    if [[ -f /etc/ppsa/wireguard.json ]] && \
       grep -q '"enabled"[[:space:]]*:[[:space:]]*true' /etc/ppsa/wireguard.json 2>/dev/null; then
        local wg_wait=0
        while (( wg_wait < 15 )); do
            [[ -r /run/ppsa-wireguard-ip ]] && break
            sleep 1
            wg_wait=$(( wg_wait + 1 ))
        done
    fi

    render "$TOTAL_STEPS" "PPSA is ready." "$ip"

    # Wait for any keypress, with a 30s timeout so the user can walk away.
    # After the keypress (or timeout), we exit, which lets systemd kill
    # this service, which lets getty take over tty1 (autologin).
    if read -r -t 30 -n 1 _ 2>/dev/null; then
        # User pressed a key — exit immediately
        :
    fi
}

main
