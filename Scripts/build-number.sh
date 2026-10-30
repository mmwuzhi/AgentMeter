#!/usr/bin/env bash
# Print the build number (CFBundleVersion): the current time as YYYYMMDDHHMM,
# always in Asia/Tokyo. One rule for local builds and CI, so numbers from
# either compare directly (Sparkle compares CFBundleVersion with
# sparkle:version). A fixed zone has no DST step and does not follow the
# machine or runner setting, so the number only grows.
#
# Usage: build-number.sh [floor]
# With a floor, the number is strictly greater than it. Two builds in one
# minute would otherwise share a number, and Sparkle never offers an update
# whose number equals the installed one. Still the floor's minute: wait for
# the next one (at most a minute). A clock behind the floor: fail rather than
# print a smaller number.
set -euo pipefail

floor="${1:-}"
if [[ -n "$floor" && ! "$floor" =~ ^[0-9]{1,12}$ ]]; then
    echo "build-number.sh: the floor must be a number of at most 12 digits, got: $floor" >&2
    exit 1
fi

now() { TZ=Asia/Tokyo date +%Y%m%d%H%M; }

number="$(now)"
if [[ -n "$floor" ]]; then
    if (( 10#$number < 10#$floor )); then
        echo "build-number.sh: the clock ($number) is behind the last build number $floor" >&2
        exit 1
    fi
    while (( 10#$number <= 10#$floor )); do
        echo "build-number.sh: $number is already used; waiting for the next minute" >&2
        sleep $(( 61 - 10#$(date +%S) ))
        number="$(now)"
    done
fi
echo "$number"
