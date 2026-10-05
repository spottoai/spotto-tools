#Requires -Version 7.4
<#
.SYNOPSIS
Configure customer-managed AWS access for a Spotto company using its portal setup package.
.DESCRIPTION
Uses customer AWS profiles and API-authored policies. CheckOnly and WhatIf do not change AWS.
The result reports IAM configuration only; Create/Update in Spotto performs live validation.
Each account's exact IAM changes are listed before approval and only those differences are
written, so a rerun against a matching role makes no changes. Changing an existing unowned
role requires RepairExistingRole and explicit adoption. Never deletes roles,
changes SCPs or enables paid AWS services. PowerShell 7.4+ and AWS CLI v2 are required.
.EXAMPLE
./Setup-SpottoAws.ps1 -SetupPackagePath ./spotto-aws-setup.json -Profile customer-admin
.EXAMPLE
./Setup-SpottoAws.ps1 -SetupPackagePath ./spotto-aws-setup.json -CheckOnly
.EXAMPLE
./Setup-SpottoAws.ps1 -SetupPackagePath ./spotto-aws-setup.json -ProfileMapPath ./profiles.json -RepairExistingRole
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SetupPackagePath,
    [string]$Profile,
    [string]$ProfileMapPath,
    [ValidatePattern('^(?!cn-)(?!us-gov-)[a-z]{2}(?:-[a-z0-9]+)+-\d$')][string]$Region = 'us-east-1',
    [string]$OutputPath,
    [switch]$CheckOnly,
    [switch]$RepairExistingRole,
    [switch]$NonInteractive
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SpottoAwsCliAttempt {
    param([string[]]$Arguments, [string]$Profile, [string]$Region, [switch]$AllowMissing)
    $command = Get-Command aws -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $command.Source
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['AWS_PAGER'] = ''
    $start.Environment['AWS_CLI_AUTO_PROMPT'] = 'off'
    # Keep service error codes deterministic even when the operator selects JSON/YAML errors.
    $start.Environment['AWS_CLI_ERROR_FORMAT'] = 'legacy'
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($argument in @('--output', 'json', '--no-cli-pager', '--cli-connect-timeout', '10', '--cli-read-timeout', '30')) {
        $start.ArgumentList.Add($argument)
    }
    if ($Profile) { $start.ArgumentList.Add('--profile'); $start.ArgumentList.Add($Profile) }
    if ($Region) { $start.ArgumentList.Add('--region'); $start.ArgumentList.Add($Region) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'AWS CLI could not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(45000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "AWS $($Arguments[0]) $($Arguments[1]) timed out. Retry after checking your AWS session."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            if ($AllowMissing -and $errorOutput -match '\(NoSuchEntity\)') { return $null }
            $code = if ($errorOutput -match '\(([A-Za-z0-9_.-]{1,80})\)') { $Matches[1] } else { 'CliFailure' }
            # Never echo raw CLI responses: an operator's credential process can include secrets.
            throw "AWS $($Arguments[0]) $($Arguments[1]) failed ($code). Check operator permissions, session expiry, SCPs and permissions boundaries."
        }
        if ($output.Trim()) { return ConvertFrom-Json -InputObject $output -AsHashtable -Depth 100 }
        return @{}
    } finally { $process.Dispose() }
}

function Invoke-SpottoAwsCli {
    param([string[]]$Arguments, [string]$Profile, [string]$Region, [switch]$AllowMissing, [switch]$RetryMissing)
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { return Invoke-SpottoAwsCliAttempt $Arguments $Profile $Region -AllowMissing:$AllowMissing }
        catch {
            if (-not $RetryMissing -or $attempt -eq 4 -or $_.Exception.Message -notmatch '\(NoSuchEntity\)') { throw }
            Start-Sleep -Milliseconds (250 * [Math]::Pow(2, $attempt))
        }
    }
}

function ConvertTo-SpottoCanonicalJson {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $ordered[$key] = ConvertTo-SpottoCanonicalValue $Value[$key] }
        return ConvertTo-Json -InputObject $ordered -Depth 100 -Compress
    }
    return ConvertTo-Json -InputObject (ConvertTo-SpottoCanonicalValue $Value) -Depth 100 -Compress
}

