#!/usr/bin/env bash
# Print the build number (CFBundleVersion): the current time as YYYYMMDDHHMM,
# always in Asia/Tokyo. One rule for local builds and CI, so numbers from
# either compare directly (Sparkle compares CFBundleVersion with
# sparkle:version). A fixed zone has no DST step and does not follow the
# machine or runner setting, so the number only grows.
set -euo pipefail

TZ=Asia/Tokyo date +%Y%m%d%H%M
