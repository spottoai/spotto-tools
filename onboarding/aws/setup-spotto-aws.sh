#!/usr/bin/env bash
# Configure company AWS access from the portal package. Never generates IAM policies.
# Keep validation, ownership and handoff behavior aligned with Setup-SpottoAws.ps1
# and terraform-aws-spotto/modules/setup-package. Supports Bash 3.2 and later.
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage: bash setup-spotto-aws.sh --setup-package FILE [options]

  --setup-package FILE       Company setup package downloaded from Spotto
  --profile NAME             Authorized AWS CLI profile (default: current session)
  --profile-map FILE         JSON object mapping account IDs to profile names
  --region REGION            Commercial AWS Region (default: us-east-1)
  --output FILE              New results JSON file; never overwrites a file
  --check-only               Compare configuration without AWS changes (default)
  --configure                Review and approve IAM changes
  --dry-run                  Preview changes, recording planned outcomes; no writes
  --repair-existing-role     Explicitly adopt an existing unmanaged role
  --non-interactive          Do not prompt; defaults to check-only
  --yes                      Approve --configure changes without prompting
  --help                     Show this help

Requires Bash 3.2+, AWS CLI v2, jq 1.6+, and GNU timeout (or gtimeout on macOS).
Run Create/Update in Spotto after importing results to validate effective access.
USAGE
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
value_required() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "A value is required for $1."; }
absolute_file() { (cd -- "$(dirname -- "$1")" && printf '%s/%s\n' "$PWD" "$(basename -- "$1")"); }

setup_path='' profile='' profile_map='' region='us-east-1' output_path=''
mode='' repair=0 non_interactive=0 approve=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup-package|--profile|--profile-map|--region|--output)
            value_required "$@"
            case "$1" in
                --setup-package) setup_path=$2 ;; --profile) profile=$2 ;;
                --profile-map) profile_map=$2 ;; --region) region=$2 ;; --output) output_path=$2 ;;
            esac
            shift 2 ;;
        --check-only|--configure|--dry-run)
            [[ -z $mode || $mode == "$1" ]] || fail 'Choose only one of --check-only, --configure or --dry-run.'
            mode=$1; shift ;;
        --repair-existing-role) repair=1; shift ;;
        --non-interactive) non_interactive=1; shift ;;
        --yes) approve=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1. Use --help." ;;
    esac
done
# Store regexes in variables: Bash 3.2 parses inline grouping differently.
region_pattern='^[a-z]{2}(-[a-z0-9]+)+-[0-9]$'
[[ $region =~ $region_pattern && $region != cn-* && $region != us-gov-* ]] || fail 'Use a commercial AWS Region.'
[[ $approve == 0 || $mode == --configure ]] || fail '--yes requires --configure.'
[[ $non_interactive == 0 || $mode != --configure || $approve == 1 ]] || fail 'Unattended configuration requires --configure --yes.'
if [[ -z $setup_path ]]; then
    [[ $non_interactive == 0 ]] || fail '--setup-package is required in non-interactive mode.'
    read -r -p 'Path to the AWS setup package downloaded from Spotto: ' setup_path || true
fi
[[ -f $setup_path && -r $setup_path ]] || fail 'The setup package must be a readable JSON file.'
[[ $(wc -c < "$setup_path") -le 1048576 ]] || fail 'Setup package exceeds the 1 MiB limit.'
command -v jq >/dev/null || fail 'Install jq 1.6 or later.'
# Probe the feature we use: jq 1.5 otherwise misreports every package as invalid.
jq -ne 'IN(1; 1)' >/dev/null 2>&1 || fail 'Install jq 1.6 or later.'
aws_command=$(command -v aws) || fail 'Install AWS CLI v2.'
timeout_command=''
for timeout_name in timeout gtimeout; do
    if timeout_candidate=$(command -v "$timeout_name") &&
        "$timeout_candidate" --kill-after=1s 1s true >/dev/null 2>&1; then
        timeout_command=$timeout_candidate
        break
    fi
