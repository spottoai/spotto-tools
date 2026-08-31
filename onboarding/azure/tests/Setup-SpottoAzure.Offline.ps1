$ErrorActionPreference = "Stop"

$setupScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\Setup-SpottoAzure.ps1")).Path
$parseErrors = $null
$tokens = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Setup script does not parse."
}

$setupSource = Get-Content -LiteralPath $setupScriptPath -Raw
if ($setupSource -notmatch '(?s)\$configureBillingExports\s*=\s*Read-SetupConfirmation.+?-Prompt\s+"Set up the recommended Cost Management exports.+?-DefaultYes\s+\$true') {
    throw "Billing export setup is not an explicit default-yes choice in every setup mode."
}
if ($setupSource -notmatch '(?s)\$tryManagementGroupExports\s*=\s*Read-SetupConfirmation.+?-Prompt\s+"Try the management-group scope') {
    throw "Broad management-group billing export consent is not explicit in every setup mode."
}
$transcriptStopIndex = $setupSource.LastIndexOf('Stop-Transcript | Out-Null')
$secretHandoffIndex = $setupSource.LastIndexOf('Complete-SpottoClientSecretHandoff -Application $app')
if ($transcriptStopIndex -lt 0 -or $secretHandoffIndex -le $transcriptStopIndex) {
    throw "Secret creation and JSON handoff must remain after transcript shutdown."
}
if ($setupSource.Substring($transcriptStopIndex) -notmatch '(?s)Complete-SpottoClientSecretHandoff.+?Show-Credentials.+?Remove-OnboardingJsonAfterConfirmedImport') {
    throw "The post-transcript secret handoff, display, and explicit cleanup order changed."
}
if ($setupSource -notmatch '(?s)Resolve-SpottoAzureApplication.+?Ensure-SpottoServicePrincipal') {
    throw "Application ownership resolution or service-principal repair is not wired into setup."
}
if ($setupSource -notmatch '(?s)New-AzStorageAccount.+?SpottoPurpose\s*=.+?SpottoTenantId\s*=.+?spotto\s*=\s*\$BILLING_EXPORT_STORAGE_ALIAS_VALUE') {
    throw "New billing export storage is missing its Spotto ownership tags."
}
if ($setupSource -notmatch '(?s)Get-CostManagementContributorSelfRemediationTargets\s+-Results\s+\$requiredResults.+?Invoke-CostManagementContributorSelfRemediation.+?SelfRemediation\s*=\s*\$selfRemediation') {
    throw "Prerequisite Cost Management self-remediation is not wired into its returned outcome."
}

$functionNames = @(
    "Get-StableHashSuffix",
    "Get-BillingStorageAccountNameCandidates",
    "Resolve-BillingExportStorageAccountName",
    "Test-SpottoBillingStorageAccountOwnership",
    "Confirm-BillingStorageAccountReuse",
    "Test-YesResponse",
    "Read-SetupConfirmation",
    "Read-IndexedSelection",
    "New-BillingExportStorageAccount",
    "Select-BillingExportStorageAccount",
    "Confirm-ExistingBillingStorageNetworkChanges",
    "Confirm-ExistingBillingStorageMutation",
    "Assert-ResourceProviderRegistered",
    "Get-AzRestStatusCodeFromError",
    "Invoke-AzRestGetJson",
    "Test-BillingCostExportScope",
    "Test-ManagementGroupCostExportScope",
    "Normalize-CostExportScope",
    "Get-SubscriptionIdFromCostExportScope",
    "Get-CostExportResourceId",
    "Get-CostExport",
    "Get-CostExportDefinitionTypeCandidates",
    "Test-ShouldRetryActualCostAsUsage",
    "Get-AzureBillingExportScopeType",
    "Get-AzureBillingExportDatasetType",
    "Test-TenantRootManagementGroup",
    "Get-ManagementGroupScope",
    "Get-ManagementGroupDisplayLabel",
    "Get-ManagementGroupParentScope",
    "Get-PreferredManagementGroupExportTargets",
    "Get-CostExportProperties",
    "Test-CostExportDefinitionTypeMatches",
    "Test-RecurringCostExportMeetsRequirements",
    "Get-StorageAccountParts",
    "Get-ExportDestinationInfo",
    "Get-SpottoBackfillQueuedDescription",
    "Test-SpottoBackfillQueued",
    "Get-SpottoApplicationTags",
    "Get-SpottoApplicationObjectId",
    "Get-SpottoApplicationOwnershipTags",
    "Test-SpottoAzureOnboardingApplicationOwnership",
    "Resolve-SpottoAzureApplication",
    "Ensure-SpottoServicePrincipal",
    "New-SpottoClientSecret",
    "Complete-SpottoClientSecretHandoff",
    "Remove-OnboardingJsonAfterConfirmedImport",
    "Test-SpottoBackfillPending",
    "New-CostExportBody",
    "Get-SpottoRecurringExportName",
    "Ensure-RecurringAndBackfillExports",
    "ConvertTo-AzureManualOnboardingBillingExportSource",
    "Get-AzureManualOnboardingBillingExportSourcesForHandoff",
    "Add-AzureManualOnboardingBillingExportSource",
    "Ensure-ManagementGroupRecurringExport",
    "Get-BillingExportSetupOutcome",
    "Get-AzureProvisioningFailureCategory",
    "Test-ShouldRetryAzureProvisioningInAnotherLocation",
    "Get-AzureOnboardingPrerequisiteActionChecks",
    "Get-AzureOnboardingPrerequisiteActionDetail",
    "Get-CostManagementContributorSelfRemediationTargets",
    "Invoke-CostManagementContributorSelfRemediation",
    "Set-OnboardingJsonOwnerOnlyPermissions",
    "Export-AzureManualOnboardingJson"
)
foreach ($functionName in $functionNames) {
    $definition = $setupAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    if (-not $definition) {
        throw "Missing function $functionName."
    }

    Invoke-Expression $definition.Extent.Text
}

$BILLING_EXPORT_STORAGE_NAME_PREFIX = "billingexports"
$BILLING_EXPORT_STORAGE_PURPOSE_TAG = "SpottoPurpose"
$BILLING_EXPORT_STORAGE_PURPOSE_VALUE = "BillingExports"
$BILLING_EXPORT_STORAGE_TENANT_TAG = "SpottoTenantId"
$BILLING_EXPORT_STORAGE_ALIAS_VALUE = "billing-exports"
$BILLING_EXPORT_SUCCESS_STATUSES = @("existing", "created", "updated", "created-run-queued", "queued", "requeued")
$SPOTTO_BACKFILL_QUEUED_PREFIX = "Spotto backfill queued"
$SPOTTO_BACKFILL_PENDING_PREFIX = "Spotto backfill pending"
$SPOTTO_APP_OWNERSHIP_TAG = "SpottoAzureOnboarding"
$SPOTTO_APP_TENANT_TAG_PREFIX = "SpottoTenantId:"
$APP_NAME = "Spotto"
$LEGACY_APP_NAMES = @("Spotto AI")
$APP_LOOKUP_NAMES = @($APP_NAME) + $LEGACY_APP_NAMES
$COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME = "Cost Management Contributor"
$AZURE_MANUAL_ONBOARDING_IMPORT_SCHEMA_VERSION = 1
$AZURE_MANUAL_ONBOARDING_IMPORT_KIND = "spotto.azure.manual-onboarding"
$tenantId = "11111111-2222-3333-4444-abcdef123456"
$subscriptionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
$script:tenantId = $tenantId

& {
    function Read-Host { return "" }
    if ((Read-SetupConfirmation -Prompt "Configure exports?" -DefaultYes $true) -ne "yes") {
        throw "Explicit setup confirmation did not accept the default-yes response."
    }
}
& {
    function Read-Host { return "no" }
    if ((Read-SetupConfirmation -Prompt "Configure exports?" -DefaultYes $true) -ne "no") {
        throw "Explicit setup confirmation ignored an explicit decline."
    }
}
& {
    function Read-Host { return "" }
    if ((Read-SetupConfirmation -Prompt "Use broad scope?" -DefaultYes $false) -ne "no") {
        throw "Explicit setup confirmation did not preserve a default-no response."
    }
}

