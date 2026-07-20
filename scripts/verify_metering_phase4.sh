#!/bin/bash
set -euo pipefail

IOS_ROOT="/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
BACKEND_ROOT="/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend"
EVIDENCE="$IOS_ROOT/.superpowers/evidence/metering-phase4"
LOGS="$EVIDENCE/logs"
REPORT_REL="docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md"
REPORT="$IOS_ROOT/$REPORT_REL"
PYTHON="$BACKEND_ROOT/.venv/bin/python"
STATUS_CODE="AUTOMATED_PASSED_PHYSICAL_PENDING"

fail() { echo "phase4_verifier_error: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

validate_report_file() {
    local path="$1"
    grep -qx 'status_code: AUTOMATED_PASSED_PHYSICAL_PENDING' "$path" || fail "invalid status_code"
    grep -qx 'phase_complete: false' "$path" || fail "phase_complete must remain false"
    grep -qx 'releasable: false' "$path" || fail "releasable must remain false"
    ! grep -qx 'phase_complete: true' "$path" || fail "phase_complete promoted"
    ! grep -qx 'releasable: true' "$path" || fail "releasable promoted"
    [[ "$(grep -c '| PENDING |' "$path")" -ge 4 ]] || fail "physical rows are not all pending"
    grep -Eq '^task16_stale_path_removal_commit: [0-9a-f]{40}$' "$path" || fail "Task 16 SHA missing"
}

run_logged() {
    local name="$1"; shift
    local started ended rc
    started="$(date +%s)"
    set +e
    "$@" >"$LOGS/$name.log" 2>&1
    rc=$?
    set -e
    ended="$(date +%s)"
    printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "$((ended-started))" "$(sha "$LOGS/$name.log")" >> "$EVIDENCE/gates.tsv"
    [[ $rc -eq 0 ]] || { tail -80 "$LOGS/$name.log" >&2; fail "$name failed ($rc)"; }
}

verify_dirty_allowlist() {
    local record path unexpected=""
    while IFS= read -r -d '' record; do
        path="${record:3}"
        case "$path" in
            'Evlin iOS.xcodeproj/project.pbxproj'|\
            'Evlin iOS.xcodeproj/project.xcworkspace/xcuserdata/'*|\
            'Evlin iOS.xcodeproj/xcuserdata/'*|\
            'Evlin iOS/ContentView.swift'|\
            'Evlin iOS/Services/APIClient.swift'|\
            'Evlin iOS/Views/Onboarding/OnboardingCoordinator.swift'|\
            'Evlin iOS/Views/Onboarding/Parent/V2/'*|\
            'docs/superpowers/plans/2026-07-16-metering-epoch-phase-2.md'|\
            'docs/superpowers/plans/2026-07-17-metering-epoch-phase-4.md'|\
            'scripts/verify_metering_phase4.sh'|\
            'scripts/build_verify_six_release_iphoneos.sh'|\
            'Evlin iOSTests/MeteringPhase4CompletionVerifierTests.swift'|\
            'docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md'|\
            '.DS_Store') ;;
            *) unexpected+="$path"$'\n' ;;
        esac
    done < <(git -C "$IOS_ROOT" status --porcelain=v1 -z)
    [[ -z "$unexpected" ]] || fail "unexpected dirty paths: $unexpected"
}