done
[[ -n $timeout_command ]] || fail 'Install GNU timeout (on macOS: brew install coreutils).'

working=$(mktemp -d "${TMPDIR:-/tmp}/spotto-aws.XXXXXXXX")
trap 'rm -rf -- "$working"' EXIT
# Invoked indirectly by signal traps in the main process and account subshells.
# shellcheck disable=SC2317
cancel_run() {
    local job_pid
    trap '' INT TERM
    # Both account workflows and CLI calls run as owned asynchronous jobs so wait
    # is interruptible. Account traps relay TERM to GNU timeout, which terminates
    # its CLI process group (including credential helpers), then escalates after 2s.
    for job_pid in $(jobs -pr); do kill -TERM "$job_pid" 2>/dev/null || true; done
    wait || true
    exit "$1"
}
trap 'cancel_run 130' INT
trap 'cancel_run 143' TERM
package="$working/package.json"
# Snapshot the package once; later file edits cannot alter an approved operation.
jq -se 'if length == 1 then .[0] else error("Expected one JSON document") end' "$setup_path" > "$package" 2>/dev/null || fail 'Invalid setup package JSON.'

validate_package() {
    jq -e '
        def matches($pattern): type == "string" and test($pattern);
        def credential_free:
            [.. | objects | keys[] | ascii_downcase |
                select(IN("accesskeyid", "secretaccesskey", "sessiontoken", "credentials",
                    "resolvedcredentials", "secret", "encryptedsecret", "credentialreference",
                    "accesstoken", "connectionstring", "sastoken", "storagecredential", "externalid"))] | length == 0;
        def policy_document: type == "object" and (.Statement | type == "array" and length > 0);
        . as $package |
        .configuration as $config |
        ([.. | objects | select(has("schemaVersion")) | .schemaVersion] | all(. == 1 and type == "number")) and
        .kind == "spotto.aws.setup" and .schemaVersion == 1 and
        (.companyId | matches("^[A-Za-z0-9_-]{1,256}$")) and
        ($config | credential_free) and $config.provider == "AWS" and
        $config.schemaVersion == 1 and $config.companyId == .companyId and
        ($config.estates | type == "array") and
        all($config.estates[];
            .companyId == $package.companyId and (.enabled | type == "boolean") and
            (.accounts | type == "array") and (.billingSources | type == "array") and
            all(.accounts[]; .companyId == $package.companyId and (.enabled | type == "boolean"))) and
        # Billing purposes count only when an enabled source assigns this account.
        ([ $config.estates[] | select(.enabled) | . as $estate | .accounts[] | select(.enabled) | . as $account |
            {accountId, roleArn, purposes: [.purposes[] |
                select((. != "billing-definition" or any($estate.billingSources[]; .enabled == true and .definitionRoleAccountId == $account.accountId)) and
                       (. != "billing-storage" or any($estate.billingSources[]; .enabled == true and .storageRoleAccountId == $account.accountId)))]}
        ]) as $accounts |
        (.roles | type == "array" and length >= 1 and length <= 100) and
        (.roles | length) == ($accounts | length) and
        ([.roles[].accountId] | unique | length) == (.roles | length) and
        ([$accounts[].accountId] | unique | length) == ($accounts | length) and
        all($accounts[]; (.purposes | index("resource-discovery")) != null) and
        all(.roles[]; . as $role | .setup as $setup | $setup.onboardingBundle as $bundle |
            (.accountId | matches("^[0-9]{12}$")) and
            .roleArn == ("arn:aws:iam::" + .accountId + ":role/SpottoReadOnlyRole") and
            any($accounts[]; .accountId == $role.accountId and .roleArn == $role.roleArn and
                (.purposes | sort) == ($bundle.rolePurposes | sort)) and
            $setup.provider == "AWS" and ($setup.externalId | matches("^spotto-[A-Za-z0-9-]{8,256}$")) and
            $setup.externalId == $package.roles[0].setup.externalId and
            $bundle.schemaVersion == 1 and $bundle.roleName == "SpottoReadOnlyRole" and
            ($bundle.trustedPrincipalArn | matches("^arn:aws:iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]{1,512}$")) and
            $bundle.trustedPrincipalArn == $package.roles[0].setup.onboardingBundle.trustedPrincipalArn and
            ($bundle.trustPolicy.Statement | type == "array" and length == 1) and
            ($bundle.trustPolicy.Statement[0] |
                .Effect == "Allow" and .Action == "sts:AssumeRole" and
                (.Principal | keys) == ["AWS"] and .Principal.AWS == $bundle.trustedPrincipalArn and
                .Condition.StringEquals["sts:ExternalId"] == $setup.externalId) and
            $bundle.guardrailPolicyName == "SpottoGuardrails" and ($bundle.guardrailPolicy | policy_document) and
            # Current API packages carry discovery allows in SpottoGuardrails and
            # need no managed attachments. Retain support for older generated packages.
            ($bundle.managedPolicies | type == "array" and
                all(.[]; .arn == "arn:aws:iam::aws:policy/ReadOnlyAccess" or .arn == "arn:aws:iam::aws:policy/SecurityAudit")) and
            # Missing selected policies must never look like deselected capabilities.
            ($bundle | has("billingAccessPolicy")) ==
                any($bundle.rolePurposes[]; . == "billing-definition" or . == "billing-storage") and
            ($bundle | has("commitmentsAccessPolicy")) ==
                any($bundle.rolePurposes[]; . == "commitments-planning") and
            (if $bundle | has("billingAccessPolicy") then
                $bundle.billingAccessPolicyName == "SpottoBillingExportRead" and ($bundle.billingAccessPolicy | policy_document) else true end) and
            (if $bundle | has("commitmentsAccessPolicy") then
                $bundle.commitmentsAccessPolicyName == "SpottoCommitmentsPlanning" and ($bundle.commitmentsAccessPolicy | policy_document) else true end))
    ' "$package" >/dev/null 2>&1
}
validate_package || fail 'Invalid V1 AWS setup package: check company, accounts, purposes, trust and policies. Download a fresh package from Spotto.'
company=$(jq -r .companyId "$package")
account_count=$(jq '.roles | length' "$package")
profiles="$working/profiles.json"
printf '{}\n' > "$profiles"
if [[ -n $profile_map ]]; then
    [[ -f $profile_map && -r $profile_map ]] || fail 'Profile map must be a readable JSON file.'
    [[ $(wc -c < "$profile_map") -le 65536 ]] || fail 'Profile map exceeds the 64 KiB limit.'
    jq -se 'length == 1 and (.[0] | type == "object" and
        all(to_entries[]; (.key | test("^[0-9]{12}$")) and
            (.value | type == "string" and length <= 256 and (test("[\u0000-\u001f\u007f]") | not))))' "$profile_map" >/dev/null 2>&1 || fail 'Invalid profile map: map account IDs to profile names only.'
    jq -s '.[0]' "$profile_map" > "$profiles"
