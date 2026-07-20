#!/bin/bash
set -euo pipefail

IOS_ROOT="/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS"
BACKEND_ROOT="/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend"
PYTHON="$BACKEND_ROOT/.venv/bin/python"
EVIDENCE="$IOS_ROOT/.superpowers/evidence/metering-phase5"
REPORT_REL="docs/superpowers/reports/2026-07-17-metering-epoch-phase-5-completion.md"
REPORT="$IOS_ROOT/$REPORT_REL"
STATUS="AUTOMATED_PASSED_PHYSICAL_PENDING"

fail() { echo "phase5_verifier_error: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

validate_report() {
    local path="$1"
    [[ "$(grep -c '^status_code:' "$path")" -eq 1 ]] || fail "status_code must be unique"
    [[ "$(grep -c '^phase_complete:' "$path")" -eq 1 ]] || fail "phase_complete must be unique"
    [[ "$(grep -c '^releasable:' "$path")" -eq 1 ]] || fail "releasable must be unique"
    grep -qx "status_code: $STATUS" "$path" || fail "invalid status_code"
    grep -qx 'phase_complete: false' "$path" || fail "phase_complete must remain false"
    grep -qx 'releasable: false' "$path" || fail "releasable must remain false"
    ! grep -qx 'phase_complete: true' "$path" || fail "phase_complete promoted"
    ! grep -qx 'releasable: true' "$path" || fail "releasable promoted"
    [[ "$(grep -Ec '^\| (Force-killed|DEBUG one-minute|Two-device|TestFlight|Physical 17\.6).*\| PENDING \|$' "$path")" -eq 6 ]] \
        || fail "all six physical rows must remain PENDING"
    [[ "$(grep -Ec '^\| (Force-killed|DEBUG one-minute|Two-device|TestFlight|Physical 17\.6).*\| (PASS|FAILED|COMPLETE) \|$' "$path")" -eq 0 ]] \
        || fail "physical evidence was promoted"
}

run_logged() {
    local name="$1"; shift
    local started rc
    started="$(date +%s)"
    set +e
    "$@" >"$RUN_LOGS/$name.log" 2>&1
    rc=$?
    set -e
    printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "$(( $(date +%s) - started ))" \
        "$(sha "$RUN_LOGS/$name.log")" >> "$RUN_DIR/gates.tsv"
    [[ $rc -eq 0 ]] || { tail -100 "$RUN_LOGS/$name.log" >&2; fail "$name failed ($rc)"; }
}

require_subject() {
    local repo="$1" subject="$2"
    local commit
    commit="$(git -C "$repo" log -1 --format=%H --grep="^${subject}$")"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "missing commit subject: $subject"
    git -C "$repo" merge-base --is-ancestor "$commit" HEAD || fail "commit is not in HEAD: $subject"
}

run_self_test() {
    local temp
    temp="$(mktemp -d)"; trap "rm -rf '$temp'" EXIT
    cat >"$temp/report.md" <<'EOF'
**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE
status_code: AUTOMATED_PASSED_PHYSICAL_PENDING
phase_complete: false
releasable: false
| Force-killed set/clear physical | x | PENDING |
| Force-killed config physical | x | PENDING |
| DEBUG one-minute per-app threshold | x | PENDING |
| Two-device attribution smoke | x | PENDING |
| TestFlight overnight | x | PENDING |
| Physical 17.6 minimum floor | x | PENDING |
EOF
    validate_report "$temp/report.md"
    sed 's/phase_complete: false/phase_complete: true/' "$temp/report.md" >"$temp/bad.md"
    if (validate_report "$temp/bad.md") >/dev/null 2>&1; then fail "self-test accepted completion"; fi
    sed 's/| PENDING |/| PASS |/' "$temp/report.md" >"$temp/bad.md"
    if (validate_report "$temp/bad.md") >/dev/null 2>&1; then fail "self-test accepted physical promotion"; fi
    grep -q 'NOT RELEASABLE' "$temp/report.md" || fail "display status missing"
    echo "phase5_completion_self_test=PASS"
}

case "${1:-}" in
    --self-test)
        [[ $# -eq 1 ]] || fail "--self-test takes no arguments"
        run_self_test
        ;;
    final)
        [[ $# -eq 2 && "$2" =~ ^[0-9a-f]{40}$ ]] || fail "final requires one report commit SHA"
        temp="$(mktemp)"; trap 'rm -f "$temp"' EXIT
        git -C "$IOS_ROOT" show "$2:$REPORT_REL" >"$temp" || fail "committed report missing"
        validate_report "$temp"
        echo "final_report_commit=$2"
        echo "physical_status=PENDING"
        ;;
    pre-report)
        [[ $# -eq 1 ]] || fail "pre-report takes no arguments"
        RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$IOS_ROOT" rev-parse --short HEAD)"
        RUN_DIR="$EVIDENCE/runs/$RUN_ID"
        RUN_LOGS="$RUN_DIR/logs"
        mkdir -p "$RUN_LOGS"
        : >"$RUN_DIR/gates.tsv"

        run_logged prerequisite /bin/bash "$IOS_ROOT/scripts/verify_metering_phase5_prerequisites.sh"
        run_logged prerequisite-self-test /bin/bash "$IOS_ROOT/scripts/verify_metering_phase5_prerequisites.sh" --self-test
        run_logged fixture-bytes cmp \
            "$IOS_ROOT/Evlin iOSTests/Fixtures/metering_epoch_phase5_vectors.json" \
            "$BACKEND_ROOT/tests/fixtures/metering_epoch_phase5_vectors.json"

        require_subject "$BACKEND_ROOT" 'feat: add canonical queue-before-mutate reflection transition helper (G-17)'
        require_subject "$BACKEND_ROOT" 'feat: order earned policy delivery per device'
        require_subject "$IOS_ROOT" 'test: mirror metering phase 5 delivery vectors'

        DB_TESTS=(
            tests/test_reflection_transition_delivery.py
            tests/api/test_bigkid_task_notifications.py
            tests/api/test_reflection_e2e.py
            tests/test_earned_time_config.py
            tests/api/test_notif_phase4_command_receipt.py
            tests/api/test_command_scoped_fetch.py
            tests/services/test_lock_escalation.py
            tests/test_command_delivery_apns.py
            tests/test_metering_policy_delivery_ordering.py
            tests/test_metering_day_reconciler.py
            tests/test_metering_phase5_delivery.py
            tests/test_earned_time_lock_receipts.py
            tests/test_metering_epoch_phase2_integration.py
        )
        printf -v db_args ' %q' "${DB_TESTS[@]}"
        run_logged backend-explicit bash -lc \
            "cd '$BACKEND_ROOT' && '$PYTHON' scripts/run_limits_db_regression.py$db_args"
        run_logged backend-full bash -lc \
            "cd '$BACKEND_ROOT' && '$PYTHON' scripts/run_limits_db_regression.py"

        IOS_TESTS=(
            -only-testing:'Evlin iOSTests/MeteringPhase5PrerequisiteTests'
            -only-testing:'Evlin iOSTests/MeteringPhase5G18HandoffTests'
            -only-testing:'Evlin iOSTests/MeteringPhase5G18OwnerReadbackTests'
            -only-testing:'Evlin iOSTests/MeteringPolicyInboxTests'
            -only-testing:'Evlin iOSTests/MeteringPolicyOwnerReadbackTests'
            -only-testing:'Evlin iOSTests/MeteringEpochPhase5VectorTests'
            -only-testing:'Evlin iOSTests/MeteringEpochVectorCoverageTests'
            -only-testing:'Evlin iOSTests/AppLimitWakeRecoveryTests'
            -only-testing:'Evlin iOSTests/NSEAppLimitPersistenceTests'
        )
        run_logged ios-iphone xcodebuild test -quiet CODE_SIGNING_ALLOWED=NO \
            -disableAutomaticPackageResolution -project "$IOS_ROOT/Evlin iOS.xcodeproj" -scheme 'Evlin iOS' \
            -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
            -derivedDataPath "$RUN_DIR/DerivedData-iPhone" -parallel-testing-enabled NO \
            IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' "${IOS_TESTS[@]}"
        run_logged ios-ipad xcodebuild test -quiet CODE_SIGNING_ALLOWED=NO \
            -disableAutomaticPackageResolution -project "$IOS_ROOT/Evlin iOS.xcodeproj" -scheme 'Evlin iOS' \
            -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1' \
            -derivedDataPath "$RUN_DIR/DerivedData-iPad" -parallel-testing-enabled NO \
            IPHONEOS_DEPLOYMENT_TARGET=17.6 TARGETED_DEVICE_FAMILY='1,2' \
            -only-testing:'Evlin iOSTests/MeteringEpochPhase5VectorTests' \
            -only-testing:'Evlin iOSTests/MeteringPhase5G18HandoffTests'

        run_logged release-products /bin/bash "$IOS_ROOT/scripts/build_verify_six_release_iphoneos.sh" \
            --derived-data "$RUN_DIR/DerivedData-Release" \
            --evidence "$RUN_DIR/release-products.sha256"
        run_logged push-release-owner-scan bash -lc \
            "! strings '$RUN_DIR/DerivedData-Release/Build/Products/Release-iphoneos/EvlinPushApplier.appex/EvlinPushApplier' | rg 'DeviceActivityCenter|startMonitoring|stopMonitoring|MeteringPolicyOwnerReadbackClient|AppLimitOwnerRecoveryDriver'"

        gate_sha="$(sha "$RUN_DIR/gates.tsv")"
        release_sha="$(sha "$RUN_DIR/release-products.sha256")"
        vector_sha="$(sha "$IOS_ROOT/Evlin iOSTests/Fixtures/metering_epoch_phase5_vectors.json")"
        cat >"$REPORT" <<EOF
# Metering Epoch Phase 5 Automated Evidence

**Status:** AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE

status_code: $STATUS
phase_complete: false
releasable: false
ios_head: $(git -C "$IOS_ROOT" rev-parse HEAD)
backend_head: $(git -C "$BACKEND_ROOT" rev-parse HEAD)
phase4_report_commit: $(git -C "$IOS_ROOT" log -1 --format=%H -- docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md)
gate_run_id: $RUN_ID
gate_manifest_sha256: $gate_sha
release_products_sha256: $release_sha
vector_fixture_sha256: $vector_sha

Simulator tests ran using Debug products. The fixed production products were
built and scanned separately using Release. This report does not claim that
Release XCTest ran.

| Gate | Required evidence | Status |
|---|---|---|
| G-17 five bypasses | canonical helper plus durable command/wake rows | AUTOMATED PASS |
| G-18 newest delivery | P5V01-P5V05 plus tombstones | AUTOMATED PASS |
| G-18 owner readback | exact owner receipt before ack | AUTOMATED PASS |
| G-19 persistence/readback | P5V06-P5V07 monotonic policy owner | AUTOMATED PASS |
| Multi-device fanout | P5V08-P5V11 A/B receipts and attribution | AUTOMATED PASS |
| Force-killed set/clear physical | App Group capture and owner ack | PENDING |
| Force-killed config physical | policy bytes and owner activation ack | PENDING |
| DEBUG one-minute per-app threshold | real-use shield only | PENDING |
| Two-device attribution smoke | distinct own-cap bars | PENDING |
| TestFlight overnight | two devices across canonical midnight | PENDING |
| Physical 17.6 minimum floor | install, callback, stop, horizon | PENDING |

Raw logs and immutable hashes are archived under
.superpowers/evidence/metering-phase5/runs/$RUN_ID/. A failed rerun creates a
new directory and cannot overwrite this successful run.
EOF
        validate_report "$REPORT"
        printf '%s\n' "$RUN_ID" >"$EVIDENCE/latest-successful-run"
        echo "status_code=$STATUS"
        echo "run_id=$RUN_ID"
        echo "report=$REPORT"
        ;;
    *) fail "usage: $0 --self-test|pre-report|final <report-commit-sha>" ;;
esac
