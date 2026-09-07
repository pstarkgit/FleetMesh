#!/usr/bin/env bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT=(/usr/bin/xcrun swift test)

run_group() {
  local group="$1"
  echo "=== FleetMesh test group: $group ==="
  "${SWIFT[@]}" --filter "$group"
}

TEST_LIST="$("${SWIFT[@]}" list 2>/dev/null)"
run_suite_individually() {
  local suite="$1"
  local found=0
  while IFS= read -r test_id; do
    [[ -n "$test_id" ]] || continue
    found=1
    echo "=== FleetMesh isolated test: $test_id ==="
    "${SWIFT[@]}" --filter "$test_id"
  done < <(printf '%s\n' "$TEST_LIST" | /usr/bin/grep "^DeviceSyncTests\\.${suite}/" || true)
  if [[ "$found" -ne 1 ]]; then
    echo "No tests found for required suite: $suite" >&2
    return 1
  fi
}

run_group 'DynamoDB|FleetMigration|FleetPayloadHash|FleetShadowComparison|ShadowFleetRepositoryBackend|FleetStorage|FleetRepositoryBackendBuilder'
run_group 'DoctorOrchestrationTests'

isolated_suites=(
  'FleetRepositoryTests'
  'FleetScopeOrchestrationTests'
  'DevicePolicyModelTests'
  'DevicePolicyStoreTests'
)
for suite in "${isolated_suites[@]}"; do
  run_suite_individually "$suite"
done

run_group 'DoctorPlannerTests|DriftEngineTests|MenuBarSummaryTests|BootstrapPlannerTests|FleetMeshIdentityTests|HeadlessFleetReportTests|FleetEnrollmentInvitationTests|ProductVersionTargetResolverTests'

echo "FleetMesh split suite passed with ${#isolated_suites[@]} isolated suites"