function ConvertTo-SpottoCanonicalValue {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $ordered[$key] = ConvertTo-SpottoCanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-SpottoCanonicalValue $_ }) }
    return $Value
}

function Assert-SpottoCredentialFree {
    param($Value)
    $forbidden = @('accessKeyId', 'secretAccessKey', 'sessionToken', 'credentials', 'resolvedCredentials', 'secret',
        'encryptedSecret', 'credentialReference', 'accessToken', 'connectionString', 'sasToken', 'storageCredential', 'externalId')
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -in $forbidden) { throw 'Configuration must not contain credentials or an External ID.' }
            Assert-SpottoCredentialFree $Value[$key]
        }
    } elseif ($Value -is [array]) { foreach ($item in $Value) { Assert-SpottoCredentialFree $item } }
}

function Assert-SpottoSchemaVersions {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -eq 'schemaVersion') {
                $version = $Value[$key]
                if (($version -isnot [long] -and $version -isnot [int] -and $version -isnot [double]) -or $version -ne 1) {
                    throw 'Every schemaVersion must be the number 1, not a string or boolean.'
                }
            }
            Assert-SpottoSchemaVersions $Value[$key]
        }
    } elseif ($Value -is [array]) { foreach ($item in $Value) { Assert-SpottoSchemaVersions $item } }
}

