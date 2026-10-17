#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('spotto-aws-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$originalPath = $env:PATH
$environmentNames = @('SPOTTO_TEST_STATE', 'SPOTTO_TEST_ACCOUNT', 'SPOTTO_TEST_WRONG_ACCOUNT', 'SPOTTO_TEST_FAIL_ACTION', 'SPOTTO_TEST_TRANSIENT_ACTION', 'AWS_CLI_ERROR_FORMAT', 'SPOTTO_TEST_ERROR_PREFIX', 'SPOTTO_TEST_ERROR_CODE')
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$setupScriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../Setup-SpottoAws.ps1')).Path
$parseErrors = $null
$tokens = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'AWS setup script does not parse.' }
# Load only definitions from the trusted script, matching the Azure offline test pattern.
# The wizard remains a normal single-file entrypoint without a test-only runtime mode.
foreach ($definition in $setupAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    Invoke-Expression $definition.Extent.Text
}
# Run the actual wizard from an isolated directory containing just the downloaded PS1.
$entrypoint = Join-Path $testRoot 'Setup-SpottoAws.ps1'
Copy-Item -LiteralPath $setupScriptPath -Destination $entrypoint
$script:assertions = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertions++
}
function Write-State { param($Value) [IO.File]::WriteAllText($env:SPOTTO_TEST_STATE, (ConvertTo-Json $Value -Depth 100)) }
function Read-State { ConvertFrom-Json ([IO.File]::ReadAllText($env:SPOTTO_TEST_STATE)) -AsHashtable }
function Mutations { param($State) return ,@($State.calls | Where-Object { $_.action -in @('create-role', 'update-assume-role-policy', 'tag-role', 'put-role-policy', 'attach-role-policy', 'delete-role-policy') }) }
function Run-Wizard {
    param([string[]]$Options = @(), [int]$ExpectedExit = 0, [string[]]$Answers, [switch]$OmitConfirmation)
    $output = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.json')
    $arguments = @('-NoProfile', '-File', $entrypoint, '-SetupPackagePath', $packagePath, '-OutputPath', $output)
    $interactive = $PSBoundParameters.ContainsKey('Answers')
    if (-not $interactive) {
        $arguments += '-NonInteractive'
        if (-not $OmitConfirmation) { $arguments += '-Confirm:$false' }
    }
    $arguments += $Options
    $log = if ($interactive) { $Answers | & pwsh @arguments 2>&1 | Out-String } else { & pwsh @arguments 2>&1 | Out-String }
    $code = $LASTEXITCODE
    Assert-Test ($code -eq $ExpectedExit) "wizard exit $code (expected $ExpectedExit): $log"
    Assert-Test (-not $log.Contains('sensitive-diagnostic-sentinel')) 'raw CLI diagnostics must not leak'
    $report = if (Test-Path -LiteralPath $output) { ConvertFrom-Json ([IO.File]::ReadAllText($output)) -AsHashtable } else { $null }
    return @{ Report = $report; Log = $log; Path = $output }
}
try {
    if ($IsWindows) { throw 'The offline process fixture requires Linux/macOS, Python 3 and PowerShell 7.4+. Customer setup supports Windows AWS CLI v2.' }
    $fakeCli = Join-Path $testRoot 'aws'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'FakeAwsCli.py') -Destination $fakeCli
    [IO.File]::SetUnixFileMode($fakeCli, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    $env:PATH = "$testRoot$([IO.Path]::PathSeparator)$originalPath"
    $env:SPOTTO_TEST_STATE = Join-Path $testRoot 'state.json'
    $env:SPOTTO_TEST_ACCOUNT = '111122223333'
    $env:SPOTTO_TEST_WRONG_ACCOUNT = $null
    $env:SPOTTO_TEST_FAIL_ACTION = $null
    $env:SPOTTO_TEST_TRANSIENT_ACTION = $null
    $packagePath = Join-Path $testRoot 'setup.json'
    $accountId = '111122223333'
    $roleArn = "arn:aws:iam::${accountId}:role/SpottoReadOnlyRole"
    $bundle = @{
        schemaVersion = 1; roleName = 'SpottoReadOnlyRole'; rolePurposes = @('resource-discovery')
        trustedPrincipalArn = 'arn:aws:iam::999900001111:role/SpottoEngine'; trustedPrincipalAccountId = '999900001111'
        trustPolicy = @{ Version = '2012-10-17'; Statement = @(@{ Sid = 'AllowSpotto'; Effect = 'Allow'; Action = 'sts:AssumeRole'
            Principal = @{ AWS = 'arn:aws:iam::999900001111:role/SpottoEngine' }
            Condition = @{ StringEquals = @{ 'sts:ExternalId' = 'spotto-example-company-id' } } }) }
        managedPolicies = @(@{ name = 'SecurityAudit'; arn = 'arn:aws:iam::aws:policy/SecurityAudit' }, @{ name = 'ReadOnlyAccess'; arn = 'arn:aws:iam::aws:policy/ReadOnlyAccess' })
        guardrailPolicyName = 'SpottoGuardrails'; guardrailPolicy = @{ Version = '2012-10-17'; Statement = @(
            @{ Sid = 'DenyCredentialValueReads'; Effect = 'Deny'; Action = @('ssm:GetParameter', 'secretsmanager:GetSecretValue'); Resource = '*' },
            @{ Sid = 'DenyS3ObjectReadsWithoutBillingStoragePurpose'; Effect = 'Deny'; Action = 's3:GetObject*'; Resource = '*' }) }
    }
    $package = @{ kind = 'spotto.aws.setup'; schemaVersion = 1; companyId = 'company-example'
        configuration = @{ schemaVersion = 1; provider = 'AWS'; companyId = 'company-example'; updatedAt = '2026-10-05T00:00:00Z'; estates = @(
            @{ schemaVersion = 1; companyId = 'company-example'; estateId = 'estate-example'; name = 'Example'; kind = 'standalone'; enabled = $true; billingSources = @();
                accounts = @(@{ schemaVersion = 1; companyId = 'company-example'; estateId = 'estate-example'; accountId = $accountId; roleArn = $roleArn; name = 'Example'; purposes = @('resource-discovery'); enabled = $true }) }) }
        roles = @(@{ accountId = $accountId; roleArn = $roleArn; setup = @{ provider = 'AWS'; externalId = 'spotto-example-company-id'; onboardingBundle = $bundle } }) }
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))
    $read = Read-SpottoAwsSetupPackage $packagePath
    Assert-Test ($read.roles[0].accountId -ceq $accountId) 'package preserves 12-digit string IDs'

    # Only an explicit managed-policy array can distinguish current [] packages from malformed input.
    $managedShapeFailures = @()
    foreach ($shape in @('null', 'empty-object', 'object-entries', 'missing')) {
        $invalid = ConvertFrom-Json (ConvertTo-Json $package -Depth 100) -AsHashtable
        $invalidBundle = $invalid.roles[0].setup.onboardingBundle
        switch ($shape) {
            'null' { $invalidBundle.managedPolicies = $null }
            'empty-object' { $invalidBundle.managedPolicies = @{} }
            'object-entries' { $invalidBundle.managedPolicies = @{ SecurityAudit = @{ name = 'SecurityAudit'; arn = 'arn:aws:iam::aws:policy/SecurityAudit' } } }
            'missing' { $invalidBundle.Remove('managedPolicies') }
        }
        [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $invalid -Depth 100))
        $rejected = $false
        try { $null = Read-SpottoAwsSetupPackage $packagePath } catch { $rejected = $true }
        if (-not $rejected) { $managedShapeFailures += $shape }
    }
    Assert-Test ($managedShapeFailures.Count -eq 0) "malformed managed-policy shapes rejected: $($managedShapeFailures -join ', ')"
    $currentPackage = ConvertFrom-Json (ConvertTo-Json $package -Depth 100) -AsHashtable
    $currentPackage.roles[0].setup.onboardingBundle.managedPolicies = @()
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $currentPackage -Depth 100))
    $currentRead = Read-SpottoAwsSetupPackage $packagePath
    Assert-Test ($currentRead.roles[0].setup.onboardingBundle.managedPolicies.Count -eq 0) 'current explicit empty managed-policy arrays remain valid'
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))
    $legacyRead = Read-SpottoAwsSetupPackage $packagePath
    Assert-Test ($legacyRead.roles[0].setup.onboardingBundle.managedPolicies.Count -eq 2) 'legacy managed-policy arrays remain valid'

    # Guardrails have the same document contract as the optional inline policies.
    $guardrailShapeFailures = @()
    foreach ($shape in @('missing-policy', 'null-policy', 'empty-policy', 'missing-statements', 'empty-statements',
        'object-statement', 'string-statements', 'number-statements', 'boolean-statements')) {
        $invalid = ConvertFrom-Json (ConvertTo-Json $package -Depth 100) -AsHashtable
        $invalidBundle = $invalid.roles[0].setup.onboardingBundle
        switch ($shape) {
            'missing-policy' { $invalidBundle.Remove('guardrailPolicy') }
            'null-policy' { $invalidBundle.guardrailPolicy = $null }
            'empty-policy' { $invalidBundle.guardrailPolicy = @{} }
            'missing-statements' { $invalidBundle.guardrailPolicy = @{ Version = '2012-10-17' } }
            'empty-statements' { $invalidBundle.guardrailPolicy = @{ Statement = @() } }
            'object-statement' { $invalidBundle.guardrailPolicy = @{ Statement = @{ Effect = 'Deny'; Action = 's3:GetObject'; Resource = '*' } } }
            'string-statements' { $invalidBundle.guardrailPolicy = @{ Statement = 'not-a-statement-list' } }
            'number-statements' { $invalidBundle.guardrailPolicy = @{ Statement = 1 } }
            'boolean-statements' { $invalidBundle.guardrailPolicy = @{ Statement = $true } }
        }
        [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $invalid -Depth 100))
        $rejected = $false
        try { $null = Read-SpottoAwsSetupPackage $packagePath } catch { $rejected = $true }
        if (-not $rejected) { $guardrailShapeFailures += $shape }
    }
    Assert-Test ($guardrailShapeFailures.Count -eq 0) "malformed guardrail shapes rejected: $($guardrailShapeFailures -join ', ')"
    # Exercise the actual entrypoint too: malformed guardrails must stop before AWS.
    Write-State @{ roles = @{}; calls = @() }
    $invalidGuardrail = Run-Wizard @('-CheckOnly') -ExpectedExit 1
    Assert-Test ($null -eq $invalidGuardrail.Report -and @((Read-State).calls).Count -eq 0) 'invalid guardrails fail before AWS calls or handoff'
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))
    $validGuardrails = Read-SpottoAwsSetupPackage $packagePath
    Assert-Test ($validGuardrails.roles[0].setup.onboardingBundle.guardrailPolicy.Statement.Count -eq 2) 'valid nonempty guardrail statement arrays remain accepted'

    # Capabilities and documents must agree: missing/extra/empty policies cannot silently change access.
    $policyValidationFailures = @()
    foreach ($capability in @('billing-definition', 'billing-storage', 'commitments-planning')) {
        $field = if ($capability -eq 'commitments-planning') { 'commitmentsAccessPolicy' } else { 'billingAccessPolicy' }
        $policyName = if ($capability -eq 'commitments-planning') { 'SpottoCommitmentsPlanning' } else { 'SpottoBillingExportRead' }
        foreach ($variant in @('missing', 'unselected', 'null', 'empty-statements', 'object-statement', 'empty-object')) {
            $invalid = ConvertFrom-Json (ConvertTo-Json $package -Depth 100) -AsHashtable
            $invalidBundle = $invalid.roles[0].setup.onboardingBundle
            if ($variant -ne 'unselected') {
                $invalid.configuration.estates[0].accounts[0].purposes += $capability
                $invalidBundle.rolePurposes += $capability
                if ($capability -like 'billing-*') {
                    $invalid.configuration.estates[0].billingSources = @(@{ enabled = $true; definitionRoleAccountId = $accountId; storageRoleAccountId = $accountId })
                }
            }
            if ($variant -ne 'missing') {
                $invalidBundle[$field + 'Name'] = $policyName
                $invalidBundle[$field] = switch ($variant) {
                    'null' { $null }
                    'empty-statements' { @{ Statement = @() } }
                    'object-statement' { @{ Statement = @{ Effect = 'Allow'; Action = 's3:GetObject'; Resource = '*' } } }
                    'empty-object' { @{} }
                    default { @{ Statement = @(@{ Effect = 'Allow'; Action = 's3:GetObject'; Resource = '*' }) } }
                }
            }
            [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $invalid -Depth 100))
            $rejected = $false
            try { $null = Read-SpottoAwsSetupPackage $packagePath } catch { $rejected = $true }
            if (-not $rejected) { $policyValidationFailures += "$capability/$variant" }
        }
    }
    Assert-Test ($policyValidationFailures.Count -eq 0) "invalid capability policy packages rejected: $($policyValidationFailures -join ', ')"
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))

    # Map values are CLI profile names, never terminal control sequences.
    $controlMapPath = Join-Path $testRoot 'control-profiles.json'
    foreach ($control in @(0, 9, 10, 13, 27, 31, 127)) {
        [IO.File]::WriteAllText($controlMapPath, (ConvertTo-Json @{ $accountId = ('operator' + [char]$control + 'profile') }))
        Write-State @{ roles = @{}; calls = @() }
        $invalidMap = Run-Wizard @('-CheckOnly', '-ProfileMapPath', $controlMapPath) -ExpectedExit 1
        Assert-Test ($null -eq $invalidMap.Report -and $invalidMap.Log.Contains('Invalid profile map entry')) "control character $control is rejected during profile-map validation"
        Assert-Test (@((Read-State).calls).Count -eq 0) "control character $control is rejected before AWS calls"
    }
    [IO.File]::WriteAllText($controlMapPath, (ConvertTo-Json @{ $accountId = '' }))
    $emptyMap = Run-Wizard @('-CheckOnly', '-ProfileMapPath', $controlMapPath)
    Assert-Test ($emptyMap.Report.results[0].status -eq 'changes-required') 'explicit empty profile mapping still uses the current session'

    # Service diagnostics may follow credential-helper text; arbitrary parenthesized text is never an error code.
    Write-State @{ roles = @{}; calls = @() }
    $env:SPOTTO_TEST_ERROR_PREFIX = 'credential helper (sensitive-diagnostic-sentinel)'
    $missing = Invoke-SpottoAwsCliAttempt @('iam', 'get-role', '--role-name', 'SpottoReadOnlyRole') '' 'us-east-1' -AllowMissing
    Assert-Test ($null -eq $missing) 'real NoSuchEntity is recognized after unrelated diagnostic parentheses'
    $env:SPOTTO_TEST_FAIL_ACTION = 'get-role'
    $env:SPOTTO_TEST_ERROR_PREFIX = 'credential helper (NoSuchEntity)'
    $errorMessage = ''
    try { $null = Invoke-SpottoAwsCliAttempt @('iam', 'get-role', '--role-name', 'SpottoReadOnlyRole') '' 'us-east-1' -AllowMissing }
    catch { $errorMessage = $_.Exception.Message }
    Assert-Test ($errorMessage.Contains('failed (AccessDenied)')) 'diagnostic NoSuchEntity cannot hide a real AccessDenied as a missing role'
    $env:SPOTTO_TEST_ERROR_PREFIX = 'credential helper (sensitive-diagnostic-sentinel)'
    $env:SPOTTO_TEST_ERROR_CODE = 'sensitive-diagnostic-sentinel'
    $errorMessage = ''
    try { $null = Invoke-SpottoAwsCliAttempt @('iam', 'get-role', '--role-name', 'SpottoReadOnlyRole') '' 'us-east-1' -AllowMissing }
    catch { $errorMessage = $_.Exception.Message }
    Assert-Test ($errorMessage.Contains('failed (CliFailure)') -and -not $errorMessage.Contains('sensitive-diagnostic-sentinel')) 'unknown service codes and helper tokens cannot leak to the console'
    $env:SPOTTO_TEST_ERROR_CODE = 'AccessDenied'
    $env:SPOTTO_TEST_ERROR_PREFIX = 'credential helper (NoSuchEntity)'
    $env:SPOTTO_TEST_FAIL_ACTION = 'put-role-policy'
    Write-State @{ roles = @{}; calls = @() }
    try { $null = Invoke-SpottoAwsCli @('iam', 'put-role-policy') '' 'us-east-1' -RetryMissing } catch {}
    Assert-Test (@((Read-State).calls | Where-Object { $_.action -eq 'put-role-policy' }).Count -eq 1) 'diagnostic NoSuchEntity cannot trigger propagation retries for AccessDenied'
    $env:SPOTTO_TEST_ERROR_PREFIX = $null
    $env:SPOTTO_TEST_FAIL_ACTION = 'get-role'
    foreach ($safeCode in @('NoSuchEntity', 'AccessDenied', 'AccessDeniedException', 'EntityAlreadyExists', 'MalformedPolicyDocument',
        'InvalidClientTokenId', 'ExpiredToken', 'ExpiredTokenException', 'InvalidIdentityToken', 'ValidationError', 'LimitExceeded',
        'ServiceFailure', 'Throttling', 'ThrottlingException', 'RequestLimitExceeded', 'UnrecognizedClientException', 'SignatureDoesNotMatch')) {
        $env:SPOTTO_TEST_ERROR_CODE = $safeCode
        $errorMessage = ''
        try { $null = Invoke-SpottoAwsCliAttempt @('iam', 'get-role', '--role-name', 'SpottoReadOnlyRole') '' 'us-east-1' }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Test ($errorMessage.Contains("failed ($safeCode)")) "known safe service error code is retained: $safeCode"
    }
    $env:SPOTTO_TEST_ERROR_CODE = $null
    $env:SPOTTO_TEST_FAIL_ACTION = $null

    # Foreign company bindings are refused even with alternate operators, key casing or IAM's object Statement form.
    $trustValidationFailures = @()
    foreach ($operator in @('StringEquals', 'StringLike', 'StringEqualsIfExists', 'ForAnyValue:StringEquals', 'ForAllValues:StringLike')) {
        foreach ($shape in @('array', 'object')) {
            foreach ($key in @('sts:ExternalId', 'STS:EXTERNALID')) {
                $statement = @{ Effect = 'Allow'; Action = 'sts:AssumeRole'; Principal = @{ AWS = $bundle.trustedPrincipalArn }
                    Condition = @{ $operator = @{ $key = @('spotto-example-company-id', 'spotto-another-company') } } }
                $trust = @{ Version = '2012-10-17'; Statement = if ($shape -eq 'object') { $statement } else { @($statement) } }
                Write-State @{ roles = @{ $accountId = @{ Arn = $roleArn; RoleId = 'AROA111122223333'; Tags = @(); AssumeRolePolicyDocument = $trust;
                    inline = @{ SpottoGuardrails = $bundle.guardrailPolicy }; managed = @($bundle.managedPolicies | ForEach-Object { $_.arn }) } }; calls = @() }
                $rejected = $false
                try { $null = Get-SpottoAwsRoleState $package.roles[0] $package.companyId '' 'us-east-1' }
                catch { $rejected = $_.Exception.Message.Contains('another External ID') }
                if (-not $rejected) { $trustValidationFailures += "$operator/$shape/$key" }
                Assert-Test ((Mutations (Read-State)).Count -eq 0) "foreign trust inspection performs no writes: $operator/$shape/$key"
            }
        }
    }
    Assert-Test ($trustValidationFailures.Count -eq 0) "all foreign External ID forms refused: $($trustValidationFailures -join ', ')"
    $foreignRepair = Run-Wizard @('-RepairExistingRole') -ExpectedExit 1
    Assert-Test ($foreignRepair.Report.results[0].status -eq 'failed' -and (Mutations (Read-State)).Count -eq 0) 'explicit repair cannot replace a foreign alternate-operator company binding'
    foreach ($value in @('spotto-another-company', @('spotto-another-company'), @{ ambiguous = 'spotto-another-company' })) {
        $state = Read-State
        $state.roles[$accountId].AssumeRolePolicyDocument.Statement.Condition = @{ StringLike = @{ 'sts:ExternalId' = $value } }
        Write-State $state
        $rejected = $false
        try { $null = Get-SpottoAwsRoleState $package.roles[0] $package.companyId '' 'us-east-1' }
        catch { $rejected = $_.Exception.Message.Contains('another External ID') }
        Assert-Test $rejected 'foreign scalar, single-value array and ambiguous External ID values are refused'
    }
    $state = Read-State
    $state.roles[$accountId].AssumeRolePolicyDocument.Statement.Condition = @{ 'ForAnyValue:StringEquals' = @{ 'STS:EXTERNALID' = @('spotto-example-company-id', 'spotto-example-company-id') } }
    Write-State $state
    $sameCompany = Get-SpottoAwsRoleState $package.roles[0] $package.companyId '' 'us-east-1'
    Assert-Test (-not $sameCompany.Matches -and @($sameCompany.Steps | Where-Object { $_.Action -eq 'update-trust' }).Count -eq 1) 'same-company External ID arrays remain eligible for reviewed trust repair'

    Write-State @{ roles = @{}; calls = @() }
    $unattendedDefault = Run-Wizard -OmitConfirmation
    Assert-Test ($unattendedDefault.Report.results[0].status -eq 'changes-required') 'non-interactive without explicit approval defaults to read-only checks'
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'non-interactive default cannot mutate AWS'
    $unattendedConfirm = Run-Wizard -OmitConfirmation -Options @('-Confirm:$true')
    Assert-Test ($unattendedConfirm.Report.results[0].status -eq 'changes-required') 'Confirm true does not authorize unattended configuration'
    $unattendedPreview = Run-Wizard -OmitConfirmation -Options @('-WhatIf')
    Assert-Test ($unattendedPreview.Report.results[0].status -eq 'planned' -and (Mutations (Read-State)).Count -eq 0) 'WhatIf retains preview behavior without explicit unattended approval'
    $defaultMode = Run-Wizard -Answers @('')
    Assert-Test ($defaultMode.Report.results[0].status -eq 'changes-required') 'interactive Enter defaults to read-only checks'
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'interactive default cannot mutate AWS'
    $declined = Run-Wizard -Answers @('2', 'n')
    Assert-Test ($declined.Report.results[0].status -eq 'planned') 'declined interactive confirmation records planned outcome'
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'declining changes cannot mutate AWS'
    $check = Run-Wizard @('-CheckOnly')
    Assert-Test ($check.Report.results[0].status -eq 'changes-required') 'check-only identifies missing role'
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'check-only must never mutate AWS'
    $preview = Run-Wizard @('-WhatIf')
    Assert-Test ($preview.Report.results[0].status -eq 'planned') 'WhatIf is planned, never configured'
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'WhatIf must never mutate AWS'
    $create = Run-Wizard
    Assert-Test ($create.Report.results[0].status -eq 'configured') 'first run creates configured role'
    $state = Read-State
    Assert-Test ($state.roles[$accountId].inline.ContainsKey('SpottoGuardrails')) 'guardrail policy is deployed'
    $writeActions = @((Mutations $state) | ForEach-Object { $_.action })
    Assert-Test ([array]::IndexOf($writeActions, 'put-role-policy') -lt [array]::IndexOf($writeActions, 'attach-role-policy')) 'guardrails precede broad managed policies'
    Assert-Test ($state.roles[$accountId].AssumeRolePolicyDocument.Statement[0].Condition.StringEquals['sts:ExternalId'] -ceq 'spotto-example-company-id') 'trust requires issued External ID'
    $state.calls = @(); Write-State $state
    $rerun = Run-Wizard
    Assert-Test ($rerun.Report.results[0].status -eq 'configured' -and (Mutations (Read-State)).Count -eq 0) 'unchanged rerun performs no IAM writes'
    Assert-Test ((Run-Wizard @('-CheckOnly')).Report.results[0].status -eq 'configuration-matches') 'check-only validates configured policies'
    Assert-Test (-not ([IO.File]::ReadAllText($rerun.Path)).Contains('ExternalId')) 'handoff excludes External ID and trust bundle'
    Assert-Test ($rerun.Report.kind -ceq 'spotto.aws.manual-onboarding') 'handoff uses portal V1 kind'
    Assert-Test ($rerun.Report.configuration.companyId -ceq 'company-example') 'handoff retains company binding'

    # Modern packages leave obsolete discovery attachments visible for customer review without changing them.
    $withoutManaged = ConvertFrom-Json (ConvertTo-Json $package -Depth 100) -AsHashtable
    $withoutManaged.roles[0].setup.onboardingBundle.managedPolicies = @()
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $withoutManaged -Depth 100))
    $state = Read-State
    $state.roles[$accountId].managed += 'arn:aws:iam::111122223333:policy/CustomerPolicy'
    foreach ($mode in @('check', 'configure', 'preview')) {
        $state.calls = @(); Write-State $state
        $options = switch ($mode) { 'check' { @('-CheckOnly') } 'preview' { @('-WhatIf') } default { @() } }
        $legacy = Run-Wizard -Options $options
        $expectedStatus = if ($mode -eq 'check') { 'configuration-matches' } else { 'configured' }
        Assert-Test ($legacy.Report.results[0].status -eq $expectedStatus) "legacy attachments do not change matching status: $mode"
        Assert-Test ($legacy.Log.Contains('ReadOnlyAccess') -and $legacy.Log.Contains('SecurityAudit') -and $legacy.Log.Contains('WARNING:')) "obsolete discovery attachments are warned about: $mode"
        Assert-Test ((Mutations (Read-State)).Count -eq 0 -and (Read-State).roles[$accountId].managed.Count -eq 3) "all unrelated and legacy attachments are preserved: $mode"
    }
    # An attachment still requested by the package never produces an obsolete-attachment warning.
    $withoutManaged.roles[0].setup.onboardingBundle.managedPolicies = @(@{ name = 'SecurityAudit'; arn = 'arn:aws:iam::aws:policy/SecurityAudit' })
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $withoutManaged -Depth 100))
    $oneLegacy = Run-Wizard @('-CheckOnly')
    Assert-Test ($oneLegacy.Log.Contains('ReadOnlyAccess') -and -not $oneLegacy.Log.Contains('SecurityAudit') -and -not $oneLegacy.Log.Contains('CustomerPolicy')) 'warning names only obsolete documented discovery attachments'
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))

    # Simulate changes while the caller is deciding whether to approve a role update.
    $approvalRole = (Read-State).roles[$accountId]
    foreach ($change in @('foreign-owner', 'replaced', 'appeared', 'disappeared', 'policy-drift', 'session')) {
        Write-State @{ roles = if ($change -eq 'appeared') { @{} } else { @{ $accountId = $approvalRole } }; calls = @() }
        $approval = Get-SpottoAwsRoleState $package.roles[0] $package.companyId '' 'us-east-1'
        $changed = Read-State
        if ($change -eq 'foreign-owner') {
            $changed.roles[$accountId].Tags = @(@{ Key = 'SpottoCompanyId'; Value = 'other-company' })
        } elseif ($change -eq 'replaced') {
            $changed.roles[$accountId].RoleId = 'AROAREPLACED012345'
        } elseif ($change -eq 'appeared') {
            $changed.roles[$accountId] = $approvalRole
        } elseif ($change -eq 'disappeared') {
            $changed.roles.Remove($accountId)
        } elseif ($change -eq 'policy-drift') {
            $changed.roles[$accountId].inline.Remove('SpottoGuardrails')
        } else {
            $env:SPOTTO_TEST_WRONG_ACCOUNT = '000011112222'
        }
        $changed.calls = @(); Write-State $changed
        $rejected = $false
        try { Set-SpottoAwsRole $package.roles[0] $package.companyId $approval '' 'us-east-1' } catch { $rejected = $true }
        $env:SPOTTO_TEST_WRONG_ACCOUNT = $null
        Assert-Test $rejected "changed approval binding is rejected: $change"
        Assert-Test ((Mutations (Read-State)).Count -eq 0) "changed approval cannot issue IAM mutations: $change"
    }
    Write-State @{ roles = @{ $accountId = $approvalRole }; calls = @() }

    # An approved adoption must stop if CloudFormation takes ownership meanwhile,
    # even when the pending policy/tag steps have identical descriptions.
    $stackRaceRole = ConvertFrom-Json (ConvertTo-Json $approvalRole -Depth 100) -AsHashtable
    $stackRaceRole.Tags = @()
    $stackRaceRole.inline.Remove('SpottoGuardrails')
    Write-State @{ roles = @{ $accountId = $stackRaceRole }; calls = @() }
    $approval = Get-SpottoAwsRoleState $package.roles[0] $package.companyId '' 'us-east-1'
    $changed = Read-State
    $changed.roles[$accountId].Tags = @(@{ Key = 'aws:cloudformation:stack-id'; Value = 'NewOwnerStack' })
    $changed.calls = @(); Write-State $changed
    $rejected = $false
    try { Set-SpottoAwsRole $package.roles[0] $package.companyId $approval '' 'us-east-1' } catch { $rejected = $true }
    Assert-Test $rejected 'CloudFormation ownership acquired after approval must be rejected'
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'new stack ownership prevents all approved adoption writes'
    Write-State @{ roles = @{ $accountId = $approvalRole }; calls = @() }

    $state = Read-State
    $state.roles[$accountId].Tags = @()
    $state.roles[$accountId].inline['CustomerPolicy'] = @{ Version = '2012-10-17'; Statement = @() }
    $state.calls = @(); Write-State $state
    $matchingUnowned = Run-Wizard
    Assert-Test ($matchingUnowned.Report.results[0].status -eq 'configured' -and (Mutations (Read-State)).Count -eq 0) 'matching unowned role is configured without writes or adoption'
    Assert-Test ($matchingUnowned.Log.Contains('not tagged as managed by Setup-SpottoAws')) 'matching unowned role explains adoption is only needed for changes'
    Assert-Test ((Run-Wizard @('-CheckOnly')).Report.results[0].status -eq 'configuration-matches') 'check-only and configure agree for matching unowned role'
    $state = Read-State
    $state.roles[$accountId].inline.Remove('SpottoGuardrails')
    $state.roles[$accountId].AssumeRolePolicyDocument.Statement += @{ Sid = 'CustomerAudit'; Effect = 'Allow'; Action = 'sts:AssumeRole'; Principal = @{ AWS = 'arn:aws:iam::444455556666:root' } }
    $state.roles[$accountId]['PermissionsBoundary'] = @{ PermissionsBoundaryType = 'Policy'; PermissionsBoundaryArn = 'arn:aws:iam::111122223333:policy/CustomerBoundary' }
    $state.calls = @(); Write-State $state
    $drifted = Run-Wizard @('-CheckOnly')
    Assert-Test ($drifted.Report.results[0].status -eq 'changes-required' -and (Mutations (Read-State)).Count -eq 0) 'check-only reports drift without writes'
    Assert-Test ($drifted.Log.Contains('Add inline policy SpottoGuardrails') -and $drifted.Log.Contains('removes 1 existing statement(s)')) 'check-only lists exact policy and trust changes'
    Assert-Test ($drifted.Log.Contains('permissions boundary arn:aws:iam::111122223333:policy/CustomerBoundary')) 'permissions boundary is reported'
    $unowned = Run-Wizard -ExpectedExit 1
    Assert-Test ($unowned.Report.results[0].status -eq 'failed' -and (Mutations (Read-State)).Count -eq 0) 'unowned role cannot change without adoption'
    $state = Read-State; $state.calls = @(); Write-State $state
    $adopted = Run-Wizard @('-RepairExistingRole')
    Assert-Test ($adopted.Report.results[0].status -eq 'configured') 'explicit repair adopts role'
    $adoptActions = @((Mutations (Read-State)) | ForEach-Object { $_.action })
    Assert-Test (($adoptActions -join ',') -ceq 'put-role-policy,update-assume-role-policy,tag-role') 'adoption writes only the differences, guardrails before trust'
    Assert-Test ((Read-State).roles[$accountId].inline.ContainsKey('CustomerPolicy')) 'adoption preserves unrelated policies'
    $state = Read-State; $state.calls = @(); Write-State $state
    Assert-Test ((Run-Wizard).Report.results[0].status -eq 'configured' -and (Mutations (Read-State)).Count -eq 0) 'rerun after adoption is idempotent'
    $state = Read-State
    $state.roles[$accountId].inline['SpottoCommitmentsPlanning'] = @{ Version = '2012-10-17'; Statement = @() }
    Write-State $state
    $null = Run-Wizard
    Assert-Test (-not (Read-State).roles[$accountId].inline.ContainsKey('SpottoCommitmentsPlanning')) 'deselected Spotto permissions are removed'
    Assert-Test ((Read-State).roles[$accountId].inline.ContainsKey('CustomerPolicy')) 'permission removal preserves unrelated customer policies'
    $state = Read-State
    $state.roles[$accountId].Tags = @(@{ Key = 'SpottoCompanyId'; Value = 'another-company' }); $state.calls = @(); Write-State $state
    $null = Run-Wizard @('-RepairExistingRole') -ExpectedExit 1
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'another company role cannot be adopted'
    # Roles owned by terraform-aws-spotto are verified but never adopted or changed by the wizard.
    $state.roles[$accountId].Tags = @(@{ Key = 'SpottoCompanyId'; Value = 'company-example' }, @{ Key = 'SpottoManagedBy'; Value = 'Terraform' }); $state.calls = @(); Write-State $state
    $terraformRole = Run-Wizard @('-RepairExistingRole')
    Assert-Test ($terraformRole.Report.results[0].status -eq 'configured' -and (Mutations (Read-State)).Count -eq 0) 'matching Terraform-managed role is verified without writes'
    Assert-Test ($terraformRole.Log.Contains('managed by Terraform')) 'Terraform ownership is reported'
    Assert-Test ((Run-Wizard @('-CheckOnly')).Report.results[0].status -eq 'configuration-matches') 'check-only verifies a Terraform-managed role'
    $state = Read-State
    $state.roles[$accountId].inline.Remove('SpottoGuardrails'); $state.calls = @(); Write-State $state
    $terraformDrift = Run-Wizard @('-RepairExistingRole') -ExpectedExit 1
    Assert-Test ($terraformDrift.Report.results[0].status -eq 'failed' -and (Mutations (Read-State)).Count -eq 0) 'drifted Terraform-managed role cannot be adopted or changed'
    Assert-Test ($terraformDrift.Log.Contains('Add inline policy SpottoGuardrails')) 'drift on a Terraform-managed role is listed for the owning tool'
    $state = Read-State
    $state.roles[$accountId].Tags = @(@{ Key = 'aws:cloudformation:stack-name'; Value = 'CustomerStack' }); $state.calls = @(); Write-State $state
    $null = Run-Wizard @('-RepairExistingRole') -ExpectedExit 1
    Assert-Test ((Mutations (Read-State)).Count -eq 0) 'CloudFormation ownership cannot be bypassed'

    # Stack tags establish verify-only ownership even if a script marker is also present.
    foreach ($manager in @('', 'Terraform', 'CloudFormation', 'Setup-SpottoAws')) {
        $state = Read-State
        $state.roles[$accountId].inline['SpottoGuardrails'] = $bundle.guardrailPolicy
        $state.roles[$accountId].Tags = @(@{ Key = 'spottocompanyid'; Value = 'company-example' }, @{ Key = 'spottomanagedby'; Value = $manager })
        if ($manager -eq 'Setup-SpottoAws' -or $manager -eq 'CloudFormation') {
            $state.roles[$accountId].Tags += @{ Key = 'aws:cloudformation:stack-id'; Value = 'CustomerStack' }
        }
        $state.calls = @(); Write-State $state
        $verified = Run-Wizard @('-RepairExistingRole')
        Assert-Test ($verified.Report.results[0].status -eq 'configured' -and (Mutations (Read-State)).Count -eq 0) "matching external-manager role is verify-only: '$manager'"
        Assert-Test ((Run-Wizard @('-CheckOnly')).Report.results[0].status -eq 'configuration-matches') "external-manager role supports read-only verification: '$manager'"
        $state = Read-State
        $state.roles[$accountId].inline.Remove('SpottoGuardrails'); $state.calls = @(); Write-State $state
        $blocked = Run-Wizard @('-RepairExistingRole') -ExpectedExit 1
        Assert-Test ($blocked.Report.results[0].status -eq 'failed' -and (Mutations (Read-State)).Count -eq 0) "external-manager role cannot be repaired: '$manager'"
    }

    Write-State @{ roles = @{}; calls = @() }
    $env:SPOTTO_TEST_WRONG_ACCOUNT = '000011112222'
    $wrong = Run-Wizard -ExpectedExit 1
    Assert-Test ($null -eq $wrong.Report -and (Mutations (Read-State)).Count -eq 0) 'wrong AWS session stops before any changes or handoff'
    $env:SPOTTO_TEST_WRONG_ACCOUNT = $null
    $env:SPOTTO_TEST_FAIL_ACTION = 'get-role'
    $denied = Run-Wizard -ExpectedExit 1
    Assert-Test ($denied.Report.results[0].status -eq 'failed' -and (Mutations (Read-State)).Count -eq 0) 'AccessDenied is not interpreted as a missing role'
    $env:SPOTTO_TEST_FAIL_ACTION = 'attach-role-policy'
    $partial = Run-Wizard -ExpectedExit 1
    Assert-Test ($partial.Report.results[0].status -eq 'failed') 'partial provisioning failure is reported'
    $env:SPOTTO_TEST_FAIL_ACTION = $null
    $state = Read-State; $state.calls = @(); Write-State $state
    Assert-Test ((Run-Wizard).Report.results[0].status -eq 'configured') 'partial role creation can be repaired on rerun'
    $repairActions = @((Mutations (Read-State)) | ForEach-Object { $_.action })
    Assert-Test (($repairActions -join ',') -ceq 'attach-role-policy,attach-role-policy') 'repair rerun only attaches the missing managed policies'
    Write-State @{ roles = @{}; calls = @() }
    $env:SPOTTO_TEST_TRANSIENT_ACTION = 'put-role-policy'
    Assert-Test ((Run-Wizard).Report.results[0].status -eq 'configured') 'transient IAM propagation retries complete setup'
    Assert-Test ((Read-State).missingCount -eq 2) 'propagation errors were exercised through real CLI processes'
    $env:SPOTTO_TEST_TRANSIENT_ACTION = $null
    Write-State @{ roles = @{}; calls = @() }
    $env:AWS_CLI_ERROR_FORMAT = 'json'
    Assert-Test ((Run-Wizard).Report.results[0].status -eq 'configured') 'configured structured AWS errors do not break role creation'
    Assert-Test (@((Read-State).calls | Where-Object { $_.errorFormat -ne 'legacy' }).Count -eq 0) 'every child uses deterministic legacy error format'
    Assert-Test ($env:AWS_CLI_ERROR_FORMAT -ceq 'json') 'operator environment is not modified'
    $env:AWS_CLI_ERROR_FORMAT = $null

    # A separate billing-storage account keeps its leading zero and gets only its generated source scopes.
    $organizationPackage = ConvertFrom-Json (ConvertTo-Json $package -Depth 100) -AsHashtable
    $storageAccountId = '000011112222'
    $storageRoleArn = "arn:aws:iam::${storageAccountId}:role/SpottoReadOnlyRole"
    $estate = $organizationPackage.configuration.estates[0]
    $estate.kind = 'organization'
    $estate['organization'] = @{ schemaVersion = 1; companyId = $package.companyId; estateId = $estate.estateId;
        organizationId = 'o-example12345'; managementAccountId = $accountId; accountSource = 'manual'; roleDeploymentMode = 'customer-managed'; excludedAccounts = @() }
    $estate.accounts[0].purposes = @('resource-discovery', 'billing-definition', 'commitments-planning')
    $estate.accounts += @{ schemaVersion = 1; companyId = $package.companyId; estateId = $estate.estateId; accountId = $storageAccountId;
        roleArn = $storageRoleArn; name = 'Billing storage'; purposes = @('resource-discovery', 'billing-storage'); enabled = $true }
    $estate.billingSources = @(@{ schemaVersion = 1; companyId = $package.companyId; estateId = $estate.estateId; billingSourceId = 'billing-example'; name = 'Example billing';
        definitionRoleAccountId = $accountId; payerAccountId = $accountId; storageRoleAccountId = $storageAccountId; enabled = $true;
        coverage = @{ type = 'estate' }; export = @{ type = 'DATA_EXPORTS'; exportArn = "arn:aws:bcm-data-exports:us-east-1:${accountId}:export/example";
            exportName = 'example'; destination = @{ bucketName = 'example-cost-exports'; basePrefix = 'billing'; region = 'us-east-1'; bucketOwnerAccountId = $storageAccountId } } })
    $definitionBundle = $organizationPackage.roles[0].setup.onboardingBundle
    $definitionBundle.rolePurposes = $estate.accounts[0].purposes
    $definitionBundle['billingAccessPolicyName'] = 'SpottoBillingExportRead'
    $definitionBundle['billingAccessPolicy'] = @{ Version = '2012-10-17'; Statement = @(@{ Sid = 'ReadExactDefinition'; Effect = 'Allow';
        Action = 'bcm-data-exports:GetExport'; Resource = $estate.billingSources[0].export.exportArn }) }
    $definitionBundle['commitmentsAccessPolicyName'] = 'SpottoCommitmentsPlanning'
    $definitionBundle['commitmentsAccessPolicy'] = @{ Version = '2012-10-17'; Statement = @(@{ Sid = 'RefreshRecommendations'; Effect = 'Allow'; Action = 'ce:StartSavingsPlansPurchaseRecommendationGeneration'; Resource = '*' }) }
    $storageRole = ConvertFrom-Json (ConvertTo-Json $package.roles[0] -Depth 100) -AsHashtable
    $storageRole.accountId = $storageAccountId; $storageRole.roleArn = $storageRoleArn
    $storageBundle = $storageRole.setup.onboardingBundle
    $storageBundle.rolePurposes = @('resource-discovery', 'billing-storage')
    $storageBundle['billingAccessPolicyName'] = 'SpottoBillingExportRead'
    $storageBundle['billingAccessPolicy'] = @{ Version = '2012-10-17'; Statement = @(@{ Sid = 'ReadExactObjects'; Effect = 'Allow';
        Action = 's3:GetObject'; Resource = 'arn:aws:s3:::example-cost-exports/billing/example/*' }) }
    $storageBundle.guardrailPolicy.Statement[1] = @{ Sid = 'DenyS3ObjectReadsOutsideBillingScopes'; Effect = 'Deny'; Action = 's3:GetObject*'; NotResource = 'arn:aws:s3:::example-cost-exports/billing/example/*' }
    $organizationPackage.roles += $storageRole
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $organizationPackage -Depth 100))
    $mapPath = Join-Path $testRoot 'profiles.json'
    [IO.File]::WriteAllText($mapPath, (ConvertTo-Json @{ $accountId = "account-$accountId"; $storageAccountId = "account-$storageAccountId" }))
    Write-State @{ roles = @{}; calls = @() }
    $organization = Run-Wizard @('-ProfileMapPath', $mapPath)
    Assert-Test ($organization.Report.results.Count -eq 2 -and $organization.Report.results[1].accountId -ceq $storageAccountId) 'multiple profiles preserve leading-zero account IDs'
    $state = Read-State
    Assert-Test ($state.roles[$accountId].inline.SpottoBillingExportRead.Statement[0].Resource -ceq $estate.billingSources[0].export.exportArn) 'definition permission remains on exact export in payer account'
    Assert-Test ($state.roles[$storageAccountId].inline.SpottoBillingExportRead.Statement[0].Resource -ceq 'arn:aws:s3:::example-cost-exports/billing/example/*') 'storage permission remains on exact delivery path in storage account'
    Assert-Test (-not $state.roles[$storageAccountId].inline.ContainsKey('SpottoCommitmentsPlanning')) 'optional commitments permissions are not added to another account'
    $actions = @($state.calls | ForEach-Object { $_.action })
    Assert-Test ($actions[0] -eq 'get-caller-identity' -and $actions[1] -eq 'get-caller-identity') 'all profile identities are checked before provisioning'
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))

    $package.configuration['secretAccessKey'] = 'forbidden'
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))
    $rejected = $false
    try { $null = Read-SpottoAwsSetupPackage $packagePath } catch { $rejected = $true }
    Assert-Test $rejected 'credential-shaped fields in configuration are rejected'
    $package.configuration.Remove('secretAccessKey')
    $package.configuration.schemaVersion = '1'
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))
    $rejected = $false
    try { $null = Read-SpottoAwsSetupPackage $packagePath } catch { $rejected = $true }
    Assert-Test $rejected 'string configuration schema versions are rejected before AWS calls'
    $package.configuration.schemaVersion = 1
    $package.roles[0].setup.onboardingBundle.trustPolicy.Statement[0].Principal.AWS = '*'
    [IO.File]::WriteAllText($packagePath, (ConvertTo-Json $package -Depth 100))
    $rejected = $false
    try { $null = Read-SpottoAwsSetupPackage $packagePath } catch { $rejected = $true }
    Assert-Test $rejected 'wildcard trust is rejected'
    Write-Host "AWS onboarding offline tests passed: $script:assertions assertions (real script entrypoint, fake AWS CLI processes)." -ForegroundColor Green
} finally {
    $env:PATH = $originalPath
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name]) }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
