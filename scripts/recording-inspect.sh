#!/usr/bin/env bash

record_commands() {
    [[ ${DEMO_RECORDING:-0} == 1 ]] || return 0
    local inspection_command
    for inspection_command in "$@"; do
        printf '\n$ %s\n' "$inspection_command"
        timeout 30s bash -o pipefail -c "$inspection_command" || return "$?"
        sleep 3
    done
}