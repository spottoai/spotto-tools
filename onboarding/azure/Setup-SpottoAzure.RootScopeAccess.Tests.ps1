<#
.SYNOPSIS
    Native regression tests for tenant root scope role-assignment validation.

.DESCRIPTION
    The Microsoft.Authorization/permissions API is not available at tenant root scope (/),
    so root-scope access must be validated by inspecting the signed-in principal's
    root-scope role assignments. These tests run without contacting Azure by mocking
    the REST helper.
#>

$ErrorActionPreference = "Stop"

# Extract the functions under test from the setup script without executing the wizard.
$scriptPath = Join-Path $PSScriptRoot "Setup-SpottoAzure.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
    throw "Setup-SpottoAzure.ps1 failed to parse: $($parseErrors | Out-String)"
}

$functionsUnderTest = @(
    "Test-AzureActionMatchesPattern",
    "Test-RootScopeRoleAssignmentGrantsAction"
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

    if ($Expected -eq $Actual) {
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

# Mocked helpers used by the function under test.
function Write-Info { param([string]$Message) }

function New-RoleAssignment {
    param([string]$Scope, [string]$RoleDefinitionId)
    [pscustomobject]@{ properties = [pscustomobject]@{ scope = $Scope; roleDefinitionId = $RoleDefinitionId } }
}

function New-RoleDefinition {
    param([string[]]$Actions, [string[]]$NotActions = @())
    [pscustomobject]@{
        properties = [pscustomobject]@{
            permissions = @([pscustomobject]@{ actions = $Actions; notActions = $NotActions })
        }
    }
}

$requiredAction = "Microsoft.Authorization/roleAssignments/write"
$principalId = "9a860000-0000-0000-0000-000000000001"

function Invoke-TestCase {
    param(
        [string]$Name,
        [bool]$Expected,
        [object[]]$Assignments,
        [hashtable]$RoleDefinitionsById
    )

    $script:MockAssignments = $Assignments
    $script:MockRoleDefinitions = $RoleDefinitionsById

    function global:Invoke-AzRestGetJson {
        param([string]$Path)

        if ($Path -match "roleAssignments\?") {
            return [pscustomobject]@{ value = $script:MockAssignments }
        }

        foreach ($id in $script:MockRoleDefinitions.Keys) {
            if ($Path -like "$id*") {
                return $script:MockRoleDefinitions[$id]
            }
        }

        # Unknown paths behave like the ARM error payload: no .value, no .properties of interest.
        return [pscustomobject]@{ error = [pscustomobject]@{ code = "NotFound" } }
    }

    $actual = Test-RootScopeRoleAssignmentGrantsAction -PrincipalObjectId $principalId -RequiredAction $requiredAction
    Assert-Equal $Expected $actual $Name
}

$uaaRoleId = "/providers/Microsoft.Authorization/roleDefinitions/18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"
$readerRoleId = "/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
$deniedOwnerRoleId = "/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-00000000dead"

Invoke-TestCase -Name "User Access Administrator at root scope grants access" -Expected $true `
    -Assignments @(New-RoleAssignment -Scope "/" -RoleDefinitionId $uaaRoleId) `
    -RoleDefinitionsById @{ $uaaRoleId = (New-RoleDefinition -Actions @("*/read", "Microsoft.Authorization/*", "Microsoft.Support/*")) }

Invoke-TestCase -Name "Owner wildcard action at root scope grants access" -Expected $true `
    -Assignments @(New-RoleAssignment -Scope "/" -RoleDefinitionId $uaaRoleId) `
    -RoleDefinitionsById @{ $uaaRoleId = (New-RoleDefinition -Actions @("*")) }

Invoke-TestCase -Name "Reader at root scope does not grant access" -Expected $false `
    -Assignments @(New-RoleAssignment -Scope "/" -RoleDefinitionId $readerRoleId) `
    -RoleDefinitionsById @{ $readerRoleId = (New-RoleDefinition -Actions @("*/read")) }

Invoke-TestCase -Name "Role assignment at subscription scope is ignored" -Expected $false `
    -Assignments @(New-RoleAssignment -Scope "/subscriptions/00000000-0000-0000-0000-000000000002" -RoleDefinitionId $uaaRoleId) `
    -RoleDefinitionsById @{ $uaaRoleId = (New-RoleDefinition -Actions @("Microsoft.Authorization/*")) }

Invoke-TestCase -Name "notActions excluding the required action denies access" -Expected $false `
    -Assignments @(New-RoleAssignment -Scope "/" -RoleDefinitionId $deniedOwnerRoleId) `
    -RoleDefinitionsById @{ $deniedOwnerRoleId = (New-RoleDefinition -Actions @("*") -NotActions @("Microsoft.Authorization/roleAssignments/write")) }

Invoke-TestCase -Name "No root-scope assignments returns false" -Expected $false `
    -Assignments @() -RoleDefinitionsById @{}

Invoke-TestCase -Name "ARM error payload without value returns false" -Expected $false `
    -Assignments $null -RoleDefinitionsById @{}

$emptyPrincipal = Test-RootScopeRoleAssignmentGrantsAction -PrincipalObjectId "" -RequiredAction $requiredAction
Assert-Equal $false $emptyPrincipal "empty principal object ID returns false"

if ($script:TestFailures.Count -gt 0) {
    Write-Host "`n$($script:TestFailures.Count) test(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll tests passed." -ForegroundColor Green
exit 0