function Read-SpottoAwsSetupPackage {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt 1MB) { throw 'Setup package exceeds the 1 MiB limit.' }
    $package = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName)) -AsHashtable -Depth 100
    Assert-SpottoSchemaVersions $package
    if ($package.kind -cne 'spotto.aws.setup' -or $package.schemaVersion -ne 1 -or
        $package.companyId -isnot [string] -or $package.companyId -notmatch '^[A-Za-z0-9_-]{1,256}$') {
        throw 'Use a V1 AWS PowerShell setup package downloaded from Spotto.'
    }
    $configuration = $package.configuration
    Assert-SpottoCredentialFree $configuration
    if ($configuration.provider -cne 'AWS' -or $configuration.schemaVersion -ne 1 -or
        $configuration.companyId -cne $package.companyId -or $configuration.estates -isnot [array]) {
        throw 'The package configuration is not bound to this Spotto company.'
    }
    $accounts = @{}
    foreach ($estate in $configuration.estates) {
        if ($estate.companyId -cne $package.companyId -or $estate.enabled -isnot [bool] -or $estate.accounts -isnot [array] -or $estate.billingSources -isnot [array]) {
            throw 'Invalid estate configuration.'
        }
        foreach ($account in $estate.accounts) {
            if ($account.companyId -cne $package.companyId -or $account.enabled -isnot [bool]) { throw 'Invalid account configuration.' }
            if ($estate.enabled -and $account.enabled) {
                if ($accounts.ContainsKey($account.accountId)) { throw 'Duplicate enabled AWS account.' }
                if ('resource-discovery' -cnotin $account.purposes) { throw 'Every enabled account requires resource-discovery.' }
                $purposes = @($account.purposes | Where-Object {
                    if ($_ -eq 'billing-definition') { return @($estate.billingSources | Where-Object { $_.enabled -and $_.definitionRoleAccountId -ceq $account.accountId }).Count -gt 0 }
                    if ($_ -eq 'billing-storage') { return @($estate.billingSources | Where-Object { $_.enabled -and $_.storageRoleAccountId -ceq $account.accountId }).Count -gt 0 }
                    return $true
                })
                $accounts[$account.accountId] = @{ Account = $account; Purposes = $purposes }
            }
        }
    }
    if ($package.roles -isnot [array] -or $package.roles.Count -lt 1 -or $package.roles.Count -gt 100 -or
        $package.roles.Count -ne $accounts.Count) { throw 'The package must cover 1–100 enabled AWS accounts exactly once.' }
    $seen = @{}
    $externalId = $null
    $principal = $null
    foreach ($role in $package.roles) {
        if ($role.accountId -isnot [string] -or $role.accountId -notmatch '^\d{12}$' -or $seen.ContainsKey($role.accountId) -or
            $role.roleArn -cne "arn:aws:iam::$($role.accountId):role/SpottoReadOnlyRole" -or -not $accounts.ContainsKey($role.accountId) -or
            $accounts[$role.accountId].Account.roleArn -cne $role.roleArn) { throw 'Account IDs and standard role ARNs must match the configuration.' }
        $seen[$role.accountId] = $true
        $setup = $role.setup
        $bundle = $setup.onboardingBundle
        if ($setup.provider -cne 'AWS' -or $setup.externalId -notmatch '^spotto-[A-Za-z0-9-]{8,256}$' -or
            $bundle.schemaVersion -ne 1 -or $bundle.roleName -cne 'SpottoReadOnlyRole' -or
            $bundle.trustedPrincipalArn -notmatch '^arn:aws:iam::\d{12}:(user|role)/[A-Za-z0-9+=,.@_/-]{1,512}$') {
            throw 'Invalid Spotto trust setup.'
        }
        if ($externalId -and ($externalId -cne $setup.externalId -or $principal -cne $bundle.trustedPrincipalArn)) {
            throw 'Every role must use the same company trust.'
        }
        $externalId = $setup.externalId
        $principal = $bundle.trustedPrincipalArn
        if ((ConvertTo-SpottoCanonicalJson @($bundle.rolePurposes | Sort-Object)) -cne
            (ConvertTo-SpottoCanonicalJson @($accounts[$role.accountId].Purposes | Sort-Object))) { throw 'Role purposes do not match active configuration.' }
        $statements = @($bundle.trustPolicy.Statement)
        if ($statements.Count -ne 1 -or $statements[0].Effect -cne 'Allow' -or $statements[0].Action -cne 'sts:AssumeRole' -or
            $statements[0].Principal.Count -ne 1 -or $statements[0].Principal.AWS -cne $principal -or
            $statements[0].Condition.StringEquals['sts:ExternalId'] -cne $externalId) {
            throw 'The trust policy must require the exact Spotto principal and company External ID.'
        }
        if ($bundle.guardrailPolicyName -cne 'SpottoGuardrails' -or -not $bundle.guardrailPolicy.Statement) { throw 'Spotto guardrails are required.' }
        foreach ($policy in $bundle.managedPolicies) {
            if ($policy.arn -cnotin @('arn:aws:iam::aws:policy/SecurityAudit', 'arn:aws:iam::aws:policy/ReadOnlyAccess')) {
                throw 'Unexpected managed policy in setup package.'
            }
        }
        if ($bundle.ContainsKey('billingAccessPolicy') -and $bundle.billingAccessPolicyName -cne 'SpottoBillingExportRead') { throw 'Invalid billing policy name.' }
        if ($bundle.ContainsKey('commitmentsAccessPolicy') -and $bundle.commitmentsAccessPolicyName -cne 'SpottoCommitmentsPlanning') { throw 'Invalid commitments policy name.' }
    }
    return $package
}

function Get-SpottoInlinePolicies {
    param([hashtable]$Bundle)
    $policies = [ordered]@{ SpottoGuardrails = $Bundle.guardrailPolicy }
    if ($Bundle.ContainsKey('billingAccessPolicy')) { $policies['SpottoBillingExportRead'] = $Bundle.billingAccessPolicy }
    if ($Bundle.ContainsKey('commitmentsAccessPolicy')) { $policies['SpottoCommitmentsPlanning'] = $Bundle.commitmentsAccessPolicy }
    return $policies
}

