#!/usr/bin/env bash
# Connects, updates, repairs or checks an AWS account (and optionally its organization)
# by deploying the hosted CloudFormation templates with your own AWS CLI session.
# Requires AWS CLI v2 only, so it runs in AWS CloudShell.
set -euo pipefail

TEMPLATE_BASE_URL="https://spotto-aws-onboarding.s3.amazonaws.com/cloudformation/"
REGION="" DEPLOYMENT="" REGISTRATION_TOPIC_ARN=""
# The AWS managed read baseline every role attaches (the templates' ManagedPolicyArns).
MANAGED_POLICY_ARNS="arn:aws:iam::aws:policy/job-function/ViewOnlyAccess arn:aws:iam::aws:policy/SecurityAudit"
EXTERNAL_ID="" PRINCIPAL_ARN="" PROFILE="" COST_DATA="" EXPORT_ARN="" CONNECT_MEMBERS="" OU_IDS=""
ROLE_NAME="" YES=0 MODE="connect"

usage() {
  cat <<'USAGE'
Usage: connect.sh --deployment <deployment> --external-id <id> --trusted-principal-arn <arn> [options]
       connect.sh --check | --repair [options]

  --external-id <id>                External ID shown in the portal (required to connect)
  --trusted-principal-arn <arn>     Trusted principal ARN shown in the portal (required to connect)
  --deployment <name>              dev-au, prod-au, prod-us or prod-eu (required)
  --registration-topic-arn <arn>    Topic ARN from the portal; must match the deployment
  --profile <name>                  AWS CLI profile (default: current session)
  --cost-data create|existing       Create a new billing export (default) or use an existing one; billing is required
  --export-arn <arn>                Existing export to use (with --cost-data existing)
  --connect-members yes|no          Deploy the role to member accounts (management account only)
  --organizational-unit-ids <ids>   Comma-separated OU or root IDs (default: organization root)
  --role-name <name>                IAM role name (default: SpottoReadOnlyRole)
  --check                           Report version, drift and member status; change nothing
  --repair                          Re-apply the role and policies (recreates a deleted role)
  --yes                             Don't ask questions; use defaults and flags
  --help                            Show this help

Rerunning updates existing stacks to the latest template version.
USAGE
}

die() { printf '\nError: %s\n' "$*" >&2; exit 1; }
BILLING_FIX="Rerun with --cost-data create (recommended), or --cost-data existing --export-arn <arn>."
info() { printf '%s\n' "$*"; }
aws_() {
  local call_region="$REGION" arg
  case "$1" in bcm-data-exports|organizations|account) call_region="us-east-1" ;; esac
  if [ "$1" = cloudformation ]; then
    for arg in "$@"; do
      case "$arg" in "$EXPORT_STACK"|*spotto-aws-billing-export.template.json) call_region="us-east-1" ;; esac
    done
  fi
  aws ${PROFILE:+--profile "$PROFILE"} --region "$call_region" "$@"
}
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
none_to_empty() { [ "$1" = "None" ] && printf '' || printf '%s' "$1"; }
lookup() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print substr($0, length(k) + 2); f = 1 } END { exit !f }'; }
# True when a Data Exports query selects line_item_resource_id (bare or as an alias) or every column.
selects_resource_ids() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | awk '
    function name(x) {
      gsub(/^ +| +$/, "", x)
      if (match(toupper(x), / AS +"?[A-Z0-9_]+"?$/)) { x = substr(x, RSTART + 1); sub(/^[Aa][Ss] +/, "", x) }
      gsub(/"/, "", x)
      return tolower(x)
    }
    {
      if (!match(toupper($0), /^ *SELECT +/)) exit 1
      rest = substr($0, RLENGTH + 1)
      if (!match(toupper(rest), / +FROM +/)) exit 1
      list = substr(rest, 1, RSTART - 1) ","
      depth = 0; item = ""; found = 0
      for (i = 1; i <= length(list); i++) {
        c = substr(list, i, 1)
        if (c == "(" || c == "[") depth++
        if (c == ")" || c == "]") depth--
        if (c == "," && depth == 0) {
          n = name(item)
          if (n == "*" || n == "line_item_resource_id") found = 1
          item = ""
        } else item = item c
      }
      ok = found
    }
    END { exit !ok }'
}

ask() { # ask <question> <default y|n>
  local answer=""
  if [ "$YES" -eq 1 ]; then [ "$2" = "y" ]; return; fi
  printf '%s %s ' "$1" "$([ "$2" = "y" ] && echo '[Y/n]' || echo '[y/N]')"
  { read -r answer </dev/tty; } 2>/dev/null || die "No terminal for questions. Rerun with --yes and flags."
  answer="$(printf '%s' "${answer:-$2}" | tr '[:upper:]' '[:lower:]')"
  [ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

while [ $# -gt 0 ]; do
  case "$1" in
    --external-id) EXTERNAL_ID="${2:-}"; shift 2 ;;
    --trusted-principal-arn) PRINCIPAL_ARN="${2:-}"; shift 2 ;;
    --deployment) DEPLOYMENT="${2:-}"; shift 2 ;;
    --registration-topic-arn) REGISTRATION_TOPIC_ARN="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --cost-data) COST_DATA="${2:-}"; shift 2 ;;
    --export-arn) EXPORT_ARN="${2:-}"; shift 2 ;;
    --connect-members) CONNECT_MEMBERS="${2:-}"; shift 2 ;;
    --organizational-unit-ids) OU_IDS="${2:-}"; shift 2 ;;
    --role-name) ROLE_NAME="${2:-}"; shift 2 ;;
    --check) MODE="check"; shift ;;
    --repair) MODE="repair"; shift ;;
    --yes|-y) YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

case "$DEPLOYMENT" in
  dev-au|prod-au) REGION="ap-southeast-2" ;;
  prod-us) REGION="us-east-1" ;;
  prod-eu) REGION="eu-north-1" ;;
  *) die "--deployment is required: dev-au, prod-au, prod-us or prod-eu. Copy the command from the portal." ;;