fi
[[ ${#profile} -le 256 && $profile != *$'\n'* && $profile != *$'\r'* ]] || fail 'Invalid profile name.'
if [[ -z $output_path ]]; then
    output_path="SpottoAwsOnboarding-$(date -u +%Y%m%d-%H%M%S)-${working##*.}.json"
fi
output_path=$(absolute_file "$output_path") || fail 'The output directory must already exist.'
[[ ! -e $output_path && ! -L $output_path ]] || fail 'Output path already exists. Choose a new file.'
# A hard process deadline also bounds credential helpers and the CLI retry loop.
if ! "$timeout_command" --kill-after=2s 45s "$aws_command" --version > "$working/version" 2>/dev/null; then
    fail 'Could not check the AWS CLI version. Install AWS CLI v2.'
fi
[[ $(cat "$working/version") == aws-cli/2.* ]] || fail 'AWS CLI v2 is required.'

active_profile=''
aws_cli() {
    local destination=$1 allow_missing=$2 retry_missing=$3 attempt=0 exit_code code diagnostics diagnostic_line cli_pid
    local error_pattern='^An error occurred \(([A-Za-z0-9_.-]{1,80})\)'
    shift 3
    local arguments=("$@" --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 30 --region "$region")
    [[ -z $active_profile ]] || arguments+=(--profile "$active_profile")
    while :; do
        AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off AWS_CLI_ERROR_FORMAT=legacy AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=3 \
            "$timeout_command" --kill-after=2s 45s "$aws_command" "${arguments[@]}" <&0 > "$destination" 2> "$working/cli-error" &
        cli_pid=$!
        if wait "$cli_pid"; then
            if [[ ! -s $destination ]]; then printf '{}\n' > "$destination"; fi
            jq -se 'length == 1 and (.[0] | type == "object")' "$destination" >/dev/null 2>&1 || { printf 'AWS %s %s returned invalid JSON.\n' "$1" "$2" >&2; return 1; }
            return 0
        else
            exit_code=$?
        fi
        code=CliFailure
        diagnostics=$(cat "$working/cli-error")
        while IFS= read -r diagnostic_line; do
            if [[ $diagnostic_line =~ $error_pattern ]]; then code=${BASH_REMATCH[1]}; break; fi
        done <<< "$diagnostics"
        # Only known service codes may reach the console. A credential helper can
        # put arbitrary sensitive text in parentheses; an arbitrary match is not safe.
        case "$code" in
            NoSuchEntity|AccessDenied|AccessDeniedException|EntityAlreadyExists|MalformedPolicyDocument|\
            InvalidClientTokenId|ExpiredToken|ExpiredTokenException|InvalidIdentityToken|ValidationError|\
            LimitExceeded|ServiceFailure|Throttling|ThrottlingException|RequestLimitExceeded|\
            UnrecognizedClientException|SignatureDoesNotMatch) ;;
            *) code=CliFailure ;;
        esac
        if [[ $exit_code == 124 || $exit_code == 137 ]]; then code=Timeout; fi
        if [[ $code == NoSuchEntity && $allow_missing == 1 ]]; then printf 'null\n' > "$destination"; return 0; fi
        if [[ $code == NoSuchEntity && $retry_missing == 1 && $attempt -lt 4 ]]; then
            case $attempt in 0) sleep 0.25 ;; 1) sleep 0.5 ;; 2) sleep 1 ;; 3) sleep 2 ;; esac
            attempt=$((attempt + 1)); continue
        fi
        # Raw stderr may include credentials from an operator credential_process.
        printf 'AWS %s %s failed (%s). Check permissions, session expiry, SCPs and permissions boundaries.\n' "$1" "$2" "$code" >&2
        if [[ $code == Timeout && $1 == sts && $2 == get-caller-identity ]]; then
            printf 'Authenticate in your terminal first: aws sts get-caller-identity' >&2
            if [[ -n $active_profile ]]; then printf ' --profile %q' "$active_profile" >&2; fi
            printf '\nFor SSO, run aws sso login with the same profile. Complete MFA and credential-helper prompts before rerunning this script.\n' >&2
        fi
        return 1
    done
}

