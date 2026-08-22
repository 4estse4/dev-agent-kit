#!/usr/bin/env bash
# Stop: warn about uncommitted changes when a turn ends.
status=$(git status --short 2>/dev/null) || exit 0
[ -z "$status" ] && exit 0
count=$(printf '%s\n' "$status" | wc -l | tr -d ' ')
files=$(printf '%s\n' "$status" | head -5 | sed 's/^[[:space:]]*//' | paste -sd '|' -)
suffix=""; [ "$count" -gt 5 ] && suffix=" ..."
printf 'Uncommitted: %s file(s) — %s%s\n' "$count" "$files" "$suffix"
