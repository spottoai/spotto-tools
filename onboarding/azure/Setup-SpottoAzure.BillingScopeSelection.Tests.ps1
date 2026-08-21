<#
.SYNOPSIS
    Native regression tests for billing scope selection input handling.

.DESCRIPTION
    Tenants can expose dozens of accessible billing scopes; selecting them should
    not require typing every index. These tests cover 'all' and numeric range
    tokens plus the end-to-end selector without contacting Azure.
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
    "Test-YesResponse",
    "Expand-SelectionToken",
    "Select-BillingCostExportScopes"
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

# --- Expand-SelectionToken ---
# Returns 1-based indices for index-like tokens, an empty array for index-like
# but out-of-range tokens, and $null for tokens that are not index-like.

Assert-Equal "7" ((Expand-SelectionToken -Token "7" -MaxValue 35) -join ",") "single number expands to itself"
Assert-Equal "3,4,5" ((Expand-SelectionToken -Token "3-5" -MaxValue 35) -join ",") "range expands to each index"
Assert-Equal "3,4,5" ((Expand-SelectionToken -Token " 3 - 5 " -MaxValue 35) -join ",") "range tolerates whitespace"
Assert-Equal ((1..35) -join ",") ((Expand-SelectionToken -Token "all" -MaxValue 35) -join ",") "'all' expands to every index"
Assert-Equal ((1..35) -join ",") ((Expand-SelectionToken -Token "ALL" -MaxValue 35) -join ",") "'all' is case-insensitive"
Assert-Equal "" ((Expand-SelectionToken -Token "40" -MaxValue 35) -join ",") "out-of-range number yields no indices"
Assert-Equal "" ((Expand-SelectionToken -Token "30-40" -MaxValue 35) -join ",") "out-of-range range yields no indices"
Assert-Equal "" ((Expand-SelectionToken -Token "5-3" -MaxValue 35) -join ",") "reversed range yields no indices"
Assert-Equal $true ($null -eq (Expand-SelectionToken -Token "/providers/Microsoft.Billing/billingAccounts/x" -MaxValue 35)) "scope ID is not index-like"
Assert-Equal $true ($null -eq (Expand-SelectionToken -Token "" -MaxValue 35)) "empty token is not index-like"
Assert-Equal $true ($null -eq (Expand-SelectionToken -Token "all" -MaxValue 35 -AllowAll $false)) "'all' is rejected when AllowAll is disabled"
Assert-Equal "3,4,5" ((Expand-SelectionToken -Token "3-5" -MaxValue 35 -AllowAll $false) -join ",") "ranges still work when AllowAll is disabled"

# --- Select-BillingCostExportScopes end-to-end ---

function Write-SectionLabel { param([string]$Message) }
function Write-DetailRow { param([string]$Label, [string]$Value) }
function Write-Info { param([string]$Message) }
function Write-Warning-Custom { param([string]$Message) $script:Warnings += $Message }

$script:MockScopes = @(1..35 | ForEach-Object {
    [pscustomobject]@{
        Scope = "/providers/Microsoft.Billing/billingAccounts/acct$_"
        Label = "Account $_"
        Type = "Billing account"
    }
})
function Get-AccessibleBillingCostScopes { $script:MockScopes }
function Normalize-CostExportScope { param([string]$Scope) $Scope }
function Test-BillingCostExportScope { param([string]$Scope) $Scope -like "/providers/Microsoft.Billing/*" }
function Get-CostExportScopeLabel { param([string]$Scope) $Scope }

$script:PromptAnswers = @()
function Read-Host {
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $answer, $script:PromptAnswers = $script:PromptAnswers
    $answer
}

# 'all' selects every discovered scope with one word.
$script:Warnings = @()
$script:billingScopeExportStatus = ""
$script:PromptAnswers = @("yes", "all")
$result = @(Select-BillingCostExportScopes)
Assert-Equal 35 $result.Count "'all' selects every accessible billing scope"
Assert-Equal "processed" $script:billingScopeExportStatus "'all' marks billing scope status processed"

# Ranges and numbers combine and deduplicate.
$script:Warnings = @()
$script:PromptAnswers = @("yes", "1-3, 3, 10")
$result = @(Select-BillingCostExportScopes)
Assert-Equal 4 $result.Count "ranges and numbers combine with deduplication"

# Pasted scope IDs still work alongside indices.
$script:Warnings = @()
$script:PromptAnswers = @("yes", "2, /providers/Microsoft.Billing/billingAccounts/pasted")
$result = @(Select-BillingCostExportScopes)
Assert-Equal 2 $result.Count "index and pasted scope ID combine"

# Out-of-range index warns instead of being treated as a scope ID.
$script:Warnings = @()
$script:PromptAnswers = @("yes", "40")
$result = @(Select-BillingCostExportScopes)
Assert-Equal 0 $result.Count "out-of-range index selects nothing"
Assert-Equal 1 $script:Warnings.Count "out-of-range index produces a warning"

# Enter still skips.
$script:Warnings = @()
$script:PromptAnswers = @("yes", "")
$result = @(Select-BillingCostExportScopes)
Assert-Equal 0 $result.Count "empty selection skips billing scopes"
Assert-Equal "skipped" $script:billingScopeExportStatus "empty selection marks status skipped"

if ($script:TestFailures.Count -gt 0) {
    Write-Host "`n$($script:TestFailures.Count) test(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll tests passed." -ForegroundColor Green
exit 0
