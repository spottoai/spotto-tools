#Requires -Version 7.0
<#
.SYNOPSIS
Connects, updates, repairs or checks an AWS account (and optionally its organization)
by deploying the hosted CloudFormation templates with your own AWS CLI session.
Requires AWS CLI v2. Rerunning updates existing stacks to the latest template version.

.PARAMETER CostData
create (default) makes a new billing export; existing uses -ExportArn. Billing is required: none only keeps
an older connection without billing, with a warning.

.PARAMETER Check
Report template version, drift and member account status. Changes nothing.

.PARAMETER Repair
Re-apply the role's trust and policies, or recreate the role if it was deleted.

.EXAMPLE
./Connect-SpottoAws.ps1 -Deployment dev-au -ExternalId spotto-<uuid> -TrustedPrincipalArn arn:aws:iam::<account>:user/<name>

.EXAMPLE
./Connect-SpottoAws.ps1 -Deployment dev-au -Check
#>
[CmdletBinding()]
param(
    [string]$ExternalId,
    [string]$TrustedPrincipalArn,
    [ValidateSet('dev-au', 'prod-au', 'prod-us', 'prod-eu')][string]$Deployment,
    [string]$RegistrationTopicArn,
    [Alias('Profile')][string]$AwsProfile,
    [ValidateSet('create', 'existing', 'none')][string]$CostData,
    [string]$ExportArn,
    [ValidateSet('yes', 'no')][string]$ConnectMembers,
    [string[]]$OrganizationalUnitIds,
    [string]$RoleName,
    [switch]$Check,
    [switch]$Repair,
    [switch]$Yes,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$TemplateBaseUrl = 'https://spotto-aws-onboarding.s3.amazonaws.com/cloudformation/'
$Region = ''
# The AWS managed read baseline every role attaches (the templates' ManagedPolicyArns).
$ManagedPolicyArns = 'arn:aws:iam::aws:policy/job-function/ViewOnlyAccess', 'arn:aws:iam::aws:policy/SecurityAudit'

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
if ($Check -and $Repair) { Write-Host 'Use either -Check or -Repair.'; exit 1 }
function Stop-Connect([string]$Message) { Write-Host "`nError: $Message" -ForegroundColor Red; exit 1 }
if (-not $Deployment) { Stop-Connect '-Deployment is required: dev-au, prod-au, prod-us or prod-eu. Copy the command from the portal.' }
$Deployment = $Deployment.ToLowerInvariant()
$Region = switch ($Deployment) { 'dev-au' { 'ap-southeast-2' } 'prod-au' { 'ap-southeast-2' } 'prod-us' { 'us-east-1' } 'prod-eu' { 'eu-north-1' } }
$expectedTopic = "arn:aws:sns:${Region}:715809501612:spotto-aws-connect-$Deployment"
if (-not $RegistrationTopicArn) { $RegistrationTopicArn = $expectedTopic }
if ($RegistrationTopicArn -cne $expectedTopic) { Stop-Connect 'Registration topic does not match -Deployment. Copy the command from the portal.' }
$ConnectStack = "SpottoConnect-$Deployment"; $BillingStack = "SpottoBillingAccess-$Deployment"
$MembersStack = "SpottoMemberAccounts-$Deployment"; $ExportStack = "SpottoBillingExport-$Deployment"
# The role name is the same in every deployment; stacks and billing resources carry the deployment.
$DefaultRoleName = "SpottoReadOnlyRole"; $CreatedExportName = "spotto-cur2-$Deployment"

function Invoke-Aws([string[]]$Arguments, [string]$AtRegion = $Region) {
    if ($Arguments[0] -in 'bcm-data-exports', 'organizations', 'account') { $AtRegion = 'us-east-1' }
    if ($Arguments[0] -eq 'cloudformation' -and (@($Arguments | Where-Object { $_ -eq $ExportStack -or $_ -like '*spotto-aws-billing-export.template.json' }).Count -gt 0)) { $AtRegion = 'us-east-1' }

    $all = @(); if ($AwsProfile) { $all += '--profile', $AwsProfile }
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out = & aws @all --region $AtRegion @Arguments 2>$errFile
        [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = (($out | ForEach-Object { "$_" }) -join "`n").Trim(); Error = (Get-Content -Raw $errFile) }
    } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
}
function Test-SelectsResourceIds([string]$Query) { # true when a Data Exports query selects line_item_resource_id (bare or as an alias) or every column
    $m = [regex]::Match($Query, '^\s*SELECT\s+([\s\S]+?)\s+FROM\s+', 'IgnoreCase')
    if (-not $m.Success) { return $false }
    $items = @(); $depth = 0; $current = ''
    foreach ($c in ($m.Groups[1].Value + ',').ToCharArray()) {
        if ($c -in '(', '[') { $depth++ }
        if ($c -in ')', ']') { $depth-- }
        if ($c -eq ',' -and $depth -eq 0) { $items += $current; $current = '' } else { $current += $c }
    }
    foreach ($item in $items) {
        $name = $item.Trim()
        $alias = [regex]::Match($name, '\s+AS\s+"?([A-Za-z0-9_]+)"?$', 'IgnoreCase')
        if ($alias.Success) { $name = $alias.Groups[1].Value }
        if ($name.Trim('"').ToLowerInvariant() -in '*', 'line_item_resource_id') { return $true }
    }
    return $false
}
function Confirm-Step([string]$Question, [bool]$Default = $true) {
    if ($Yes) { return $Default }
    $answer = Read-Host "$Question $(if ($Default) { '[Y/n]' } else { '[y/N]' })"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLower() -in 'y', 'yes'
}
function Get-Exports { (Invoke-Aws 'bcm-data-exports', 'list-exports', '--query', 'Exports[].[ExportName,ExportArn]', '--output', 'text').Text -split "`n" | Where-Object { $_ -and $_ -ne 'None' } }
$StackErrors = @{}
function Get-StackStatus([string]$Stack) { # the status, NONE when the stack doesn't exist, or UNREADABLE (reason in $StackErrors)
    $r = Invoke-Aws 'cloudformation', 'describe-stacks', '--stack-name', $Stack, '--query', 'Stacks[0].StackStatus', '--output', 'text'
    if ($r.Ok) { $r.Text } # Preserve failed access state for retained-storage recovery.
    elseif ($r.Error -match 'does not exist') { 'NONE' }
    else { $StackErrors[$Stack] = "$($r.Error)".Trim(); 'UNREADABLE' }
}
function Get-StackParams([string]$Stack) {
    $map = [ordered]@{}
    $r = Invoke-Aws 'cloudformation', 'describe-stacks', '--stack-name', $Stack, '--query', 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]', '--output', 'text'
    if ($r.Ok) { foreach ($line in ($r.Text -split "`n" | Where-Object { $_ })) { $k, $v = $line -split "`t", 2; $map[$k] = [string]$v } }
    $map
}
function Get-StackOutput([string]$Stack, [string]$Key) {
    $v = (Invoke-Aws 'cloudformation', 'describe-stacks', '--stack-name', $Stack, '--query', "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue | [0]", '--output', 'text').Text
    if ($v -eq 'None') { '' } else { $v }
}
function Get-TemplateVersion([string[]]$Source) { # '--template-url', <url> or '--stack-name', <name>; Version is '' when the template has none
    $r = Invoke-Aws (@('cloudformation', 'get-template-summary') + $Source + @('--query', 'Metadata', '--output', 'text'))
    $version = if ($r.Ok -and $r.Text -match '"TemplateVersion"\s*:\s*"([^"]+)"') { $Matches[1] } else { '' }
    [pscustomobject]@{ Ok = $r.Ok; Version = $version; Error = "$($r.Error)".Trim() }
}
function Get-RoleState([string]$Name) { # present or missing; any other failure stops, because only NoSuchEntity proves the role is gone
    $r = Invoke-Aws 'iam', 'get-role', '--role-name', $Name, '--query', 'Role.Arn', '--output', 'text'
    if ($r.Ok) { return 'present' }
    if ($r.Error -match 'NoSuchEntity') { return 'missing' }
    Stop-Connect "Couldn't check whether role $Name exists: $("$($r.Error)".Trim())"
}
function Get-Drift([string]$Stack) { # returns @{ Status; Reason; Resources }; UNKNOWN means it couldn't be read
    $driftRegion = if ($Stack -eq $ExportStack) { 'us-east-1' } else { $Region }
    $id = Invoke-Aws 'cloudformation', 'detect-stack-drift', '--stack-name', $Stack, '--query', 'StackDriftDetectionId', '--output', 'text'
    if (-not $id.Ok) { return @{ Status = 'UNKNOWN'; Reason = "$($id.Error)".Trim(); Resources = @() } }
    for ($i = 0; $i -lt 60; $i++) {
        $poll = Invoke-Aws 'cloudformation', 'describe-stack-drift-detection-status', '--stack-drift-detection-id', $id.Text, '--query', '[DetectionStatus,StackDriftStatus]', '--output', 'text' -AtRegion $driftRegion
        if (-not $poll.Ok) { return @{ Status = 'UNKNOWN'; Reason = "$($poll.Error)".Trim(); Resources = @() } }
        $r = $poll.Text -split "`t"
        if ($r[0] -ne 'DETECTION_IN_PROGRESS') { break }
        Start-Sleep -Seconds 5
    }
    if (-not ($r.Count -gt 1 -and $r[1] -in 'IN_SYNC', 'DRIFTED', 'NOT_CHECKED')) { return @{ Status = 'UNKNOWN'; Reason = "drift detection ended with $($r[0])"; Resources = @() } }
    $status = $r[1]
    $resources = (Invoke-Aws 'cloudformation', 'describe-stack-resource-drifts', '--stack-name', $Stack, '--stack-resource-drift-status-filters', 'MODIFIED', 'DELETED', '--query', 'StackResourceDrifts[].[LogicalResourceId,StackResourceDriftStatus]', '--output', 'text').Text -split "`n" |
        Where-Object { $_ } | ForEach-Object { $logicalId, $st = $_ -split "`t"; "    $logicalId was $($st.ToLower()) outside CloudFormation" }
    @{ Status = $status; Resources = @($resources) }
}
function Format-Drift([string]$Status) { $Status.Replace('_', ' ').ToLower() }