function Get-SpottoAwsRoleState {
    param([hashtable]$Role, [string]$CompanyId, [string]$Profile, [string]$Region)
    $bundle = $Role.setup.onboardingBundle
    $policies = Get-SpottoInlinePolicies $bundle
    # Steps are the exact, ordered IAM writes needed to reach the generated configuration.
    # Guardrails come before trust changes and broad managed policies.
    $steps = [Collections.Generic.List[hashtable]]::new()
    $existing = Invoke-SpottoAwsCli @('iam', 'get-role', '--role-name', 'SpottoReadOnlyRole') $Profile $Region -AllowMissing
    if ($null -eq $existing) {
        $steps.Add(@{ Action = 'create-role'; Text = 'Create SpottoReadOnlyRole with the Spotto trust policy and ownership tags' })
        foreach ($name in $policies.Keys) { $steps.Add(@{ Action = 'put-policy'; Name = $name; Text = "Add inline policy $name" }) }
        foreach ($policy in $bundle.managedPolicies) { $steps.Add(@{ Action = 'attach'; Name = $policy.arn; Text = "Attach AWS managed policy $($policy.arn)" }) }
        return @{ Exists = $false; Matches = $false; Owned = $false; Steps = $steps.ToArray(); Boundary = $null }
    }
    if ($existing.Role.Arn -cne $Role.roleArn) { throw 'Existing role ARN does not match the expected account and role path.' }
    if ($existing.Role.RoleId -isnot [string] -or $existing.Role.RoleId -notmatch '^\w{16,128}$') {
        throw 'AWS did not return an immutable role identity. Retry role inspection before changing access.'
    }
    $tags = @{}
    if ($existing.Role.ContainsKey('Tags')) { foreach ($tag in $existing.Role.Tags) { $tags[$tag.Key] = $tag.Value } }
    if (@($tags.Keys | Where-Object { $_ -like 'aws:cloudformation:*' }).Count) {
        throw 'This role is managed by CloudFormation. Update its owning stack with the portal template.'
    }
    if ($tags.ContainsKey('SpottoCompanyId') -and $tags.SpottoCompanyId -cne $CompanyId) { throw 'This role belongs to another Spotto company.' }
    $owned = $tags.ContainsKey('SpottoCompanyId') -and $tags.SpottoCompanyId -ceq $CompanyId -and
        $tags.ContainsKey('SpottoManagedBy') -and $tags.SpottoManagedBy -ceq 'Setup-SpottoAws'
    $boundary = if ($existing.Role.ContainsKey('PermissionsBoundary') -and $existing.Role.PermissionsBoundary -is [System.Collections.IDictionary]) {
        $existing.Role.PermissionsBoundary['PermissionsBoundaryArn']
    } else { $null }
    foreach ($statement in $existing.Role.AssumeRolePolicyDocument.Statement) {
        if ($statement.ContainsKey('Condition') -and $statement.Condition.ContainsKey('StringEquals') -and
            $statement.Condition.StringEquals.ContainsKey('sts:ExternalId') -and
            $statement.Condition.StringEquals['sts:ExternalId'] -cne $Role.setup.externalId) {
            throw 'Existing role trust uses another External ID. Review its company binding before changing access.'
        }
    }
    $trustMatches = (ConvertTo-SpottoCanonicalJson $existing.Role.AssumeRolePolicyDocument) -ceq (ConvertTo-SpottoCanonicalJson $bundle.trustPolicy)
    # Only the three documented Spotto inline policy names are managed by this wizard.
    $names = Invoke-SpottoAwsCli @('iam', 'list-role-policies', '--role-name', 'SpottoReadOnlyRole') $Profile $Region
    foreach ($name in $policies.Keys) {
        if ($name -cnotin $names.PolicyNames) { $steps.Add(@{ Action = 'put-policy'; Name = $name; Text = "Add inline policy $name" }); continue }
        $policy = Invoke-SpottoAwsCli @('iam', 'get-role-policy', '--role-name', 'SpottoReadOnlyRole', '--policy-name', $name) $Profile $Region
        if ((ConvertTo-SpottoCanonicalJson $policy.PolicyDocument) -cne (ConvertTo-SpottoCanonicalJson $policies[$name])) {
            $steps.Add(@{ Action = 'put-policy'; Name = $name; Text = "Replace inline policy $name (current document differs from the generated policy)" })
        }
    }
    foreach ($name in @('SpottoBillingExportRead', 'SpottoCommitmentsPlanning')) {
        if ($name -cin $names.PolicyNames -and -not $policies.Contains($name)) {
            $steps.Add(@{ Action = 'delete-policy'; Name = $name; Text = "Delete inline policy $name (purpose not selected in Spotto)" })
        }
    }
    if (-not $trustMatches) {
        $expected = ConvertTo-SpottoCanonicalJson $bundle.trustPolicy.Statement[0]
        $removed = @(@($existing.Role.AssumeRolePolicyDocument.Statement) | Where-Object { (ConvertTo-SpottoCanonicalJson $_) -cne $expected }).Count
        $text = 'Replace the trust policy with the Spotto trust policy'
        if ($removed) { $text += " (removes $removed existing statement(s) that differ from the Spotto statement)" }
        $steps.Add(@{ Action = 'update-trust'; Text = $text })
    }
    if (-not $owned) { $steps.Add(@{ Action = 'tag'; Text = 'Add SpottoCompanyId and SpottoManagedBy ownership tags' }) }
    $attached = Invoke-SpottoAwsCli @('iam', 'list-attached-role-policies', '--role-name', 'SpottoReadOnlyRole') $Profile $Region
    foreach ($policy in $bundle.managedPolicies) {
        if ($policy.arn -cnotin @($attached.AttachedPolicies | ForEach-Object { $_.PolicyArn })) {
            $steps.Add(@{ Action = 'attach'; Name = $policy.arn; Text = "Attach AWS managed policy $($policy.arn)" })
        }
    }
    # Ownership tags do not change Spotto access, so they never make the configuration a mismatch.
    $matches = @($steps | Where-Object { $_.Action -ne 'tag' }).Count -eq 0
    $approvalProof = ConvertTo-SpottoCanonicalJson @{
        RoleId = $existing.Role.RoleId; CompanyId = $tags['SpottoCompanyId']; ManagedBy = $tags['SpottoManagedBy']
        Trust = $existing.Role.AssumeRolePolicyDocument; Plan = @($steps | ForEach-Object { $_.Text })
    }
    return @{ Exists = $true; Matches = $matches; Owned = $owned; TrustMatches = $trustMatches; ApprovalProof = $approvalProof
        Steps = $steps.ToArray(); Boundary = $boundary }
}