case "${1:-}" in
    final)
        [[ $# -eq 2 && "$2" =~ ^[0-9a-f]{40}$ ]] || fail "final requires one report commit SHA"
        temp="$(mktemp)"; trap 'rm -f "$temp"' EXIT
        git -C "$IOS_ROOT" show "$2:$REPORT_REL" > "$temp" || fail "canonical report missing from commit"
        validate_report_file "$temp"
        echo "final_report_commit=$2"
        echo "physical_status=PENDING"
        ;;
    --release)
        [[ $# -eq 1 ]] || fail "--release takes no arguments"
        validate_report_file "$REPORT"
        echo "physical_gate_pending" >&2
        exit 3
        ;;
    --automated)
        [[ $# -eq 1 ]] || fail "--automated takes no arguments"
        mkdir -p "$LOGS"
        : > "$EVIDENCE/gates.tsv"
        verify_dirty_allowlist
        run_logged fixture-bytes cmp \
            "$IOS_ROOT/Evlin iOSTests/Fixtures/metering_epoch_vectors.json" \
            "$BACKEND_ROOT/tests/fixtures/metering_epoch_vectors.json"
        run_logged backend-pure bash -lc \
            "cd '$BACKEND_ROOT' && '$PYTHON' -m pytest tests/test_metering_epoch_vector_contract.py tests/test_app_limit_delivery.py tests/services/test_lock_command_alert_payload.py -q"
        run_logged backend-wire bash -lc \
            "cd '$BACKEND_ROOT' && '$PYTHON' scripts/run_limits_db_regression.py tests/test_command_delivery_apns.py tests/test_app_limit_wire_contract.py"
        run_logged backend-db bash -lc \
            "cd '$BACKEND_ROOT' && '$PYTHON' scripts/run_limits_db_regression.py"
        IOS_TESTS=(
            -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests'
            -only-testing:'Evlin iOSTests/AppLimitEpochStoreTests'
            -only-testing:'Evlin iOSTests/AppLimitCommandCoordinatorTests'
            -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests'
            -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests'
            -only-testing:'Evlin iOSTests/AppLimitPlannerTests'
            -only-testing:'Evlin iOSTests/AppLimitCallbackValidatorTests'
            -only-testing:'Evlin iOSTests/AppLimitCallbackNoEffectsTests'
            -only-testing:'Evlin iOSTests/AppLimitEffectJournalTests'
            -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests'
            -only-testing:'Evlin iOSTests/AppLimitProductionReorderingTests'
            -only-testing:'Evlin iOSTests/MeteringPhase4CompletionVerifierTests'
        )
        run_logged ios-iphone xcodebuild test CODE_SIGNING_ALLOWED=NO \
            -disableAutomaticPackageResolution -project "$IOS_ROOT/Evlin iOS.xcodeproj" -scheme 'Evlin iOS' \
            -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
            -derivedDataPath "$EVIDENCE/DerivedData-iPhone" -parallel-testing-enabled NO \
            IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' "${IOS_TESTS[@]}"
        run_logged ios-ipad xcodebuild test CODE_SIGNING_ALLOWED=NO \
            -disableAutomaticPackageResolution -project "$IOS_ROOT/Evlin iOS.xcodeproj" -scheme 'Evlin iOS' \
            -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' \
            -derivedDataPath "$EVIDENCE/DerivedData-iPad" -parallel-testing-enabled NO \
            IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' \
            -only-testing:'Evlin iOSTests/MeteringEpochGoldenVectorTests' \
            -only-testing:'Evlin iOSTests/AppLimitProductionReorderingTests' \
            -only-testing:'Evlin iOSTests/AppLimitPauseResumeTests'
        run_logged release-products /bin/bash "$IOS_ROOT/scripts/build_verify_six_release_iphoneos.sh" \
            --derived-data "$EVIDENCE/DerivedData-Release" \
            --evidence "$EVIDENCE/release-products.sha256"
        run_logged push-ownership bash -lc \
            "if rg -n 'DeviceActivityCenter|MeteringDeviceActivityCenter|ManagedSettingsStore|AppLimitPlanner|AppLimitEffectDriver' '$IOS_ROOT/EvlinPushApplier' | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//'; then exit 1; fi"
        task16="$(git -C "$IOS_ROOT" log -1 --format=%H --grep='^test: prove app limit reordering convergence$')"
        [[ "$task16" =~ ^[0-9a-f]{40}$ ]] || fail "Task 16 commit missing"
        manifest_sha="$(sha "$EVIDENCE/gates.tsv")"
        product_sha="$(sha "$EVIDENCE/release-products.sha256")"
        vector_sha="$(sha "$IOS_ROOT/Evlin iOSTests/Fixtures/metering_epoch_vectors.json")"
        cat > "$REPORT" <<EOF
# Metering Epoch Phase 4 Automated Evidence

**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE

status_code: $STATUS_CODE
phase_complete: false
releasable: false
task16_stale_path_removal_commit: $task16
ios_head: $(git -C "$IOS_ROOT" rev-parse HEAD)
backend_head: $(git -C "$BACKEND_ROOT" rev-parse HEAD)
gate_manifest_sha256: $manifest_sha
release_products_sha256: $product_sha
vector_fixture_sha256: $vector_sha

Tests ran using Debug simulator products. Five unsigned production products were
built using Release; the XCTest executable was built separately using Debug
build-for-testing. This report does not claim that Release tests ran.

| Gate | Required physical evidence | Status |
|---|---|---|
| P4-DEVICE-1 | One-minute app-limit callback and shield | PENDING |
| P4-DEVICE-2 | Pause, force-quit, resume replacement | PENDING |
| P4-DEVICE-3 | New clear followed by delayed old set | PENDING |
| P4-DEVICE-4 | Two-device attribution | PENDING |

Automated gate details, command exit codes, runtimes, and raw-log hashes are in
\`.superpowers/evidence/metering-phase4/gates.tsv\`. Physical evidence is not
fabricated by this automated run.
EOF
        validate_report_file "$REPORT"
        echo "status_code=$STATUS_CODE"
        echo "report=$REPORT"
        ;;
    *)
        fail "usage: $0 --automated|--release|final <report-commit-sha>"
        ;;
esac