esac
EXPECTED_TOPIC="arn:aws:sns:$REGION:715809501612:spotto-aws-connect-$DEPLOYMENT"
[ -n "$REGISTRATION_TOPIC_ARN" ] || REGISTRATION_TOPIC_ARN="$EXPECTED_TOPIC"
[ "$REGISTRATION_TOPIC_ARN" = "$EXPECTED_TOPIC" ] || die "Registration topic does not match --deployment. Copy the command from the portal."
CONNECT_STACK="SpottoConnect-$DEPLOYMENT" BILLING_STACK="SpottoBillingAccess-$DEPLOYMENT"
MEMBERS_STACK="SpottoMemberAccounts-$DEPLOYMENT" EXPORT_STACK="SpottoBillingExport-$DEPLOYMENT"
# The role name is the same in every deployment; stacks and billing resources carry the deployment.
DEFAULT_ROLE_NAME="SpottoReadOnlyRole" CREATED_EXPORT_NAME="spotto-cur2-$DEPLOYMENT"

[ -z "$EXTERNAL_ID" ] || printf '%s' "$EXTERNAL_ID" | grep -Eq '^spotto-[0-9a-f-]{36}$' || die "--external-id must look like spotto-<uuid>. Copy it from the portal."
[ -z "$PRINCIPAL_ARN" ] || printf '%s' "$PRINCIPAL_ARN" | grep -Eq '^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/.+$' || die "--trusted-principal-arn must be an IAM user or role ARN. Copy it from the portal."
[ -z "$ROLE_NAME" ] || printf '%s' "$ROLE_NAME" | grep -Eq '^[A-Za-z0-9+=,.@_-]{1,64}$' || die "--role-name is not a valid IAM role name."
case "$COST_DATA" in ""|create|existing|none) ;; *) die "--cost-data must be create, existing or none." ;; esac
case "$CONNECT_MEMBERS" in ""|yes|no) ;; *) die "--connect-members must be yes or no." ;; esac
[ -z "$EXPORT_ARN" ] || [ -n "$COST_DATA" ] || COST_DATA="existing"
[ -z "$EXPORT_ARN" ] || [ "$COST_DATA" = "existing" ] || die "--export-arn needs --cost-data existing."
for ou in $(printf '%s' "$OU_IDS" | tr ',' ' '); do
  printf '%s' "$ou" | grep -Eq '^(r-[0-9a-z]{4,32}|ou-[0-9a-z]{4,32}-[0-9a-z]{8,32})$' || die "Not an OU or root ID: $ou"
done

command -v aws >/dev/null 2>&1 || die "AWS CLI v2 is required. Open AWS CloudShell, or install it from https://aws.amazon.com/cli/."
aws --version 2>&1 | grep '^aws-cli/2' >/dev/null || die "AWS CLI v2 is required (found: $(aws --version 2>&1))."

# --- Stack helpers ---------------------------------------------------------
aws_error() { aws_ "$@" 2>&1 >/dev/null | tr '\n' ' ' | sed 's/^ *//; s/ *$//' || true; } # reason a failed call gave
stack_status() { # prints the status, NONE when the stack doesn't exist, or UNREADABLE
  aws_ cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null && return
  case "$(aws_error cloudformation describe-stacks --stack-name "$1")" in *"does not exist"*) echo NONE ;; *) echo UNREADABLE ;; esac
}
stack_params() { aws_ cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]' --output text 2>/dev/null || true; }
output_of() { none_to_empty "$(aws_ cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text 2>/dev/null || true)"; }
version_in() { grep -o '"TemplateVersion" *: *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1; }
template_version() { # prints the TemplateVersion (empty if the template has none); on a failed read prints the reason and returns 1
  local meta
  meta="$(aws_ cloudformation get-template-summary "$@" --query Metadata --output text 2>/dev/null)" ||
    { aws_error cloudformation get-template-summary "$@" --query Metadata --output text; return 1; }
  printf '%s\n' "$meta" | version_in || true
}
list_exports() { aws_ bcm-data-exports list-exports --query 'Exports[].[ExportName,ExportArn]' --output text; }
role_state() { # present or missing; any other failure stops, because only NoSuchEntity proves the role is gone
  local err
  if aws_ iam get-role --role-name "$1" --query 'Role.Arn' --output text >/dev/null 2>&1; then echo present; return; fi
  err="$(aws_error iam get-role --role-name "$1" --query 'Role.Arn' --output text)"
  case "$err" in *NoSuchEntity*) echo missing ;; *) die "Couldn't check whether role $1 exists: ${err:-no error details}" ;; esac
}

drift_status() { # first line: IN_SYNC, DRIFTED, NOT_CHECKED or UNKNOWN<tab>reason; then any drifted resources
  local id result i=0 REGION="$REGION"
  [ "$1" != "$EXPORT_STACK" ] || REGION="us-east-1"
  id="$(aws_ cloudformation detect-stack-drift --stack-name "$1" --query StackDriftDetectionId --output text 2>/dev/null)" ||
    { printf 'UNKNOWN\t%s\n' "$(aws_error cloudformation detect-stack-drift --stack-name "$1")"; return; }
  while [ $i -lt 60 ]; do
    result="$(aws_ cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$id" --query '[DetectionStatus,StackDriftStatus]' --output text 2>/dev/null)" ||
      { printf 'UNKNOWN\t%s\n' "$(aws_error cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$id")"; return; }
    [ "$(printf '%s' "$result" | cut -f1)" = "DETECTION_IN_PROGRESS" ] || break
    sleep 5; i=$((i + 1))
  done
  case "$(printf '%s' "$result" | cut -f2)" in
    IN_SYNC|DRIFTED|NOT_CHECKED) printf '%s\n' "$result" | cut -f2 ;;
    *) printf 'UNKNOWN\tdrift detection ended with %s\n' "$(printf '%s' "$result" | cut -f1)" ;;
  esac
  aws_ cloudformation describe-stack-resource-drifts --stack-name "$1" --stack-resource-drift-status-filters MODIFIED DELETED \
    --query 'StackResourceDrifts[].[LogicalResourceId,StackResourceDriftStatus]' --output text 2>/dev/null |
    awk -F'\t' 'NF { printf "    %s was %s outside CloudFormation\n", $1, tolower($2) }' || true
}

# 1. Who am I, and which template version is current?
IDENTITY="$(aws_ sts get-caller-identity --query '[Account,Arn]' --output text 2>&1)" ||
  die "Can't read your AWS session. Sign in first (aws sso login, or open CloudShell). AWS said: $IDENTITY"
