#!/usr/bin/env bash
# queue-install.sh — WSL-side dispatcher for PATH-A v5 install via mm-task-runner queue.
#
# Submits a PATHA-V5-INSTALL request to C:\mm-dev-queue\request.txt, triggers the
# 'MM-Dev-Cycle' scheduled task (which runs mm-task-runner.ps1 as SYSTEM), and
# polls C:\mm-dev-queue\result.txt for the matching nonce.
#
# Nothing for the user to run on Windows manually. The user just runs this script
# from WSL and waits for the queue to dispatch.
#
# Usage:
#   bash queue-install.sh                     # use default bundle dir C:\mm-dev-queue\PATH-A-v5
#   bash queue-install.sh stage               # stage bundle to C:\ first, then submit
#   bash queue-install.sh uninstall           # submit PATHA-V5-UNINSTALL request

set -euo pipefail

QUEUE='/mnt/c/mm-dev-queue'
REQ="$QUEUE/request.txt"
RES="$QUEUE/result.txt"
TASK='MM-Dev-Cycle'
BUNDLE_DIR_WIN='C:\mm-dev-queue\PATH-A-v5'
BUNDLE_DIR_WSL='/mnt/c/mm-dev-queue/PATH-A-v5'
REPO='/home/lesley/projects/Personal/magic-mouse-tray'
ACTION="${1:-install}"

mkdir -p "$QUEUE"
NONCE="v5-$(date +%Y%m%d-%H%M%S)-$$"

stage_bundle() {
    echo "[$NONCE] staging bundle from $REPO/dist/PATH-A-v5 -> $BUNDLE_DIR_WSL"
    mkdir -p "$BUNDLE_DIR_WSL"
    cp -f "$REPO/dist/PATH-A-v5/MagicMouseFixV3.inf"  "$BUNDLE_DIR_WSL/" 2>/dev/null
    cp -f "$REPO/dist/PATH-A-v5/install.ps1"          "$BUNDLE_DIR_WSL/" 2>/dev/null
    cp -f "$REPO/dist/PATH-A-v5/uninstall.ps1"        "$BUNDLE_DIR_WSL/" 2>/dev/null
    cp -f "$REPO/dist/PATH-A-v5/instrumented-test.ps1" "$BUNDLE_DIR_WSL/" 2>/dev/null
    cp -f "$REPO/dist/PATH-A-v5/notmyfault-validate.ps1" "$BUNDLE_DIR_WSL/" 2>/dev/null
    cp -f "$REPO/sign-and-install.ps1"                "$BUNDLE_DIR_WSL/" 2>/dev/null
    cp -f "$REPO/startup-repair.ps1"                  "$BUNDLE_DIR_WSL/" 2>/dev/null
    # Patched .sys (WHQL overlay intact)
    if [ ! -f "$BUNDLE_DIR_WSL/MagicMouseFixV3.sys" ]; then
        if [ -f /mnt/c/mm-dev-queue/applewirelessmouse-pathA-unsigned.sys ]; then
            cp -f /mnt/c/mm-dev-queue/applewirelessmouse-pathA-unsigned.sys "$BUNDLE_DIR_WSL/MagicMouseFixV3.sys"
            echo "[$NONCE] copied patched .sys (renamed to MagicMouseFixV3.sys)"
        else
            echo "[$NONCE] WARNING: no patched .sys source found at /mnt/c/mm-dev-queue/applewirelessmouse-pathA-unsigned.sys"
        fi
    fi
    ls -la "$BUNDLE_DIR_WSL"
}

submit_and_wait() {
    local phase="$1"; shift
    local args=("$@")
    local req_line="$phase|$NONCE"
    for a in "${args[@]}"; do req_line="$req_line|$a"; done

    echo "[$NONCE] submitting: $req_line"
    printf '%s' "$req_line" > "$REQ"

    # Trigger the scheduled task (works from WSL if schtasks.exe is callable)
    /mnt/c/Windows/System32/schtasks.exe /run /tn "$TASK" >/dev/null
    echo "[$NONCE] scheduled task triggered, polling $RES (timeout 600s)..."

    # Poll for matching nonce in result.txt (max 10 min)
    for i in $(seq 1 120); do
        sleep 5
        if [ -f "$RES" ]; then
            local content
            content=$(tr -d '\r\n' < "$RES" 2>/dev/null || echo '')
            if [[ "$content" == *"|$NONCE" ]]; then
                local exit_code="${content%%|*}"
                echo "[$NONCE] result: exit=$exit_code"
                return "$exit_code"
            fi
        fi
    done
    echo "[$NONCE] timeout - no matching result"
    return 124
}

case "$ACTION" in
    stage)
        stage_bundle
        ;;
    install)
        stage_bundle
        submit_and_wait 'PATHA-V5-INSTALL' "$BUNDLE_DIR_WIN"
        rc=$?
        echo "[$NONCE] log: $QUEUE/pathA-v5-install-$NONCE.log"
        if [ -f "$QUEUE/pathA-v5-install-$NONCE.log" ]; then
            echo "--- last 30 lines of route log ---"
            tail -30 "$QUEUE/pathA-v5-install-$NONCE.log"
        fi
        exit $rc
        ;;
    uninstall)
        submit_and_wait 'PATHA-V5-UNINSTALL'
        rc=$?
        echo "[$NONCE] log: $QUEUE/pathA-v5-uninstall-$NONCE.log"
        if [ -f "$QUEUE/pathA-v5-uninstall-$NONCE.log" ]; then
            tail -30 "$QUEUE/pathA-v5-uninstall-$NONCE.log"
        fi
        exit $rc
        ;;
    *)
        echo "Usage: $0 {stage|install|uninstall}"
        exit 1
        ;;
esac