$ownedApplication = [pscustomobject]@{
    Id = "app-object-1"
    AppId = "app-client-1"
    DisplayName = "Spotto"
    Tag = @($SPOTTO_APP_OWNERSHIP_TAG, "$SPOTTO_APP_TENANT_TAG_PREFIX$tenantId")
}
if (-not (Test-SpottoAzureOnboardingApplicationOwnership -Application $ownedApplication -TenantId $tenantId)) {
    throw "A tenant-tagged Spotto application was not recognized."
}
if (Test-SpottoAzureOnboardingApplicationOwnership -Application $ownedApplication -TenantId "different-tenant") {
    throw "A Spotto application tagged for another tenant was accepted."
}

& {
    function Get-AzADApplication { return $ownedApplication }
    function Read-Host { throw "A tagged application must not prompt for display-name reuse." }
    function Update-AzADApplication { throw "A tagged application must not be retagged." }
    $resolvedApp = Resolve-SpottoAzureApplication -TenantId $tenantId
    if ($resolvedApp.AppId -ne $ownedApplication.AppId) {
        throw "The exact tenant-tagged application was not selected."
    }
}

& {
    function Get-AzADApplication {
        return @($ownedApplication, [pscustomobject]@{
            Id = "app-object-2"
            AppId = "app-client-2"
            DisplayName = "Spotto"
            Tag = @($SPOTTO_APP_OWNERSHIP_TAG, "$SPOTTO_APP_TENANT_TAG_PREFIX$tenantId")
        })
    }
    $duplicateOwnedAppsRejected = $false
    try {
        Resolve-SpottoAzureApplication -TenantId $tenantId | Out-Null
    } catch {
        $duplicateOwnedAppsRejected = $true
    }
    if (-not $duplicateOwnedAppsRejected) {
        throw "Duplicate tenant-tagged Spotto applications were not rejected."
    }
}

& {
    $legacyApp = [pscustomobject]@{ Id = "legacy-object"; AppId = "legacy-client"; DisplayName = "Spotto AI"; Tag = @("existing-tag") }
    $script:updatedApplicationTags = @()
    function Get-AzADApplication { return $legacyApp }
    function Read-Host { return "legacy-client" }
    function Write-Warning-Custom { param($Message) }
    function Write-Info { param($Message) }
    function Write-DetailRow { param($Label, $Value) }
    function Write-Success { param($Message) }
    function Update-AzADApplication {
        param($ObjectId, $Tag)
        if ($ObjectId -ne $legacyApp.Id) { throw "Legacy app tagging used the wrong object ID." }
        $script:updatedApplicationTags = @($Tag)
    }
    $resolvedApp = Resolve-SpottoAzureApplication -TenantId $tenantId
    if ($resolvedApp.AppId -ne $legacyApp.AppId -or
        "existing-tag" -notin $script:updatedApplicationTags -or
        $SPOTTO_APP_OWNERSHIP_TAG -notin $script:updatedApplicationTags -or
        "$SPOTTO_APP_TENANT_TAG_PREFIX$tenantId" -notin $script:updatedApplicationTags) {
        throw "Explicit legacy application selection did not preserve and add ownership tags."
    }
}

& {
    $script:newServicePrincipalCalls = 0
    function Get-AzADServicePrincipal { return $null }
    function New-AzADServicePrincipal {
        param($ApplicationId)
        $script:newServicePrincipalCalls++
        return [pscustomobject]@{ Id = "sp-object"; AppId = $ApplicationId }
    }
    function Start-Sleep {}
    function Write-Success { param($Message) }
    function Write-Info { param($Message) }
    $servicePrincipal = Ensure-SpottoServicePrincipal -Application $ownedApplication
    if ($servicePrincipal.Id -ne "sp-object" -or $script:newServicePrincipalCalls -ne 1) {
        throw "A missing service principal was not repaired exactly once (id=$($servicePrincipal.Id), calls=$script:newServicePrincipalCalls)."
    }
}

& {
    $script:secretCreationAttempts = 0
    function New-AzADAppCredential {
        param($ApplicationId, $EndDate)
        $script:secretCreationAttempts++
        if ($script:secretCreationAttempts -eq 1) {
            throw "simulated tenant lifetime policy"
        }
        return [pscustomobject]@{ SecretText = "retrievable-secret"; EndDateTime = $EndDate; KeyId = "created-key" }
    }
    function Remove-AzADAppCredential { throw "A retrievable credential must not be removed." }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-Warning-Custom { param($Message) }
    $credential = New-SpottoClientSecret -Application $ownedApplication
    if ($credential.SecretText -ne "retrievable-secret" -or $script:secretCreationAttempts -ne 2) {
        throw "Client-secret lifetime fallback did not stop at the first retrievable value."
    }
}

& {
    $script:secretCreationAttempts = 0
    $script:removedEmptyCredentialKey = $null
    function New-AzADAppCredential {
        $script:secretCreationAttempts++
        return [pscustomobject]@{ SecretText = $null; EndDateTime = (Get-Date).AddMonths(24); KeyId = "empty-value-key" }
    }
    function Remove-AzADAppCredential {
        param($ApplicationId, $KeyId, $Confirm, $ErrorAction)
        $script:removedEmptyCredentialKey = $KeyId
    }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-Warning-Custom { param($Message) }
    $emptySecretRejected = $false
    try {
        New-SpottoClientSecret -Application $ownedApplication | Out-Null
    } catch {
        $emptySecretRejected = $true
    }
    if (-not $emptySecretRejected -or $script:secretCreationAttempts -ne 1 -or $script:removedEmptyCredentialKey -ne "empty-value-key") {
        throw "A credential without a retrievable value was not removed exactly once before stopping."
    }
}

$firstRun = @(Get-BillingStorageAccountNameCandidates -TenantId $tenantId -SubscriptionId $subscriptionId)
$secondRun = @(Get-BillingStorageAccountNameCandidates -TenantId $tenantId -SubscriptionId $subscriptionId)
if (($firstRun -join ",") -ne ($secondRun -join ",")) {
    throw "Naming is not deterministic."
}
if ($firstRun[0] -ne "billingexportscdef123456") {
    throw "Unexpected preferred name: $($firstRun[0])"
}
if (@($firstRun | Where-Object { $_ -notmatch "^[a-z0-9]{3,24}$" }).Count -gt 0) {
    throw "An invalid storage name was generated."
}
if (@($firstRun | Sort-Object -Unique).Count -ne 20) {
    throw "Collision candidates are not unique."
}

