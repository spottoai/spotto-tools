#Requires -Version 7.0
# Offline smoke tests for Connect-SpottoAws.ps1 using fake_aws.py as the aws executable. No Pester needed.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..' 'Connect-SpottoAws.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ("connect-test-" + [guid]::NewGuid())
$bin = New-Item -ItemType Directory -Path (Join-Path $work 'bin')
$fake = Join-Path $PSScriptRoot 'fake_aws.py'
if ($IsWindows) { Set-Content (Join-Path $bin 'aws.cmd') "@python `"$fake`" %*" }
else { Set-Content (Join-Path $bin 'aws') "#!/usr/bin/env bash`nexec python3 `"$fake`" `"`$@`""; chmod +x (Join-Path $bin 'aws') }
$ext = 'spotto-0f8fad5b-d9cb-469f-a165-70867728950e'
$arn = 'arn:aws:iam::715809501612:user/spotto-cloud-engine-prod'
$base = 'https://spotto-aws-onboarding.s3.amazonaws.com/cloudformation/'
$v = 'v2026-11-03.1/'
$state = Join-Path $work 'state'; $log = Join-Path $work 'log'
$env:FAKE_AWS_STATE = $state; $env:FAKE_AWS_LOG = $log
$originalPath = $env:PATH
$env:PATH = "$bin$([IO.Path]::PathSeparator)$originalPath"
$script:pass = 0; $script:fail = 0

function Reset-State { Remove-Item $state -Recurse -Force -ErrorAction SilentlyContinue; $null = New-Item -ItemType Directory $state; Set-Content $log '' }
function Add-Stack([string]$Stack, [string]$Version, [string[]]$Params) { $env:FAKE_AWS_SCENARIO = 'x'; & aws fake-seed $Stack $Version @Params; Set-Content $log '' }
function Add-Connect([string]$Version, [string]$CostData) { Add-Stack 'SpottoConnect-prod-us' $Version @("ExternalId=$ext", "TrustedPrincipalArn=$arn", "Deployment=prod-us", "RegistrationTopicArn=arn:aws:sns:us-east-1:715809501612:spotto-aws-connect-prod-us", "BillingExportName=spotto-cur2-prod-us", "CostData=$CostData", 'RetainedBillingStorage=false', 'RoleName=SpottoReadOnlyRole'); if ($CostData -eq 'CreateExport') { Add-Stack 'SpottoBillingExport-prod-us' $Version @('Deployment=prod-us', 'BucketRegion=us-east-1') } }
function Add-Members { Add-Stack 'SpottoMemberAccounts-prod-us' '2026-11-03.1' @("ExternalId=$ext", "TrustedPrincipalArn=$arn", 'OrganizationalUnitIds=r-ab12', 'RoleName=SpottoReadOnlyRole') }
function Invoke-Script([string]$Scenario, [int]$ExpectedExit, [string[]]$Extra, [hashtable]$Env = @{}) {
    Set-Content $log ''
    $env:FAKE_AWS_SCENARIO = $Scenario
    foreach ($k in $Env.Keys) { Set-Item "env:$k" $Env[$k] }
    try { $out = & pwsh -NoProfile -NonInteractive -File $script -Deployment $(if ($Env.ContainsKey('FAKE_DEPLOYMENT')) { $Env['FAKE_DEPLOYMENT'] } else { 'prod-us' }) @Extra 2>&1 | Out-String; $code = $LASTEXITCODE }
    finally { foreach ($k in $Env.Keys) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } }
    if ($code -ne $ExpectedExit) { throw "expected exit $ExpectedExit, got $code`n$out" }
    [pscustomobject]@{ Out = $out; Log = (Get-Content -Raw $log) }
}
function Invoke-Connect([string]$Scenario, [int]$ExpectedExit, [string[]]$Extra = @(), [hashtable]$Env = @{}) {
    Invoke-Script $Scenario $ExpectedExit (@('-ExternalId', $ext, '-TrustedPrincipalArn', $arn) + $Extra) $Env
}
function Assert-Has([string]$Text, [string]$Expected) { if (-not $Text.Contains($Expected)) { throw "missing: $Expected" } }
function Assert-Lacks([string]$Text, [string]$Unexpected) { if ($Text.Contains($Unexpected)) { throw "unexpected: $Unexpected" } }
function Assert-Match([string]$Text, [string]$Pattern) { if ($Text -notmatch $Pattern) { throw "no match: $Pattern" } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    Reset-State
    try { & $Body; $script:pass++; Write-Host "ok   $Name" } catch { $script:fail++; Write-Host "FAIL $Name`n    $($_.Exception.Message)" }
}

