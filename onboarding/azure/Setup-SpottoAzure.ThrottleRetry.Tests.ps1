<#
.SYNOPSIS
    Native regression tests for Cost Management 429 throttle retry handling.

.DESCRIPTION
    Queueing 13 months of backfill exports per dataset per subscription routinely
    trips Cost Management rate limits ("429 : Too many requests. Please retry after
    60 seconds."). These tests cover throttle detection, Retry-After parsing, and
    the retry wrapper without contacting Azure.
#>

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "Setup-SpottoAzure.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
    throw "Setup-SpottoAzure.ps1 failed to parse: $($parseErrors | Out-String)"
}

$functionsUnderTest = @(
    "Test-TooManyRequestsMessage",
    "Get-RetryAfterSecondsFromMessage",
    "Invoke-WithCostManagementThrottleRetry"
)

$found = @{}
foreach ($node in $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $functionsUnderTest -contains $n.Name
    }, $true)) {
    Invoke-Expression $node.Extent.Text
    $found[$node.Name] = $true
}

$script:TestFailures = @()

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)

    if ("$Expected" -eq "$Actual") {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red
        $script:TestFailures += $Name
    }
}

foreach ($fn in $functionsUnderTest) {
    Assert-Equal $true ([bool]$found[$fn]) "function '$fn' exists in Setup-SpottoAzure.ps1"
}

if ($script:TestFailures.Count -gt 0) {
    Write-Host "`n$($script:TestFailures.Count) test(s) failed." -ForegroundColor Red
    exit 1
}

# --- Test-TooManyRequestsMessage ---

Assert-Equal $true (Test-TooManyRequestsMessage -Message "429 : Too many requests. Please retry after 60 seconds.") "detects the observed 429 error message"
Assert-Equal $true (Test-TooManyRequestsMessage -Message "TooManyRequests: rate limit exceeded") "detects TooManyRequests error code"
Assert-Equal $false (Test-TooManyRequestsMessage -Message "RBACAccessDenied : The client does not have authorization") "does not match RBAC denials"
Assert-Equal $false (Test-TooManyRequestsMessage -Message "queued 4290 rows") "does not match 429 embedded in a longer number"
Assert-Equal $false (Test-TooManyRequestsMessage -Message "") "empty message is not a throttle"

# --- Get-RetryAfterSecondsFromMessage ---

Assert-Equal 60 (Get-RetryAfterSecondsFromMessage -Message "429 : Too many requests. Please retry after 60 seconds.") "parses retry-after seconds from the message"
Assert-Equal 15 (Get-RetryAfterSecondsFromMessage -Message "Please retry after 15 seconds") "parses other retry-after values"
Assert-Equal 60 (Get-RetryAfterSecondsFromMessage -Message "Too many requests") "defaults to 60 seconds when no hint is present"
Assert-Equal 300 (Get-RetryAfterSecondsFromMessage -Message "Please retry after 4000 seconds") "clamps excessive retry-after hints to 300 seconds"

# --- Invoke-WithCostManagementThrottleRetry ---

function Write-Info { param([string]$Message) }
$script:SleepCalls = @()
function Start-Sleep { param([int]$Seconds) $script:SleepCalls += $Seconds }

# Succeeds first try without sleeping.
$script:SleepCalls = @()
$result = Invoke-WithCostManagementThrottleRetry -OperationLabel "test op" -Operation { "ok" }
Assert-Equal "ok" $result "successful operation returns its result"
Assert-Equal 0 $script:SleepCalls.Count "successful operation does not sleep"

# Retries on 429 with the hinted delay, then succeeds.
$script:SleepCalls = @()
$script:AttemptCount = 0
$result = Invoke-WithCostManagementThrottleRetry -OperationLabel "test op" -Operation {
    $script:AttemptCount++
    if ($script:AttemptCount -lt 3) {
        throw "429 : Too many requests. Please retry after 60 seconds."
    }
    "ok after retries"
}
Assert-Equal "ok after retries" $result "throttled operation succeeds after retries"
Assert-Equal 2 $script:SleepCalls.Count "throttled operation sleeps once per retry"
Assert-Equal 60 $script:SleepCalls[0] "throttled operation honours the retry-after hint"

# Non-throttle errors are rethrown immediately.
$script:SleepCalls = @()
$threw = $false
try {
    Invoke-WithCostManagementThrottleRetry -OperationLabel "test op" -Operation {
        throw "RBACAccessDenied : The client does not have authorization"
    } | Out-Null
} catch {
    $threw = $true
}
Assert-Equal $true $threw "non-throttle error is rethrown"
Assert-Equal 0 $script:SleepCalls.Count "non-throttle error does not retry"

# Gives up after MaxRetries and rethrows the throttle error.
$script:SleepCalls = @()
$threw = $false
try {
    Invoke-WithCostManagementThrottleRetry -OperationLabel "test op" -MaxRetries 2 -Operation {
        throw "429 : Too many requests. Please retry after 60 seconds."
    } | Out-Null
} catch {
    $threw = $true
}
Assert-Equal $true $threw "persistent throttle eventually rethrows"
Assert-Equal 2 $script:SleepCalls.Count "persistent throttle retries exactly MaxRetries times"

if ($script:TestFailures.Count -gt 0) {
    Write-Host "`n$($script:TestFailures.Count) test(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll tests passed." -ForegroundColor Green
exit 0
