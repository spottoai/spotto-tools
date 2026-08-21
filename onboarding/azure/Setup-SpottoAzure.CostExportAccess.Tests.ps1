<#
.SYNOPSIS
    Native regression tests for operator Cost Management export access preflight
    and guided self-elevation.

.DESCRIPTION
    Creating Cost Management exports needs Microsoft.CostManagement/exports/write,
    which User Access Administrator alone does not grant. These tests cover the
    preflight assessment and the self-elevation decision flow without contacting
    Azure by mocking the permission and role-assignment helpers.
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
    "Get-OperatorCostExportAccessAssessment",
    "Ensure-OperatorCostExportAccess"
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

# Shared mocks. Permission results are keyed by "<scope>|<action>".
function Write-SectionLabel { param([string]$Message) }
function Write-Success { param([string]$Message) }
function Write-Info { param([string]$Message) }
function Write-Warning-Custom { param([string]$Message) }
function Write-Error-Custom { param([string]$Message) }
function Write-Skipped { param([string]$Message) }

function Test-AzurePermissionActionAtScope {
    param([string]$Scope, [string]$RequiredAction)
    [bool]$script:MockPermissions["$Scope|$RequiredAction"]
}

$subA = [pscustomobject]@{ Name = "sub-a"; Id = "00000000-0000-0000-0000-00000000000a" }
$subB = [pscustomobject]@{ Name = "sub-b"; Id = "00000000-0000-0000-0000-00000000000b" }
$subC = [pscustomobject]@{ Name = "sub-c"; Id = "00000000-0000-0000-0000-00000000000c" }
$exportAction = "Microsoft.CostManagement/exports/write"
$assignAction = "Microsoft.Authorization/roleAssignments/write"

# --- Get-OperatorCostExportAccessAssessment ---

$script:MockPermissions = @{
    "/subscriptions/$($subA.Id)|$exportAction" = $true
    "/subscriptions/$($subB.Id)|$exportAction" = $false
    "/subscriptions/$($subB.Id)|$assignAction" = $true
    "/subscriptions/$($subC.Id)|$exportAction" = $false
    "/subscriptions/$($subC.Id)|$assignAction" = $false
}

$assessment = @(Get-OperatorCostExportAccessAssessment -Subscriptions @($subA, $subB, $subC))
Assert-Equal 3 $assessment.Count "assessment returns one entry per subscription"
Assert-Equal $true $assessment[0].HasExportWrite "granted subscription reports export write access"
Assert-Equal $false $assessment[0].CanSelfElevate "granted subscription does not need self-elevation"
Assert-Equal $false $assessment[1].HasExportWrite "elevatable subscription reports missing export write access"
Assert-Equal $true $assessment[1].CanSelfElevate "elevatable subscription reports self-elevation is possible"
Assert-Equal $false $assessment[2].HasExportWrite "blocked subscription reports missing export write access"
Assert-Equal $false $assessment[2].CanSelfElevate "blocked subscription reports self-elevation is not possible"

# --- Ensure-OperatorCostExportAccess ---

function Get-SignedInPrincipalObjectId { "9a860000-0000-0000-0000-000000000001" }
function Wait-AzurePermissionActionAtScope { param([string]$Scope, [string]$RequiredAction, [int]$TimeoutSeconds, [int]$PollSeconds) $true }

# The wizard initializes these at startup; mirror that here.
$script:operatorElevatedExportScopes = @()

$script:AssignedScopes = @()
function New-AzRoleAssignment {
    param([string]$ObjectId, [string]$RoleDefinitionName, [string]$Scope)
    $script:AssignedScopes += "$RoleDefinitionName@$Scope"
    [pscustomobject]@{ Scope = $Scope }
}

$script:PromptAnswers = @()
function Read-Host {
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $answer, $script:PromptAnswers = $script:PromptAnswers
    $answer
}

# Granted subscription passes through without prompting or assigning.
$script:AssignedScopes = @()
$script:PromptAnswers = @()
$ready = @(Ensure-OperatorCostExportAccess -Subscriptions @($subA))
Assert-Equal 1 $ready.Count "granted subscription is kept for export setup"
Assert-Equal "sub-a" $ready[0].Name "granted subscription passes through unchanged"
Assert-Equal 0 $script:AssignedScopes.Count "granted subscription triggers no role assignment"

# Elevatable subscription with a yes answer gets Cost Management Contributor and is kept.
$script:AssignedScopes = @()
$script:PromptAnswers = @("yes")
$ready = @(Ensure-OperatorCostExportAccess -Subscriptions @($subB))
Assert-Equal 1 $ready.Count "elevated subscription is kept for export setup"
Assert-Equal "Cost Management Contributor@/subscriptions/$($subB.Id)" $script:AssignedScopes[0] "self-elevation assigns Cost Management Contributor at the subscription scope"

# Elevatable subscription defaults to yes on an empty answer.
$script:AssignedScopes = @()
$script:PromptAnswers = @("")
$ready = @(Ensure-OperatorCostExportAccess -Subscriptions @($subB))
Assert-Equal 1 $ready.Count "empty answer defaults to self-elevation"
Assert-Equal 1 $script:AssignedScopes.Count "empty answer assigns the role"

# Elevatable subscription with a no answer is excluded and no role is assigned.
$script:AssignedScopes = @()
$script:PromptAnswers = @("no")
$ready = @(Ensure-OperatorCostExportAccess -Subscriptions @($subB))
Assert-Equal 0 $ready.Count "declined self-elevation excludes the subscription from export setup"
Assert-Equal 0 $script:AssignedScopes.Count "declined self-elevation assigns no role"

# Blocked subscription is excluded without prompting.
$script:AssignedScopes = @()
$script:PromptAnswers = @()
$ready = @(Ensure-OperatorCostExportAccess -Subscriptions @($subC))
Assert-Equal 0 $ready.Count "blocked subscription is excluded from export setup"
Assert-Equal 0 $script:AssignedScopes.Count "blocked subscription assigns no role"

# Mixed set keeps granted and elevated, drops blocked.
$script:AssignedScopes = @()
$script:PromptAnswers = @("yes")
$ready = @(Ensure-OperatorCostExportAccess -Subscriptions @($subA, $subB, $subC))
Assert-Equal 2 $ready.Count "mixed set keeps granted and elevated subscriptions only"
Assert-Equal "sub-a" $ready[0].Name "mixed set keeps the granted subscription"
Assert-Equal "sub-b" $ready[1].Name "mixed set keeps the elevated subscription"

# A failed role assignment excludes the subscription instead of aborting.
$script:AssignedScopes = @()
$script:PromptAnswers = @("yes")
function New-AzRoleAssignment { param([string]$ObjectId, [string]$RoleDefinitionName, [string]$Scope) throw "Forbidden" }
$ready = @(Ensure-OperatorCostExportAccess -Subscriptions @($subB))
Assert-Equal 0 $ready.Count "failed self-elevation excludes the subscription without aborting"

if ($script:TestFailures.Count -gt 0) {
    Write-Host "`n$($script:TestFailures.Count) test(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll tests passed." -ForegroundColor Green
exit 0