ACCOUNT_ID="$(printf '%s' "$IDENTITY" | cut -f1)"
info "Signed in to account $ACCOUNT_ID as $(printf '%s' "$IDENTITY" | cut -f2)"
LATEST_ERR=""
if ! LATEST="$(template_version --template-url "${TEMPLATE_BASE_URL}spotto-aws-connect.template.json")"; then
  LATEST_ERR="$LATEST" LATEST=""
  [ "$MODE" = "check" ] || die "Couldn't read the template version for the latest templates: $LATEST_ERR"
fi
TEMPLATE_URL="$TEMPLATE_BASE_URL${LATEST:+v$LATEST/}"
CONNECT_STATUS="$(stack_status ${CONNECT_STACK})"
BILLING_STATUS="$(stack_status ${BILLING_STACK})"
MEMBERS_STATUS="$(stack_status ${MEMBERS_STACK})"
EXPORT_STATUS="$(stack_status "$EXPORT_STACK")"
[ "$BILLING_STATUS" != "ROLLBACK_COMPLETE" ] || BILLING_STATUS="NONE"
[ "$MEMBERS_STATUS" != "ROLLBACK_COMPLETE" ] || MEMBERS_STATUS="NONE"
if [ "$MODE" != "check" ]; then
  for stack in ${CONNECT_STACK} ${BILLING_STACK} ${MEMBERS_STACK} ${EXPORT_STACK}; do
    [ "$(stack_status "$stack")" != "UNREADABLE" ] || die "Couldn't read stack $stack: $(aws_error cloudformation describe-stacks --stack-name "$stack")"
  done
fi

# 2. --check: read-only report. Anything that can't be read counts as a problem, never as healthy.
if [ "$MODE" = "check" ]; then
  if [ "$CONNECT_STATUS" = "UNREADABLE" ]; then
    info "Couldn't read stack ${CONNECT_STACK}: $(aws_error cloudformation describe-stacks --stack-name ${CONNECT_STACK})"; exit 1
  fi
  [ "$CONNECT_STATUS" != "NONE" ] || { info "Not connected: there's no ${CONNECT_STACK} stack in account $ACCOUNT_ID ($REGION)."; exit 1; }
  PROBLEMS=0 UPDATE=0 UNREAD=0 PENDING=0 # UNREAD: a status read failed, so health is indeterminate
  if [ -n "$LATEST_ERR" ]; then info "Couldn't read the template version for the latest templates: $LATEST_ERR"; UNREAD=1
  else info "Latest template version: ${LATEST:-unknown}"; fi
  for stack in ${CONNECT_STACK} ${BILLING_STACK} ${MEMBERS_STACK} ${EXPORT_STACK}; do
    status="$(stack_status "$stack")"
    if [ "$status" = NONE ]; then
      if [ "$stack" = "$EXPORT_STACK" ] && { [ "$(lookup "$(stack_params "$CONNECT_STACK")" CostData || true)" = CreateExport ] || [ "$(lookup "$(stack_params "$CONNECT_STACK")" RetainedBillingStorage || true)" = true ]; }; then
        info "Required billing export stack $EXPORT_STACK is missing. Rerun the connect command to complete billing setup."; PROBLEMS=1
      fi
      if [ "$stack" = "$BILLING_STACK" ] && [ "$(lookup "$(stack_params "$CONNECT_STACK")" RetainedBillingStorage || true)" = true ]; then
        info "Required retained billing access stack $BILLING_STACK is missing. Rerun the connect command to complete billing setup."; PROBLEMS=1
      fi
      continue
    fi
    if [ "$status" = "UNREADABLE" ]; then
      info "Couldn't read stack $stack: $(aws_error cloudformation describe-stacks --stack-name "$stack")"; UNREAD=1; continue
    fi
    note="up to date"
    if ! version="$(template_version --stack-name "$stack")"; then
      info "Couldn't read the template version for $stack: $version"; UNREAD=1; version="" note="version unreadable"
    elif [ -n "$LATEST" ] && [ "$version" != "$LATEST" ]; then note="update available"; UPDATE=1
    elif [ -z "$LATEST" ]; then note="latest unknown"; fi
    case "$status" in CREATE_COMPLETE|UPDATE_COMPLETE) ;; *) note="$note, stack is $status"; PROBLEMS=1 ;; esac
    info "$stack: version ${version:-unknown} ($note)"
    drift="$(drift_status "$stack")"
    case "$(printf '%s\n' "$drift" | head -1 | cut -f1)" in
      DRIFTED) PROBLEMS=1 ;;
      UNKNOWN) UNREAD=1 ;;
    esac
    if [ "$(printf '%s\n' "$drift" | head -1 | cut -f1)" = "UNKNOWN" ]; then
      info "  Couldn't read drift status: $(printf '%s\n' "$drift" | head -1 | cut -f2)"
    else
      info "  Drift: $(printf '%s\n' "$drift" | head -1 | awk '{ gsub("_", " "); print tolower($0) }')"
    fi
    printf '%s\n' "$drift" | tail -n +2
  done
  CHECK_ROLE="$(stack_params ${CONNECT_STACK} | awk -F'\t' '$1 == "RoleName" { print $2 }')"
  CHECK_ROLE="${CHECK_ROLE:-${DEFAULT_ROLE_NAME}}"
  if ATTACHED="$(aws_ iam list-attached-role-policies --role-name "$CHECK_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)"; then
    ATTACHED=" $(printf '%s' "$ATTACHED" | tr '\t\n' '  ') " MISSING_MANAGED=""
    for policy in $MANAGED_POLICY_ARNS; do
      case "$ATTACHED" in *" $policy "*) ;; *) MISSING_MANAGED="$MISSING_MANAGED ${policy##*/}" ;; esac
    done
    if [ -z "$MISSING_MANAGED" ]; then info "$CHECK_ROLE: AWS managed policies ViewOnlyAccess and SecurityAudit attached"
    else
      MISSING_MANAGED="$(printf '%s' "${MISSING_MANAGED# }" | sed 's/ / and /g')"
      case "$MISSING_MANAGED" in *" and "*) noun="policies" ;; *) noun="policy" ;; esac
      info "$CHECK_ROLE is missing the AWS managed $MISSING_MANAGED $noun"; PROBLEMS=1
    fi
  else
    info "Couldn't read the managed policies attached to $CHECK_ROLE: $(aws_error iam list-attached-role-policies --role-name "$CHECK_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text)"
    UNREAD=1
  fi
  if [ "$MEMBERS_STATUS" != "NONE" ] && [ "$MEMBERS_STATUS" != "UNREADABLE" ]; then
    if INSTANCES="$(aws_ cloudformation list-stack-instances --stack-set-name ${MEMBERS_STACK} \
      --query 'Summaries[].[Account,Status,StackInstanceStatus.DetailedStatus]' --output text 2>/dev/null)"; then
      # failed first, then in progress (PENDING/RUNNING or any status not listed), then OK (CURRENT) and outdated
      CLASSIFIED="$(printf '%s\n' "$INSTANCES" | awk -F'\t' 'NF && $1 != "None" {
        if ($3 ~ /^(FAILED|FAILED_IMPORT|CANCELLED|INOPERABLE)$/ || $2 == "INOPERABLE") c = "failed"
        else if ($3 ~ /^(PENDING|RUNNING)$/) c = "progress"
        else if ($2 == "CURRENT") c = "ok"
        else if ($2 == "OUTDATED") c = "outdated"
        else c = "progress"
        print c "\t" $1 "\t" $2 "\t" $3 }')"
      count() { printf '%s\n' "$CLASSIFIED" | awk -F'\t' -v c="$1" '$1 == c { n++ } END { print n + 0 }'; }
      OK_N="$(count ok)" OUT_N="$(count outdated)" FAIL_N="$(count failed)" PROG_N="$(count progress)"
      info "Member accounts: $OK_N OK, $OUT_N outdated, $FAIL_N failed, $PROG_N in progress"
      printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "failed" { printf "    %s: %s\n", $2, $4 }'
      [ "$OUT_N" -eq 0 ] || UPDATE=1
      [ "$FAIL_N" -eq 0 ] || PROBLEMS=1
      [ "$PROG_N" -eq 0 ] || PENDING=1
    else
      info "Couldn't read member account status: $(aws_error cloudformation list-stack-instances --stack-set-name ${MEMBERS_STACK})"
      UNREAD=1
    fi
  fi
  info ""
  if [ $PROBLEMS -eq 0 ] && [ $UNREAD -eq 0 ] && [ $UPDATE -eq 0 ] && [ $PENDING -eq 0 ]; then info "Everything is up to date and in sync."; exit 0; fi
  [ $UPDATE -eq 0 ] || info "Update available: rerun this command without --check."
  [ $PENDING -eq 0 ] || info "Member account deployment is in progress: rerun --check shortly."
  [ $UNREAD -eq 0 ] || info "Some status couldn't be read, so health isn't confirmed. Check your permissions and rerun --check."
  [ $PROBLEMS -eq 0 ] || info "Access has drifted or failed: rerun with --repair."
  exit 1
