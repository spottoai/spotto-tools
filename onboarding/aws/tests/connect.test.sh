#!/usr/bin/env bash
# Offline tests for connect.sh using fake_aws.py as the aws executable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../connect.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexec python3 "%s" "$@"\n' "$HERE/fake_aws.py" > "$WORK/bin/aws"
chmod +x "$WORK/bin/aws"
EXT="spotto-0f8fad5b-d9cb-469f-a165-70867728950e"
ARN="arn:aws:iam::715809501612:user/spotto-cloud-engine-prod"
BASE="https://spotto-aws-onboarding.s3.amazonaws.com/cloudformation/"
V="v2026-10-30.1/"
OUT="$WORK/out" LOG="$WORK/log"
export FAKE_AWS_STATE="$WORK/state" FAKE_AWS_LOG="$LOG"
PASS=0 FAIL=0

fresh() { rm -rf "$WORK/state"; mkdir -p "$WORK/state"; : > "$LOG"; }
seed() { FAKE_AWS_SCENARIO=x "$WORK/bin/aws" fake-seed "$@"; : > "$LOG"; }
run() { # run <scenario> <expected exit> args...  (state is kept; call fresh first)
  local scenario="$1" expected="$2" code=0
  shift 2
  : > "$LOG"
  PATH="$WORK/bin:$PATH" FAKE_AWS_SCENARIO="$scenario" bash "$SCRIPT" --deployment "${TEST_DEPLOYMENT:-prod-us}" "$@" > "$OUT" 2>&1 </dev/null || code=$?
  [ "$code" = "$expected" ] || { echo "    expected exit $expected, got $code"; sed 's/^/    | /' "$OUT"; return 1; }
}
connect() { local s="$1" e="$2"; shift 2; run "$s" "$e" --external-id "$EXT" --trusted-principal-arn "$ARN" "$@"; }
has() { grep -F -- "$1" "$2" >/dev/null || { echo "    missing in $(basename "$2"): $1"; return 1; }; }
lacks() { ! grep -F -- "$1" "$2" >/dev/null || { echo "    unexpected in $(basename "$2"): $1"; return 1; }; }
check() { fresh; if "$2"; then PASS=$((PASS + 1)); echo "ok   $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1"; fi; }
seed_connect() { # seed_connect <version> <CostData>
  seed SpottoConnect-prod-us "$1" "ExternalId=$EXT" "TrustedPrincipalArn=$ARN" "Deployment=prod-us" "RegistrationTopicArn=arn:aws:sns:us-east-1:715809501612:spotto-aws-connect-prod-us" "BillingExportName=spotto-cur2-prod-us" "CostData=$2" RetainedBillingStorage=false RoleName=SpottoReadOnlyRole
  if [ "$2" = CreateExport ]; then seed SpottoBillingExport-prod-us "$1" Deployment=prod-us BucketRegion=us-east-1; fi
}