function Format-SpottoAwsPlan {
    param([array]$Steps)
    return (@($Steps | ForEach-Object { "  - $($_.Text)" }) -join [Environment]::NewLine)
}

function Set-SpottoAwsRole {
    param([hashtable]$Role, [string]$CompanyId, [hashtable]$State, [string]$Profile, [string]$Region)
    # Confirmation can take minutes. Revalidate the account and role binding after approval,
    # before any mutation; IAM has no compare-and-swap updates for the remaining operation window.
    $identity = Invoke-SpottoAwsCli @('sts', 'get-caller-identity') $Profile $Region
    if ($identity.Account -cne $Role.accountId) { throw 'AWS session changed after inspection. Review the target profile and rerun.' }
    $freshState = Get-SpottoAwsRoleState $Role $CompanyId $Profile $Region
    if ($State.Exists -ne $freshState.Exists -or
        ($State.Exists -and $State.ApprovalProof -cne $freshState.ApprovalProof)) {
        throw 'The IAM role changed after inspection. Review its ownership, trust and policies, then rerun before applying changes.'
    }
    # Apply only the approved plan, in order: guardrails precede trust changes and broad managed
    # policies. Unchanged items are never rewritten, and a failed run can be rerun to finish.
    $directory = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    $null = [IO.Directory]::CreateDirectory($directory)
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) }
    try {
        $bundle = $Role.setup.onboardingBundle
        $policies = Get-SpottoInlinePolicies $bundle
        $trustPath = Join-Path $directory 'trust.json'
        [IO.File]::WriteAllText($trustPath, (ConvertTo-Json $bundle.trustPolicy -Depth 100))
        $tags = @("Key=SpottoCompanyId,Value=$CompanyId", 'Key=SpottoManagedBy,Value=Setup-SpottoAws')
        foreach ($step in $freshState.Steps) {
            switch ($step.Action) {
                'create-role' {
                    $null = Invoke-SpottoAwsCli (@('iam', 'create-role', '--role-name', 'SpottoReadOnlyRole', '--assume-role-policy-document', "file://$trustPath", '--tags') + $tags) $Profile $Region
                }
                'put-policy' {
                    $path = Join-Path $directory "$($step.Name).json"
                    [IO.File]::WriteAllText($path, (ConvertTo-Json $policies[$step.Name] -Depth 100))
                    $null = Invoke-SpottoAwsCli @('iam', 'put-role-policy', '--role-name', 'SpottoReadOnlyRole', '--policy-name', $step.Name, '--policy-document', "file://$path") $Profile $Region -RetryMissing
                }
                'delete-policy' {
                    $null = Invoke-SpottoAwsCli @('iam', 'delete-role-policy', '--role-name', 'SpottoReadOnlyRole', '--policy-name', $step.Name) $Profile $Region
                }
                'update-trust' {
                    $null = Invoke-SpottoAwsCli @('iam', 'update-assume-role-policy', '--role-name', 'SpottoReadOnlyRole', '--policy-document', "file://$trustPath") $Profile $Region
                }
                'tag' {
                    $null = Invoke-SpottoAwsCli (@('iam', 'tag-role', '--role-name', 'SpottoReadOnlyRole', '--tags') + $tags) $Profile $Region
                }
                'attach' {
                    $null = Invoke-SpottoAwsCli @('iam', 'attach-role-policy', '--role-name', 'SpottoReadOnlyRole', '--policy-arn', $step.Name) $Profile $Region -RetryMissing
                }
                default { throw "Unknown IAM plan step: $($step.Action)" }
            }
        }
    } finally { Remove-Item -LiteralPath $directory -Recurse -Force }
}