function Find-BillingExportStorageAccountByName { return $null }
$script:availabilityCalls = @()
function Test-StorageAccountNameAvailable {
    param([string]$SubscriptionId, [string]$Name)
    $script:availabilityCalls += $Name
    return $script:availabilityCalls.Count -eq 2
}
$collisionResolution = Resolve-BillingExportStorageAccountName -SubscriptionId $subscriptionId -TenantId $tenantId
if ($collisionResolution.Name -ne $firstRun[1] -or $collisionResolution.ExistingStorageAccount) {
    throw "Stable collision fallback failed."
}
function Test-StorageAccountNameAvailable { return $true }
$excludedResolution = Resolve-BillingExportStorageAccountName `
    -SubscriptionId $subscriptionId `
    -TenantId $tenantId `
    -ExcludedNames @($firstRun[0])
if ($excludedResolution.Name -ne $firstRun[1]) {
    throw "Rejected deterministic names are not excluded on retry."
}

function Find-BillingExportStorageAccountByName {
    param([string]$SubscriptionId, [string]$Name)
    return [pscustomobject]@{
        ResourceId = "/existing"
        SubscriptionId = $SubscriptionId
        ResourceGroupName = "rg"
        Name = $Name
        Tags = @{
            SpottoPurpose = "BillingExports"
            SpottoTenantId = $tenantId
        }
    }
}
function Test-StorageAccountNameAvailable { throw "Availability was queried for an exact owned account." }
$reuseResolution = Resolve-BillingExportStorageAccountName -SubscriptionId $subscriptionId -TenantId $tenantId
if ($reuseResolution.ExistingStorageAccount.ResourceId -ne "/existing" -or $reuseResolution.Name -ne $firstRun[0]) {
    throw "Exact-name rerun reuse failed."
}
if (-not (Test-SpottoBillingStorageAccountOwnership -StorageAccount $reuseResolution.ExistingStorageAccount)) {
    throw "Tagged Spotto storage ownership was not recognized."
}
$unownedStorage = [pscustomobject]@{ Tags = @{ SpottoPurpose = "Other"; SpottoTenantId = $tenantId } }
if (Test-SpottoBillingStorageAccountOwnership -StorageAccount $unownedStorage) {
    throw "An unrelated storage account was recognized as Spotto-owned."
}
$aliasOnlyStorage = [pscustomobject]@{ Tags = @{ spotto = "billing-exports" } }
if (Test-SpottoBillingStorageAccountOwnership -StorageAccount $aliasOnlyStorage) {
    throw "The optional alias tag was incorrectly accepted as tenant ownership."
}
function Write-Warning-Custom { param($Message) }
function Write-Info { param($Message) }
& {
    function Read-Host { return "" }
    if (Confirm-BillingStorageAccountReuse -StorageAccount $unownedStorage) {
        throw "Untagged storage was approved by default."
    }
}

& {
    function Invoke-AzRestMethod {
        return [pscustomobject]@{ StatusCode = 503; Content = '{"value":[]}' }
    }
    $restFailure = $null
    try {
        Invoke-AzRestGetJson -Path "/subscriptions/sub-1/providers/Microsoft.CostManagement/exports?api-version=test&sig=secret" | Out-Null
    } catch {
        $restFailure = $_
    }
    if (-not $restFailure -or (Get-AzRestStatusCodeFromError -ErrorRecord $restFailure) -ne 503) {
        throw "Invoke-AzRestGetJson did not surface a typed non-2xx failure."
    }
    if ($restFailure.Exception.Message -match "sig=secret") {
        throw "Invoke-AzRestGetJson leaked query parameters in its failure message."
    }

    function Invoke-AzRestMethod { throw "Transport failure for ?sig=secret" }
    $transportFailure = $null
    try {
        Invoke-AzRestGetJson -Path "/subscriptions/sub-1/providers/Microsoft.CostManagement/exports?api-version=test&sig=secret" | Out-Null
    } catch {
        $transportFailure = $_
    }
    if (-not $transportFailure -or $transportFailure.Exception.Message -match "sig=secret") {
        throw "Invoke-AzRestGetJson did not sanitize a cmdlet-thrown transport failure."
    }
}

& {
    function Invoke-WithCostManagementThrottleRetry {
        param([string]$OperationLabel, [scriptblock]$Operation)
        & $Operation
    }
    function Invoke-AzRestGetJson {
        $exception = [System.InvalidOperationException]::new("Azure REST GET failed with HTTP 404.")
        $exception.Data["SpottoAzRestStatusCode"] = 404
        throw $exception
    }
    if ($null -ne (Get-CostExport -Scope "/providers/Microsoft.Management/managementGroups/mg-1" -ExportName "missing")) {
        throw "A typed 404 export lookup did not return null."
    }

    function Invoke-AzRestGetJson { throw "A resource named NotFoundElsewhere failed validation." }
    $untypedNotFoundWasPropagated = $false
    try {
        Get-CostExport -Scope "/providers/Microsoft.Management/managementGroups/mg-1" -ExportName "invalid" | Out-Null
    } catch {
        $untypedNotFoundWasPropagated = $true
    }
    if (-not $untypedNotFoundWasPropagated) {
        throw "An untyped NotFound message was incorrectly treated as an absent export."
    }
}

$actualCandidates = @(Get-CostExportDefinitionTypeCandidates -DatasetType "ActualCost")
if (($actualCandidates -join ",") -ne "ActualCost,Usage") {
    throw "ActualCost does not expose the single Usage compatibility fallback."
}
if ((@(Get-CostExportDefinitionTypeCandidates -DatasetType "AmortizedCost") -join ",") -ne "AmortizedCost") {
    throw "AmortizedCost unexpectedly exposes a compatibility fallback."
}
if (-not (Test-ShouldRetryActualCostAsUsage -Message "InvalidRequest: ActualCost is not supported at this billing scope.")) {
    throw "A recognized ActualCost scope rejection did not enable Usage fallback."
}
if (Test-ShouldRetryActualCostAsUsage -Message "AuthorizationFailed: ActualCost export write was denied.") {
    throw "An authorization failure incorrectly enabled Usage fallback."
}

$pendingBackfill = [pscustomobject]@{ Properties = [pscustomobject]@{ exportDescription = "$SPOTTO_BACKFILL_PENDING_PREFIX 202601" } }
if (-not (Test-SpottoBackfillPending -Export $pendingBackfill -PeriodName "202601")) {
    throw "A pending Spotto backfill marker was not recognized."
}

& {
    $script:backfillRunCount = 0
    $script:backfillResults = @()
    function Assert-ResourceProviderRegistered {}
    function Get-BackfillMonthPeriods { return @([pscustomobject]@{ Name = "202601"; From = "2026-01-01T00:00:00Z"; To = "2026-01-31T23:59:59Z" }) }
    function Get-CostExport {
        param($Scope, $ExportName)
        $descriptionPrefix = if ($ExportName -match "amortized") { $SPOTTO_BACKFILL_QUEUED_PREFIX } else { $SPOTTO_BACKFILL_PENDING_PREFIX }
        return [pscustomobject]@{ Properties = [pscustomobject]@{ exportDescription = "$descriptionPrefix 202601" } }
    }
    function Invoke-CostExportRun { $script:backfillRunCount++ }
    function Add-BillingExportResult {
        param($SubscriptionName, $SubscriptionId, $DatasetType, $ExportKind, $ExportName, $Status, $StorageAccountId, $ContainerName, $RootFolderPath, $Message)
        $script:backfillResults += [pscustomobject]@{ DatasetType = $DatasetType; Status = $Status; Message = $Message }
    }
    function Add-AzureManualOnboardingBillingExportSource {}
    function Write-Success { param($Message) }
    function Write-Info { param($Message) }
    function Write-Warning-Custom { param($Message) }
    $existingRecurring = @{}
    foreach ($datasetType in @("ActualCost", "AmortizedCost")) {
        $existingRecurring["sub-1|$datasetType"] = [pscustomobject]@{
            name = "existing-$datasetType"
            Properties = [pscustomobject]@{
                definition = [pscustomobject]@{ type = $datasetType }
                deliveryInfo = [pscustomobject]@{ destination = [pscustomobject]@{ resourceId = "/storage"; container = "exports"; rootFolderPath = "spotto" } }
            }
        }
    }
    Ensure-RecurringAndBackfillExports `
        -Subscription ([pscustomobject]@{ Id = "sub-1"; Name = "Subscription One" }) `
        -StorageDestination ([pscustomobject]@{ ResourceId = "/storage" }) `
        -ContainerName "exports" `
        -ExistingRecurringExports $existingRecurring

    $ambiguousResults = @($script:backfillResults | Where-Object { $_.Status -eq "ambiguous" })
    if ($script:backfillRunCount -ne 0 -or $ambiguousResults.Count -ne 1 -or $ambiguousResults[0].DatasetType -ne "ActualCost") {
        throw "A pending backfill marker did not prevent an ambiguous duplicate run."
    }
}

& {
    $script:backfillRunCount = 0
    $script:backfillResults = @()
    function Assert-ResourceProviderRegistered {}
    function Get-BackfillMonthPeriods { return @([pscustomobject]@{ Name = "202601"; From = "2026-01-01T00:00:00Z"; To = "2026-01-31T23:59:59Z" }) }
    function Get-CostExport {
        param($Scope, $ExportName)
        if ($ExportName -match "amortized") {
            return [pscustomobject]@{ Properties = [pscustomobject]@{ exportDescription = "$SPOTTO_BACKFILL_QUEUED_PREFIX 202601" } }
        }
        return $null
    }
    function Ensure-CostExport {
        param($Scope, $ExportName, $Body)
        if ($Body.properties.exportDescription -eq "$SPOTTO_BACKFILL_QUEUED_PREFIX 202601") {
            throw "simulated marker save failure"
        }
        return "created"
    }
    function Invoke-CostExportRun { $script:backfillRunCount++ }
    function Add-BillingExportResult {
        param($SubscriptionName, $SubscriptionId, $DatasetType, $ExportKind, $ExportName, $Status, $StorageAccountId, $ContainerName, $RootFolderPath, $Message)
        $script:backfillResults += [pscustomobject]@{ DatasetType = $DatasetType; Status = $Status; Message = $Message }
    }
    function Add-AzureManualOnboardingBillingExportSource {}
    function Write-Success { param($Message) }
    function Write-Info { param($Message) }
    function Write-Warning-Custom { param($Message) }
    $existingRecurring = @{}
    foreach ($datasetType in @("ActualCost", "AmortizedCost")) {
        $existingRecurring["sub-1|$datasetType"] = [pscustomobject]@{
            name = "existing-$datasetType"
            Properties = [pscustomobject]@{
                definition = [pscustomobject]@{ type = $datasetType }
                deliveryInfo = [pscustomobject]@{ destination = [pscustomobject]@{ resourceId = "/storage"; container = "exports"; rootFolderPath = "spotto" } }
            }
        }
    }
    Ensure-RecurringAndBackfillExports `
        -Subscription ([pscustomobject]@{ Id = "sub-1"; Name = "Subscription One" }) `
        -StorageDestination ([pscustomobject]@{ ResourceId = "/storage" }) `
        -ContainerName "exports" `
        -ExistingRecurringExports $existingRecurring

    $markerFailures = @($script:backfillResults | Where-Object { $_.Status -eq "queued-marker-failed" })
    $falseSuccesses = @($script:backfillResults | Where-Object { $_.DatasetType -eq "ActualCost" -and $_.Status -in @("queued", "requeued") })
    if ($script:backfillRunCount -ne 1 -or $markerFailures.Count -ne 1 -or $falseSuccesses.Count -ne 0) {
        throw "A failed queued-marker save was still reported as a successful idempotent backfill."
    }
}

& {
    $script:definitionAttempts = @()
    $script:immediateRunCount = 0
    $script:recurringResults = @()
    $script:effectiveSources = @()
    function Get-BackfillMonthPeriods { return @() }
    function Ensure-ResourceProviderRegistered { return "Registered" }
    function Ensure-CostExport {
        param([string]$Scope, [string]$ExportName, [hashtable]$Body)
        $definitionType = $Body.properties.definition.type
        $script:definitionAttempts += $definitionType
        if ($definitionType -eq "ActualCost") {
            throw "InvalidRequest: ActualCost is not supported at this billing scope."
        }
        return "created"
    }
    function Invoke-CostExportRun { $script:immediateRunCount++ }
    function Add-BillingExportResult {
        param($SubscriptionName, $SubscriptionId, $DatasetType, $ExportKind, $ExportName, $Status, $StorageAccountId, $ContainerName, $RootFolderPath, $Message)
        $script:recurringResults += [pscustomobject]@{ DatasetType = $DatasetType; Status = $Status }
    }
    function Add-AzureManualOnboardingBillingExportSource {
        param($Scope, $DatasetType, $ExportName, $Destination)
        $script:effectiveSources += $DatasetType
    }
    function Write-Success { param($Message) }
    function Write-Info { param($Message) }
    function Write-Warning-Custom { param($Message) }
    function Write-Error-Custom { param($Message) }
    $BILLING_EXPORT_ROOT_PATH = "spotto"
    Ensure-RecurringAndBackfillExports `
        -Subscription ([pscustomobject]@{ Id = "sub-1"; Name = "Subscription One" }) `
        -StorageDestination ([pscustomobject]@{ ResourceId = "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/exports" }) `
        -ContainerName "cost-exports" `
        -ExistingRecurringExports @{}

    if (($script:definitionAttempts -join ",") -ne "ActualCost,Usage,AmortizedCost") {
        throw "ActualCost fallback did not try Usage exactly once before continuing to AmortizedCost."
    }
    if ($script:immediateRunCount -ne 2 -or @($script:recurringResults | Where-Object { $_.Status -ne "created-run-queued" }).Count -gt 0) {
        throw "New recurring exports were not classified as created with immediate runs queued."
    }
    if (($script:effectiveSources -join ",") -ne "Usage,AmortizedCost") {
        throw "The effective fallback definition was not recorded in onboarding sources."
    }
}

& {
    $script:networkConsentCalls = 0
    function Confirm-ExistingBillingStorageNetworkChanges {
        $script:networkConsentCalls++
        return $false
    }
    $approvalCache = @{}
    $storageId = "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/existing"
    if (Confirm-ExistingBillingStorageMutation -StorageAccountId $storageId -ApprovalCache $approvalCache) {
        throw "Existing storage mutation was approved despite a default-no rejection."
    }
    if (Confirm-ExistingBillingStorageMutation -StorageAccountId $storageId.ToUpperInvariant() -ApprovalCache $approvalCache) {
        throw "Rejected existing storage mutation was not cached."
    }
    if ($script:networkConsentCalls -ne 1) {
        throw "Existing storage network consent was requested more than once for one account."
    }
}

$completeOutcome = Get-BillingExportSetupOutcome -Results @([pscustomobject]@{ Status = "created-run-queued" })
$partialOutcome = Get-BillingExportSetupOutcome -Results @(
    [pscustomobject]@{ Status = "existing" },
    [pscustomobject]@{ Status = "failed" }
)
$failedOutcome = Get-BillingExportSetupOutcome -Results @([pscustomobject]@{ Status = "unavailable" })
if ($completeOutcome -ne "complete" -or $partialOutcome -ne "partial" -or $failedOutcome -ne "failed") {
    throw "Billing export aggregate outcomes are not complete/partial/failed as required."
}
$skippedOutcome = Get-BillingExportSetupOutcome -Results @([pscustomobject]@{ Status = "skipped" })
$immediateRunFailureOutcome = Get-BillingExportSetupOutcome -Results @(
    [pscustomobject]@{ Status = "created-run-queued" },
    [pscustomobject]@{ Status = "created-run-failed" }
)
if ($skippedOutcome -ne "failed" -or $immediateRunFailureOutcome -ne "partial") {
    throw "Skipped or failed immediate-run rows were incorrectly counted as successful billing exports."
}

& {
    function Ensure-ResourceProviderRegistered { return $false }
    $registrationFailure = $null
    try {
        Assert-ResourceProviderRegistered -SubscriptionId "sub-1" -ProviderNamespace "Microsoft.CostManagementExports"
    } catch {
        $registrationFailure = $_
    }
    if (-not $registrationFailure -or $registrationFailure.Exception.Message -notmatch "did not reach Registered state") {
        throw "Provider registration did not fail closed when Azure remained pending."
    }
}

& {
    $script:failedRunResults = @()
    function Ensure-CostExport { return "created" }
    function Invoke-CostExportRun { throw "simulated immediate-run failure" }
    function Add-BillingExportResult {
        param($SubscriptionName, $SubscriptionId, $DatasetType, $ExportKind, $ExportName, $Status, $StorageAccountId, $ContainerName, $RootFolderPath, $Message)
        $script:failedRunResults += [pscustomobject]@{ Status = $Status; Message = $Message }
    }
    function Add-AzureManualOnboardingBillingExportSource {}
    function Write-Success { param($Message) }
    function Write-Info { param($Message) }
    $BILLING_EXPORT_ROOT_PATH = "spotto"
    Ensure-ManagementGroupRecurringExport `
        -ManagementGroup ([pscustomobject]@{ Name = "platform"; Id = "/providers/Microsoft.Management/managementGroups/platform" }) `
        -StorageDestination ([pscustomobject]@{ ResourceId = "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/exports" }) `
        -ContainerName "cost-exports" `
        -TenantId $tenantId

    if ($script:failedRunResults.Count -ne 1 -or
        $script:failedRunResults[0].Status -ne "created-run-failed" -or
        $script:failedRunResults[0].Message -notmatch "simulated immediate-run failure") {
        throw "A created export with a failed immediate run was not reported truthfully."
    }
}

if ((Get-AzureProvisioningFailureCategory -Message "Code: SkuNotAvailable. Standard_LRS is unavailable in this location.") -ne "location-or-sku") {
    throw "A proven SKU/location rejection was not classified for region retry."
}
foreach ($terminalFailure in @(
    "AuthorizationFailed: the client does not have authorization",
    "RequestDisallowedByPolicy: resource creation was denied",
    "StorageAccountAlreadyTaken: the name is unavailable",
    "QuotaExceeded: storage account quota exceeded"
)) {
    if (Test-ShouldRetryAzureProvisioningInAnotherLocation -Message $terminalFailure) {
        throw "A terminal provisioning failure incorrectly offered a region retry: $terminalFailure"
    }
}

$subscriptionActionChecks = @(Get-AzureOnboardingPrerequisiteActionChecks -ScopeType "Subscription")
$subscriptionActions = @($subscriptionActionChecks.Action)
foreach ($requiredAction in @(
    "Microsoft.CostManagement/exports/write",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Storage/storageAccounts/blobServices/containers/write",
    "Microsoft.Authorization/roleAssignments/write"
)) {
    if ($requiredAction -notin $subscriptionActions) {
        throw "Prerequisite mode does not separately assess '$requiredAction'."
    }
}
$broadScopeActions = @((Get-AzureOnboardingPrerequisiteActionChecks -ScopeType "ManagementGroup").Action)
if ("Microsoft.CostManagement/exports/write" -notin $broadScopeActions -or "Microsoft.Authorization/roleAssignments/write" -notin $broadScopeActions) {
    throw "Prerequisite mode does not assess broad-scope export and RBAC authority."
}
$costManagementActionCheck = @($subscriptionActionChecks | Where-Object { $_.Category -eq "BillingExport" })[0]
$costManagementActionDetail = Get-AzureOnboardingPrerequisiteActionDetail `
    -Assessment ([pscustomobject]@{ Status = "action"; Detail = "No export-write permission." }) `
    -ActionCheck $costManagementActionCheck
if ($costManagementActionDetail -notmatch "Cost Management Contributor" -or $costManagementActionDetail -notmatch "self-remediation") {
    throw "The prerequisite failure does not name its role-based remediation."
}

$managementGroupScope = "/providers/Microsoft.Management/managementGroups/mg-1"
$subscriptionScope = "/subscriptions/sub-1"
$selfRemediationTargets = @(Get-CostManagementContributorSelfRemediationTargets -Results @(
    [pscustomobject]@{ Status = "action"; Category = "BroadScopeExport"; Scope = $managementGroupScope; Name = "MG export" },
    [pscustomobject]@{ Status = "ready"; Category = "BroadScopeRbac"; Scope = $managementGroupScope; Name = "MG RBAC" },
    [pscustomobject]@{ Status = "action"; Category = "BillingExport"; Scope = $subscriptionScope; Name = "Subscription export" },
    [pscustomobject]@{ Status = "action"; Category = "SubscriptionRbac"; Scope = $subscriptionScope; Name = "Subscription RBAC" }
))
if ($selfRemediationTargets.Count -ne 1 -or $selfRemediationTargets[0].Scope -ne $managementGroupScope) {
    throw "Cost Management self-remediation was offered without matching same-scope assignment authority."
}

& {
    $script:selfRemediationWrites = 0
    function Read-Host { return "" }
    function Get-AzRoleAssignment { throw "Role lookup must not run after a default-no response." }
    function New-AzRoleAssignment { $script:selfRemediationWrites++ }
    function Write-SectionLabel { param($Message) }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-Error-Custom { param($Message) }

    $result = Invoke-CostManagementContributorSelfRemediation `
        -PrincipalObjectId "principal-1" `
        -AccountId "operator@example.com" `
        -Targets $selfRemediationTargets
    if ($result.Status -ne "declined" -or $script:selfRemediationWrites -ne 0) {
        throw "Default-no Cost Management self-remediation changed Azure."
    }
}

