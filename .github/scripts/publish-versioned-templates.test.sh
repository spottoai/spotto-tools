#!/usr/bin/env bash
# Offline tests for publish-versioned-templates.sh using a fake aws command.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/publish-versioned-templates.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/templates"
printf '{"a":1}\n' > "$WORK/templates/spotto-aws-connect.template.json"
printf '{"b":2}\n' > "$WORK/templates/spotto-aws-members.template.json"
# FAKE_LIST: missing | sibling | 403 | 500 | network | exists | malformed.  FAKE_CP: ok | fail.  FAKE_REMOTE: file served by s3 cp.
cat > "$WORK/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "s3api list-objects-v2")
    # Require the IAM-authorized prefix and an exact-key query, including when
    # the only remote object is a longer key beginning with the same prefix.
    prefix="" query="" output=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --prefix) prefix="$2" ;;
        --query) query="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2
    done
    [[ "$prefix" == cloudformation/*.json ]] || exit 2
    [[ "$query" == "Contents[?Key=='$prefix'].Key" && "$output" == text ]] || exit 2
    mode="$FAKE_LIST"
    if [[ "$prefix" != cloudformation/v*/* ]]; then
      case "$FAKE_LATEST" in
        missing|403|500|network) mode="$FAKE_LATEST" ;;
        *) mode=exists ;;
      esac
    fi
    case "$mode" in
      missing) : ;;
      sibling) echo None ;;
      403) echo "An error occurred (403) when calling the ListObjectsV2 operation: Forbidden" >&2; exit 254 ;;
      500) echo "An error occurred (500) when calling the ListObjectsV2 operation: Internal Server Error" >&2; exit 254 ;;
      network) echo 'Could not connect to the endpoint URL: "https://spotto-aws-onboarding.s3.amazonaws.com/"' >&2; exit 255 ;;
      exists) echo "$prefix" ;;
      malformed) echo "unexpected-response" ;;
    esac ;;
  "s3 cp")
    if [[ "$3" != s3://*/cloudformation/v*/* ]]; then
      case "$FAKE_LATEST" in
        download-fail) echo "GetObject operation: Forbidden" >&2; exit 1 ;;
        malformed) printf 'not-json' > "$4" ;;
        no-version) printf '{}' > "$4" ;;
        late-newer)
          remote_version=2026-10-22.1
          [[ "$3" == */spotto-aws-members.template.json ]] && remote_version=2026-10-25.2
          printf '{"Metadata":{"TemplateVersion":"%s"}}' "$remote_version" > "$4" ;;
        *) printf '{"Metadata":{"TemplateVersion":"%s"}}' "$FAKE_LATEST" > "$4" ;;
      esac
      exit 0
    fi
    [ "$FAKE_CP" = "ok" ] || { echo "fatal error: An error occurred (403) when calling the GetObject operation: Forbidden" >&2; exit 1; }
    cp "$FAKE_REMOTE" "$4" ;;
  "s3 sync")
    if [[ "$4" == s3://*/cloudformation/v*/* ]] && [ "$FAKE_SYNC" = archive-fail ]; then
      echo "archive upload failed" >&2
      exit 1
    fi ;;
  *) echo "fake aws: unexpected $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/aws"
PASS=0 FAIL=0

run() { # run <expected exit> <FAKE_LIST> <FAKE_CP> <remote file>
  local code=0
  : > "$WORK/log"
  local flags=()
  if [ "${PROMOTE_LATEST:-no}" = yes ]; then flags+=(--promote-latest); fi
  PATH="$WORK/bin:$PATH" FAKE_SYNC="${SYNC_FAILURE:-none}" FAKE_LATEST="${LATEST_VERSION:-missing}" FAKE_LOG="$WORK/log" FAKE_LIST="$2" FAKE_CP="$3" FAKE_REMOTE="$4" \
    bash "$SCRIPT" "$WORK/templates" spotto-aws-onboarding "${CANDIDATE_VERSION:-2026-10-22.1}" "${flags[@]}" > "$WORK/out" 2>&1 || code=$?
  [ "$code" = "$1" ] || { echo "    expected exit $1, got $code"; sed 's/^/    | /' "$WORK/out"; return 1; }
}
has() { grep -F -- "$1" "$2" >/dev/null || { echo "    missing in $(basename "$2"): $1"; return 1; }; }
synced() { grep '^s3 sync .* s3://spotto-aws-onboarding/cloudformation/v2026-10-22.1/' "$WORK/log" >/dev/null; }
check() { if "$2"; then PASS=$((PASS + 1)); echo "ok   $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1"; fi; }

t_not_published() { run 0 missing ok /dev/null && has "isn't published yet" "$WORK/out" && synced; }
t_sibling() { run 0 sibling ok /dev/null && has "isn't published yet" "$WORK/out" && synced; }
t_malformed() { run 1 malformed ok /dev/null && has "Unexpected listing result" "$WORK/out" && ! synced; }
t_same_content() {
  local result=0
  cp "$WORK/templates/spotto-aws-connect.template.json" "$WORK/templates/spotto-aws-members.template.json"
  run 0 exists ok "$WORK/templates/spotto-aws-connect.template.json" && has "already published and identical" "$WORK/out" && synced || result=1
  printf '{"b":2}\n' > "$WORK/templates/spotto-aws-members.template.json"
  return "$result"
}
t_different() { printf '{"changed":true}\n' > "$WORK/remote.json"; run 1 exists ok "$WORK/remote.json" && has "already exists with different content" "$WORK/out" && ! synced; }
t_forbidden() { run 1 403 ok /dev/null && has "::error::Couldn't check s3://spotto-aws-onboarding/cloudformation/v2026-10-22.1/spotto-aws-connect.template.json: An error occurred (403)" "$WORK/out" && ! synced; }
t_server_error() { run 1 500 ok /dev/null && has "An error occurred (500)" "$WORK/out" && ! synced; }
t_network() { run 1 network ok /dev/null && has "Could not connect to the endpoint URL" "$WORK/out" && ! synced; }
t_download_fails() { run 1 exists fail /dev/null && has "::error::Couldn't download s3://" "$WORK/out" && has "GetObject operation: Forbidden" "$WORK/out" && ! synced; }

t_syntax() { bash -n "$SCRIPT"; }
check "bash -n" t_syntax
check "empty listing: not published yet, then synced" t_not_published
check "only a longer key exists: exact key is unpublished" t_sibling
check "malformed listing: fails, nothing synced" t_malformed
check "existing identical files: synced" t_same_content
check "existing different file: fails, nothing synced" t_different
check "403 on listing: fails, nothing synced" t_forbidden
check "5xx on listing: fails, nothing synced" t_server_error
check "network error on listing: fails, nothing synced" t_network
check "download for comparison fails: fails, nothing synced" t_download_fails
# Latest aliases are checked as a set before either archive or alias uploads.
run_promotion() {
  local CANDIDATE_VERSION="$2" PROMOTE_LATEST=yes LATEST_VERSION="$3"
  printf '{"Metadata":{"TemplateVersion":"%s"}}\n' "$2" > "$WORK/templates/spotto-aws-connect.template.json"
  cp "$WORK/templates/spotto-aws-connect.template.json" "$WORK/templates/spotto-aws-members.template.json"
  run "$1" missing ok /dev/null
}
latest_synced() { grep '^s3 sync .* s3://spotto-aws-onboarding/cloudformation/ ' "$WORK/log" >/dev/null; }
no_uploads() { ! grep '^s3 sync ' "$WORK/log" >/dev/null; }
t_bootstrap_latest() { run_promotion 0 2026-10-25.1 missing && latest_synced; }
t_equal_latest() { run_promotion 0 2026-10-25.1 2026-10-25.1 && latest_synced; }
t_newer_date() { run_promotion 0 2026-10-25.1 2026-10-24.9 && latest_synced; }
t_newer_build() { run_promotion 0 2026-10-25.10 2026-10-25.2 && latest_synced; }
t_older_date() { run_promotion 1 2026-10-24.9 2026-10-25.1 && has "Refusing to replace" "$WORK/out" && no_uploads; }
t_older_build() { run_promotion 1 2026-10-25.2 2026-10-25.10 && has "Refusing to replace" "$WORK/out" && no_uploads; }
t_late_newer() { run_promotion 1 2026-10-25.1 late-newer && has "spotto-aws-members.template.json" "$WORK/out" && no_uploads; }
t_invalid_latest() { run_promotion 1 2026-10-25.1 malformed && has "Invalid published template version" "$WORK/out" && no_uploads; }
t_missing_version() { run_promotion 1 2026-10-25.1 no-version && has "Invalid published template version" "$WORK/out" && no_uploads; }
t_invalid_candidate() { run_promotion 1 invalid missing && has "Invalid template version" "$WORK/out" && no_uploads; }
t_latest_forbidden() { run_promotion 1 2026-10-25.1 403 && has "(403)" "$WORK/out" && no_uploads; }
t_latest_server_error() { run_promotion 1 2026-10-25.1 500 && has "(500)" "$WORK/out" && no_uploads; }
t_latest_network() { run_promotion 1 2026-10-25.1 network && has "Could not connect" "$WORK/out" && no_uploads; }
t_latest_download() { run_promotion 1 2026-10-25.1 download-fail && has "Couldn't download" "$WORK/out" && no_uploads; }
t_invalid_latest_format() { run_promotion 1 2026-10-25.1 2026-10-25.bad && has "Invalid published template version" "$WORK/out" && no_uploads; }
t_mismatched_local() {
  local CANDIDATE_VERSION=2026-10-25.1 PROMOTE_LATEST=yes LATEST_VERSION=missing
  printf '{"Metadata":{"TemplateVersion":"2026-10-24.1"}}\n' > "$WORK/templates/spotto-aws-members.template.json"
  run 1 missing ok /dev/null && has "Invalid template version" "$WORK/out" && no_uploads
}
t_archive_failure() {
  local SYNC_FAILURE=archive-fail
  run_promotion 1 2026-10-25.1 missing && has "archive upload failed" "$WORK/out" && ! latest_synced
}
check "latest: bootstrap" t_bootstrap_latest
check "latest: same version retry" t_equal_latest
check "latest: newer date" t_newer_date
check "latest: newer numeric build" t_newer_build
check "latest: older date rejected before uploads" t_older_date
check "latest: older numeric build rejected before uploads" t_older_build
check "latest: newer second alias rejected before uploads" t_late_newer
check "latest: malformed JSON rejected before uploads" t_invalid_latest
check "latest: missing version rejected before uploads" t_missing_version
check "latest: invalid candidate rejected before uploads" t_invalid_candidate
check "latest: forbidden lookup rejected before uploads" t_latest_forbidden
check "latest: server error rejected before uploads" t_latest_server_error
check "latest: network error rejected before uploads" t_latest_network
check "latest: failed download rejected before uploads" t_latest_download
check "latest: invalid remote version format rejected" t_invalid_latest_format
check "latest: local version mismatch rejected" t_mismatched_local
check "latest: archive upload failure leaves aliases untouched" t_archive_failure
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