function Write-SpottoAwsResult {
    param([hashtable]$Package, [array]$Results, [string]$Path)
    $value = [ordered]@{
        kind = 'spotto.aws.manual-onboarding'; schemaVersion = 1; companyId = $Package.companyId
        configuration = $Package.configuration; results = $Results
    }
    Assert-SpottoCredentialFree $value
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json $value -Depth 100))
    if ($bytes.Length -gt 1MB) { throw 'Result exceeds the 1 MiB portal limit.' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes) } finally { $stream.Dispose() }
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
}

if (-not $SetupPackagePath) {
    if ($NonInteractive) { throw 'SetupPackagePath is required in non-interactive mode.' }
    $SetupPackagePath = Read-Host 'Path to the AWS PowerShell setup package downloaded from Spotto'
}
$package = Read-SpottoAwsSetupPackage $SetupPackagePath
if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) ("SpottoAwsOnboarding-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json') }
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { throw 'OutputPath already exists. Choose a new path; existing files are never overwritten.' }
if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputPath))) { throw 'The output directory must already exist.' }
$profiles = @{}
if ($ProfileMapPath) {
    if ((Get-Item -LiteralPath $ProfileMapPath).Length -gt 64KB) { throw 'Profile map is too large.' }
    $profiles = ConvertFrom-Json ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ProfileMapPath).Path)) -AsHashtable
    if ($profiles -isnot [hashtable]) { throw 'Profile map must be a JSON object mapping account IDs to profile names.' }
    foreach ($key in $profiles.Keys) {
        if ($key -notmatch '^\d{12}$' -or $profiles[$key] -isnot [string] -or $profiles[$key].Length -gt 256) { throw 'Invalid profile map entry.' }
    }
}
Write-Host "Spotto AWS setup — company $($package.companyId), $($package.roles.Count) account(s)" -ForegroundColor Cyan
Write-Host 'Review the setup package policies before continuing. Discovery uses AWS SecurityAudit and ReadOnlyAccess.'
Write-Host 'Spotto guardrails block secret values and S3 object reads outside configured billing exports.'
if (@($package.roles | Where-Object { $_.setup.onboardingBundle.ContainsKey('commitmentsAccessPolicy') }).Count) {
    Write-Host 'Selected commitments planning includes starting a Savings Plans recommendation calculation; it does not purchase commitments.'
}
if (-not $NonInteractive -and -not $CheckOnly -and -not $WhatIfPreference) {
    $choice = Read-Host 'Mode: 1 = check prerequisites/configuration, 2 = configure access (default 1)'
    if ($choice -ne '2') { $CheckOnly = $true }
}