& {
    $script:selfRemediationWrites = @()
    function Read-Host { return "yes" }
    function Get-AzRoleAssignment { return $null }
    function New-AzRoleAssignment {
        param($ObjectId, $RoleDefinitionName, $Scope)
        $script:selfRemediationWrites += [pscustomobject]@{ ObjectId = $ObjectId; Role = $RoleDefinitionName; Scope = $Scope }
    }
    function Write-SectionLabel { param($Message) }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-Error-Custom { param($Message) }

    $result = Invoke-CostManagementContributorSelfRemediation `
        -PrincipalObjectId "principal-1" `
        -AccountId "operator@example.com" `
        -Targets $selfRemediationTargets
    if ($result.Status -ne "complete" -or $result.Created -ne 1 -or $script:selfRemediationWrites.Count -ne 1 -or
        $script:selfRemediationWrites[0].Role -ne "Cost Management Contributor" -or
        $script:selfRemediationWrites[0].Scope -ne $managementGroupScope) {
        throw "Approved Cost Management self-remediation did not create the exact role assignment."
    }
}

& {
    $script:selfRemediationWrites = 0
    function Read-Host { return "yes" }
    function Get-AzRoleAssignment {
        return [pscustomobject]@{ Scope = $managementGroupScope; RoleDefinitionName = "Cost Management Contributor" }
    }
    function New-AzRoleAssignment { $script:selfRemediationWrites++ }
    function Write-SectionLabel { param($Message) }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-Error-Custom { param($Message) }

    $result = Invoke-CostManagementContributorSelfRemediation `
        -PrincipalObjectId "principal-1" `
        -AccountId "operator@example.com" `
        -Targets $selfRemediationTargets
    if ($result.Status -ne "complete" -or $result.Existing -ne 1 -or $script:selfRemediationWrites -ne 0) {
        throw "Existing Cost Management Contributor assignment was not reused idempotently."
    }
}