printf 'Spotto AWS setup — company %s, %s account(s)\n' "$company" "$account_count"
printf '%s\n' 'Review the package. Discovery permissions and guardrails come from its generated policies.'
if jq -e 'any(.roles[]; .setup.onboardingBundle | has("commitmentsAccessPolicy"))' "$package" >/dev/null; then
    printf '%s\n' 'Commitments planning can start a Savings Plans recommendation calculation; it does not purchase commitments.'
fi
if [[ -z $mode ]]; then
    mode=--check-only
    if [[ $non_interactive == 0 ]]; then
        choice=''
        read -r -p 'Mode: 1 = check configuration, 2 = configure access (default 1): ' choice || true
        [[ $choice != 2 ]] || mode=--configure
    fi
fi

# Resolve and verify ALL sessions before making any account changes.
for ((index=0; index<account_count; index++)); do
    account=$(jq -r --argjson index "$index" '.roles[$index].accountId' "$package")
    active_profile=$(jq -r --arg account "$account" --arg fallback "$profile" '.[$account] // $fallback' "$profiles")
    if [[ -z $active_profile && $account_count -gt 1 ]] && ! jq -e --arg account "$account" 'has($account)' "$profiles" >/dev/null; then
        [[ $non_interactive == 0 ]] || fail "A profile mapping is required for account $account (an empty mapped name uses the current session)."
        read -r -p "AWS profile for account $account (blank = current session): " active_profile || true
    fi
    jq --arg account "$account" --arg name "$active_profile" '. + {($account): $name}' "$profiles" > "$working/profiles-next.json"
    mv -- "$working/profiles-next.json" "$profiles"
    printf 'Checking AWS identity for account %s.\n' "$account"
    aws_cli "$working/identity.json" 0 0 sts get-caller-identity
    [[ $(jq -r .Account "$working/identity.json") == "$account" ]] || fail "AWS profile resolves to another account; expected $account. No AWS changes were made."