# Verify ALL sessions before making any AWS change. Profile names are never credentials.
foreach ($role in $package.roles) {
    $accountProfile = if ($profiles.ContainsKey($role.accountId)) { $profiles[$role.accountId] } else { $Profile }
    if (-not $accountProfile -and $package.roles.Count -gt 1 -and -not $profiles.ContainsKey($role.accountId)) {
        if ($NonInteractive) { throw "A profile mapping is required for account $($role.accountId)." }
        $accountProfile = Read-Host "AWS profile for account $($role.accountId) (blank = current AWS session)"
    }
    $profiles[$role.accountId] = $accountProfile
    $identity = Invoke-SpottoAwsCli @('sts', 'get-caller-identity') $accountProfile $Region
    if ($identity.Account -cne $role.accountId) { throw "AWS profile resolves to another account; expected $($role.accountId). No AWS changes were made." }
}

$results = @()
foreach ($role in $package.roles) {
    $status = 'failed'
    try {
        $accountProfile = $profiles[$role.accountId]
        $state = Get-SpottoAwsRoleState $role $package.companyId $accountProfile $Region
        $unowned = $state.Exists -and -not $state.Owned
        $accessSteps = @($state.Steps | Where-Object { $_.Action -ne 'tag' })
        if ($state.Boundary) {
            Write-Warning "Account $($role.accountId): SpottoReadOnlyRole has permissions boundary $($state.Boundary). It can deny Spotto reads even when these policies are correct; review it before onboarding."
        }
        if ($accessSteps.Count) { Write-Host "Account $($role.accountId): IAM changes required:$([Environment]::NewLine)$(Format-SpottoAwsPlan $accessSteps)" }
        if ($unowned) {
            Write-Host "Account $($role.accountId): existing role is not tagged as managed by Setup-SpottoAws. Changes require -RepairExistingRole, which also adds ownership tags. If Terraform, CDK, StackSets or Control Tower customizations manage this role, apply the changes there instead; their next deployment would revert this wizard."
        }
        if ($CheckOnly) {
            $status = if ($state.Matches) { 'configuration-matches' } else { 'changes-required' }
        } elseif ($state.Matches -and ($state.Owned -or -not $RepairExistingRole)) {
            # Nothing affecting Spotto access differs, so a matching role needs no writes or adoption.
            $status = 'configured'
        } elseif ($unowned -and -not $RepairExistingRole) {
            throw 'Existing role is not owned by this script. Review the changes above, then rerun with -RepairExistingRole to explicitly adopt it.'
        } else {
            $verb = if ($unowned) { 'Adopt existing IAM role and apply' } else { 'Apply' }
            $operation = "$verb these IAM changes (unrelated customer policies are preserved):$([Environment]::NewLine)$(Format-SpottoAwsPlan $state.Steps)"
            if ($PSCmdlet.ShouldProcess($role.roleArn, $operation)) {
                Set-SpottoAwsRole $role $package.companyId $state $accountProfile $Region
                $status = 'configured'
            } else { $status = 'planned' }
        }
    } catch {
        Write-Warning "Account $($role.accountId): $($_.Exception.Message)"
    }
    Write-Host "Account $($role.accountId): $status"
    $results += @{ accountId = $role.accountId; roleArn = $role.roleArn; status = $status }
}
Write-SpottoAwsResult $package $results $OutputPath
Write-Host "Results saved to $OutputPath" -ForegroundColor Cyan
Write-Host 'Paste the complete JSON into Read PowerShell results in Spotto. Then use Create/Update for live role, billing and resource validation.'
Write-Host 'This script has not tested access from the Spotto principal. SCPs, boundaries, bucket policies and KMS policies can still block access.'
if (@($results | Where-Object { $_.status -eq 'failed' }).Count) { exit 1 }