& {
    function Read-Host { return "yes" }
    function Get-AzRoleAssignment { return $null }
    function New-AzRoleAssignment { throw "simulated role-assignment denial" }
    function Write-SectionLabel { param($Message) }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-Error-Custom { param($Message) }

    $result = Invoke-CostManagementContributorSelfRemediation `
        -PrincipalObjectId "principal-1" `
        -AccountId "operator@example.com" `
        -Targets $selfRemediationTargets
    if ($result.Status -ne "failed" -or $result.Created -ne 0 -or $result.Failed -ne 1) {
        throw "A denied Cost Management role assignment was not reported as failed."
    }
}
& {
    function Read-Host { return "yes" }
    if (-not (Confirm-BillingStorageAccountReuse -StorageAccount $unownedStorage)) {
        throw "Explicit untagged storage approval was ignored."
    }
}

$recurringExportWithoutRootPath = [pscustomobject]@{
    Name = "missing-root"
    Properties = [pscustomobject]@{
        schedule = [pscustomobject]@{ status = "Active"; recurrence = "Daily" }
        definition = [pscustomobject]@{ type = "ActualCost"; timeframe = "MonthToDate" }
        format = "Csv"
        compressionMode = "gzip"
        deliveryInfo = [pscustomobject]@{
            destination = [pscustomobject]@{
                resourceId = "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/billingexports123"
                container = "cost-exports"
                rootFolderPath = ""
            }
        }
    }
}
if (Test-RecurringCostExportMeetsRequirements -Export $recurringExportWithoutRootPath -DatasetType "ActualCost") {
    throw "An export without the required root folder path was accepted."
}
$recurringExportWithoutRootPath.Properties.deliveryInfo.destination.rootFolderPath = "   "
if (Test-RecurringCostExportMeetsRequirements -Export $recurringExportWithoutRootPath -DatasetType "ActualCost") {
    throw "An export with a whitespace-only root folder path was accepted."
}
$recurringExportWithoutRootPath.Properties.deliveryInfo.destination.rootFolderPath = "spotto"
if (-not (Test-RecurringCostExportMeetsRequirements -Export $recurringExportWithoutRootPath -DatasetType "ActualCost")) {
    throw "A compatible recurring export was rejected."
}
$recurringExportWithoutRootPath.Properties.definition.type = "Usage"
if (Test-RecurringCostExportMeetsRequirements -Export $recurringExportWithoutRootPath -DatasetType "ActualCost") {
    throw "A Usage-only export was accepted as complete ActualCost."
}
if (-not (Test-RecurringCostExportMeetsRequirements -Export $recurringExportWithoutRootPath -DatasetType "Usage")) {
    throw "A management-group Usage export was rejected."
}

$scopeTypeCases = @(
    @{ Scope = "/subscriptions/sub-1"; Expected = "subscription" },
    @{ Scope = "/subscriptions/sub-1/resourceGroups/rg-1"; Expected = "resourceGroup" },
    @{ Scope = "/providers/Microsoft.Management/managementGroups/mg-1"; Expected = "managementGroup" },
    @{ Scope = "/providers/Microsoft.Billing/billingAccounts/account-1"; Expected = "billingAccount" },
    @{ Scope = "/providers/Microsoft.Billing/billingAccounts/account-1/billingProfiles/profile-1"; Expected = "billingProfile" },
    @{ Scope = "/providers/Microsoft.Billing/billingAccounts/account-1/billingProfiles/profile-1/invoiceSections/section-1"; Expected = "invoiceSection" },
    @{ Scope = "/providers/Microsoft.Billing/billingAccounts/account-1/invoiceSections/section-1"; Expected = "invoiceSection" },
    @{ Scope = "/providers/Microsoft.Billing/billingAccounts/account-1/departments/department-1"; Expected = "department" },
    @{ Scope = "/providers/Microsoft.Billing/billingAccounts/account-1/enrollmentAccounts/enrollment-1"; Expected = "enrollmentAccount" },
    @{ Scope = "/providers/Microsoft.Billing/billingAccounts/account-1/customers/customer-1"; Expected = "partnerCustomer" }
)
foreach ($scopeTypeCase in $scopeTypeCases) {
    $actualScopeType = Get-AzureBillingExportScopeType -Scope $scopeTypeCase.Scope
    if ($actualScopeType -ne $scopeTypeCase.Expected) {
        throw "Scope '$($scopeTypeCase.Scope)' classified as '$actualScopeType' instead of '$($scopeTypeCase.Expected)'."
    }
}
$unsupportedScopeWasRejected = $false
try {
    Get-AzureBillingExportScopeType -Scope "/tenants/tenant-1" | Out-Null
} catch {
    $unsupportedScopeWasRejected = $true
}
if (-not $unsupportedScopeWasRejected) {
    throw "An unsupported billing export scope was accepted."
}
if (-not (Test-ManagementGroupCostExportScope -Scope "/providers/Microsoft.Management/managementGroups/mg-1")) {
    throw "Management-group export scope was rejected."
}
if ((Get-AzureBillingExportDatasetType -DatasetType "Usage") -ne "actual" -or
    (Get-AzureBillingExportDatasetType -DatasetType "AmortizedCost") -ne "amortized") {
    throw "Azure export dataset mapping failed."
}

& {
    function Invoke-WithCostManagementThrottleRetry {
        param([string]$OperationLabel, [scriptblock]$Operation)
        & $Operation
    }
    function Invoke-AzRestGetJson { throw "Response status code does not indicate success: 503" }
    $transientReadWasPropagated = $false
    try {
        Get-CostExport -Scope "/providers/Microsoft.Management/managementGroups/mg-1" -ExportName "spotto-usage-daily" | Out-Null
    } catch {
        $transientReadWasPropagated = $true
    }
    if (-not $transientReadWasPropagated) {
        throw "A transient export read failure was treated as a missing export."
    }

    function Invoke-AzRestGetJson {
        $exception = [System.InvalidOperationException]::new("Azure REST GET failed with HTTP 404.")
        $exception.Data["SpottoAzRestStatusCode"] = 404
        throw $exception
    }
    if ($null -ne (Get-CostExport -Scope "/providers/Microsoft.Management/managementGroups/mg-1" -ExportName "missing")) {
        throw "A confirmed missing export did not return null."
    }
}

$rootManagementGroup = [pscustomobject]@{
    Name = $tenantId
    Id = "/providers/Microsoft.Management/managementGroups/$tenantId"
}
$childManagementGroup = [pscustomobject]@{
    Name = "platform"
    Id = "/providers/Microsoft.Management/managementGroups/platform"
    ParentId = $rootManagementGroup.Id
}
$rootTargets = @(Get-PreferredManagementGroupExportTargets -ManagementGroups @($childManagementGroup, $rootManagementGroup) -TenantId $tenantId)
if ($rootTargets.Count -ne 1 -or $rootTargets[0].Name -ne $tenantId) {
    throw "The exact tenant-root management group was not preferred alone."
}

$topLevelA = [pscustomobject]@{
    Name = "platform"
    Id = "/providers/Microsoft.Management/managementGroups/platform"
    ParentId = $rootManagementGroup.Id
}
$nestedA = [pscustomobject]@{
    Name = "platform-prod"
    Id = "/providers/Microsoft.Management/managementGroups/platform-prod"
    Details = [pscustomobject]@{ Parent = [pscustomobject]@{ Id = $topLevelA.Id } }
}
$topLevelB = [pscustomobject]@{
    Name = "business"
    Id = "/providers/Microsoft.Management/managementGroups/business"
    ParentId = $rootManagementGroup.Id
}
$topmostTargets = @(Get-PreferredManagementGroupExportTargets -ManagementGroups @($nestedA, $topLevelB, $topLevelA) -TenantId $tenantId)
if (($topmostTargets.Name -join ",") -ne "business,platform") {
    throw "Topmost visible management groups were not selected without their nested descendants."
}

& {
    $script:acceptedBillingExportSources = @()
    $script:capturedManagementGroupExport = $null
    function Ensure-CostExport {
        param([string]$Scope, [string]$ExportName, [hashtable]$Body)
        $script:capturedManagementGroupExport = [pscustomobject]@{ Scope = $Scope; ExportName = $ExportName; Body = $Body }
        return "created"
    }
    function Invoke-CostExportRun {}
    function Add-BillingExportResult {}
    function Write-Success { param($Message) }
    function Write-Info { param($Message) }
    $BILLING_EXPORT_ROOT_PATH = "spotto"
    $storageDestination = [pscustomobject]@{
        ResourceId = "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/billingexports123"
    }
    Ensure-ManagementGroupRecurringExport -ManagementGroup $topLevelA -StorageDestination $storageDestination -ContainerName "cost-exports" -TenantId $tenantId
    if ($script:capturedManagementGroupExport.Scope -ne $topLevelA.Id -or
        $script:capturedManagementGroupExport.Body.properties.definition.type -ne "Usage" -or
        $script:capturedManagementGroupExport.Body.properties.compressionMode -ne "None" -or
        $script:capturedManagementGroupExport.Body.properties.deliveryInfo.destination.rootFolderPath -ne "spotto/management-groups/platform/actual/recurring") {
        throw "Management-group recurring export was not created as scoped Usage."
    }
    if ($script:acceptedBillingExportSources.Count -ne 1 -or $script:acceptedBillingExportSources[0].scopeType -ne "managementGroup") {
        throw "Created management-group export was not recorded for JSON output."
    }
}

$script:useRecommendedReadOnlySetup = $true
function Write-SectionLabel {}
function Write-OptionRow {}
function Write-Error-Custom { param($Message) }
function Write-Info { param($Message) }
& {
    $script:selectedStorageSubscription = $null
    $script:storageSubscriptionPrompt = ""
    function Write-Host {}
    function Read-Host {
        param($Prompt)
        $script:storageSubscriptionPrompt = $Prompt
        return "2"
    }
    function Set-AzContext {
        param($SubscriptionId, $TenantId)
        $script:selectedStorageSubscription = $SubscriptionId
    }
    function Assert-ResourceProviderRegistered {}
    function Get-AvailableAzureLocationNames { return @("australiaeast") }
    function Resolve-BillingExportStorageAccountName {
        param($SubscriptionId, $TenantId, $ExcludedNames)
        return [pscustomobject]@{
            Name = "billingexportscdef123456"
            ExistingStorageAccount = [pscustomobject]@{
                ResourceId = "/subscriptions/$SubscriptionId/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/billingexportscdef123456"
                SubscriptionId = $SubscriptionId
            }
        }
    }
    function Confirm-BillingStorageAccountReuse { return $true }
    $storageSubscriptions = @(
        [pscustomobject]@{ Id = "sub-1"; Name = "First" },
        [pscustomobject]@{ Id = "sub-2"; Name = "Second" }
    )
    $selectedStorage = New-BillingExportStorageAccount -Subscriptions $storageSubscriptions
    if ($script:selectedStorageSubscription -ne "sub-2" -or
        $selectedStorage.SubscriptionId -ne "sub-2" -or
        $script:storageSubscriptionPrompt -notmatch "Select subscription for the billing export storage account") {
        throw "Recommended billing storage creation did not honor the selected host subscription."
    }
}
& {
    function Read-Host { return "" }
    function New-BillingExportStorageAccount { return "new-storage" }
    function Select-ExistingBillingStorageAccount { throw "Existing picker ran for the default option." }
    $selectedStorage = Select-BillingExportStorageAccount -Subscriptions @([pscustomobject]@{ Id = $subscriptionId })
    if ($selectedStorage -ne "new-storage") {
        throw "Default storage option did not create or reuse dedicated storage."
    }
}
& {
    function Read-Host { return "2" }
    function New-BillingExportStorageAccount { throw "New storage ran for the existing option." }
    function Select-ExistingBillingStorageAccount { return [pscustomobject]@{ ResourceId = "/existing-storage" } }
    function Confirm-ExistingBillingStorageNetworkChanges { return $true }
    $selectedStorage = Select-BillingExportStorageAccount -Subscriptions @([pscustomobject]@{ Id = $subscriptionId })
    if ($selectedStorage.ResourceId -ne "/existing-storage") {
        throw "Existing storage option routing failed in Recommended mode."
    }
}
$script:useRecommendedReadOnlySetup = $false

& {
    function Get-StorageAccountResource {
        return [pscustomobject]@{
            PublicNetworkAccess = "Disabled"
            NetworkRuleSet = [pscustomobject]@{ DefaultAction = "Deny" }
        }
    }
    function Write-Warning-Custom { param($Message) }
    function Write-Info { param($Message) }
    function Read-Host { return "" }
    if (Confirm-ExistingBillingStorageNetworkChanges -StorageAccount ([pscustomobject]@{ ResourceId = "/restricted" })) {
        throw "Restricted existing storage network changes were approved by default."
    }
}

$temporaryRoot = [System.IO.Path]::GetTempPath()
$temporaryPath = Join-Path $temporaryRoot ("spotto-onboarding-json-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryPath | Out-Null
try {
    Push-Location $temporaryPath
    function Write-Success { param($Message) }
    function Write-Warning-Custom { param($Message) }
    function Write-Info { param($Message) }
    function Write-Error-Custom { param($Message) }
    $script:clientId = "client-id"
    $script:clientSecret = "secret-value"
    $script:secretExpiry = "2027-08-30"
    $script:isNewSecret = $true
    $script:billingExportResults = @()
    $script:acceptedBillingExportSources = @()
    $testDestination = [pscustomobject]@{
        StorageAccountId = "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/billingexports123"
        Container = "cost-exports"
        RootFolderPath = "spotto"
    }
    Add-AzureManualOnboardingBillingExportSource -Scope "/providers/Microsoft.Billing/billingAccounts/account-1" -DatasetType "ActualCost" -ExportName "actual-daily" -Destination $testDestination
    Add-AzureManualOnboardingBillingExportSource -Scope "/providers/Microsoft.Billing/billingAccounts/account-1/billingProfiles/profile-1" -DatasetType "AmortizedCost" -ExportName "amortized-daily" -Destination $testDestination
    Add-AzureManualOnboardingBillingExportSource -Scope "/providers/Microsoft.Management/managementGroups/platform" -DatasetType "Usage" -ExportName "management-group-usage" -Destination $testDestination
    Add-AzureManualOnboardingBillingExportSource -Scope "/subscriptions/sub-1" -DatasetType "ActualCost" -ExportName "subscription-actual" -Destination $testDestination
    Add-AzureManualOnboardingBillingExportSource -Scope "/subscriptions/sub-1" -DatasetType "ActualCost" -ExportName "subscription-actual" -Destination $testDestination

    if ($script:acceptedBillingExportSources.Count -ne 4) {
        throw "Accepted billing export sources were not deduplicated."
    }

    $jsonPath = Export-AzureManualOnboardingJson
    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    if ($json.schemaVersion -ne 1 -or $json.kind -ne "spotto.azure.manual-onboarding") {
        throw "JSON envelope failed."
    }
    if ($json.credentials.clientSecret -ne "secret-value") {
        throw "New secret is missing from JSON."
    }
    if ($json.billingExports.sources.Count -ne 4) {
        throw "Billing export source-array output failed."
    }
    if ($json.billingExports.sources[0].scopeType -ne "subscription") {
        throw "Subscription export sources were not prioritized in the onboarding handoff."
    }
    $billingAccountSource = @($json.billingExports.sources | Where-Object { $_.scopeType -eq "billingAccount" })[0]
    $managementGroupSource = @($json.billingExports.sources | Where-Object { $_.scopeType -eq "managementGroup" })[0]
    $subscriptionSource = @($json.billingExports.sources | Where-Object { $_.scopeType -eq "subscription" })[0]
    if ($billingAccountSource.datasetType -ne "actual" -or $managementGroupSource.datasetType -ne "actual" -or $subscriptionSource.datasetType -ne "actual") {
        throw "Billing export dataset or scope classification failed in JSON."
    }
    $amortizedSource = @($json.billingExports.sources | Where-Object { $_.datasetType -eq "amortized" })[0]
    if ($amortizedSource.destination.storageAccountName -ne "billingexports123") {
        throw "Storage details are missing from JSON."
    }
    if ($amortizedSource.destination.PSObject.Properties.Name -contains "storageAccountResourceId") {
        throw "The onboarding JSON retained a redundant storage resource ID after resolving the account name."
    }

    $largeSourceSet = @()
    foreach ($index in 1..80) {
        $largeSourceSet += ConvertTo-AzureManualOnboardingBillingExportSource `
            -Scope ("/subscriptions/00000000-0000-0000-0000-{0:d12}" -f $index) `
            -DatasetType $(if ($index % 2 -eq 0) { "AmortizedCost" } else { "ActualCost" }) `
            -ExportName ("export-{0:d3}" -f $index) `
            -Destination $testDestination
    }
    $boundedSources = @(Get-AzureManualOnboardingBillingExportSourcesForHandoff -Sources $largeSourceSet)
    $boundedJson = [ordered]@{ sources = $boundedSources } | ConvertTo-Json -Depth 12 -Compress
    if ($boundedSources.Count -gt 50 -or [System.Text.Encoding]::UTF8.GetByteCount($boundedJson) -gt (24 * 1024)) {
        throw "The onboarding JSON source handoff exceeded the UI/API contract."
    }
    if ($boundedSources.Count -ge $largeSourceSet.Count) {
        throw "The onboarding JSON capacity test did not exercise bounded source output."
    }

    $rediscoveryPrioritySources = @()
    foreach ($index in 1..50) {
        $rediscoveryPrioritySources += ConvertTo-AzureManualOnboardingBillingExportSource `
            -Scope ("/subscriptions/10000000-0000-0000-0000-{0:d12}" -f $index) `
            -DatasetType "ActualCost" `
            -ExportName "spotto-actual-daily" `
            -Destination $testDestination
    }
    $rediscoveryPrioritySources += ConvertTo-AzureManualOnboardingBillingExportSource `
        -Scope "/providers/Microsoft.Management/managementGroups/platform-child" `
        -DatasetType "Usage" `
        -ExportName "customer-management-group-usage" `
        -Destination $testDestination
    $priorityBoundedSources = @(Get-AzureManualOnboardingBillingExportSourcesForHandoff -Sources $rediscoveryPrioritySources)
    if (-not @($priorityBoundedSources | Where-Object { $_.scopePath -eq "/providers/Microsoft.Management/managementGroups/platform-child" }).Count) {
        throw "The bounded onboarding handoff omitted a non-conventional child management-group locator before a rediscoverable canonical source."
    }

    if ($env:OS -eq "Windows_NT") {
        $jsonAcl = Get-Acl -LiteralPath $jsonPath
        if (-not $jsonAcl.AreAccessRulesProtected) {
            throw "Onboarding JSON still inherits filesystem permissions."
        }
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $allowRules = @($jsonAcl.Access | Where-Object { $_.AccessControlType -eq "Allow" })
        if ($allowRules.Count -ne 1 -or $allowRules[0].IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $currentSid) {
            throw "Onboarding JSON grants access to a principal other than its owner."
        }
    } else {
        $statCommand = Get-Command stat -CommandType Application -ErrorAction Stop
        $fileMode = if ($IsMacOS) { & $statCommand.Source "-f" "%Lp" $jsonPath } else { & $statCommand.Source "-c" "%a" $jsonPath }
        if ($fileMode.Trim() -ne "600") {
            throw "Onboarding JSON Unix mode is not 0600."
        }
    }

    $script:isNewSecret = $false
    $script:clientSecret = "<USE_EXISTING_SECRET>"
    $reusedCredentialJsonPath = Export-AzureManualOnboardingJson
    $reusedCredentialJson = Get-Content -LiteralPath $reusedCredentialJsonPath -Raw | ConvertFrom-Json
    if ($reusedCredentialJson.credentials.PSObject.Properties.Name -contains "clientSecret") {
        throw "An existing-secret placeholder was written to JSON."
    }
    if ($jsonPath -eq $reusedCredentialJsonPath) {
        throw "A rerun overwrote the previous onboarding JSON."
    }

    $script:acceptedBillingExportSources = @($script:acceptedBillingExportSources | Select-Object -First 1)
    $singleSourceJsonPath = Export-AzureManualOnboardingJson
    $singleSourceJsonText = Get-Content -LiteralPath $singleSourceJsonPath -Raw
    if ($singleSourceJsonText -notmatch '(?s)"sources"\s*:\s*\[') {
        throw "A single billing export source was serialized as an object instead of an array."
    }

    $jsonFileCountBeforeFailure = @(Get-ChildItem -LiteralPath $temporaryPath -Filter "SpottoAzureOnboarding-*.json").Count
    & {
        function Set-OnboardingJsonOwnerOnlyPermissions { throw "simulated permission failure" }
        $script:onboardingJsonPath = $null
        $failedJsonPath = Export-AzureManualOnboardingJson
        if ($failedJsonPath -or $script:onboardingJsonPath) {
            throw "A permission failure still reported successful JSON output."
        }
    }
    $jsonFileCountAfterFailure = @(Get-ChildItem -LiteralPath $temporaryPath -Filter "SpottoAzureOnboarding-*.json").Count
    if ($jsonFileCountAfterFailure -ne $jsonFileCountBeforeFailure) {
        throw "A failed JSON permission setup left an output file behind."
    }

    & {
        function Read-Host { return "" }
        if (Remove-OnboardingJsonAfterConfirmedImport -Path $singleSourceJsonPath) {
            throw "The onboarding JSON was deleted by the default response."
        }
        if (-not (Test-Path -LiteralPath $singleSourceJsonPath -PathType Leaf)) {
            throw "The onboarding JSON did not remain available for portal import."
        }
    }
    & {
        function Read-Host { return "yes" }
        function Write-Success { param($Message) }
        if (-not (Remove-OnboardingJsonAfterConfirmedImport -Path $singleSourceJsonPath)) {
            throw "Explicit onboarding JSON deletion was not honored."
        }
        if (Test-Path -LiteralPath $singleSourceJsonPath) {
            throw "Explicit onboarding JSON deletion left the file behind."
        }
    }
} finally {
    Pop-Location
    $resolvedTemporaryPath = (Resolve-Path -LiteralPath $temporaryPath).Path
    if (-not $resolvedTemporaryPath.StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe temporary cleanup path."
    }
    Remove-Item -LiteralPath $resolvedTemporaryPath -Recurse -Force
}

& {
    $script:shouldCreateClientSecret = $true
    $script:clientSecret = $null
    $script:secretExpiry = $null
    $script:isNewSecret = $false
    $script:onboardingJsonPath = $null
    $script:cleanupCalls = 0
    function New-SpottoClientSecret {
        return [pscustomobject]@{ SecretText = "new-secret"; EndDateTime = [datetime]"2027-08-31"; KeyId = "credential-key" }
    }
    function Export-AzureManualOnboardingJson {
        if ($script:clientSecret -ne "new-secret" -or -not $script:isNewSecret) {
            throw "The secret was not placed in memory immediately before JSON export."
        }
        $script:onboardingJsonPath = "C:\protected\handoff.json"
        return $script:onboardingJsonPath
    }
    function Remove-AzADAppCredential { $script:cleanupCalls++ }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    $handoffPath = Complete-SpottoClientSecretHandoff -Application $ownedApplication
    if ($handoffPath -ne $script:onboardingJsonPath -or $script:cleanupCalls -ne 0 -or $script:shouldCreateClientSecret) {
        throw "Successful deferred secret handoff did not preserve the protected JSON result."
    }
}

& {
    $script:shouldCreateClientSecret = $true
    $script:clientSecret = $null
    $script:secretExpiry = $null
    $script:isNewSecret = $false
    $script:onboardingJsonPath = $null
    $script:removedCredential = $null
    function New-SpottoClientSecret {
        return [pscustomobject]@{ SecretText = "new-secret"; EndDateTime = [datetime]"2027-08-31"; KeyId = "credential-key" }
    }
    function Export-AzureManualOnboardingJson { return $null }
    function Remove-AzADAppCredential {
        param($ApplicationId, $KeyId, $Confirm, $ErrorAction)
        $script:removedCredential = [pscustomobject]@{ ApplicationId = $ApplicationId; KeyId = $KeyId }
    }
    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-Warning-Custom { param($Message) }
    $handoffFailed = $false
    try {
        Complete-SpottoClientSecretHandoff -Application $ownedApplication | Out-Null
    } catch {
        $handoffFailed = $true
    }
    if (-not $handoffFailed -or
        $script:removedCredential.ApplicationId -ne $ownedApplication.AppId -or
        $script:removedCredential.KeyId -ne "credential-key" -or
        $script:clientSecret -or $script:isNewSecret) {
        throw "Failed secret-file persistence did not roll back the exact generated Azure credential."
    }
}

Write-Host "Setup-SpottoAzure offline tests: PASS"