if ($ExternalId -and $ExternalId -notmatch '^spotto-[0-9a-f-]{36}$') { Stop-Connect '-ExternalId must look like spotto-<uuid>. Copy it from the portal.' }
if ($TrustedPrincipalArn -and $TrustedPrincipalArn -notmatch '^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/.+$') { Stop-Connect '-TrustedPrincipalArn must be an IAM user or role ARN. Copy it from the portal.' }
if ($RoleName -and $RoleName -notmatch '^[A-Za-z0-9+=,.@_-]{1,64}$') { Stop-Connect '-RoleName is not a valid IAM role name.' }
if ($ExportArn -and -not $CostData) { $CostData = 'existing' }
if ($ExportArn -and $CostData -ne 'existing') { Stop-Connect '-ExportArn needs -CostData existing.' }
$OrganizationalUnitIds = @($OrganizationalUnitIds | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($ou in $OrganizationalUnitIds) { if ($ou -notmatch '^(r-[0-9a-z]{4,32}|ou-[0-9a-z]{4,32}-[0-9a-z]{8,32})$') { Stop-Connect "Not an OU or root ID: $ou" } }
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { Stop-Connect 'AWS CLI v2 is required. Open AWS CloudShell, or install it from https://aws.amazon.com/cli/.' }
if ((& aws --version 2>&1 | Out-String) -notmatch '^aws-cli/2') { Stop-Connect 'AWS CLI v2 is required.' }

# 1. Who am I, and which template version is current?
$identity = Invoke-Aws 'sts', 'get-caller-identity', '--query', '[Account,Arn]', '--output', 'text'
if (-not $identity.Ok) { Stop-Connect "Can't read your AWS session. Sign in first (aws sso login, or open CloudShell). AWS said: $($identity.Error)" }
$AccountId, $CallerArn = $identity.Text -split "`t"
Write-Host "Signed in to account $AccountId as $CallerArn"
$latestRead = Get-TemplateVersion '--template-url', "${TemplateBaseUrl}spotto-aws-connect.template.json"
$Latest = $latestRead.Version
if (-not $latestRead.Ok -and -not $Check) { Stop-Connect "Couldn't read the template version for the latest templates: $($latestRead.Error)" }
$TemplateUrl = if ($Latest) { "${TemplateBaseUrl}v$Latest/" } else { $TemplateBaseUrl }
$ConnectStatus = Get-StackStatus $ConnectStack
$BillingStatus = Get-StackStatus $BillingStack
$MembersStatus = Get-StackStatus $MembersStack
$ExportStatus = Get-StackStatus $ExportStack

# 2. -Check: read-only report. Anything that can't be read counts as a problem, never as healthy.
if ($Check) {
    if ($ConnectStatus -eq 'UNREADABLE') { Write-Host "Couldn't read stack ${ConnectStack}: $($StackErrors[$ConnectStack])"; exit 1 }
    if ($ConnectStatus -eq 'NONE') { Write-Host "Not connected: there's no $ConnectStack stack in account $AccountId ($Region)."; exit 1 }
    $problems = $false; $update = $false; $unread = $false; $pending = $false
    if (-not $latestRead.Ok) { Write-Host "Couldn't read the template version for the latest templates: $($latestRead.Error)"; $unread = $true }
    else { Write-Host "Latest template version: $(if ($Latest) { $Latest } else { 'unknown' })" }
    foreach ($stack in $ConnectStack, $BillingStack, $MembersStack, $ExportStack) {
        $status = Get-StackStatus $stack
        if ($status -eq 'NONE') {
            if ($stack -eq $ExportStack -and ((Get-StackParams $ConnectStack)['CostData'] -eq 'CreateExport' -or (Get-StackParams $ConnectStack)['RetainedBillingStorage'] -eq 'true')) { Write-Host "Required billing export stack $ExportStack is missing. Rerun the connect command to complete billing setup."; $problems = $true }
            if ($stack -eq $BillingStack -and (Get-StackParams $ConnectStack)['RetainedBillingStorage'] -eq 'true') { Write-Host "Required retained billing access stack $BillingStack is missing. Rerun the connect command to complete billing setup."; $problems = $true }
            continue
        }
        if ($status -eq 'UNREADABLE') { Write-Host "Couldn't read stack ${stack}: $($StackErrors[$stack])"; $unread = $true; continue }
        $read = Get-TemplateVersion '--stack-name', $stack
        $version = $read.Version
        $note = 'up to date'
        if (-not $read.Ok) { Write-Host "Couldn't read the template version for ${stack}: $($read.Error)"; $unread = $true; $note = 'version unreadable' }
        elseif ($Latest -and $version -ne $Latest) { $note = 'update available'; $update = $true }
        elseif (-not $Latest) { $note = 'latest unknown' }
        if ($status -notin 'CREATE_COMPLETE', 'UPDATE_COMPLETE') { $note += ", stack is $status"; $problems = $true }
        Write-Host "${stack}: version $(if ($version) { $version } else { 'unknown' }) ($note)"
        $drift = Get-Drift $stack
        if ($drift.Status -eq 'UNKNOWN') { Write-Host "  Couldn't read drift status: $($drift.Reason)"; $unread = $true }
        else { Write-Host "  Drift: $(Format-Drift $drift.Status)" }
        $drift.Resources | ForEach-Object { Write-Host $_ }
        if ($drift.Status -eq 'DRIFTED') { $problems = $true } # NOT_CHECKED isn't drift
    }
    $checkRole = (Get-StackParams $ConnectStack)['RoleName']
    if (-not $checkRole) { $checkRole = $DefaultRoleName }
    $attached = Invoke-Aws 'iam', 'list-attached-role-policies', '--role-name', $checkRole, '--query', 'AttachedPolicies[].PolicyArn', '--output', 'text'
    if (-not $attached.Ok) {
        Write-Host "Couldn't read the managed policies attached to ${checkRole}: $("$($attached.Error)".Trim())"; $unread = $true
    } else {
        $attachedArns = @($attached.Text -split '\s+' | Where-Object { $_ -and $_ -ne 'None' })
        $missing = @($ManagedPolicyArns | Where-Object { $_ -notin $attachedArns } | ForEach-Object { ($_ -split '/')[-1] })
        if (-not $missing.Count) { Write-Host "${checkRole}: AWS managed policies ViewOnlyAccess and SecurityAudit attached" }
        else {
            Write-Host "$checkRole is missing the AWS managed $($missing -join ' and ') $(if ($missing.Count -gt 1) { 'policies' } else { 'policy' })"
            $problems = $true
        }
    }
    if ($MembersStatus -notin 'NONE', 'UNREADABLE') {
        $list = Invoke-Aws 'cloudformation', 'list-stack-instances', '--stack-set-name', $MembersStack, '--query', 'Summaries[].[Account,Status,StackInstanceStatus.DetailedStatus]', '--output', 'text'
        if (-not $list.Ok) {
            Write-Host "Couldn't read member account status: $("$($list.Error)".Trim())"; $unread = $true
        } else {
            # failed first, then in progress (PENDING/RUNNING or any status not listed), then OK (CURRENT) and outdated
            $rows = @($list.Text -split "`n" | Where-Object { $_ -and $_ -ne 'None' } | ForEach-Object {
                $c = $_ -split "`t"
                $class = if ($c[2] -in 'FAILED', 'FAILED_IMPORT', 'CANCELLED', 'INOPERABLE' -or $c[1] -eq 'INOPERABLE') { 'failed' }
                    elseif ($c[2] -in 'PENDING', 'RUNNING') { 'progress' } elseif ($c[1] -eq 'CURRENT') { 'ok' } elseif ($c[1] -eq 'OUTDATED') { 'outdated' } else { 'progress' }
                [pscustomobject]@{ Class = $class; Account = $c[0]; Detail = $c[2] }
            })
            $n = @{}; foreach ($k in 'ok', 'outdated', 'failed', 'progress') { $n[$k] = @($rows | Where-Object Class -eq $k).Count }
            Write-Host "Member accounts: $($n.ok) OK, $($n.outdated) outdated, $($n.failed) failed, $($n.progress) in progress"
            $rows | Where-Object Class -eq 'failed' | ForEach-Object { Write-Host "    $($_.Account): $($_.Detail)" }
            if ($n.outdated) { $update = $true }
            if ($n.failed) { $problems = $true }
            if ($n.progress) { $pending = $true }
        }
    }
    Write-Host ''
    if (-not ($problems -or $unread -or $update -or $pending)) { Write-Host 'Everything is up to date and in sync.' -ForegroundColor Green; exit 0 }
    if ($update) { Write-Host 'Update available: rerun this command without -Check.' }
    if ($pending) { Write-Host 'Member account deployment is in progress: rerun -Check shortly.' }
    if ($unread) { Write-Host "Some status couldn't be read, so health isn't confirmed. Check your permissions and rerun -Check." }
    if ($problems) { Write-Host 'Access has drifted or failed: rerun with -Repair.' }
    exit 1
}
foreach ($stack in $ConnectStack, $BillingStack, $MembersStack, $ExportStack) {
    if ((Get-StackStatus $stack) -eq 'UNREADABLE') { Stop-Connect "Couldn't read stack ${stack}: $($StackErrors[$stack])" }
}

# 3. Management, member or standalone?
$OrgId = ''; $Kind = 'standalone'
$org = Invoke-Aws 'organizations', 'describe-organization', '--query', 'Organization.[Id,MasterAccountId]', '--output', 'text'
if ($org.Ok) {
    $OrgId, $ManagementId = $org.Text -split "`t"
    $Kind = if ($ManagementId -eq $AccountId) { 'management' } else { 'member' }
} elseif ($org.Error -notmatch 'AWSOrganizationsNotInUseException') {
    Write-Host "Warning: couldn't read the organization, so this account is treated as standalone." -ForegroundColor Yellow
}
switch ($Kind) {
    'management' { Write-Host "This is the management account of organization $OrgId." }
    'standalone' { Write-Host "This account isn't part of an organization." }
    'member' {
        Write-Host "`nWarning: this is a member account of organization $OrgId (management account $ManagementId)." -ForegroundColor Yellow
        Write-Host 'Connect the management account instead to see costs for the whole organization.'
        if ($ConnectStatus -eq 'NONE' -and -not (Confirm-Step 'Continue with this account only?')) { exit 1 }
    }
}

# 4. What to deploy
$ConnectPrev = Get-StackParams $ConnectStack
$RepairToken = ''; $Recreate = $false; $ReuseBilling = $ConnectPrev['RetainedBillingStorage'] -eq 'true' -and (-not $CostData -or $CostData -eq 'create')
if ($ConnectStatus -eq 'NONE') {
    if ($Repair) { Stop-Connect "Nothing to repair: there's no $ConnectStack stack in account $AccountId. Run without -Repair to connect." }
    if (-not $ExternalId -or -not $TrustedPrincipalArn) { Stop-Connect '-ExternalId and -TrustedPrincipalArn are required to connect. Copy the command from the portal.' }
    if (-not $RoleName) { $RoleName = $DefaultRoleName }
} else {
    $prevRole = if ($ConnectPrev['RoleName']) { $ConnectPrev['RoleName'] } else { $DefaultRoleName }
    if ($RoleName -and $RoleName -ne $prevRole) { Stop-Connect "The role is named $prevRole. Renaming it isn't supported." }
    $RoleName = $prevRole
    $deployedRead = Get-TemplateVersion '--stack-name', $ConnectStack
    if (-not $deployedRead.Ok) { Stop-Connect "Couldn't read the template version for ${ConnectStack}: $($deployedRead.Error)" }
    $deployed = $deployedRead.Version
    Write-Host "Found $ConnectStack (version $(if ($deployed) { $deployed } else { 'unknown' })); latest is $(if ($Latest) { $Latest } else { 'unknown' })."
    if ($ConnectStatus -eq 'ROLLBACK_COMPLETE') {
        if (-not $deployed) { Stop-Connect 'Refusing to recreate an unversioned failed stack; review retained resources explicitly.' }
        $Recreate = $true
    }
    if ($Repair) {
        Write-Host 'Checking for changes made outside CloudFormation...'
        foreach ($stack in $ConnectStack, $BillingStack) {
            if ((Get-StackStatus $stack) -eq 'NONE') { continue }
            $drift = Get-Drift $stack
            Write-Host "  ${stack}: $(Format-Drift $drift.Status)"; $drift.Resources | ForEach-Object { Write-Host $_ }
        }
        $RepairToken = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ((Get-RoleState $RoleName) -eq 'missing') {
            $Recreate = $true
            if (-not $deployed) { Stop-Connect "The role $RoleName was deleted, and this stack predates retained exports, so deleting it could remove the billing export. Create an empty IAM role named $RoleName, then rerun with -Repair." }
        }
    }
}

if ($ConnectStatus -eq 'NONE' -or $CostData) {
    if (-not $CostData) { $CostData = if (Confirm-Step 'Create a new billing export (recommended)?') { 'create' } else { 'existing' } }
    if ($CostData -eq 'existing' -and -not $ExportArn) {
        $exports = @(Get-Exports)
        if ($exports.Count -eq 0) { Stop-Connect 'No billing exports found in this account. Billing is required: rerun with -CostData create.' }
        if ($Yes) {
            if ($exports.Count -ne 1) { Stop-Connect 'Several exports found. Pass one with -ExportArn.' }
            $ExportArn = ($exports[0] -split "`t")[1]
        } else {
            Write-Host 'Existing billing exports:'
            for ($i = 0; $i -lt $exports.Count; $i++) { Write-Host "  $($i + 1)) $(($exports[$i] -split "`t")[0])" }
            $pick = Read-Host 'Choose an export (number)'
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $exports.Count) { $ExportArn = ($exports[[int]$pick - 1] -split "`t")[1] }
            else { Stop-Connect "Not a valid choice: $pick" }
        }
    }
}
# Billing is required. A new connection must create or name an export; an existing one without billing
# still updates (CostData=None stays valid in the template) but is warned.
$billingFix = 'Rerun with -CostData create (recommended), or -CostData existing -ExportArn <arn>.'
$noBilling = ($CostData -eq 'none' -and $BillingStatus -eq 'NONE') -or
    (-not $CostData -and -not $ReuseBilling -and $ConnectPrev['CostData'] -ne 'CreateExport' -and $BillingStatus -eq 'NONE')
if ($noBilling) {
    if ($ConnectStatus -eq 'NONE') { Stop-Connect "Billing is required to connect AWS. $billingFix" }
    Write-Host "Warning: this connection has no billing data, and billing is required. $billingFix" -ForegroundColor Yellow
}
$KmsKeyArn = ''
if ($CostData -eq 'existing') {
    $e = Invoke-Aws 'bcm-data-exports', 'get-export', '--export-arn', $ExportArn, '--query', 'Export.[Name,DestinationConfigurations.S3Destination.S3Bucket,DestinationConfigurations.S3Destination.S3Prefix,DestinationConfigurations.S3Destination.S3Region,DestinationConfigurations.S3Destination.S3OutputConfigurations.Format,DataQuery.TableConfigurations.COST_AND_USAGE_REPORT.TIME_GRANULARITY,DataQuery.TableConfigurations.COST_AND_USAGE_REPORT.INCLUDE_RESOURCES]', '--output', 'text'
    if (-not $e.Ok) { Stop-Connect "Can't read export $ExportArn. AWS said: $($e.Error)" }
    $ExportName, $Bucket, $Prefix, $BucketRegion, $Format, $Granularity, $IncludeResources = $e.Text -split "`t"
    if ($Prefix -eq 'None') { $Prefix = '' }
    if ($Format -ne 'PARQUET') { Stop-Connect "Export $ExportName isn't Parquet. Parquet is required; create a new export instead (-CostData create)." }
    if ($Granularity -notin 'DAILY', 'HOURLY') { Stop-Connect "Export $ExportName isn't a daily or hourly CUR 2.0 export. Monthly isn't supported; create a new export instead (-CostData create)." }
    if ($IncludeResources -ne 'TRUE') { Stop-Connect "Export $ExportName doesn't include resource IDs (INCLUDE_RESOURCES). Turn them on in the export, or create a new export instead (-CostData create)." }
    # INCLUDE_RESOURCES only makes the column available; the query must select it too.
    $q = Invoke-Aws 'bcm-data-exports', 'get-export', '--export-arn', $ExportArn, '--query', 'Export.DataQuery.QueryStatement', '--output', 'text'
    if (-not $q.Ok) { Stop-Connect "Can't read the query of export $ExportArn. AWS said: $($q.Error)" }
    if (-not (Test-SelectsResourceIds $q.Text)) { Stop-Connect "Export $ExportName doesn't select line_item_resource_id, so costs can't be attributed to resources. Add the column to the export, or create a new export instead (-CostData create)." }
    # The billing role needs decrypt on the exact key that encrypts the bucket, so a key that can't be found stops here.
    $sse = Invoke-Aws 's3api', 'get-bucket-encryption', '--bucket', $Bucket, '--query', 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.[SSEAlgorithm,KMSMasterKeyID]', '--output', 'text' -AtRegion $BucketRegion
    $key = ''
    if ($sse.Ok) { $key = "$(($sse.Text -split "`t")[1])".Trim(); if ($key -eq 'None') { $key = '' } }
    elseif ($sse.Error -notmatch 'ServerSideEncryptionConfigurationNotFoundError') {
        Stop-Connect "Can't read the default encryption of bucket $Bucket, so the KMS decrypt permission can't be set. AWS said: $("$($sse.Error)".Trim())"
    }
    if ($key -match '^arn:aws[a-z-]*:kms:[^:]*:[^:]*:key/') { $KmsKeyArn = $key }
    elseif ($key) {
        # A key ID or an alias (name or ARN): resolve it to the key ARN in the key's Region.
        $keyRegion = if ($key -like 'arn:*') { ($key -split ':')[3] } else { $BucketRegion }
        $d = Invoke-Aws 'kms', 'describe-key', '--key-id', $key, '--query', 'KeyMetadata.Arn', '--output', 'text' -AtRegion $keyRegion
        if (-not $d.Ok) { Stop-Connect "Can't resolve the KMS key $key that encrypts bucket $Bucket. AWS said: $("$($d.Error)".Trim())" }
        if ($d.Text -notmatch '^arn:aws[a-z-]*:kms:[^:]*:[^:]*:key/') { Stop-Connect "KMS key $key that encrypts bucket $Bucket didn't resolve to a key ARN: $($d.Text)" }
        $KmsKeyArn = $d.Text
    }
}

# Member accounts: asked on first connect; on reruns only existing or explicitly requested.
if ($Kind -eq 'management') {
    if ($MembersStatus -ne 'NONE') { if (-not $ConnectMembers) { $ConnectMembers = 'yes' } }
    elseif (-not $ConnectMembers -and $ConnectStatus -eq 'NONE') { $ConnectMembers = if (Confirm-Step 'Also connect every member account (StackSet)?') { 'yes' } else { 'no' } }
    if ($ConnectMembers -eq 'yes' -and $OrganizationalUnitIds.Count -eq 0 -and $MembersStatus -eq 'NONE') {
        $roots = Invoke-Aws 'organizations', 'list-roots', '--query', 'Roots[0].Id', '--output', 'text'
        if (-not $roots.Ok) { Stop-Connect "Can't read the organization root. AWS said: $($roots.Error)" }
        $OrganizationalUnitIds = @($roots.Text)
    }
} else {
    if ($ConnectMembers -eq 'yes') { Write-Host 'Note: member accounts can only be connected from the management account. Skipping them.' }
    $ConnectMembers = 'no'
}
$OuList = $OrganizationalUnitIds -join ','

# 5. Checks that would otherwise fail halfway through
if ($ConnectStatus -eq 'NONE' -and (Get-RoleState $RoleName) -eq 'present') { Stop-Connect "An IAM role named $RoleName already exists (perhaps from an earlier setup). Delete it, or pass -RoleName with a new name." }
if ($CostData -eq 'create' -and -not $ReuseBilling -and $ConnectPrev['CostData'] -ne 'CreateExport' -and (@(Get-Exports) | Where-Object { ($_ -split "`t")[0] -eq $CreatedExportName })) {
    Stop-Connect 'An export named $CreatedExportName already exists (kept from an earlier setup). Use it with -CostData existing.'
}
$EnableTrustedAccess = $ConnectMembers -eq 'yes' -and (Invoke-Aws 'cloudformation', 'describe-organizations-access', '--query', 'Status', '--output', 'text').Text -ne 'ENABLED'
$cfnCostData = switch ($CostData) { 'create' { 'CreateExport' } 'existing' { 'None' } 'none' { 'None' } default { '' } }
$recreateCost = if ($cfnCostData) { $cfnCostData } else { $ConnectPrev['CostData'] }
if ($ReuseBilling -or ($Recreate -and $recreateCost -eq 'CreateExport' -and $ConnectPrev['CostData'] -eq 'CreateExport')) {
    $retainedBucket = "spotto-billing-$AccountId-$Deployment"
    $head = Invoke-Aws 's3api', 'head-bucket', '--bucket', $retainedBucket, '--expected-bucket-owner', $AccountId
    if ($head.Ok) {
        $location = Invoke-Aws 's3api', 'get-bucket-location', '--bucket', $retainedBucket, '--expected-bucket-owner', $AccountId, '--query', 'LocationConstraint', '--output', 'text'
        if (-not $location.Ok) { Stop-Connect "Couldn't verify the retained billing bucket region." }
        $bucketRegion = if ($location.Text -in '', 'None') { 'us-east-1' } elseif ($location.Text -eq 'EU') { 'eu-west-1' } else { $location.Text }
        if ($bucketRegion -ne $Region) { Stop-Connect "The retained billing bucket is outside $Region. Nothing was deleted." }
        if (-not (Invoke-Aws 's3api', 'get-bucket-policy', '--bucket', $retainedBucket, '--expected-bucket-owner', $AccountId).Ok) { Stop-Connect 'The retained billing bucket needs its delivery policy restored. Review it before retrying; nothing was deleted.' }
        $ReuseBilling = $true
    } elseif ($ReuseBilling -or $head.Error -notmatch '404|NoSuchBucket|Not Found') { Stop-Connect "Couldn't verify retained bucket ownership. Nothing was deleted." }
}


if ($ReuseBilling) {
    $cfnCostData = 'None'
    $CostData = 'existing'; $ExportName = $CreatedExportName; $Bucket = $retainedBucket; $Prefix = 'cur2'; $KmsKeyArn = ''
}

# 6. Plan
function Get-Verb([string]$Status) { if ($Status -eq 'NONE') { 'Create' } else { 'Update' } }
$prefixPath = if ($Prefix) { "$Prefix/" } else { '' }
Write-Host "`nPlan (CloudFormation, $Region, template version $(if ($Latest) { $Latest } else { 'latest' })):"
if ($Recreate) {
    Write-Host "  - Recover the access stack: remove and recreate $ConnectStack (billing bucket and export are kept)"
    Write-Host '  - Recreate $BillingStack for the kept billing export'
} else {
    Write-Host "  - $(Get-Verb $ConnectStatus) ${ConnectStack}: read-only IAM role $RoleName in account $AccountId$(if ($RepairToken) { ', re-applying its trust and policies' })"
}
if ($cfnCostData -eq 'CreateExport' -and $ConnectPrev['CostData'] -ne 'CreateExport') { Write-Host "    plus bucket spotto-billing-$AccountId-$Deployment and daily CUR 2.0 export $CreatedExportName (first files within 24 hours)" }
if ($CostData -eq 'existing') { Write-Host "  - $(Get-Verb $BillingStatus) ${BillingStack}: read access to export $ExportName (s3://$Bucket/$prefixPath$ExportName)" }
elseif ($BillingStatus -ne 'NONE' -and -not $Recreate) { Write-Host '  - Update $BillingStack' }
if ($EnableTrustedAccess) { Write-Host '  - Turn on StackSets trusted access for the organization' }
if ($ConnectMembers -eq 'yes') { Write-Host "  - $(Get-Verb $MembersStatus) ${MembersStack}: StackSet that adds $RoleName to member accounts$(if ($OuList) { " in $OuList" }) (and new ones automatically)" }
elseif ($Kind -eq 'management' -and $ConnectStatus -ne 'NONE') { Write-Host "  (Member accounts aren't connected. Add -ConnectMembers yes to connect them.)" }
if ($noBilling) { Write-Host "  - No cost data. Billing is required: $billingFix" }
Write-Host ''
$effectiveCostData = if ($cfnCostData) { $cfnCostData } else { $ConnectPrev['CostData'] }
if ($effectiveCostData -eq 'CreateExport' -or $ReuseBilling -or $ExportStatus -ne 'NONE') { Write-Host "  - $ExportStack (us-east-1): AWS-global export definition; billing files stay in $Region" }
if (-not (Confirm-Step 'Deploy now?')) { Write-Host 'Nothing changed.'; exit 1 }

# 7. Deploy
function Show-StackFailure([string]$Stack) {
    $events = @((Invoke-Aws 'cloudformation', 'describe-stack-events', '--stack-name', $Stack, '--query', "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]", '--output', 'text').Text -split "`n" |
        Where-Object { $_ -and $_ -notmatch 'Resource creation cancelled' } | Select-Object -First 5)
    [array]::Reverse($events)
    Write-Host "Stack $Stack failed. First errors:" -ForegroundColor Red
    foreach ($line in $events) { $logicalId, $reason = $line -split "`t", 2; Write-Host "  - ${logicalId}: $reason" }
    if ($events -match '^SpottoRegistration') {
        Write-Host "`nThe portal didn't confirm the connection within 5 minutes. Check that:"
        Write-Host '  - the External ID is the one shown in the portal for this company (copy the command again);'
        Write-Host '  - no service control policy blocks CloudFormation from publishing to the SNS topic $RegistrationTopicArn.'
        Write-Host 'Then rerun this command.'
    }
    if ($Stack -eq $MembersStack -and ($events -join ' ') -match 'organizations access|trusted access') {
        Write-Host "`nStackSets trusted access isn't turned on for the organization. To turn it on:"
        Write-Host '  CloudFormation console → StackSets → Enable trusted access (in the management account)'
        Write-Host "  or run: aws cloudformation activate-organizations-access --region $Region"
        Write-Host 'Then rerun this command.'
    }
    exit 1
}
function Remove-Stack([string]$Stack) {
    Write-Host "Removing $Stack..."
    $null = Invoke-Aws 'cloudformation', 'delete-stack', '--stack-name', $Stack
    if (-not (Invoke-Aws 'cloudformation', 'wait', 'stack-delete-complete', '--stack-name', $Stack).Ok) { Stop-Connect "Couldn't remove $Stack. Check its events in the CloudFormation console." }
}
function Deploy-Stack([string]$Stack, [string]$Template, [hashtable]$Desired) {
    # Unchanged or unset parameters reuse their previous values, so a rerun with no changes changes nothing.
    $url = "$TemplateUrl$Template"
    $r = Invoke-Aws 'cloudformation', 'describe-stacks', '--stack-name', $Stack, '--query', 'Stacks[0].StackStatus', '--output', 'text'
    if ($r.Ok -and $r.Text -eq 'ROLLBACK_COMPLETE') { Remove-Stack $Stack }
    $status = Get-StackStatus $Stack
    $keys = Invoke-Aws 'cloudformation', 'get-template-summary', '--template-url', $url, '--query', 'Parameters[].ParameterKey', '--output', 'text'
    if (-not $keys.Ok) { Stop-Connect "Can't read template $url. AWS said: $($keys.Error)" }
    $prev = Get-StackParams $Stack
    $list = foreach ($key in ($keys.Text -split '\s+' | Where-Object { $_ })) {
        if ($prev.Contains($key) -and (-not $Desired.ContainsKey($key) -or [string]$Desired[$key] -ceq $prev[$key])) { [ordered]@{ ParameterKey = $key; UsePreviousValue = $true } }
        elseif ($Desired.ContainsKey($key)) { [ordered]@{ ParameterKey = $key; ParameterValue = [string]$Desired[$key] } }
    }
    $paramFile = [IO.Path]::GetTempFileName()
    try {
        ConvertTo-Json -InputObject @($list) -Depth 3 | Set-Content -Path $paramFile -Encoding utf8NoBOM
        $common = '--stack-name', $Stack, '--template-url', $url, '--capabilities', 'CAPABILITY_NAMED_IAM', '--parameters', "file://$paramFile"
        if ($status -eq 'NONE') {
            Write-Host "Creating $Stack (usually 1–2 minutes$(if ($Stack -eq $ConnectStack) { ', up to 5 while the portal confirms' }))..."
            $r = Invoke-Aws (@('cloudformation', 'create-stack') + $common)
            if (-not $r.Ok) { Stop-Connect "Couldn't create $Stack. AWS said: $($r.Error)" }
            $wait = 'stack-create-complete'
        } else {
            Write-Host "Updating $Stack..."
            $r = Invoke-Aws (@('cloudformation', 'update-stack') + $common)
            if (-not $r.Ok -and $r.Error -match 'No updates are to be performed') { Write-Host "$Stack is already up to date."; return }
            if (-not $r.Ok) { Stop-Connect "Couldn't update $Stack. AWS said: $($r.Error)" }
            $wait = 'stack-update-complete'
        }
        if (-not (Invoke-Aws 'cloudformation', 'wait', $wait, '--stack-name', $Stack).Ok) { Show-StackFailure $Stack }
    } finally { Remove-Item $paramFile -ErrorAction SilentlyContinue }
}

$ids = @{ RetainedBillingStorage = $(if ($ReuseBilling) { 'true' } else { 'false' }); RoleName = $RoleName; Deployment = $Deployment; RegistrationTopicArn = $RegistrationTopicArn; BillingExportName = $CreatedExportName }
if ($ExternalId) { $ids.ExternalId = $ExternalId }
if ($TrustedPrincipalArn) { $ids.TrustedPrincipalArn = $TrustedPrincipalArn }
if ($RepairToken) { $ids.RepairToken = $RepairToken }
if ($Recreate) {
    $prevCost = $ConnectPrev['CostData']; $billingPrev = Get-StackParams $BillingStack
    if ($BillingStatus -ne 'NONE') { Remove-Stack $BillingStack }
    Remove-Stack $ConnectStack
    Deploy-Stack $ConnectStack 'spotto-aws-connect.template.json' @{
        ExternalId = $(if ($ExternalId) { $ExternalId } else { $ConnectPrev['ExternalId'] })
        TrustedPrincipalArn = $(if ($TrustedPrincipalArn) { $TrustedPrincipalArn } else { $ConnectPrev['TrustedPrincipalArn'] })
        RetainedBillingStorage = $(if ($ReuseBilling) { 'true' } else { 'false' }); RoleName = $RoleName; CostData = $(if ($ReuseBilling) { 'None' } elseif ($recreateCost) { $recreateCost } else { 'None' }); Deployment = $Deployment; RegistrationTopicArn = $RegistrationTopicArn; BillingExportName = $CreatedExportName
    }
    if ($CostData -ne 'existing' -and $ReuseBilling) {
        $CostData = 'existing'; $ExportName = $CreatedExportName; $Bucket = "spotto-billing-$AccountId-$Deployment"; $Prefix = 'cur2'; $KmsKeyArn = ''
    } elseif ($CostData -ne 'existing' -and $billingPrev.Count) {
        $CostData = 'existing'; $ExportName = $billingPrev['ExportName']; $Bucket = $billingPrev['BucketName']; $Prefix = [string]$billingPrev['BasePrefix']; $KmsKeyArn = [string]$billingPrev['KmsKeyArn']
    }
    $prefixPath = if ($Prefix) { "$Prefix/" } else { '' }
} else {
    $connectArgs = $ids.Clone(); if ($cfnCostData) { $connectArgs.CostData = $cfnCostData }
    Deploy-Stack $ConnectStack 'spotto-aws-connect.template.json' $connectArgs
}
# AWS's global export-definition stack receives regional destination values only.
if ((Get-StackParams $ConnectStack)['CostData'] -eq 'CreateExport' -or $ReuseBilling) {
    $createdBucket = if ($ReuseBilling) { $retainedBucket } else { Get-StackOutput $ConnectStack 'BillingBucketName' }
    if (-not $createdBucket) { Stop-Connect 'The regional stack did not return its billing bucket.' }
    Deploy-Stack $ExportStack 'spotto-aws-billing-export.template.json' @{ Deployment = $Deployment; BucketRegion = $Region }
} elseif ($ExportStatus -ne 'NONE') {
    Deploy-Stack $ExportStack 'spotto-aws-billing-export.template.json' @{ Deployment = $Deployment; BucketRegion = $Region }
}
if ($CostData -eq 'existing') {
    $billingArgs = @{ RoleName = $RoleName; ExportName = $ExportName; BucketName = $Bucket; BasePrefix = [string]$Prefix; KmsKeyArn = $KmsKeyArn }
    if ($RepairToken) { $billingArgs.RepairToken = $RepairToken }
    Deploy-Stack $BillingStack 'spotto-aws-billing-access.template.json' $billingArgs
} elseif ($BillingStatus -ne 'NONE' -and -not $Recreate) {
    $billingArgs = @{ RoleName = $RoleName }; if ($RepairToken) { $billingArgs.RepairToken = $RepairToken }
    Deploy-Stack $BillingStack 'spotto-aws-billing-access.template.json' $billingArgs
}
if ($ConnectMembers -eq 'yes') {
    if ($EnableTrustedAccess) {
        Write-Host 'Turning on StackSets trusted access...'
        if (-not (Invoke-Aws 'cloudformation', 'activate-organizations-access').Ok) { Write-Host "Couldn't turn it on automatically (CloudFormation console → StackSets → Enable trusted access)." }
    }
    # The members stack takes its trust from the parameters, or from $ConnectStack when they're omitted (e.g. adding members later).
    $memberArgs = $ids.Clone(); if ($OuList) { $memberArgs.OrganizationalUnitIds = $OuList }
    if (-not $ExternalId) { $memberArgs.ExternalId = $ConnectPrev['ExternalId'] }
    if (-not $TrustedPrincipalArn) { $memberArgs.TrustedPrincipalArn = $ConnectPrev['TrustedPrincipalArn'] }
    Deploy-Stack $MembersStack 'spotto-aws-members.template.json' $memberArgs
}

# 8. Summary
$roleArn = Get-StackOutput $ConnectStack 'RoleArn'
if (-not $roleArn) { $roleArn = "arn:aws:iam::${AccountId}:role/$RoleName" }
$exportSummary = if ((Get-StackParams $ConnectStack)['CostData'] -eq 'CreateExport') { "$CreatedExportName → s3://$(Get-StackOutput $ConnectStack 'BillingBucketName')/cur2 (first files within 24 hours)" }
elseif ($CostData -eq 'existing') { "$ExportName (s3://$Bucket/$prefixPath$ExportName)" }
elseif ((Get-StackStatus $BillingStack) -ne 'NONE') { 'existing export ($BillingStack)' }
else { 'none' }
$orgSummary = if ($OrgId) { "$OrgId ($Kind account)" } else { 'none (standalone)' }
Write-Host "`nConnected." -ForegroundColor Green
Write-Host "  Account:         $AccountId"
Write-Host "  Organization:    $orgSummary"
Write-Host "  Role ARN:        $roleArn"
Write-Host "  Billing export:  $exportSummary"
Write-Host "  Template:        $(if ($Latest) { $Latest } else { 'latest' })"
if ($ConnectMembers -eq 'yes') { Write-Host "  Member accounts: StackSet $MembersStack$(if ($OuList) { " deploying to $OuList" })" }
Write-Host "`nReturn to the portal — it detects the connection automatically."