done

inspect_role() {
    local snapshot=$1 name foreign_external_id
    aws_cli "$working/existing.json" 1 0 iam get-role --role-name SpottoReadOnlyRole || return 1
    printf '{}\n' > "$working/inline.json"
    printf '{"AttachedPolicies":[]}\n' > "$working/managed.json"
    if jq -e '. != null' "$working/existing.json" >/dev/null; then
        # IAM permits Statement as an object or array. Normalize before traversing
        # it, and fail closed if AWS returns an uninspectable policy or tag shape.
        jq '.Role.AssumeRolePolicyDocument.Statement |= (if type == "object" then [.] else . end)' \
            "$working/existing.json" > "$working/normalized-role.json" || fail 'Could not inspect existing role trust.'
        mv -- "$working/normalized-role.json" "$working/existing.json"
        jq -e --arg arn "$role_arn" '.Role.Arn == $arn and (.Role.RoleId | type == "string" and test("^[A-Za-z0-9_]{16,128}$"))' "$working/existing.json" >/dev/null || fail 'Existing role ARN or immutable role ID is invalid.'
        jq -e '(.Role.AssumeRolePolicyDocument.Statement | type == "array" and length > 0 and all(.[]; type == "object")) and
            ((.Role.Tags // []) | type == "array" and all(.[]; (.Key | type == "string") and (.Value | type == "string")))' \
            "$working/existing.json" >/dev/null || fail 'Could not inspect existing role trust or ownership tags.'
        if jq -e --arg company "$company" 'any(.Role.Tags[]?; (.Key | ascii_downcase) == "spottocompanyid" and .Value != $company)' "$working/existing.json" >/dev/null; then fail 'This role belongs to another Spotto company.'; fi
        # IAM condition keys are case-insensitive. Inspect all operators, including
        # StringLike and set/IfExists forms; ambiguous or foreign values block adoption.
        foreign_external_id=$(jq --slurpfile target "$working/role.json" 'any(
            .Role.AssumeRolePolicyDocument.Statement[]?.Condition | .. | objects | to_entries[] |
            select(.key | ascii_downcase == "sts:externalid") | .value |
            if type == "array" then .[] else . end;
            . != $target[0].setup.externalId)' "$working/existing.json") || fail 'Could not inspect existing role company binding.'
        [[ $foreign_external_id == false ]] || fail 'Existing role trust uses another or ambiguous External ID.'
        aws_cli "$working/policy-names.json" 0 0 iam list-role-policies --role-name SpottoReadOnlyRole || return 1
        # Read only the documented Spotto policies; unrelated policies stay untouched.
        for name in SpottoGuardrails SpottoBillingExportRead SpottoCommitmentsPlanning; do
            if jq -e --arg name "$name" '.PolicyNames | index($name) != null' "$working/policy-names.json" >/dev/null; then
                aws_cli "$working/policy.json" 0 0 iam get-role-policy --role-name SpottoReadOnlyRole --policy-name "$name" || return 1
                jq --arg name "$name" --slurpfile policy "$working/policy.json" '. + {($name): $policy[0].PolicyDocument}' "$working/inline.json" > "$working/inline-next.json"
                mv -- "$working/inline-next.json" "$working/inline.json"
            fi
        done
        aws_cli "$working/managed.json" 0 0 iam list-attached-role-policies --role-name SpottoReadOnlyRole || return 1
    fi
    jq -n --slurpfile existing "$working/existing.json" --slurpfile target "$working/role.json" \
        --slurpfile inline "$working/inline.json" --slurpfile managed "$working/managed.json" --arg company "$company" '
        $existing[0].Role as $current | $target[0].setup.onboardingBundle as $bundle |
        ({SpottoGuardrails: $bundle.guardrailPolicy} +
            (if $bundle | has("billingAccessPolicy") then {SpottoBillingExportRead: $bundle.billingAccessPolicy} else {} end) +
            (if $bundle | has("commitmentsAccessPolicy") then {SpottoCommitmentsPlanning: $bundle.commitmentsAccessPolicy} else {} end)) as $desired |
        # IAM role tag keys are case-insensitive; values retain their exact case.
        (reduce $current.Tags[]? as $tag ({}; .[($tag.Key | ascii_downcase)] = $tag.Value)) as $tags |
        (any($current.Tags[]?; .Key | ascii_downcase | startswith("aws:cloudformation:"))) as $cloudformation |
        (($cloudformation | not) and $tags.spottocompanyid == $company and $tags.spottomanagedby == "Setup-SpottoAws") as $owned |
        (if $cloudformation then "CloudFormation"
            elif ($tags | has("spottomanagedby")) and $tags.spottomanagedby != "Setup-SpottoAws" then $tags.spottomanagedby
            else null end) as $manager |
        ([if $current == null then {action:"create-role", text:"Create SpottoReadOnlyRole with company trust and ownership tags"} else empty end] +
         [(["SpottoGuardrails", "SpottoBillingExportRead", "SpottoCommitmentsPlanning"][]) as $name |
            select($desired | has($name)) | select($current == null or $inline[0][$name] != $desired[$name]) |
            {action:"put-policy", name:$name, text:((if $inline[0] | has($name) then "Replace" else "Add" end) + " inline policy " + $name)}] +
         [(["SpottoBillingExportRead", "SpottoCommitmentsPlanning"][]) as $name |
            select(($inline[0] | has($name)) and ($desired | has($name) | not)) |
            {action:"delete-policy", name:$name, text:("Delete inline policy " + $name + " (purpose not selected)")}] +
         [if $current != null and $current.AssumeRolePolicyDocument != $bundle.trustPolicy then
            {action:"update-trust", text:("Replace trust policy (removes " +
                ([$current.AssumeRolePolicyDocument.Statement[] | select(. != $bundle.trustPolicy.Statement[0])] | length | tostring) + " existing statement(s) that differ)")} else empty end] +
         [if $current != null and ($owned | not) then {action:"tag", text:"Add SpottoCompanyId and SpottoManagedBy ownership tags"} else empty end] +
         [$bundle.managedPolicies[] | .arn as $arn | select(any($managed[0].AttachedPolicies[]; .PolicyArn == $arn) | not) |
            {action:"attach", name:$arn, text:("Attach AWS managed policy " + $arn)}]) as $steps |
        {exists:($current != null), owned:$owned, otherManager:$manager, steps:$steps,
         matches:([$steps[] | select(.action != "tag")] | length == 0),
         legacyPolicyArns:([$managed[0].AttachedPolicies[].PolicyArn |
            select(. == "arn:aws:iam::aws:policy/ReadOnlyAccess" or . == "arn:aws:iam::aws:policy/SecurityAudit") |
            . as $arn | select(any($bundle.managedPolicies[]; .arn == $arn) | not)] | unique),
         boundary:$current.PermissionsBoundary.PermissionsBoundaryArn,
         proof:{roleId:$current.RoleId, tags:$tags, trust:$current.AssumeRolePolicyDocument,
                boundary:$current.PermissionsBoundary, inline:$inline[0], managed:([$managed[0].AttachedPolicies[].PolicyArn] | sort), steps:$steps}}
    ' > "$snapshot"
}

apply_role() {
    local action name count step
    aws_cli "$working/identity.json" 0 0 sts get-caller-identity
    [[ $(jq -r .Account "$working/identity.json") == "$account" ]] || fail 'AWS session changed after inspection. Rerun and review.'
    inspect_role "$working/fresh.json"
    jq -e --slurpfile approved "$working/state.json" '.exists == $approved[0].exists and .proof == $approved[0].proof' "$working/fresh.json" >/dev/null || fail 'The IAM role changed after inspection. Rerun and review before applying.'
    jq '.setup.onboardingBundle.trustPolicy' "$working/role.json" > "$working/trust.json"
    count=$(jq '.steps | length' "$working/fresh.json")
    for ((step=0; step<count; step++)); do
        action=$(jq -r --argjson step "$step" '.steps[$step].action' "$working/fresh.json")
        name=$(jq -r --argjson step "$step" '.steps[$step].name // ""' "$working/fresh.json")
        case "$action" in
            create-role)
                aws_cli "$working/write.json" 0 0 iam create-role --role-name SpottoReadOnlyRole \
                    --assume-role-policy-document "file://$working/trust.json" \
                    --tags "Key=SpottoCompanyId,Value=$company" Key=SpottoManagedBy,Value=Setup-SpottoAws ;;
            put-policy)
                case "$name" in SpottoGuardrails) field=guardrailPolicy ;; SpottoBillingExportRead) field=billingAccessPolicy ;; SpottoCommitmentsPlanning) field=commitmentsAccessPolicy ;; *) fail 'Unknown inline policy.' ;; esac
                jq --arg field "$field" '.setup.onboardingBundle[$field]' "$working/role.json" > "$working/desired-policy.json"
                aws_cli "$working/write.json" 0 1 iam put-role-policy --role-name SpottoReadOnlyRole --policy-name "$name" --policy-document "file://$working/desired-policy.json" ;;
            delete-policy) aws_cli "$working/write.json" 0 0 iam delete-role-policy --role-name SpottoReadOnlyRole --policy-name "$name" ;;
            update-trust) aws_cli "$working/write.json" 0 0 iam update-assume-role-policy --role-name SpottoReadOnlyRole --policy-document "file://$working/trust.json" ;;
            tag) aws_cli "$working/write.json" 0 0 iam tag-role --role-name SpottoReadOnlyRole --tags "Key=SpottoCompanyId,Value=$company" Key=SpottoManagedBy,Value=Setup-SpottoAws ;;
            attach) aws_cli "$working/write.json" 0 1 iam attach-role-policy --role-name SpottoReadOnlyRole --policy-arn "$name" ;;
            *) fail 'Unknown IAM plan step.' ;;
        esac
    done
}

