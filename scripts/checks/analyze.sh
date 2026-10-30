#!/usr/bin/env bash
#
# Runs clang's static analyzer over every piece's macOS test bundle and fails
# on any finding outside third_party/. Vendored code is not restyled. Modeled
# on Vibe's scripts/build/analyze.sh.
#
# Usage: scripts/checks/analyze.sh [Debug|Release] [K/N] [REV]
#   Release by default, as CI runs it. K/N and REV pick the bundles, as
#   scripts/checks/targets.py's --shard and --since do.
set -euo pipefail

CONFIGURATION="${1:-Release}"
SHARD="${2:-}"
SINCE="${3:-}"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "error: configuration must be Debug or Release (got '$CONFIGURATION')" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/../.."
mkdir -p build
LOG="build/analyze-$CONFIGURATION.log"
BUNDLES="$(python3 -I scripts/checks/targets.py ${SHARD:+--shard "$SHARD"} ${SINCE:+--since "$SINCE"} \
    --scheme vibe-libs-analyze)"
if [[ -z "$BUNDLES" ]]; then
    echo "static analyzer: nothing to analyze${SHARD:+ in shard $SHARD}${SINCE:+ since $SINCE}"
    exit 0
fi
DERIVED="build/AnalyzeDD"

# The scheme builds the test bundles only for testing, so the analyze action
# skips them. A build for testing with the analyzer on reaches every one.
#
# TRAP: an incremental build skips the analysis of unchanged files and prints
# none of their findings. Each run starts from empty derived data.
rm -rf "$DERIVED"
set +e
xcodebuild build-for-testing \
    -project vibe-libs.xcodeproj \
    -scheme vibe-libs-analyze \
    -destination 'platform=macOS' \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    -quiet \
    RUN_CLANG_STATIC_ANALYZER=YES \
    CLANG_STATIC_ANALYZER_MODE=deep 2>&1 | tee "$LOG"
BUILD_STATUS="${PIPESTATUS[0]}"
set -e

if [[ "$BUILD_STATUS" -ne 0 ]]; then
    echo "error: analyze failed to build (see $LOG)" >&2
    exit "$BUILD_STATUS"
fi

# A finding ends in its checker's name, such as [core.NullDereference]. A
# compiler warning ends in its flag, such as [-Wunused], which starts with -.
FINDINGS="$(grep -E '^/.*: (warning|error): .*\[[a-zA-Z]' "$LOG" | grep -v '/third_party/' || true)"
if [[ -n "$FINDINGS" ]]; then
    COUNT="$(printf '%s\n' "$FINDINGS" | wc -l | tr -d ' ')"
    echo >&2
    echo "error: static analyzer: $COUNT finding(s)" >&2
    printf '%s\n' "$FINDINGS" >&2
    exit 1
fi

echo "static analyzer: clean ($CONFIGURATION${SHARD:+, shard $SHARD})"
