#!/usr/bin/env bash
set -eu
root="$STRAPS_KAGI_TRANSPORT_FIXTURE"
n=0
if [[ -f "$root/count" ]]; then read -r n < "$root/count"; fi
n=$((n + 1))
printf '%s\n' "$n" > "$root/count"
printf '%s\n' "$@" > "$root/argv.$n"
while IFS= read -r line; do printf '%s\n' "$line"; done > "$root/stdin.$n"
if [[ -f "$root/wait.$n" ]]; then exec sleep 10; fi
if [[ -f "$root/response.$n" ]]; then cat "$root/response.$n"; fi
if [[ -f "$root/waitafter.$n" ]]; then exec sleep 10; fi
if [[ -f "$root/exit.$n" ]]; then read -r code < "$root/exit.$n"; exit "$code"; fi