try {
    Test-Case 'failed registration retains storage and creates missing global definition' {
        Add-Connect '2026-10-26.1' 'CreateExport'
        Remove-Item (Join-Path $state 'SpottoBillingExport-prod-us.json'), (Join-Path $state 'role')
        $path = Join-Path $state 'SpottoConnect-prod-us.json'
        $data = Get-Content -Raw $path | ConvertFrom-Json
        $data.status = 'ROLLBACK_COMPLETE'
        $data | ConvertTo-Json -Depth 10 | Set-Content $path
        $r = Invoke-Connect 'standalone' 0 @('-Yes')
        Assert-Has $r.Log 'CostData=None'
        Assert-Has $r.Log 'create-stack --stack-name SpottoBillingExport-prod-us'
        Assert-Has $r.Log 'head-bucket --bucket spotto-billing-111122223333-prod-us --expected-bucket-owner 111122223333'
        Assert-Has $r.Out 'AWS-global export definition; billing files stay in us-east-1'
        Assert-Lacks $r.Log 'delete-bucket'
    }
    Test-Case 'interrupted retained recovery resumes and check detects missing billing' {
        foreach ($failedStack in @('SpottoBillingExport', 'SpottoBillingAccess')) {
            Reset-State
            Add-Connect '2026-10-26.1' 'CreateExport'
            Remove-Item (Join-Path $state 'SpottoBillingExport-prod-us.json'), (Join-Path $state 'role')
            $r = Invoke-Connect 'standalone' 1 @('-Yes', '-Repair') @{ FAKE_FAIL_CREATE_STACK = $failedStack }
            Assert-Has $r.Log 'RetainedBillingStorage=true'
            $r = Invoke-Script 'standalone' 1 @('-Check')
            Assert-Has $r.Out 'is missing. Rerun the connect command to complete billing setup.'
            $r = Invoke-Connect 'standalone' 0 @('-Yes', '-CostData', 'create')
            Assert-Has $r.Log 'head-bucket --bucket spotto-billing-111122223333-prod-us'
            Assert-Has $r.Log 'CostData=(previous);RetainedBillingStorage=(previous)'
            Assert-Has $r.Log "create-stack --stack-name $failedStack-prod-us"
            Assert-Lacks $r.Log 'delete-stack'
            $null = Invoke-Script 'standalone' 0 @('-Check')
        }
    }
    Test-Case 'retained storage guard rejects foreign region or policy before deletion' {
        foreach ($kind in @('foreign', 'wrong-region', 'no-policy')) {
            Reset-State
            Add-Connect '2026-10-26.1' 'CreateExport'
            Remove-Item (Join-Path $state 'role')
            $r = Invoke-Connect 'standalone' 1 @('-Yes', '-Repair') @{ FAKE_RETAINED_BUCKET = $kind }
            Assert-Lacks $r.Log 'delete-stack'
            Assert-Lacks $r.Log 'create-stack'
        }
    }
    Test-Case 'AU/EU regional access and US export definition, including check' {
        foreach ($deployment in @('dev-au', 'prod-au', 'prod-eu')) {
            Reset-State
            $region = if ($deployment -eq 'prod-eu') { 'eu-north-1' } else { 'ap-southeast-2' }
            $r = Invoke-Connect 'standalone' 0 @('-Yes') @{ FAKE_DEPLOYMENT = $deployment }
            Assert-Has $r.Log "--region $region cloudformation create-stack --stack-name SpottoConnect-$deployment"
            Assert-Has $r.Log "--region us-east-1 cloudformation create-stack --stack-name SpottoBillingExport-$deployment"
            Assert-Has $r.Log "PARAMS SpottoBillingExport-$deployment Deployment=$deployment;BucketRegion=$region"
            $r = Invoke-Script 'standalone' 0 @('-Check') @{ FAKE_DEPLOYMENT = $deployment }
            Assert-Has $r.Out 'Everything is up to date and in sync.'
        }
    }
    Test-Case 'missing export stack is unhealthy' {
        Invoke-Connect 'standalone' 0 @('-Yes') | Out-Null
        Remove-Item (Join-Path $state 'SpottoBillingExport-prod-us.json')
        $r = Invoke-Script 'standalone' 1 @('-Check')
        Assert-Has $r.Out 'Required billing export stack SpottoBillingExport-prod-us is missing'
        Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'wrong topic fails before AWS' {
        $r = Invoke-Connect 'standalone' 1 @('-Yes', '-RegistrationTopicArn', 'arn:aws:sns:eu-north-1:715809501612:spotto-aws-connect-prod-eu')
        Assert-Has $r.Out 'Registration topic does not match'
        Assert-Lacks $r.Log 'sts get-caller-identity'
    }
    Test-Case 'parses without errors' {
        $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
    }
    Test-Case '-Help' { Assert-Has (& pwsh -NoProfile -File $script -Help | Out-String) 'Repair' }
    Test-Case 'rejects a bad external ID' { Assert-Has (Invoke-Script 'standalone' 1 @('-ExternalId', 'nope', '-TrustedPrincipalArn', $arn, '-Yes')).Out 'spotto-<uuid>' }
    Test-Case 'first connect needs the IDs' { Assert-Has (Invoke-Script 'standalone' 1 @('-Yes')).Out 'are required to connect' }
    Test-Case 'standalone account, create export (versioned URL)' {
        $r = Invoke-Connect 'standalone' 0 @('-Yes')
        Assert-Has $r.Log "create-stack --stack-name SpottoConnect-prod-us --template-url $base${v}spotto-aws-connect.template.json --capabilities CAPABILITY_NAMED_IAM"
        Assert-Has $r.Log "PARAMS SpottoConnect-prod-us ExternalId=$ext;TrustedPrincipalArn=$arn;Deployment=prod-us;RegistrationTopicArn=arn:aws:sns:us-east-1:715809501612:spotto-aws-connect-prod-us;BillingExportName=spotto-cur2-prod-us;CostData=CreateExport;RetainedBillingStorage=false;RoleName=SpottoReadOnlyRole"
        Assert-Lacks $r.Log 'stack --stack-name SpottoMemberAccounts-prod-us'
        Assert-Has $r.Out 'spotto-cur2-prod-us → s3://spotto-billing-111122223333-prod-us/cur2'
        Assert-Has $r.Out 'Return to the portal — it detects the connection automatically.'
    }
    Test-Case 'rerun with no changes changes nothing' {
        $null = Invoke-Connect 'standalone' 0 @('-Yes'); $r = Invoke-Connect 'standalone' 0 @('-Yes')
        Assert-Has $r.Log 'PARAMS SpottoConnect-prod-us ExternalId=(previous);TrustedPrincipalArn=(previous);Deployment=(previous);RegistrationTopicArn=(previous);BillingExportName=(previous);CostData=(previous);RetainedBillingStorage=(previous);RoleName=(previous)'
        Assert-Has $r.Out 'SpottoConnect-prod-us is already up to date.'; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'rerun updates stacks to a new version' {
        Add-Connect '2026-10-01.1' 'CreateExport'; Add-Members
        $r = Invoke-Connect 'management' 0 @('-Yes')
        Assert-Has $r.Out 'Found SpottoConnect-prod-us (version 2026-10-01.1); latest is 2026-11-03.1.'
        Assert-Has $r.Log "update-stack --stack-name SpottoConnect-prod-us --template-url $base${v}spotto-aws-connect.template.json"
        Assert-Has $r.Log 'PARAMS SpottoConnect-prod-us ExternalId=(previous);TrustedPrincipalArn=(previous);Deployment=(previous);RegistrationTopicArn=(previous);BillingExportName=(previous);CostData=(previous);RetainedBillingStorage=(previous);RoleName=(previous)'
        Assert-Has $r.Log 'OrganizationalUnitIds=(previous)'; Assert-Lacks $r.Log 'create-stack'; Assert-Lacks $r.Log 'list-roots'
    }
    Test-Case 'existing export adds billing access' {
        $r = Invoke-Connect 'existing' 0 @('-Yes', '-CostData', 'existing')
        Assert-Has $r.Log 'CostData=None'
        Assert-Has $r.Log 'PARAMS SpottoBillingAccess-prod-us RoleName=SpottoReadOnlyRole;ExportName=contoso-cur2;BucketName=contoso-billing;BasePrefix=reports;KmsKeyArn=arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab'
    }
    Test-Case 'member account warns and continues alone' {
        $r = Invoke-Connect 'member' 0 @('-Yes', '-ConnectMembers', 'yes')
        Assert-Has $r.Out 'this is a member account of organization o-abc1234567 (management account 999988887777)'
        Assert-Lacks $r.Log 'stack --stack-name SpottoMemberAccounts-prod-us'
    }
    Test-Case 'management account connects members via root' {
        $r = Invoke-Connect 'management' 0 @('-Yes')
        Assert-Has $r.Log "PARAMS SpottoMemberAccounts-prod-us ExternalId=$ext;TrustedPrincipalArn=$arn;OrganizationalUnitIds=r-ab12;RoleName=SpottoReadOnlyRole"
    }
    Test-Case 'management account with explicit OUs' {
        $r = Invoke-Connect 'management' 0 @('-Yes', '-OrganizationalUnitIds', 'ou-ab12-abcdefgh,ou-ab12-12345678')
        Assert-Lacks $r.Log 'list-roots'; Assert-Has $r.Log 'OrganizationalUnitIds=ou-ab12-abcdefgh,ou-ab12-12345678'
    }
    Test-Case 'members stack failure explains trusted access' {
        Assert-Has (Invoke-Connect 'members-fail' 1 @('-Yes')).Out 'CloudFormation console → StackSets → Enable trusted access'
    }
    Test-Case 'registration failure explains what to check' {
        $r = Invoke-Connect 'registration-fail' 1 @('-Yes')
        Assert-Has $r.Out "SpottoRegistration: CloudFormation did not receive a response"; Assert-Has $r.Out "The portal didn't confirm the connection within 5 minutes"
    }
    Test-Case 'existing role stops before deploying' {
        $r = Invoke-Connect 'role-exists' 1 @('-Yes'); Assert-Has $r.Out 'Delete it, or pass -RoleName'; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'repair with the role present' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 0 @('-Repair', '-Yes') @{ FAKE_DRIFTED = 'SpottoConnect-prod-us' }
        Assert-Has $r.Out 'SpottoConnect-prod-us: drifted'; Assert-Has $r.Out 'Role was modified outside CloudFormation'
        Assert-Match $r.Log 'PARAMS SpottoConnect-prod-us ExternalId=\(previous\);TrustedPrincipalArn=\(previous\);Deployment=\(previous\);RegistrationTopicArn=\(previous\);BillingExportName=\(previous\);CostData=\(previous\);RetainedBillingStorage=\(previous\);RoleName=\(previous\);RepairToken=[0-9]{10}\r?\n'
        Assert-Lacks $r.Log 'delete-stack'
    }
    Test-Case 'repair with the role deleted' {
        Add-Connect '2026-11-03.1' 'CreateExport'; Add-Members; Remove-Item (Join-Path $state 'role')
        $r = Invoke-Script 'management' 0 @('-Repair', '-Yes')
        Assert-Has $r.Log 'delete-stack --stack-name SpottoConnect-prod-us'
        Assert-Has $r.Log "PARAMS SpottoConnect-prod-us ExternalId=$ext;TrustedPrincipalArn=$arn;Deployment=prod-us;RegistrationTopicArn=arn:aws:sns:us-east-1:715809501612:spotto-aws-connect-prod-us;BillingExportName=spotto-cur2-prod-us;CostData=None;RetainedBillingStorage=true;RoleName=SpottoReadOnlyRole"
        Assert-Has $r.Log 'PARAMS SpottoBillingAccess-prod-us RoleName=SpottoReadOnlyRole;ExportName=spotto-cur2-prod-us;BucketName=spotto-billing-111122223333-prod-us;BasePrefix=cur2;KmsKeyArn='
        Assert-Match $r.Log 'PARAMS SpottoMemberAccounts-prod-us .*RepairToken=[0-9]+'
        if (-not (Test-Path (Join-Path $state 'role'))) { throw 'role not recreated' }
    }
    Test-Case 'repair refuses to delete an unversioned stack' {
        Add-Connect '' 'CreateExport'; Remove-Item (Join-Path $state 'role')
        $r = Invoke-Script 'standalone' 1 @('-Repair', '-Yes'); Assert-Has $r.Out 'Create an empty IAM role'; Assert-Lacks $r.Log 'delete-stack'
    }
    Test-Case 'new connection without billing fails' {
        $r = Invoke-Connect 'standalone' 1 @('-Yes', '-CostData', 'none')
        Assert-Has $r.Out 'Billing is required to connect AWS. Rerun with -CostData create (recommended), or -CostData existing -ExportArn <arn>.'
        Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'update of a connection without billing warns' {
        Add-Connect '2026-11-03.1' 'None'
        $r = Invoke-Connect 'standalone' 0 @('-Yes')
        Assert-Has $r.Out 'Warning: this connection has no billing data, and billing is required.'
        Assert-Has $r.Out 'No cost data. Billing is required'
    }
    Test-Case 'monthly existing export is refused' {
        $r = Invoke-Connect 'existing' 1 @('-Yes', '-CostData', 'existing') @{ FAKE_EXPORT_GRANULARITY = 'MONTHLY' }
        Assert-Has $r.Out "Monthly isn't supported"; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'existing export without resource IDs is refused' {
        $r = Invoke-Connect 'existing' 1 @('-Yes', '-CostData', 'existing') @{ FAKE_EXPORT_RESOURCES = 'FALSE' }
        Assert-Has $r.Out "doesn't include resource IDs (INCLUDE_RESOURCES)"; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'existing export not selecting resource IDs is refused' {
        $r = Invoke-Connect 'existing' 1 @('-Yes', '-CostData', 'existing') @{ FAKE_EXPORT_QUERY = 'SELECT identity_line_item_id, line_item_unblended_cost FROM COST_AND_USAGE_REPORT' }
        Assert-Has $r.Out "doesn't select line_item_resource_id"; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'existing export selecting every column is accepted' {
        $r = Invoke-Connect 'existing' 0 @('-Yes', '-CostData', 'existing') @{ FAKE_EXPORT_QUERY = 'SELECT * FROM COST_AND_USAGE_REPORT' }
        Assert-Has $r.Log 'create-stack --stack-name SpottoBillingAccess-prod-us'
    }
    Test-Case 'KMS alias on the billing bucket resolves to the key ARN' {
        $r = Invoke-Connect 'existing' 0 @('-Yes', '-CostData', 'existing') @{ FAKE_BUCKET_KEY = 'alias/billing-exports' }
        Assert-Has $r.Log 'kms describe-key --key-id alias/billing-exports'
        Assert-Has $r.Log 'KmsKeyArn=arn:aws:kms:us-east-1:111122223333:key/5678efgh-56ef-78gh-90ij-567890abcdef'
    }
    Test-Case 'KMS alias ARN resolves in its own Region' {
        $r = Invoke-Connect 'existing' 0 @('-Yes', '-CostData', 'existing') @{ FAKE_BUCKET_KEY = 'arn:aws:kms:eu-west-1:444455556666:alias/billing-exports' }
        Assert-Has $r.Log '--region eu-west-1 kms describe-key --key-id arn:aws:kms:eu-west-1:444455556666:alias/billing-exports'
        Assert-Has $r.Log 'KmsKeyArn=arn:aws:kms:us-east-1:111122223333:key/5678efgh-56ef-78gh-90ij-567890abcdef'
    }
    Test-Case 'unresolvable KMS alias stops' {
        $r = Invoke-Connect 'existing' 1 @('-Yes', '-CostData', 'existing') @{ FAKE_BUCKET_KEY = 'alias/missing' }
        Assert-Has $r.Out "Can't resolve the KMS key alias/missing that encrypts bucket contoso-billing"; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'unreadable bucket encryption stops' {
        $r = Invoke-Connect 'existing' 1 @('-Yes', '-CostData', 'existing') @{ FAKE_DENY = 'get-bucket-encryption' }
        Assert-Has $r.Out "Can't read the default encryption of bucket contoso-billing"; Assert-Has $r.Out 'AccessDenied'; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case 'SSE-S3 billing bucket needs no KMS key' {
        $r = Invoke-Connect 'existing' 0 @('-Yes', '-CostData', 'existing') @{ FAKE_BUCKET_KEY = 'none' }
        Assert-Has $r.Log 'BasePrefix=reports;KmsKeyArn='; Assert-Lacks $r.Log 'kms describe-key'
    }
    Test-Case '-Check: all good exits 0' {
        Add-Connect '2026-11-03.1' 'CreateExport'; Add-Members
        $r = Invoke-Script 'management' 0 @('-Check') @{ FAKE_INSTANCES = '222233334444,CURRENT,SUCCEEDED;333344445555,CURRENT,SUCCEEDED' }
        Assert-Has $r.Out 'SpottoConnect-prod-us: version 2026-11-03.1 (up to date)'; Assert-Has $r.Out 'Member accounts: 2 OK, 0 outdated, 0 failed'
        Assert-Has $r.Out 'Everything is up to date and in sync.'; Assert-Lacks $r.Log 'update-stack'; Assert-Lacks $r.Log 'create-stack'
        Assert-Has $r.Log 'iam list-attached-role-policies --role-name SpottoReadOnlyRole'
        Assert-Has $r.Out 'SpottoReadOnlyRole: AWS managed policies ViewOnlyAccess and SecurityAudit attached'
    }
    Test-Case '-Check: missing managed policy exits 1' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 1 @('-Check') @{ FAKE_MANAGED_POLICIES = 'arn:aws:iam::aws:policy/job-function/ViewOnlyAccess,arn:aws:iam::aws:policy/ReadOnlyAccess' }
        Assert-Has $r.Out 'SpottoReadOnlyRole is missing the AWS managed SecurityAudit policy'; Assert-Has $r.Out 'rerun with -Repair'
        Assert-Lacks $r.Out 'Everything is up to date'
    }
    Test-Case '-Check: no managed policies on a custom role name' {
        Add-Stack 'SpottoConnect-prod-us' '2026-11-03.1' @("ExternalId=$ext", "TrustedPrincipalArn=$arn", 'CostData=None', 'RoleName=CustomRole')
        $r = Invoke-Script 'standalone' 1 @('-Check') @{ FAKE_MANAGED_POLICIES = 'none' }
        Assert-Has $r.Log 'iam list-attached-role-policies --role-name CustomRole'
        Assert-Has $r.Out 'CustomRole is missing the AWS managed ViewOnlyAccess and SecurityAudit policies'
    }
    Test-Case '-Check: unreadable managed policies exit 1' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 1 @('-Check') @{ FAKE_DENY = 'list-attached-role-policies' }
        Assert-Has $r.Out "Couldn't read the managed policies attached to SpottoReadOnlyRole: An error occurred (AccessDenied)"
        Assert-Has $r.Out "health isn't confirmed"
    }
    Test-Case '-Check: update available exits 1' {
        Add-Connect '2026-10-01.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 1 @('-Check'); Assert-Has $r.Out '(update available)'; Assert-Has $r.Out 'without -Check'
    }
    Test-Case '-Check: drift and member failures exit 1' {
        Add-Connect '2026-11-03.1' 'CreateExport'; Add-Members
        $r = Invoke-Script 'management' 1 @('-Check') @{ FAKE_DRIFTED = 'SpottoConnect-prod-us'; FAKE_INSTANCES = '222233334444,CURRENT,SUCCEEDED;333344445555,OUTDATED,SUCCEEDED;444455556666,OUTDATED,FAILED' }
        Assert-Has $r.Out 'Drift: drifted'; Assert-Has $r.Out 'Member accounts: 1 OK, 1 outdated, 1 failed'
        Assert-Has $r.Out '444455556666: FAILED'; Assert-Has $r.Out 'rerun with -Repair'
    }
    Test-Case '-Check: not connected exits 1' { Assert-Has (Invoke-Script 'standalone' 1 @('-Check')).Out 'Not connected' }
    Test-Case 'adding members later reuses the connect stack trust' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'management' 0 @('-ConnectMembers', 'yes', '-Yes')
        Assert-Has $r.Log "PARAMS SpottoMemberAccounts-prod-us ExternalId=$ext;TrustedPrincipalArn=$arn;OrganizationalUnitIds=r-ab12;RoleName=SpottoReadOnlyRole"
    }
    Test-Case 'repair passes RepairToken to billing access when declared' {
        Add-Connect '2026-11-03.1' 'None'
        Add-Stack 'SpottoBillingAccess-prod-us' '2026-11-03.1' @('RoleName=SpottoReadOnlyRole', 'ExportName=contoso-cur2', 'BucketName=contoso-billing', 'BasePrefix=reports', 'KmsKeyArn=')
        $r = Invoke-Script 'standalone' 0 @('-Repair', '-Yes') @{ FAKE_BILLING_REPAIR_TOKEN = '1' }
        Assert-Match $r.Log 'PARAMS SpottoBillingAccess-prod-us RoleName=\(previous\);ExportName=\(previous\);BucketName=\(previous\);BasePrefix=\(previous\);KmsKeyArn=\(previous\);RepairToken=[0-9]{10}\r?\n'
    }
    Test-Case '-Check: denied member status read exits 1' {
        Add-Connect '2026-11-03.1' 'CreateExport'; Add-Members
        $r = Invoke-Script 'management' 1 @('-Check') @{ FAKE_DENY = 'list-stack-instances' }
        Assert-Has $r.Out "Couldn't read member account status: An error occurred (AccessDenied)"
        Assert-Lacks $r.Out 'Everything is up to date'; Assert-Lacks $r.Out 'Member accounts: 0 OK'
    }
    Test-Case '-Check: pending/running instances are in progress' {
        Add-Connect '2026-11-03.1' 'CreateExport'; Add-Members
        $r = Invoke-Script 'management' 1 @('-Check') @{ FAKE_INSTANCES = '222233334444,CURRENT,SUCCEEDED;333344445555,OUTDATED,RUNNING;444455556666,CURRENT,PENDING' }
        Assert-Has $r.Out 'Member accounts: 1 OK, 0 outdated, 0 failed, 2 in progress'; Assert-Has $r.Out 'rerun -Check shortly'
        Assert-Lacks $r.Out 'Everything is up to date'; Assert-Lacks $r.Out '-Repair'
    }
    Test-Case '-Check: denied drift detection exits 1' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 1 @('-Check') @{ FAKE_DENY = 'detect-stack-drift' }
        Assert-Has $r.Out "Couldn't read drift status: An error occurred (AccessDenied)"
    }
    Test-Case 'denied stack read is never treated as missing' {
        Add-Connect '2026-11-03.1' 'None'
        Add-Stack 'SpottoBillingAccess-prod-us' '2026-11-03.1' @('RoleName=SpottoReadOnlyRole', 'ExportName=contoso-cur2', 'BucketName=contoso-billing', 'BasePrefix=reports', 'KmsKeyArn=')
        Assert-Has (Invoke-Script 'standalone' 1 @('-Check') @{ FAKE_DENY = 'describe-stacks:SpottoBillingAccess-prod-us' }).Out "Couldn't read stack SpottoBillingAccess-prod-us: An error occurred (AccessDenied)"
        $r = Invoke-Script 'standalone' 1 @('-Yes') @{ FAKE_DENY = 'describe-stacks:SpottoBillingAccess-prod-us' }
        Assert-Has $r.Out "Couldn't read stack SpottoBillingAccess-prod-us"; Assert-Lacks $r.Log 'update-stack'
    }
    Test-Case 'repair: denied GetRole deletes nothing' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 1 @('-Repair', '-Yes') @{ FAKE_DENY = 'get-role' }
        Assert-Has $r.Out "Couldn't check whether role SpottoReadOnlyRole exists: An error occurred (AccessDenied)"
        Assert-Lacks $r.Log 'delete-stack'; Assert-Lacks $r.Log 'create-stack'; Assert-Lacks $r.Log 'update-stack'
    }
    Test-Case 'connect: denied GetRole stops' {
        $r = Invoke-Connect 'standalone' 1 @('-Yes') @{ FAKE_DENY = 'get-role' }
        Assert-Has $r.Out "Couldn't check whether role SpottoReadOnlyRole exists"; Assert-Lacks $r.Log 'create-stack'
    }
    Test-Case '-Check: unreadable latest version exits 1' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 1 @('-Check') @{ FAKE_DENY = 'get-template-summary:' }
        Assert-Has $r.Out "Couldn't read the template version for the latest templates: An error occurred (AccessDenied)"
        Assert-Lacks $r.Out 'Everything is up to date'; Assert-Lacks $r.Out '(up to date)'
    }
    Test-Case '-Check: unreadable deployed version exits 1' {
        Add-Connect '2026-11-03.1' 'CreateExport'
        $r = Invoke-Script 'standalone' 1 @('-Check') @{ FAKE_DENY = 'get-template-summary:SpottoConnect-prod-us' }
        Assert-Has $r.Out "Couldn't read the template version for SpottoConnect-prod-us: An error occurred (AccessDenied)"
        Assert-Has $r.Out 'SpottoConnect-prod-us: version unknown (version unreadable)'; Assert-Lacks $r.Out 'Everything is up to date'
    }
    Test-Case 'connect/update: unreadable latest version stops' {
        $r = Invoke-Connect 'standalone' 1 @('-Yes') @{ FAKE_DENY = 'get-template-summary:' }
        Assert-Has $r.Out "Couldn't read the template version for the latest templates"; Assert-Lacks $r.Log 'create-stack'
        Add-Connect '2026-10-01.1' 'CreateExport'
        Assert-Lacks (Invoke-Connect 'standalone' 1 @('-Yes') @{ FAKE_DENY = 'get-template-summary:' }).Log 'update-stack'
    }
    Test-Case 'update: unreadable deployed version stops' {
        Add-Connect '2026-10-01.1' 'CreateExport'
        $r = Invoke-Connect 'standalone' 1 @('-Yes') @{ FAKE_DENY = 'get-template-summary:SpottoConnect-prod-us' }
        Assert-Has $r.Out "Couldn't read the template version for SpottoConnect-prod-us"; Assert-Lacks $r.Log 'update-stack'
    }
    Test-Case 'unversioned latest template falls back to base URL' {
        $r = Invoke-Connect 'standalone' 0 @('-Yes') @{ FAKE_LATEST_VERSION = 'none' }
        Assert-Has $r.Log "create-stack --stack-name SpottoConnect-prod-us --template-url ${base}spotto-aws-connect.template.json"
    }
} finally {
    $env:PATH = $originalPath
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$($script:pass) passed, $($script:fail) failed"
exit [int]($script:fail -gt 0)
