#!/usr/bin/env bash
#
# Runs clang's static analyzer over every piece's macOS test bundle and fails
# on any finding outside third_party/. Vendored code is not restyled. Modeled
# on Vibe's scripts/build/analyze.sh.
#
# Usage: scripts/checks/analyze.sh [Debug|Release] [K/N]
#   Release by default, as CI runs it. With K/N it analyzes only the Kth of N
#   shards of the test bundles, as scripts/checks/test-bundles.py splits them.
set -euo pipefail

CONFIGURATION="${1:-Release}"
SHARD="${2:-}"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "error: configuration must be Debug or Release (got '$CONFIGURATION')" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/../.."
mkdir -p build
LOG="build/analyze-$CONFIGURATION.log"
ONLY=()
if [[ -n "$SHARD" ]]; then
    BUNDLES="$(python3 -I scripts/checks/test-bundles.py --shard "$SHARD")"
    if [[ -z "$BUNDLES" ]]; then
        echo "error: shard $SHARD has no test bundles" >&2
        exit 1
    fi
    echo "analyzing shard $SHARD:" $BUNDLES
    for bundle in $BUNDLES; do
        ONLY+=("-only-testing:$bundle")
    done
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
    -scheme vibe-libs \
    -destination 'platform=macOS' \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    -quiet \
    ${ONLY[@]+"${ONLY[@]}"} \
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