run_account() {
    local status='failed' other_manager has_other_manager exists owned matches answer
    jq --argjson index "$index" '.roles[$index]' "$package" > "$working/role.json"
    inspect_role "$working/state.json"
    jq -r --arg account "$account" '.legacyPolicyArns[] |
        "Warning: account " + $account + ": legacy attachment " + . +
        " is not requested by this package. Validate replacement access in Spotto before removing it with the owning tool; this script has not detached it."' \
        "$working/state.json" >&2
    jq -r '.steps[] | "  - " + .text' "$working/state.json"
    if jq -e '.boundary != null' "$working/state.json" >/dev/null; then
        printf 'Permissions boundary %s can deny Spotto reads; it is not changed.\n' "$(jq -r .boundary "$working/state.json")"
    fi
    other_manager=$(jq -r '.otherManager // ""' "$working/state.json")
    has_other_manager=$(jq '.otherManager != null' "$working/state.json")
    if [[ $has_other_manager == true && -z $other_manager ]]; then other_manager='another tool (empty SpottoManagedBy tag)'; fi
    exists=$(jq .exists "$working/state.json"); owned=$(jq .owned "$working/state.json"); matches=$(jq .matches "$working/state.json")
    if [[ $has_other_manager == true ]]; then printf 'Role is managed by %s; apply changes with that tool.\n' "$other_manager"; fi
    if [[ $mode == --check-only ]]; then
        if [[ $matches == true ]]; then status=configuration-matches; else status=changes-required; fi
    elif [[ $matches == true && ( $owned == true || $has_other_manager == true || $repair == 0 ) ]]; then
        status=configured
    elif [[ $has_other_manager == true ]]; then
        fail "Role is managed by $other_manager; --repair-existing-role cannot adopt it."
    elif [[ $exists == true && $owned == false && $repair == 0 ]]; then
        fail 'Existing role is not script-owned. Review and use --repair-existing-role to explicitly adopt it.'
    elif [[ $mode == --dry-run ]]; then
        status=planned
    else
        answer=n
        if [[ $approve == 1 ]]; then answer=yes
        elif [[ $non_interactive == 0 ]]; then read -r -p "Apply these IAM changes to account $account? [y/N]: " answer || true
        fi
        case "$answer" in y|Y|yes|YES) apply_role; status=configured ;; *) status=planned ;; esac
    fi
    printf '%s\n' "$status" > "$working/status"
}