fi

# 3. Management, member or standalone?
ORG_ID="" KIND="standalone"
if ORG="$(aws_ organizations describe-organization --query 'Organization.[Id,MasterAccountId]' --output text 2>&1)"; then
  ORG_ID="$(printf '%s' "$ORG" | cut -f1)"
  if [ "$(printf '%s' "$ORG" | cut -f2)" = "$ACCOUNT_ID" ]; then KIND="management"; else KIND="member"; fi
elif ! printf '%s' "$ORG" | grep -q 'AWSOrganizationsNotInUseException'; then
  info "Warning: couldn't read the organization, so this account is treated as standalone."
fi
case "$KIND" in
  management) info "This is the management account of organization $ORG_ID." ;;
  standalone) info "This account isn't part of an organization." ;;
  member)
    info ""
    info "Warning: this is a member account of organization $ORG_ID (management account $(printf '%s' "$ORG" | cut -f2))."
    info "Connect the management account instead to see costs for the whole organization."
    [ "$CONNECT_STATUS" != "NONE" ] || ask "Continue with this account only?" y || exit 1 ;;
esac

# 4. What to deploy
CONNECT_PREV="$(stack_params ${CONNECT_STACK})"
REPAIR_TOKEN="" RECREATE=0 REUSE_BILLING=0
if [ "$(lookup "$CONNECT_PREV" RetainedBillingStorage || true)" = true ]; then
  case "$COST_DATA" in ""|create) REUSE_BILLING=1 ;; esac
fi
if [ "$CONNECT_STATUS" = "NONE" ]; then
  [ "$MODE" != "repair" ] || die "Nothing to repair: there's no ${CONNECT_STACK} stack in account $ACCOUNT_ID. Run without --repair to connect."
  [ -n "$EXTERNAL_ID" ] && [ -n "$PRINCIPAL_ARN" ] || die "--external-id and --trusted-principal-arn are required to connect. Copy the command from the portal."
  ROLE_NAME="${ROLE_NAME:-${DEFAULT_ROLE_NAME}}"
else
  PREV_ROLE="$(lookup "$CONNECT_PREV" RoleName || echo ${DEFAULT_ROLE_NAME})"
  [ -z "$ROLE_NAME" ] || [ "$ROLE_NAME" = "$PREV_ROLE" ] || die "The role is named $PREV_ROLE. Renaming it isn't supported."
  ROLE_NAME="$PREV_ROLE"
  DEPLOYED="$(template_version --stack-name ${CONNECT_STACK})" || die "Couldn't read the template version for ${CONNECT_STACK}: $DEPLOYED"
  info "Found ${CONNECT_STACK} (version ${DEPLOYED:-unknown}); latest is ${LATEST:-unknown}."
  if [ "$CONNECT_STATUS" = ROLLBACK_COMPLETE ]; then
    [ -n "$DEPLOYED" ] || die "Refusing to recreate an unversioned failed stack; review retained resources explicitly."
    RECREATE=1
  fi
  if [ "$MODE" = "repair" ]; then
    info "Checking for changes made outside CloudFormation..."
    for stack in ${CONNECT_STACK} ${BILLING_STACK}; do
      [ "$(stack_status "$stack")" = "NONE" ] || { drift="$(drift_status "$stack")"; info "  $stack: $(printf '%s\n' "$drift" | head -1 | awk '{ gsub("_", " "); print tolower($0) }')"; printf '%s\n' "$drift" | tail -n +2; }
    done
    REPAIR_TOKEN="$(date +%s)"
    ROLE_STATE="$(role_state "$ROLE_NAME")" || exit 1
    if [ "$ROLE_STATE" = "missing" ]; then
      RECREATE=1
      [ -n "$DEPLOYED" ] ||
        die "The role $ROLE_NAME was deleted, and this stack predates retained exports, so deleting it could remove the billing export. Create an empty IAM role named $ROLE_NAME, then rerun with --repair."
    fi
  fi