t_syntax() { bash -n "$SCRIPT"; }
t_help() { bash "$SCRIPT" --deployment prod-us --help | grep -- '--repair' >/dev/null; }
t_bad_external_id() { run standalone 1 --external-id nope --trusted-principal-arn "$ARN" --yes && has "spotto-<uuid>" "$OUT"; }
t_needs_ids() { run standalone 1 --yes && has "are required to connect" "$OUT" && lacks "create-stack" "$LOG"; }
t_standalone_create() {
  connect standalone 0 --yes &&
  has "isn't part of an organization" "$OUT" &&
  has "get-template-summary --template-url ${BASE}spotto-aws-connect.template.json --query Metadata" "$LOG" &&
  has "create-stack --stack-name SpottoConnect-prod-us --template-url ${BASE}${V}spotto-aws-connect.template.json --capabilities CAPABILITY_NAMED_IAM" "$LOG" &&
  has "PARAMS SpottoConnect-prod-us ExternalId=$EXT;TrustedPrincipalArn=$ARN;Deployment=prod-us;RegistrationTopicArn=arn:aws:sns:us-east-1:715809501612:spotto-aws-connect-prod-us;BillingExportName=spotto-cur2-prod-us;CostData=CreateExport;RetainedBillingStorage=false;RoleName=SpottoReadOnlyRole" "$LOG" &&
  has "--region us-east-1 cloudformation wait stack-create-complete --stack-name SpottoConnect-prod-us" "$LOG" &&
  lacks "stack --stack-name SpottoMemberAccounts-prod-us" "$LOG" && lacks "stack --stack-name SpottoBillingAccess-prod-us" "$LOG" &&
  has "up to 5 while the portal confirms" "$OUT" &&
  has "Role ARN:        arn:aws:iam::111122223333:role/SpottoReadOnlyRole" "$OUT" &&
  has "spotto-cur2-prod-us → s3://spotto-billing-111122223333-prod-us/cur2" "$OUT" &&
  has "Template:        2026-10-30.1" "$OUT" &&
  has "Return to the portal — it detects the connection automatically." "$OUT"
}
t_rerun_no_changes() {
  connect standalone 0 --yes && connect standalone 0 --yes &&
  has "PARAMS SpottoConnect-prod-us ExternalId=(previous);TrustedPrincipalArn=(previous);Deployment=(previous);RegistrationTopicArn=(previous);BillingExportName=(previous);CostData=(previous);RetainedBillingStorage=(previous);RoleName=(previous)" "$LOG" &&
  has "SpottoConnect-prod-us is already up to date." "$OUT" && lacks "create-stack" "$LOG" && lacks "Create a new billing export" "$OUT"
}
t_update_new_version() {
  seed_connect 2026-10-01.1 CreateExport
  seed SpottoMemberAccounts-prod-us 2026-10-01.1 "ExternalId=$EXT" "TrustedPrincipalArn=$ARN" OrganizationalUnitIds=r-ab12 RoleName=SpottoReadOnlyRole
  connect management 0 --yes &&
  has "Found SpottoConnect-prod-us (version 2026-10-01.1); latest is 2026-10-30.1." "$OUT" &&
  has "update-stack --stack-name SpottoConnect-prod-us --template-url ${BASE}${V}spotto-aws-connect.template.json" "$LOG" &&
  has "PARAMS SpottoConnect-prod-us ExternalId=(previous);TrustedPrincipalArn=(previous);Deployment=(previous);RegistrationTopicArn=(previous);BillingExportName=(previous);CostData=(previous);RetainedBillingStorage=(previous);RoleName=(previous)" "$LOG" &&
  has "update-stack --stack-name SpottoMemberAccounts-prod-us --template-url ${BASE}${V}spotto-aws-members.template.json" "$LOG" &&
  has "OrganizationalUnitIds=(previous)" "$LOG" && lacks "list-roots" "$LOG" && lacks "create-stack" "$LOG" &&
  has "wait stack-update-complete --stack-name SpottoMemberAccounts-prod-us" "$LOG" &&
  grep '"version": "2026-10-30.1"' "$WORK/state/SpottoConnect-prod-us.json" >/dev/null
}
t_rerun_keeps_declined_members() {
  seed_connect 2026-10-30.1 None
  connect management 0 --yes && lacks "stack --stack-name SpottoMemberAccounts-prod-us" "$LOG" && has "Add --connect-members yes" "$OUT"
}
t_existing_export() {
  connect existing 0 --yes --cost-data existing &&
  has "CostData=None" "$LOG" &&
  has "create-stack --stack-name SpottoBillingAccess-prod-us --template-url ${BASE}${V}spotto-aws-billing-access.template.json" "$LOG" &&
  has "PARAMS SpottoBillingAccess-prod-us RoleName=SpottoReadOnlyRole;ExportName=contoso-cur2;BucketName=contoso-billing;BasePrefix=reports;KmsKeyArn=arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab" "$LOG" &&
  has "Billing export:  contoso-cur2 (s3://contoso-billing/reports/contoso-cur2)" "$OUT"
}
t_member_warning() {
  connect member 0 --yes --connect-members yes &&
  has "Warning: this is a member account of organization o-abc1234567 (management account 999988887777)" "$OUT" &&
  has "can only be connected from the management account" "$OUT" &&
  has "create-stack --stack-name SpottoConnect-prod-us" "$LOG" && lacks "stack --stack-name SpottoMemberAccounts-prod-us" "$LOG"
}
t_management_members() {
  connect management 0 --yes && has "organizations list-roots" "$LOG" &&
  has "create-stack --stack-name SpottoMemberAccounts-prod-us --template-url ${BASE}${V}spotto-aws-members.template.json" "$LOG" &&
  has "PARAMS SpottoMemberAccounts-prod-us ExternalId=$EXT;TrustedPrincipalArn=$ARN;OrganizationalUnitIds=r-ab12;RoleName=SpottoReadOnlyRole" "$LOG"
}
t_management_ous() {
  connect management 0 --yes --organizational-unit-ids ou-ab12-abcdefgh,ou-ab12-12345678 &&
  lacks "list-roots" "$LOG" && has "OrganizationalUnitIds=ou-ab12-abcdefgh,ou-ab12-12345678" "$LOG"
}
t_unversioned_fallback() {
  FAKE_LATEST_VERSION="" connect standalone 0 --yes &&
  has "create-stack --stack-name SpottoConnect-prod-us --template-url ${BASE}spotto-aws-connect.template.json" "$LOG"
}
t_members_trusted_access() {
  connect members-fail 1 --yes &&
  has "MemberRoleStackSet: You must enable organizations access" "$OUT" &&
  has "CloudFormation console → StackSets → Enable trusted access" "$OUT"
}
t_registration_failure() {
  connect registration-fail 1 --yes &&
  has "SpottoRegistration: CloudFormation did not receive a response" "$OUT" &&
  has "The portal didn't confirm the connection within 5 minutes" "$OUT" && has "External ID is the one shown in the portal" "$OUT"
}
t_role_exists() { connect role-exists 1 --yes && has "Delete it, or pass --role-name" "$OUT" && lacks "create-stack" "$LOG"; }
t_rename_refused() { seed_connect 2026-10-30.1 None; connect standalone 1 --yes --role-name Other && has "Renaming it isn't supported" "$OUT"; }
t_repair_role_present() {
  seed_connect 2026-10-30.1 CreateExport
  FAKE_DRIFTED=SpottoConnect-prod-us run standalone 0 --repair --yes &&
  has "SpottoConnect-prod-us: drifted" "$OUT" && has "Role was modified outside CloudFormation" "$OUT" &&
  has "re-applying its trust and policies" "$OUT" &&
  has "update-stack --stack-name SpottoConnect-prod-us --template-url ${BASE}${V}spotto-aws-connect.template.json" "$LOG" &&
  grep -E "PARAMS SpottoConnect-prod-us ExternalId=\(previous\);TrustedPrincipalArn=\(previous\);Deployment=\(previous\);RegistrationTopicArn=\(previous\);BillingExportName=\(previous\);CostData=\(previous\);RetainedBillingStorage=\(previous\);RoleName=\(previous\);RepairToken=[0-9]{10}$" "$LOG" >/dev/null &&
  lacks "delete-stack" "$LOG"
}
t_repair_role_deleted() {
  seed_connect 2026-10-30.1 CreateExport
  seed SpottoMemberAccounts-prod-us 2026-10-30.1 "ExternalId=$EXT" "TrustedPrincipalArn=$ARN" OrganizationalUnitIds=r-ab12 RoleName=SpottoReadOnlyRole
  rm "$WORK/state/role"
  run management 0 --repair --yes &&
  has "Recover the access stack: remove and recreate" "$OUT" &&
  has "delete-stack --stack-name SpottoConnect-prod-us" "$LOG" &&
  has "PARAMS SpottoConnect-prod-us ExternalId=$EXT;TrustedPrincipalArn=$ARN;Deployment=prod-us;RegistrationTopicArn=arn:aws:sns:us-east-1:715809501612:spotto-aws-connect-prod-us;BillingExportName=spotto-cur2-prod-us;CostData=None;RetainedBillingStorage=true;RoleName=SpottoReadOnlyRole" "$LOG" &&
  has "PARAMS SpottoBillingAccess-prod-us RoleName=SpottoReadOnlyRole;ExportName=spotto-cur2-prod-us;BucketName=spotto-billing-111122223333-prod-us;BasePrefix=cur2;KmsKeyArn=" "$LOG" &&
  grep -E "PARAMS SpottoMemberAccounts-prod-us ExternalId=\(previous\);TrustedPrincipalArn=\(previous\);OrganizationalUnitIds=\(previous\);RoleName=\(previous\);RepairToken=[0-9]+$" "$LOG" >/dev/null &&
  [ -f "$WORK/state/role" ] && has "Billing export:  spotto-cur2-prod-us (s3://spotto-billing-111122223333-prod-us/cur2/spotto-cur2-prod-us)" "$OUT"
}
t_repair_old_stack_refused() {
  seed_connect "" CreateExport; rm "$WORK/state/role"
  run standalone 1 --repair --yes && has "Create an empty IAM role named SpottoReadOnlyRole" "$OUT" && lacks "delete-stack" "$LOG"
}
t_repair_nothing() { run standalone 1 --repair --yes && has "Nothing to repair" "$OUT"; }
t_check_ok() {
  seed_connect 2026-10-30.1 CreateExport
  seed SpottoMemberAccounts-prod-us 2026-10-30.1 "ExternalId=$EXT" "TrustedPrincipalArn=$ARN" OrganizationalUnitIds=r-ab12 RoleName=SpottoReadOnlyRole
  FAKE_INSTANCES="222233334444,CURRENT,SUCCEEDED;333344445555,CURRENT,SUCCEEDED" run management 0 --check &&
  has "SpottoConnect-prod-us: version 2026-10-30.1 (up to date)" "$OUT" && has "Drift: in sync" "$OUT" &&
  has "Member accounts: 2 OK, 0 outdated, 0 failed" "$OUT" && has "Everything is up to date and in sync." "$OUT" &&
  has "iam list-attached-role-policies --role-name SpottoReadOnlyRole" "$LOG" &&
  has "SpottoReadOnlyRole: AWS managed policies ViewOnlyAccess and SecurityAudit attached" "$OUT" &&
  lacks "create-stack" "$LOG" && lacks "update-stack" "$LOG" && lacks "delete-stack" "$LOG"
}
t_check_outdated() {
  seed_connect 2026-10-01.1 CreateExport
  run standalone 1 --check && has "version 2026-10-01.1 (update available)" "$OUT" && has "rerun this command without --check" "$OUT" && lacks "update-stack" "$LOG"
}
t_check_drift_and_members() {
  seed_connect 2026-10-30.1 CreateExport
  seed SpottoMemberAccounts-prod-us 2026-10-30.1 "ExternalId=$EXT" "TrustedPrincipalArn=$ARN" OrganizationalUnitIds=r-ab12 RoleName=SpottoReadOnlyRole
  FAKE_DRIFTED=SpottoConnect-prod-us FAKE_INSTANCES="222233334444,CURRENT,SUCCEEDED;333344445555,OUTDATED,SUCCEEDED;444455556666,OUTDATED,FAILED" run management 1 --check &&
  has "Drift: drifted" "$OUT" && has "Role was modified outside CloudFormation" "$OUT" &&
  has "Member accounts: 1 OK, 1 outdated, 1 failed" "$OUT" && has "444455556666: FAILED" "$OUT" && has "rerun with --repair" "$OUT"
}
t_check_managed_missing() {
  seed_connect 2026-10-30.1 CreateExport
  FAKE_MANAGED_POLICIES="arn:aws:iam::aws:policy/job-function/ViewOnlyAccess,arn:aws:iam::aws:policy/ReadOnlyAccess" run standalone 1 --check &&
  has "SpottoReadOnlyRole is missing the AWS managed SecurityAudit policy" "$OUT" && has "rerun with --repair" "$OUT" &&
  lacks "Everything is up to date" "$OUT" && lacks "update-stack" "$LOG"
}
t_check_managed_none() {
  seed SpottoConnect-prod-us 2026-10-30.1 "ExternalId=$EXT" "TrustedPrincipalArn=$ARN" CostData=None RoleName=CustomRole
  FAKE_MANAGED_POLICIES=none run standalone 1 --check &&
  has "iam list-attached-role-policies --role-name CustomRole" "$LOG" &&
  has "CustomRole is missing the AWS managed ViewOnlyAccess and SecurityAudit policies" "$OUT"
}
t_check_managed_denied() {
  seed_connect 2026-10-30.1 CreateExport
  FAKE_DENY=list-attached-role-policies run standalone 1 --check &&
  has "Couldn't read the managed policies attached to SpottoReadOnlyRole: An error occurred (AccessDenied)" "$OUT" &&
  has "health isn't confirmed" "$OUT"
}
t_check_not_connected() { run standalone 1 --check && has "Not connected" "$OUT"; }
t_add_members_later() { # existing single-account connection, no trust flags repeated
  seed_connect 2026-10-30.1 CreateExport
  run management 0 --connect-members yes --yes &&
  has "create-stack --stack-name SpottoMemberAccounts-prod-us" "$LOG" &&
  has "PARAMS SpottoMemberAccounts-prod-us ExternalId=$EXT;TrustedPrincipalArn=$ARN;OrganizationalUnitIds=r-ab12;RoleName=SpottoReadOnlyRole" "$LOG" &&
  has "SpottoConnect-prod-us is already up to date." "$OUT"
}
seed_billing() { seed SpottoBillingAccess-prod-us 2026-10-30.1 RoleName=SpottoReadOnlyRole ExportName=contoso-cur2 BucketName=contoso-billing BasePrefix=reports KmsKeyArn=; }
t_repair_billing_token() {
  seed_connect 2026-10-30.1 None; seed_billing
  FAKE_BILLING_REPAIR_TOKEN=1 run standalone 0 --repair --yes &&
  grep -E "PARAMS SpottoBillingAccess-prod-us RoleName=\(previous\);ExportName=\(previous\);BucketName=\(previous\);BasePrefix=\(previous\);KmsKeyArn=\(previous\);RepairToken=[0-9]{10}$" "$LOG" >/dev/null &&
  has "update-stack --stack-name SpottoBillingAccess-prod-us" "$LOG"
}
t_repair_billing_no_token_param() { # today's template doesn't declare it, so it isn't sent
  seed_connect 2026-10-30.1 None; seed_billing
  run standalone 0 --repair --yes && has "PARAMS SpottoBillingAccess-prod-us RoleName=(previous);ExportName=(previous);BucketName=(previous);BasePrefix=(previous);KmsKeyArn=(previous)" "$LOG" &&
  ! grep "PARAMS SpottoBillingAccess-prod-us.*RepairToken" "$LOG" >/dev/null
}
seed_org() {
  seed_connect 2026-10-30.1 CreateExport
  seed SpottoMemberAccounts-prod-us 2026-10-30.1 "ExternalId=$EXT" "TrustedPrincipalArn=$ARN" OrganizationalUnitIds=r-ab12 RoleName=SpottoReadOnlyRole
}
t_check_member_denied() {
  seed_org
  FAKE_DENY=list-stack-instances run management 1 --check &&
  has "Couldn't read member account status: An error occurred (AccessDenied)" "$OUT" &&
  has "health isn't confirmed" "$OUT" && lacks "Everything is up to date" "$OUT" && lacks "Member accounts: 0 OK" "$OUT"
}
t_check_pending() {
  seed_org
  FAKE_INSTANCES="222233334444,CURRENT,SUCCEEDED;333344445555,OUTDATED,RUNNING;444455556666,CURRENT,PENDING" run management 1 --check &&
  has "Member accounts: 1 OK, 0 outdated, 0 failed, 2 in progress" "$OUT" && has "rerun --check shortly" "$OUT" &&
  lacks "Everything is up to date" "$OUT" && lacks "--repair" "$OUT"
}
t_check_drift_denied() {
  seed_org
  FAKE_DENY=detect-stack-drift run management 1 --check &&
  has "Couldn't read drift status: An error occurred (AccessDenied)" "$OUT" && lacks "Everything is up to date" "$OUT"
}
t_stack_read_denied() {
  seed_connect 2026-10-30.1 None; seed_billing
  FAKE_DENY=describe-stacks:SpottoBillingAccess-prod-us run standalone 1 --check && has "Couldn't read stack SpottoBillingAccess-prod-us: An error occurred (AccessDenied)" "$OUT" &&
  FAKE_DENY=describe-stacks:SpottoBillingAccess-prod-us run standalone 1 --yes && has "Couldn't read stack SpottoBillingAccess-prod-us" "$OUT" && lacks "update-stack" "$LOG"
}
t_repair_getrole_denied() { # only NoSuchEntity means deleted; anything else must never delete
  seed_connect 2026-10-30.1 CreateExport
  FAKE_DENY=get-role run standalone 1 --repair --yes &&
  has "Couldn't check whether role SpottoReadOnlyRole exists: An error occurred (AccessDenied)" "$OUT" &&
  lacks "delete-stack" "$LOG" && lacks "create-stack" "$LOG" && lacks "update-stack" "$LOG"
}
t_connect_getrole_denied() {
  FAKE_DENY=get-role connect standalone 1 --yes && has "Couldn't check whether role SpottoReadOnlyRole exists" "$OUT" && lacks "create-stack" "$LOG"
}
t_check_latest_unreadable() { # "get-template-summary:" denies only --template-url reads (no stack name)
  seed_connect 2026-10-30.1 CreateExport
  FAKE_DENY="get-template-summary:" run standalone 1 --check &&
  has "Couldn't read the template version for the latest templates: An error occurred (AccessDenied)" "$OUT" &&
  lacks "Everything is up to date" "$OUT" && lacks "(up to date)" "$OUT"
}
t_check_deployed_unreadable() {
  seed_connect 2026-10-30.1 CreateExport
  FAKE_DENY="get-template-summary:SpottoConnect-prod-us" run standalone 1 --check &&
  has "Couldn't read the template version for SpottoConnect-prod-us: An error occurred (AccessDenied)" "$OUT" &&
  has "SpottoConnect-prod-us: version unknown (version unreadable)" "$OUT" && lacks "Everything is up to date" "$OUT"
}
t_run_latest_unreadable() {
  FAKE_DENY="get-template-summary:" connect standalone 1 --yes &&
  has "Couldn't read the template version for the latest templates" "$OUT" && lacks "create-stack" "$LOG" &&
  seed_connect 2026-10-01.1 CreateExport &&
  FAKE_DENY="get-template-summary:" connect standalone 1 --yes && lacks "update-stack" "$LOG"
}
t_run_deployed_unreadable() {
  seed_connect 2026-10-01.1 CreateExport
  FAKE_DENY="get-template-summary:SpottoConnect-prod-us" connect standalone 1 --yes &&
  has "Couldn't read the template version for SpottoConnect-prod-us" "$OUT" && lacks "update-stack" "$LOG"
}
t_no_tty_without_yes() { # needs setsid so the script has no controlling terminal
  command -v setsid >/dev/null || { echo "    skipped (no setsid)"; return 0; }
  ! PATH="$WORK/bin:$PATH" FAKE_AWS_SCENARIO=standalone setsid bash "$SCRIPT" --deployment prod-us --external-id "$EXT" --trusted-principal-arn "$ARN" > "$OUT" 2>&1 </dev/null &&
  has "Rerun with --yes" "$OUT" && lacks "create-stack" "$LOG"
}
t_new_none_fails() {
  connect standalone 1 --yes --cost-data none &&
  has "Billing is required to connect AWS. Rerun with --cost-data create (recommended), or --cost-data existing --export-arn <arn>." "$OUT" &&
  lacks "create-stack" "$LOG"
}
t_update_none_warns() {
  seed_connect 2026-10-30.1 None
  connect standalone 0 --yes &&
  has "Warning: this connection has no billing data, and billing is required." "$OUT" &&
  has "No cost data. Billing is required" "$OUT" &&
  has "PARAMS SpottoConnect-prod-us ExternalId=(previous);TrustedPrincipalArn=(previous);Deployment=(previous);RegistrationTopicArn=(previous);BillingExportName=(previous);CostData=(previous);RetainedBillingStorage=(previous);RoleName=(previous)" "$LOG"
}
t_update_none_with_billing_access() {
  seed_connect 2026-10-30.1 None; seed_billing
  connect standalone 0 --yes && lacks "no billing data" "$OUT"
}
t_existing_monthly_refused() {
  FAKE_EXPORT_GRANULARITY=MONTHLY connect existing 1 --yes --cost-data existing &&
  has "isn't a daily or hourly CUR 2.0 export. Monthly isn't supported" "$OUT" && lacks "create-stack" "$LOG"
}
t_existing_without_resources_refused() {
  FAKE_EXPORT_RESOURCES=FALSE connect existing 1 --yes --cost-data existing &&
  has "doesn't include resource IDs (INCLUDE_RESOURCES)" "$OUT" && lacks "create-stack" "$LOG"
}
t_existing_hourly_accepted() {
  FAKE_EXPORT_GRANULARITY=HOURLY connect existing 0 --yes --cost-data existing &&
  has "create-stack --stack-name SpottoBillingAccess-prod-us" "$LOG"
}
t_existing_unselected_resource_id_refused() {
  FAKE_EXPORT_QUERY='SELECT identity_line_item_id, line_item_unblended_cost FROM COST_AND_USAGE_REPORT' connect existing 1 --yes --cost-data existing &&
  has "doesn't select line_item_resource_id" "$OUT" && lacks "create-stack" "$LOG"
}
t_existing_select_all_accepted() {
  FAKE_EXPORT_QUERY='SELECT * FROM COST_AND_USAGE_REPORT' connect existing 0 --yes --cost-data existing &&
  has "create-stack --stack-name SpottoBillingAccess-prod-us" "$LOG"
}
t_existing_kms_alias_resolved() {
  FAKE_BUCKET_KEY=alias/billing-exports connect existing 0 --yes --cost-data existing &&
  has "kms describe-key --key-id alias/billing-exports" "$LOG" &&
  has "KmsKeyArn=arn:aws:kms:us-east-1:111122223333:key/5678efgh-56ef-78gh-90ij-567890abcdef" "$LOG"
}
t_existing_kms_alias_arn_resolved_in_its_region() {
  FAKE_BUCKET_KEY=arn:aws:kms:eu-west-1:444455556666:alias/billing-exports connect existing 0 --yes --cost-data existing &&
  has "--region eu-west-1 kms describe-key --key-id arn:aws:kms:eu-west-1:444455556666:alias/billing-exports" "$LOG" &&
  has "KmsKeyArn=arn:aws:kms:us-east-1:111122223333:key/5678efgh-56ef-78gh-90ij-567890abcdef" "$LOG"
}
t_existing_kms_alias_missing_stops() {
  FAKE_BUCKET_KEY=alias/missing connect existing 1 --yes --cost-data existing &&
  has "Can't resolve the KMS key alias/missing that encrypts bucket contoso-billing" "$OUT" && lacks "create-stack" "$LOG"
}
t_existing_encryption_unreadable_stops() {
  FAKE_DENY=get-bucket-encryption connect existing 1 --yes --cost-data existing &&
  has "Can't read the default encryption of bucket contoso-billing" "$OUT" && has "AccessDenied" "$OUT" && lacks "create-stack" "$LOG"
}
t_existing_sse_s3_needs_no_key() {
  FAKE_BUCKET_KEY=none connect existing 0 --yes --cost-data existing &&
  has "BasePrefix=reports;KmsKeyArn=" "$LOG" && lacks "kms describe-key" "$LOG"
}
t_interactive_pick() { # answers: no new export, pick export 1, deploy yes (needs util-linux script for a terminal)
  script --version 2>/dev/null | grep util-linux >/dev/null || { echo "    skipped (no util-linux script)"; return 0; }
  printf 'n\n1\ny\n' | PATH="$WORK/bin:$PATH" FAKE_AWS_SCENARIO=existing \
    script -qec "bash '$SCRIPT' --deployment prod-us --external-id $EXT --trusted-principal-arn $ARN" /dev/null > "$OUT" 2>&1 &&
  has "1) contoso-cur2" "$OUT" && has "Deploy now?" "$OUT" && has "create-stack --stack-name SpottoBillingAccess-prod-us" "$LOG"
}