results="$working/results.jsonl"
: > "$results"
failed=0
for ((index=0; index<account_count; index++)); do
    account=$(jq -r --argjson index "$index" '.roles[$index].accountId' "$package")
    role_arn=$(jq -r --argjson index "$index" '.roles[$index].roleArn' "$package")
    active_profile=$(jq -r --arg account "$account" '.[$account]' "$profiles")
    printf 'Account %s:\n' "$account"
    rm -f -- "$working/status"
    # An interruptible wait lets cancellation reach the active workflow immediately.
    # Restore stdin explicitly: unattended Bash jobs otherwise read /dev/null.
    # The main process alone owns temporary-directory cleanup.
    (trap - EXIT; trap 'cancel_run 143' TERM; set -e; run_account) <&0 &
    account_pid=$!
    if wait "$account_pid"; then account_exit=0; else account_exit=$?; fi
    status=failed
    if [[ $account_exit == 0 && -f $working/status ]]; then status=$(cat "$working/status"); fi
    if [[ $status == failed ]]; then failed=1; fi
    printf 'Account %s: %s\n' "$account" "$status"
    jq -n --arg account "$account" --arg arn "$role_arn" --arg status "$status" \
        '{accountId:$account, roleArn:$arn, status:$status}' >> "$results"
done
jq -n --slurpfile package "$package" --slurpfile results "$results" \
    '{kind:"spotto.aws.manual-onboarding", schemaVersion:1, companyId:$package[0].companyId,
      configuration:$package[0].configuration, results:$results}' > "$working/handoff.json"
[[ $(wc -c < "$working/handoff.json") -le 1048576 ]] || fail 'Result exceeds the 1 MiB portal limit.'
# noclobber uses exclusive creation, including when a file appears after preflight.
(set -C; cat "$working/handoff.json" > "$output_path") || fail 'Could not create results file. Existing files are never overwritten.'
printf 'Results saved to %s\n' "$output_path"
printf '%s\n' 'Paste the complete JSON into Setup Results JSON in Spotto and select Read Setup Results.' \
    'Then select Create/Update for live role, billing and resource validation.' \
    'Configured describes IAM setup only. SCPs, boundaries, bucket policies and KMS policies can still deny access.'
exit "$failed"