fi

if [ "$CONNECT_STATUS" = "NONE" ] || [ -n "$COST_DATA" ]; then
  if [ -z "$COST_DATA" ]; then
    if ask "Create a new billing export (recommended)?" y; then COST_DATA="create"; else COST_DATA="existing"; fi
  fi
  if [ "$COST_DATA" = "existing" ] && [ -z "$EXPORT_ARN" ]; then
    EXPORTS="$(list_exports 2>/dev/null | grep -v '^None$' || true)"
    [ -n "$EXPORTS" ] || die "No billing exports found in this account. Billing is required: rerun with --cost-data create."
    if [ "$YES" -eq 1 ]; then
      [ "$(printf '%s\n' "$EXPORTS" | wc -l | tr -d ' ')" = "1" ] || die "Several exports found. Pass one with --export-arn."
      EXPORT_ARN="$(printf '%s' "$EXPORTS" | cut -f2)"
    else
      info "Existing billing exports:"
      printf '%s\n' "$EXPORTS" | awk -F'\t' '{ printf "  %d) %s\n", NR, $1 }'
      printf 'Choose an export (number): '
      { read -r pick </dev/tty; } 2>/dev/null || die "No terminal. Rerun with --export-arn."
      EXPORT_ARN="$(printf '%s\n' "$EXPORTS" | awk -F'\t' -v n="$pick" 'NR == n { print $2 }')"
      [ -n "$EXPORT_ARN" ] || die "Not a valid choice: $pick"
    fi
  fi
fi
# Billing is required. A new connection must create or name an export; an existing one without billing
# still updates (CostData=None stays valid in the template) but is warned.
PREV_COST_DATA="$(lookup "$CONNECT_PREV" CostData || true)"
NO_BILLING=0
case "$COST_DATA" in
  none) [ "$BILLING_STATUS" != "NONE" ] || NO_BILLING=1 ;;
  "") [ "$PREV_COST_DATA" = "CreateExport" ] || [ "$REUSE_BILLING" -eq 1 ] || [ "$BILLING_STATUS" != "NONE" ] || NO_BILLING=1 ;;
esac
if [ $NO_BILLING -eq 1 ]; then
  [ "$CONNECT_STATUS" != "NONE" ] || die "Billing is required to connect AWS. $BILLING_FIX"
  info "Warning: this connection has no billing data, and billing is required. $BILLING_FIX"
