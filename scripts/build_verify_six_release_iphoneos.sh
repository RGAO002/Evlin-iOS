#!/bin/bash
set -euo pipefail

usage() {
    echo "usage: $0 --derived-data <absolute-path> --evidence <absolute-path>" >&2
    exit 64
}

DERIVED_DATA=""
EVIDENCE=""
while (($#)); do
    case "$1" in
        --derived-data) DERIVED_DATA="${2:-}"; shift 2 ;;
        --evidence) EVIDENCE="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done

[[ "$DERIVED_DATA" = /* && "$EVIDENCE" = /* ]] || usage
[[ "$DERIVED_DATA" != "/" && "$DERIVED_DATA" != "/Users" ]] || usage

IOS_ROOT="/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
PRODUCTS_ROOT="$DERIVED_DATA/Build/Products"
RELEASE_ROOT="$PRODUCTS_ROOT/Release-iphoneos"
RELEASE_APP="$RELEASE_ROOT/Evlin iOS.app"
DEBUG_ROOT="$PRODUCTS_ROOT/Debug-iphoneos"
EXPECTED="$DERIVED_DATA/expected-products.txt"
OBSERVED="$DERIVED_DATA/observed-products.txt"

rm -rf -- "$DERIVED_DATA"
mkdir -p -- "$DERIVED_DATA" "$(dirname "$EVIDENCE")"

(
    cd "$IOS_ROOT"
    SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild build \
        -project 'Evlin iOS.xcodeproj' \
        -scheme 'Evlin iOS' \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        IPHONEOS_DEPLOYMENT_TARGET=17.6 \
        TARGETED_DEVICE_FAMILY='1,2'
    SENTRY_SKIP_DSYM_UPLOAD=1 xcodebuild build-for-testing \
        -project 'Evlin iOS.xcodeproj' \
        -scheme 'Evlin iOS' \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        IPHONEOS_DEPLOYMENT_TARGET=17.6 \
        TARGETED_DEVICE_FAMILY='1,2'
)

PRODUCTS=(
    "Release-iphoneos/Evlin iOS.app/Evlin iOS"
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor"
    "Release-iphoneos/Evlin iOS.app/Extensions/EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport"
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinShieldConfig.appex/EvlinShieldConfig"
    "Release-iphoneos/Evlin iOS.app/PlugIns/EvlinPushApplier.appex/EvlinPushApplier"
    "Debug-iphoneos/Evlin iOS.app/PlugIns/Evlin iOSTests.xctest/Evlin iOSTests"
)

printf '%s\n' "${PRODUCTS[@]}" | LC_ALL=C sort > "$EXPECTED"
{
    printf '%s\n' "Release-iphoneos/Evlin iOS.app/Evlin iOS"
    find "$RELEASE_APP/PlugIns" "$RELEASE_APP/Extensions" -type d -name '*.appex' -print0 \
        | while IFS= read -r -d '' bundle; do
            name="$(basename "$bundle")"
            executable="${name%.*}"
            printf '%s/%s\n' "${bundle#"$PRODUCTS_ROOT/"}" "$executable"
        done
    find "$DEBUG_ROOT/Evlin iOS.app/PlugIns" -type d -name 'Evlin iOSTests.xctest' -print0 \
        | while IFS= read -r -d '' bundle; do
            name="$(basename "$bundle")"
            executable="${name%.*}"
            printf '%s/%s\n' "${bundle#"$PRODUCTS_ROOT/"}" "$executable"
        done
} | LC_ALL=C sort > "$OBSERVED"

cmp "$EXPECTED" "$OBSERVED"
[[ "$(find "$RELEASE_APP/PlugIns" -mindepth 1 -maxdepth 1 -type d -name '*.appex' | wc -l | tr -d ' ')" == 3 ]]
[[ "$(find "$RELEASE_APP/Extensions" -mindepth 1 -maxdepth 1 -type d -name '*.appex' | wc -l | tr -d ' ')" == 1 ]]
[[ "$(find "$RELEASE_APP" -type d -name '*.xctest' | wc -l | tr -d ' ')" == 0 ]]
[[ "$(find "$DEBUG_ROOT/Evlin iOS.app/PlugIns" -mindepth 1 -maxdepth 1 -type d -name '*.xctest' | wc -l | tr -d ' ')" == 1 ]]

: > "$EVIDENCE"
for relative in "${PRODUCTS[@]}"; do
    product="$PRODUCTS_ROOT/$relative"
    test -s "$product"
    description="$(file -b "$product")"
    [[ "$description" == *Mach-O* ]]
    printf '%s  %s\n' "$(shasum -a 256 "$product" | awk '{print $1}')" "$relative" >> "$EVIDENCE"
    printf '# %s: %s\n' "$relative" "$description" >> "$EVIDENCE"
done

echo "verified_release_production_products=5"
echo "verified_debug_xctest_products=1"
echo "release_evidence=$EVIDENCE"