t_regional_split() {
  local deployment region
  for deployment in dev-au prod-au prod-eu; do
    fresh
    region=ap-southeast-2; [ "$deployment" != prod-eu ] || region=eu-north-1
    TEST_DEPLOYMENT="$deployment" connect standalone 0 --yes || return 1
    has "--region $region cloudformation create-stack --stack-name SpottoConnect-$deployment" "$LOG" || return 1
    has "--region us-east-1 cloudformation create-stack --stack-name SpottoBillingExport-$deployment" "$LOG" || return 1
    has "PARAMS SpottoBillingExport-$deployment Deployment=$deployment;BucketRegion=$region" "$LOG" || return 1
    TEST_DEPLOYMENT="$deployment" run standalone 0 --check || return 1
    has "Everything is up to date and in sync." "$OUT" || return 1
  done
}
t_missing_export_stack() {
  connect standalone 0 --yes && rm "$WORK/state/SpottoBillingExport-prod-us.json" && run standalone 1 --check &&
  has 'Required billing export stack SpottoBillingExport-prod-us is missing' "$OUT" && lacks 'create-stack' "$LOG"
}
t_wrong_topic() {
  connect standalone 1 --yes --registration-topic-arn arn:aws:sns:eu-north-1:715809501612:spotto-aws-connect-prod-eu &&
  has 'Registration topic does not match' "$OUT" && lacks 'sts get-caller-identity' "$LOG"
}
t_failed_registration_recovers_retained_storage() {
  seed_connect 2026-10-26.1 CreateExport
  rm "$WORK/state/SpottoBillingExport-prod-us.json" "$WORK/state/role"
  python3 - "$WORK/state/SpottoConnect-prod-us.json" <<'UPDATE'
import json,sys
path=sys.argv[1]
data=json.load(open(path)); data['status']='ROLLBACK_COMPLETE'
json.dump(data,open(path,'w'))
UPDATE
  connect standalone 0 --yes && has 'CostData=None' "$LOG" &&
  has 'create-stack --stack-name SpottoBillingExport-prod-us' "$LOG" &&
  has 'head-bucket --bucket spotto-billing-111122223333-prod-us --expected-bucket-owner 111122223333' "$LOG" &&
  has 'AWS-global export definition; billing files stay in us-east-1' "$OUT" && lacks 'delete-bucket' "$LOG"
}
t_interrupted_retained_recovery_resumes() {
  local failed_stack
  for failed_stack in SpottoBillingExport SpottoBillingAccess; do
    fresh; seed_connect 2026-10-26.1 CreateExport
    rm "$WORK/state/SpottoBillingExport-prod-us.json" "$WORK/state/role"
    FAKE_FAIL_CREATE_STACK="$failed_stack" connect standalone 1 --yes --repair || return 1
    has 'RetainedBillingStorage=true' "$LOG" || return 1
    run standalone 1 --check || return 1
    has 'is missing. Rerun the connect command to complete billing setup.' "$OUT" || return 1
    connect standalone 0 --yes --cost-data create || return 1
    has 'head-bucket --bucket spotto-billing-111122223333-prod-us' "$LOG" || return 1
    has 'CostData=(previous);RetainedBillingStorage=(previous)' "$LOG" || return 1
    has "create-stack --stack-name ${failed_stack}-prod-us" "$LOG" || return 1
    lacks 'delete-stack' "$LOG" || return 1
    run standalone 0 --check || return 1
  done
}
t_retained_bucket_rejection() {
  local state
  for state in foreign wrong-region no-policy; do
    fresh; seed_connect 2026-10-26.1 CreateExport; rm "$WORK/state/role"
    FAKE_RETAINED_BUCKET="$state" connect standalone 1 --yes --repair || return 1
    lacks 'delete-stack' "$LOG" || return 1
    lacks 'create-stack' "$LOG" || return 1
  done
}
check "failed registration reuses regional retained storage and creates missing definition" t_failed_registration_recovers_retained_storage
check "interrupted retained recovery resumes and check detects missing billing" t_interrupted_retained_recovery_resumes
check "retained storage ownership/region/policy failures stop before deletion" t_retained_bucket_rejection
check "AU/EU access and storage, US billing definition; regional check" t_regional_split
check "missing required export stack is unhealthy" t_missing_export_stack
check "wrong-boundary topic rejected before AWS" t_wrong_topic
check "bash -n" t_syntax
check "--help" t_help
check "rejects a bad external ID" t_bad_external_id
check "first connect needs the IDs" t_needs_ids
check "standalone account, create export (versioned URL)" t_standalone_create
check "rerun with no changes changes nothing" t_rerun_no_changes
check "rerun updates stacks to a new version" t_update_new_version
check "rerun doesn't add declined member accounts" t_rerun_keeps_declined_members
check "existing export adds billing access" t_existing_export
check "member account warns and continues alone" t_member_warning
check "management account connects members via root" t_management_members
check "management account with explicit OUs" t_management_ous
check "unversioned latest template falls back to base URL" t_unversioned_fallback
check "members stack failure explains trusted access" t_members_trusted_access
check "registration failure explains what to check" t_registration_failure
check "existing role stops before deploying" t_role_exists
check "renaming the role is refused" t_rename_refused
check "repair with the role present" t_repair_role_present
check "repair with the role deleted" t_repair_role_deleted
check "repair refuses to delete an unversioned stack" t_repair_old_stack_refused
check "repair with nothing deployed" t_repair_nothing
check "--check: all good exits 0" t_check_ok
check "--check: update available exits 1" t_check_outdated
check "--check: drift and member failures exit 1" t_check_drift_and_members
check "--check: not connected exits 1" t_check_not_connected
check "--check: missing managed policy exits 1" t_check_managed_missing
check "--check: no managed policies on a custom role name" t_check_managed_none
check "--check: unreadable managed policies exit 1" t_check_managed_denied
check "adding members later reuses the connect stack's trust" t_add_members_later
check "repair passes RepairToken to billing access when declared" t_repair_billing_token
check "repair omits RepairToken when billing template lacks it" t_repair_billing_no_token_param
check "--check: denied member status read exits 1" t_check_member_denied
check "--check: pending/running instances are in progress" t_check_pending
check "--check: denied drift detection exits 1" t_check_drift_denied
check "denied stack read is never treated as missing" t_stack_read_denied
check "repair: denied GetRole deletes nothing" t_repair_getrole_denied
check "connect: denied GetRole stops" t_connect_getrole_denied
check "--check: unreadable latest version exits 1" t_check_latest_unreadable
check "--check: unreadable deployed version exits 1" t_check_deployed_unreadable
check "connect/update: unreadable latest version stops" t_run_latest_unreadable
check "update: unreadable deployed version stops" t_run_deployed_unreadable
check "no terminal and no --yes stops safely" t_no_tty_without_yes
check "new connection without billing fails" t_new_none_fails
check "update of a connection without billing warns" t_update_none_warns
check "None stack with billing access doesn't warn" t_update_none_with_billing_access
check "monthly existing export is refused" t_existing_monthly_refused
check "existing export without resource IDs is refused" t_existing_without_resources_refused
check "hourly existing export is accepted" t_existing_hourly_accepted
check "existing export not selecting resource IDs is refused" t_existing_unselected_resource_id_refused
check "existing export selecting every column is accepted" t_existing_select_all_accepted
check "KMS alias on the billing bucket resolves to the key ARN" t_existing_kms_alias_resolved
check "KMS alias ARN resolves in its own Region" t_existing_kms_alias_arn_resolved_in_its_region
check "unresolvable KMS alias stops" t_existing_kms_alias_missing_stops
check "unreadable bucket encryption stops" t_existing_encryption_unreadable_stops
check "SSE-S3 billing bucket needs no KMS key" t_existing_sse_s3_needs_no_key
check "interactive export pick" t_interactive_pick
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