fi
if [ "$COST_DATA" = "existing" ]; then
  EXPORT="$(aws_ bcm-data-exports get-export --export-arn "$EXPORT_ARN" --query 'Export.[Name,DestinationConfigurations.S3Destination.S3Bucket,DestinationConfigurations.S3Destination.S3Prefix,DestinationConfigurations.S3Destination.S3Region,DestinationConfigurations.S3Destination.S3OutputConfigurations.Format,DataQuery.TableConfigurations.COST_AND_USAGE_REPORT.TIME_GRANULARITY,DataQuery.TableConfigurations.COST_AND_USAGE_REPORT.INCLUDE_RESOURCES]' --output text 2>&1)" ||
    die "Can't read export $EXPORT_ARN. AWS said: $EXPORT"
  EXPORT_NAME="$(printf '%s' "$EXPORT" | cut -f1)" BUCKET="$(printf '%s' "$EXPORT" | cut -f2)"
  PREFIX="$(none_to_empty "$(printf '%s' "$EXPORT" | cut -f3)")" BUCKET_REGION="$(printf '%s' "$EXPORT" | cut -f4)"
  [ "$(printf '%s' "$EXPORT" | cut -f5)" = "PARQUET" ] || die "Export $EXPORT_NAME isn't Parquet. Parquet is required; create a new export instead (--cost-data create)."
  case "$(printf '%s' "$EXPORT" | cut -f6)" in
    DAILY|HOURLY) ;;
    *) die "Export $EXPORT_NAME isn't a daily or hourly CUR 2.0 export. Monthly isn't supported; create a new export instead (--cost-data create)." ;;
  esac
  [ "$(printf '%s' "$EXPORT" | cut -f7)" = "TRUE" ] ||
    die "Export $EXPORT_NAME doesn't include resource IDs (INCLUDE_RESOURCES). Turn them on in the export, or create a new export instead (--cost-data create)."
  # INCLUDE_RESOURCES only makes the column available; the query must select it too.
  QUERY="$(aws_ bcm-data-exports get-export --export-arn "$EXPORT_ARN" --query 'Export.DataQuery.QueryStatement' --output text 2>&1)" ||
    die "Can't read the query of export $EXPORT_ARN. AWS said: $QUERY"
  selects_resource_ids "$QUERY" ||
    die "Export $EXPORT_NAME doesn't select line_item_resource_id, so costs can't be attributed to resources. Add the column to the export, or create a new export instead (--cost-data create)."
  # The billing role needs decrypt on the exact key that encrypts the bucket, so a key that can't be found stops here.
  KMS_KEY_ARN=""
  if ! SSE="$(aws ${PROFILE:+--profile "$PROFILE"} --region "$BUCKET_REGION" s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.[SSEAlgorithm,KMSMasterKeyID]' --output text 2>&1)"; then
    case "$SSE" in
      *ServerSideEncryptionConfigurationNotFoundError*) SSE="" ;;
      *) die "Can't read the default encryption of bucket $BUCKET, so the KMS decrypt permission can't be set. AWS said: $SSE" ;;
    esac
  fi
  KEY="$(none_to_empty "$(printf '%s' "$SSE" | cut -f2)")"
  case "$KEY" in
    "") ;;
    arn:aws*:kms:*:key/*) KMS_KEY_ARN="$KEY" ;;
    *)
      # A key ID or an alias (name or ARN): resolve it to the key ARN in the key's Region.
      KEY_REGION="$BUCKET_REGION"
      case "$KEY" in arn:*) KEY_REGION="$(printf '%s' "$KEY" | cut -d: -f4)" ;; esac
      KMS_KEY_ARN="$(aws ${PROFILE:+--profile "$PROFILE"} --region "$KEY_REGION" kms describe-key --key-id "$KEY" --query 'KeyMetadata.Arn' --output text 2>&1)" ||
        die "Can't resolve the KMS key $KEY that encrypts bucket $BUCKET. AWS said: $KMS_KEY_ARN"
      case "$KMS_KEY_ARN" in
        arn:aws*:kms:*:key/*) ;;
        *) die "KMS key $KEY that encrypts bucket $BUCKET didn't resolve to a key ARN: $KMS_KEY_ARN" ;;
      esac
      ;;
  esac
fi

# Member accounts: asked on first connect; on reruns only existing or explicitly requested.
if [ "$KIND" = "management" ]; then
  if [ "$MEMBERS_STATUS" != "NONE" ]; then CONNECT_MEMBERS="${CONNECT_MEMBERS:-yes}"
  elif [ -z "$CONNECT_MEMBERS" ] && [ "$CONNECT_STATUS" = "NONE" ]; then
    if ask "Also connect every member account (StackSet)?" y; then CONNECT_MEMBERS="yes"; else CONNECT_MEMBERS="no"; fi
  fi
  if [ "$CONNECT_MEMBERS" = "yes" ] && [ -z "$OU_IDS" ] && [ "$MEMBERS_STATUS" = "NONE" ]; then
    OU_IDS="$(aws_ organizations list-roots --query 'Roots[0].Id' --output text 2>&1)" || die "Can't read the organization root. AWS said: $OU_IDS"
  fi
else
  [ "$CONNECT_MEMBERS" != "yes" ] || info "Note: member accounts can only be connected from the management account. Skipping them."
  CONNECT_MEMBERS="no"
fi

# 5. Checks that would otherwise fail halfway through
if [ "$CONNECT_STATUS" = "NONE" ]; then
  ROLE_STATE="$(role_state "$ROLE_NAME")" || exit 1
  [ "$ROLE_STATE" = "missing" ] || die "An IAM role named $ROLE_NAME already exists (perhaps from an earlier setup). Delete it, or pass --role-name with a new name."
fi
if [ "$COST_DATA" = "create" ] && [ "$REUSE_BILLING" -eq 0 ] && [ "$(lookup "$CONNECT_PREV" CostData || true)" != "CreateExport" ]; then
  ! list_exports 2>/dev/null | cut -f1 | grep -x "$CREATED_EXPORT_NAME" >/dev/null ||
    die "An export named ${CREATED_EXPORT_NAME} already exists (kept from an earlier setup). Use it with --cost-data existing."
fi
ENABLE_TRUSTED_ACCESS=0
if [ "$CONNECT_MEMBERS" = "yes" ] && [ "$(aws_ cloudformation describe-organizations-access --query Status --output text 2>/dev/null || true)" != "ENABLED" ]; then
  ENABLE_TRUSTED_ACCESS=1
fi
CFN_COST_DATA=""
case "$COST_DATA" in create) CFN_COST_DATA="CreateExport" ;; existing|none) CFN_COST_DATA="None" ;; esac
# Reuse retained storage without importing/deleting a bucket or overwriting its policy.
# A failed registration can leave a complete regional bucket but no global export yet.
recreate_cost="${CFN_COST_DATA:-$(lookup "$CONNECT_PREV" CostData || true)}"
if [ "$REUSE_BILLING" -eq 1 ] || { [ "$RECREATE" -eq 1 ] && [ "$recreate_cost" = CreateExport ] && [ "$(lookup "$CONNECT_PREV" CostData || true)" = CreateExport ]; }; then
  retained_bucket="spotto-billing-$ACCOUNT_ID-$DEPLOYMENT"
  if aws_ s3api head-bucket --bucket "$retained_bucket" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
    location="$(aws_ s3api get-bucket-location --bucket "$retained_bucket" --expected-bucket-owner "$ACCOUNT_ID" --query LocationConstraint --output text)" || die "Couldn't verify the retained billing bucket region."
    case "$location" in None|"") location=us-east-1 ;; EU) location=eu-west-1 ;; esac
    [ "$location" = "$REGION" ] || die "The retained billing bucket is outside $REGION. Nothing was deleted."
    aws_ s3api get-bucket-policy --bucket "$retained_bucket" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1 || die "The retained billing bucket needs its delivery policy restored. Review it before retrying; nothing was deleted."
    REUSE_BILLING=1
  else
    retained_error="$(aws_error s3api head-bucket --bucket "$retained_bucket" --expected-bucket-owner "$ACCOUNT_ID")"
    [ "$REUSE_BILLING" -eq 0 ] || die "The retained billing bucket is missing or unreadable. Review storage before retrying; nothing was deleted."
    case "$retained_error" in *404*|*NoSuchBucket*|*'Not Found'*) ;; *) die "Couldn't verify retained bucket ownership. Nothing was deleted: $retained_error" ;; esac
  fi
fi

if [ "$REUSE_BILLING" -eq 1 ]; then
  CFN_COST_DATA=None
  COST_DATA=existing EXPORT_NAME="$CREATED_EXPORT_NAME" BUCKET="$retained_bucket" PREFIX=cur2 KMS_KEY_ARN=""
fi

# 6. Plan
verb() { if [ "$1" = "NONE" ]; then echo "Create"; else echo "Update"; fi; }
info ""
info "Plan (CloudFormation, $REGION, template version ${LATEST:-latest}):"
if [ $RECREATE -eq 1 ]; then
  info "  - Recover the access stack: remove and recreate ${CONNECT_STACK} (billing bucket and export are kept)"
  info "  - Recreate ${BILLING_STACK} for the kept billing export"
else
  info "  - $(verb "$CONNECT_STATUS") ${CONNECT_STACK}: read-only IAM role $ROLE_NAME in account $ACCOUNT_ID${REPAIR_TOKEN:+, re-applying its trust and policies}"
fi
[ "$CFN_COST_DATA" != "CreateExport" ] || [ "$(lookup "$CONNECT_PREV" CostData || true)" = "CreateExport" ] ||
  info "    plus bucket spotto-billing-$ACCOUNT_ID-$DEPLOYMENT and daily CUR 2.0 export ${CREATED_EXPORT_NAME} (first files within 24 hours)"
[ "$COST_DATA" != "existing" ] || info "  - $(verb "$BILLING_STATUS") ${BILLING_STACK}: read access to export $EXPORT_NAME (s3://$BUCKET/${PREFIX:+$PREFIX/}$EXPORT_NAME)"
[ "$COST_DATA" = "existing" ] || [ "$BILLING_STATUS" = "NONE" ] || [ $RECREATE -eq 1 ] || info "  - Update ${BILLING_STACK}"
[ "$ENABLE_TRUSTED_ACCESS" -eq 0 ] || info "  - Turn on StackSets trusted access for the organization"
[ "$CONNECT_MEMBERS" != "yes" ] || info "  - $(verb "$MEMBERS_STATUS") ${MEMBERS_STACK}: StackSet that adds $ROLE_NAME to member accounts${OU_IDS:+ in $OU_IDS} (and new ones automatically)"
[ "$KIND" != "management" ] || [ "$CONNECT_MEMBERS" = "yes" ] || [ "$CONNECT_STATUS" = "NONE" ] || info "  (Member accounts aren't connected. Add --connect-members yes to connect them.)"
[ $NO_BILLING -eq 0 ] || info "  - No cost data. Billing is required: $BILLING_FIX"
info ""
effective_cost_data="${CFN_COST_DATA:-$(lookup "$CONNECT_PREV" CostData || true)}"
if [ "$effective_cost_data" = CreateExport ] || [ "$REUSE_BILLING" -eq 1 ] || [ "$EXPORT_STATUS" != NONE ]; then
  info "  - $EXPORT_STACK (us-east-1): AWS-global export definition; billing files stay in $REGION"
fi
ask "Deploy now?" y || { info "Nothing changed."; exit 1; }

# 7. Deploy
explain_failure() {
  local errors
  errors="$(aws_ cloudformation describe-stack-events --stack-name "$1" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" --output text 2>/dev/null |
    grep -v 'Resource creation cancelled' | head -5 | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' || true)"
  info "Stack $1 failed. First errors:"
  printf '%s\n' "$errors" | awk -F'\t' 'NF { printf "  - %s: %s\n", $1, $2 }'
  if printf '%s' "$errors" | grep '^SpottoRegistration' >/dev/null; then
    info ""
    info "The portal didn't confirm the connection within 5 minutes. Check that:"
    info "  - the External ID is the one shown in the portal for this company (copy the command again);"
    info "  - no service control policy blocks CloudFormation from publishing to the SNS topic $REGISTRATION_TOPIC_ARN."
    info "Then rerun this command."
  fi
  if [ "$1" = "${MEMBERS_STACK}" ] && printf '%s' "$errors" | grep -i 'organizations access\|trusted access' >/dev/null; then
    info ""
    info "StackSets trusted access isn't turned on for the organization. To turn it on:"
    info "  CloudFormation console → StackSets → Enable trusted access (in the management account)"
    info "  or run: aws cloudformation activate-organizations-access --region $REGION"
    info "Then rerun this command."
  fi
  exit 1
}
params_json() { # params_json <stack> <template url> key=value... ; unchanged or unset keys reuse previous values
  local stack="$1" url="$2" keys prev out="" key kv val has pv
  shift 2
  keys="$(aws_ cloudformation get-template-summary --template-url "$url" --query 'Parameters[].ParameterKey' --output text 2>&1)" ||
    die "Can't read template $url. AWS said: $keys"
  prev="$(stack_params "$stack")"
  for key in $keys; do
    has=0 val=""
    for kv in "$@"; do [ "${kv%%=*}" != "$key" ] || { has=1; val="${kv#*=}"; }; done
    if pv="$(lookup "$prev" "$key")" && { [ $has -eq 0 ] || [ "$pv" = "$val" ]; }; then
      out="$out${out:+,}{\"ParameterKey\":\"$key\",\"UsePreviousValue\":true}"
    elif [ $has -eq 1 ]; then
      out="$out${out:+,}{\"ParameterKey\":\"$key\",\"ParameterValue\":\"$(json_escape "$val")\"}"
    fi
  done
  printf '[%s]' "$out"
}
delete_stack() {
  info "Removing $1..."
  aws_ cloudformation delete-stack --stack-name "$1"
  aws_ cloudformation wait stack-delete-complete --stack-name "$1" || die "Couldn't remove $1. Check its events in the CloudFormation console."
}
deploy() { # deploy <stack> <template file> key=value...
  local stack="$1" url="$TEMPLATE_URL$2" status out params wait_note=""
  shift 2
  status="$(stack_status "$stack")"
  [ "$status" != "ROLLBACK_COMPLETE" ] || { delete_stack "$stack"; status="NONE"; }
  params="$(params_json "$stack" "$url" "$@")"
  [ "$stack" != "${CONNECT_STACK}" ] || wait_note=", up to 5 while the portal confirms"
  if [ "$status" = "NONE" ]; then
    info "Creating $stack (usually 1–2 minutes$wait_note)..."
    out="$(aws_ cloudformation create-stack --stack-name "$stack" --template-url "$url" --capabilities CAPABILITY_NAMED_IAM \
      --parameters "$params" 2>&1)" || die "Couldn't create $stack. AWS said: $out"
    aws_ cloudformation wait stack-create-complete --stack-name "$stack" || explain_failure "$stack"
  else
    info "Updating $stack..."
    if ! out="$(aws_ cloudformation update-stack --stack-name "$stack" --template-url "$url" --capabilities CAPABILITY_NAMED_IAM \
      --parameters "$params" 2>&1)"; then
      printf '%s' "$out" | grep -q 'No updates are to be performed' && { info "$stack is already up to date."; return 0; }
      die "Couldn't update $stack. AWS said: $out"
    fi
    aws_ cloudformation wait stack-update-complete --stack-name "$stack" || explain_failure "$stack"
  fi
}

CONNECT_ARGS=("RoleName=$ROLE_NAME" "Deployment=$DEPLOYMENT" "RegistrationTopicArn=$REGISTRATION_TOPIC_ARN" "BillingExportName=$CREATED_EXPORT_NAME" "RetainedBillingStorage=$([ "$REUSE_BILLING" -eq 1 ] && echo true || echo false)")
[ -z "$EXTERNAL_ID" ] || CONNECT_ARGS+=("ExternalId=$EXTERNAL_ID")
[ -z "$PRINCIPAL_ARN" ] || CONNECT_ARGS+=("TrustedPrincipalArn=$PRINCIPAL_ARN")
if [ $RECREATE -eq 1 ]; then
  PREV_COST="$(lookup "$CONNECT_PREV" CostData || true)" BILLING_PREV="$(stack_params ${BILLING_STACK})"
  [ "$BILLING_STATUS" = "NONE" ] || delete_stack ${BILLING_STACK}
  delete_stack ${CONNECT_STACK}
  deploy ${CONNECT_STACK} spotto-aws-connect.template.json "ExternalId=${EXTERNAL_ID:-$(lookup "$CONNECT_PREV" ExternalId)}" \
    "TrustedPrincipalArn=${PRINCIPAL_ARN:-$(lookup "$CONNECT_PREV" TrustedPrincipalArn)}" "RoleName=$ROLE_NAME" "CostData=$([ "$REUSE_BILLING" -eq 1 ] && echo None || echo "${recreate_cost:-None}")" "RetainedBillingStorage=$([ "$REUSE_BILLING" -eq 1 ] && echo true || echo false)" "Deployment=$DEPLOYMENT" "RegistrationTopicArn=$REGISTRATION_TOPIC_ARN" "BillingExportName=$CREATED_EXPORT_NAME"
  if [ "$COST_DATA" != "existing" ] && [ "$REUSE_BILLING" -eq 1 ]; then
    COST_DATA="existing" EXPORT_NAME="${CREATED_EXPORT_NAME}" BUCKET="spotto-billing-$ACCOUNT_ID-$DEPLOYMENT" PREFIX="cur2" KMS_KEY_ARN=""
  elif [ "$COST_DATA" != "existing" ] && [ -n "$BILLING_PREV" ]; then
    COST_DATA="existing" EXPORT_NAME="$(lookup "$BILLING_PREV" ExportName)" BUCKET="$(lookup "$BILLING_PREV" BucketName)"
    PREFIX="$(lookup "$BILLING_PREV" BasePrefix || true)" KMS_KEY_ARN="$(lookup "$BILLING_PREV" KmsKeyArn || true)"
  fi
else
  [ -z "$CFN_COST_DATA" ] || CONNECT_ARGS+=("CostData=$CFN_COST_DATA")
  [ -z "$REPAIR_TOKEN" ] || CONNECT_ARGS+=("RepairToken=$REPAIR_TOKEN")
  deploy ${CONNECT_STACK} spotto-aws-connect.template.json "${CONNECT_ARGS[@]}"
fi
# Data Exports definitions are global; this stack carries no registration or External ID.
if [ "$(lookup "$(stack_params "$CONNECT_STACK")" CostData || true)" = CreateExport ] || [ "$REUSE_BILLING" -eq 1 ]; then
  created_bucket="$([ "$REUSE_BILLING" -eq 1 ] && echo "$retained_bucket" || output_of "$CONNECT_STACK" BillingBucketName)"
  [ -n "$created_bucket" ] || die "The regional stack did not return its billing bucket."
  deploy "$EXPORT_STACK" spotto-aws-billing-export.template.json "Deployment=$DEPLOYMENT" "BucketRegion=$REGION"
elif [ "$EXPORT_STATUS" != NONE ]; then
  deploy "$EXPORT_STACK" spotto-aws-billing-export.template.json "Deployment=$DEPLOYMENT" "BucketRegion=$REGION"
fi
if [ "$COST_DATA" = "existing" ]; then
  deploy ${BILLING_STACK} spotto-aws-billing-access.template.json "RoleName=$ROLE_NAME" "ExportName=$EXPORT_NAME" "BucketName=$BUCKET" \
    "BasePrefix=$PREFIX" "KmsKeyArn=$KMS_KEY_ARN" ${REPAIR_TOKEN:+"RepairToken=$REPAIR_TOKEN"}
elif [ "$BILLING_STATUS" != "NONE" ] && [ $RECREATE -eq 0 ]; then
  deploy ${BILLING_STACK} spotto-aws-billing-access.template.json "RoleName=$ROLE_NAME" ${REPAIR_TOKEN:+"RepairToken=$REPAIR_TOKEN"}
fi
if [ "$CONNECT_MEMBERS" = "yes" ]; then
  if [ "$ENABLE_TRUSTED_ACCESS" -eq 1 ]; then
    info "Turning on StackSets trusted access..."
    aws_ cloudformation activate-organizations-access >/dev/null 2>&1 ||
      info "Couldn't turn it on automatically (CloudFormation console → StackSets → Enable trusted access)."
  fi
  # The members stack takes its trust from the flags, or from ${CONNECT_STACK} when they're omitted (e.g. adding members later).
  MEMBER_ARGS=("RoleName=$ROLE_NAME" "ExternalId=${EXTERNAL_ID:-$(lookup "$CONNECT_PREV" ExternalId || true)}"
    "TrustedPrincipalArn=${PRINCIPAL_ARN:-$(lookup "$CONNECT_PREV" TrustedPrincipalArn || true)}")
  [ -z "$OU_IDS" ] || MEMBER_ARGS+=("OrganizationalUnitIds=$OU_IDS")
  [ -z "$REPAIR_TOKEN" ] || MEMBER_ARGS+=("RepairToken=$REPAIR_TOKEN")
  deploy ${MEMBERS_STACK} spotto-aws-members.template.json "${MEMBER_ARGS[@]}"
fi

# 8. Summary
ROLE_ARN="$(output_of ${CONNECT_STACK} RoleArn)"
case "$(lookup "$(stack_params ${CONNECT_STACK})" CostData || true)/$COST_DATA" in
  CreateExport/*) EXPORT_SUMMARY="${CREATED_EXPORT_NAME} → s3://$(output_of ${CONNECT_STACK} BillingBucketName)/cur2 (first files within 24 hours)" ;;
  */existing) EXPORT_SUMMARY="$EXPORT_NAME (s3://$BUCKET/${PREFIX:+$PREFIX/}$EXPORT_NAME)" ;;
  *) [ "$(stack_status ${BILLING_STACK})" = "NONE" ] && EXPORT_SUMMARY="none" || EXPORT_SUMMARY="existing export (${BILLING_STACK})" ;;
esac
info ""
info "Connected."
info "  Account:         $ACCOUNT_ID"
info "  Organization:    ${ORG_ID:-none (standalone)}${ORG_ID:+ ($KIND account)}"
info "  Role ARN:        ${ROLE_ARN:-arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME}"
info "  Billing export:  $EXPORT_SUMMARY"
info "  Template:        ${LATEST:-latest}"
[ "$CONNECT_MEMBERS" != "yes" ] || info "  Member accounts: StackSet ${MEMBERS_STACK}${OU_IDS:+ deploying to $OU_IDS}"
info ""
info "Return to the portal — it detects the connection automatically."
