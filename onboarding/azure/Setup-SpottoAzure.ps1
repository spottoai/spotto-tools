<#
.SYNOPSIS
    Checks or sets up the Azure service principal permissions used by Spotto AI.

.DESCRIPTION
    This script creates a service principal, assigns the governance and billing permissions Spotto
    uses to analyze your Azure environment, can optionally configure billing exports,
    and offers recommended read-only, custom, or prerequisite-check profiles.
    
    Permissions granted:
    - Reader role at tenant root scope when all subscriptions are selected
      (inherits to all current and future subscriptions in the tenant), with automatic
      per-subscription fallback when tenant-root assignment is unavailable
    - Reader role on selected subscriptions when specific subscriptions are chosen
    - Monitoring Reader role on selected subscriptions (includes Microsoft.Insights/Components/Query/Read)
    - Security Reader role on selected subscriptions for Defender for Cloud posture
    - Log Analytics Reader role on selected subscriptions and visible management groups
      (includes workspace query access plus broader monitoring read access)
    - Reader, Management Group Reader, Monitoring Reader, and Log Analytics Reader
      on visible management groups (tenant root is recognized only by its tenant ID)
    - Key Vault Reader for secret, key, and certificate expiry metadata without
      secret values or private key material. All-subscription setup prefers the
      tenant-root management group and falls back to selected subscriptions.
    - Reservations Reader at /providers/Microsoft.Capacity
    - Custom setup only: Reservations Contributor at /providers/Microsoft.Capacity
      (calculate reservation refund quotes and support reservation management workflows)
    - Savings plan Reader at /providers/Microsoft.BillingBenefits
    - Microsoft Graph application permissions with admin consent
      (read applications, service principals, directory roles, Global Admin/PIM state,
       group membership, users, and audit logs for governance visibility)
    - Optional Cost Management exports to customer-owned Azure Storage
      (tenant-root or topmost visible management-group Usage where supported, plus
       subscription actual/amortized exports and one-time historical backfill)
      Existing billing-scope exports can be reused when the operator has access to the
      billing scope; billing-scope reader access for the Spotto service principal must
      be granted separately for EA/MCA billing hierarchy scopes.
    - Optional: Custom role for dismissing Azure Advisor recommendations
    - Optional: Custom role for enabling Storage Inventory Reports
    - Separately optional: least-privilege Azure Policy exemption actions on selected
      subscriptions and explicitly selected management-group assignment scopes
    
    This script is idempotent - it can be run multiple times safely.

.NOTES
    Prerequisites:
    - PowerShell 5.1 or PowerShell 7+
    - Azure PowerShell module (will be installed if missing)
    - Microsoft Graph PowerShell module if granting Graph governance permissions (will be installed if missing)
    - Global Administrator, Application Administrator, or appropriate permissions to create service principals
    - Owner on subscriptions, or at tenant root scope (/), for full role-assignment and billing export automation
    - If Owner is not available, User Access Administrator plus Contributor on each selected subscription
      can cover role assignment and storage/export resource creation. User Access Administrator alone cannot create
      Cost Management exports, resource groups, storage accounts, or containers.
    - Tenant admin consent for Microsoft Graph governance permissions if granting Graph governance permissions
    - Management Group Contributor or Reader for management group discovery; assigning management-group reader roles also
      requires Microsoft.Authorization/roleAssignments/write at the management-group scope, such as through
      Owner, User Access Administrator, or Role Based Access Control Administrator
    - Billing-scope reader access if reusing Cost Management exports created at an EA/MCA
      billing account, billing profile, invoice section, department, or enrollment scope
    - Export-create access at each selected management-group, billing, or subscription scope,
      plus separate storage and role-assignment access in the subscription that hosts the destination
    - Prerequisite mode can offer to assign Cost Management Contributor to the signed-in principal
      when export-write access is missing but role-assignment authority is already confirmed at the
      exact scope. The prompt lists every target and defaults to no.
    - If assigning Reader at tenant root scope (/), Global Administrators typically need
      to enable Microsoft Entra ID > Properties > Access management for Azure resources
      and then sign out and sign back in before running this script
    
.EXAMPLE
    .\Setup-SpottoAzure.ps1
#>

# Script configuration
$ErrorActionPreference = "Stop"
$APP_NAME = "Spotto"
$LEGACY_APP_NAMES = @("Spotto AI")
$APP_LOOKUP_NAMES = @($APP_NAME) + $LEGACY_APP_NAMES
$SPOTTO_APP_OWNERSHIP_TAG = "SpottoAzureOnboarding"
$SPOTTO_APP_TENANT_TAG_PREFIX = "SpottoTenantId:"
$CUSTOM_ROLE_NAME = "Spotto Access"
$POLICY_EXEMPTION_ROLE_NAME = "Spotto Policy Exemptions"
$KEY_VAULT_READER_ROLE_NAME = "Key Vault Reader"
$BILLING_EXPORT_CONTAINER_NAME = "spotto-cost-exports"
$BILLING_EXPORT_ROOT_PATH = "spotto"
$BILLING_EXPORT_DEFAULT_LOCATION = "australiaeast"
$BILLING_EXPORT_STORAGE_NAME_PREFIX = "billingexports"
$BILLING_EXPORT_STORAGE_PURPOSE_TAG = "SpottoPurpose"
$BILLING_EXPORT_STORAGE_PURPOSE_VALUE = "BillingExports"
$BILLING_EXPORT_STORAGE_TENANT_TAG = "SpottoTenantId"
$BILLING_EXPORT_STORAGE_ALIAS_VALUE = "billing-exports"
$BILLING_EXPORT_SUCCESS_STATUSES = @("existing", "created", "updated", "created-run-queued", "queued", "requeued")
$COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME = "Cost Management Contributor"
$AZURE_MANUAL_ONBOARDING_IMPORT_SCHEMA_VERSION = 1
$AZURE_MANUAL_ONBOARDING_IMPORT_KIND = "spotto.azure.manual-onboarding"
$COST_EXPORT_API_VERSION = "2025-03-01"
$BILLING_API_VERSION = "2020-05-01"
$SPOTTO_BACKFILL_QUEUED_PREFIX = "Spotto backfill queued"
$SPOTTO_BACKFILL_PENDING_PREFIX = "Spotto backfill pending"
$GRAPH_GOVERNANCE_PERMISSION_VALUES = @(
    "Application.Read.All",
    "RoleAssignmentSchedule.Read.Directory",
    "RoleEligibilitySchedule.Read.Directory",
    "RoleManagement.Read.Directory",
    "GroupMember.Read.All",
    "User.Read.All",
    "AuditLog.Read.All",
    "Policy.Read.All",
    "LicenseAssignment.Read.All"
)
$script:ConsolePanelWidth = 80

# Start logging
$logPath = "SpottoSetup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append

function Show-StartupSplash {
    param([string]$TranscriptPath)

    $logo = @'
   _____ ____   ____  ______ ______ ____
  / ___// __ \ / __ \/_  __//_  __// __ \
  \__ \/ /_/ // / / / / /    / /  / / / /
 ___/ / ____// /_/ / / /    / /  / /_/ /
/____/_/     \____/ /_/    /_/   \____/
'@

    Write-Host ""
    Write-Host ("=" * $script:ConsolePanelWidth) -ForegroundColor Cyan
    Write-Host $logo -ForegroundColor Cyan
    Write-Host ("-" * $script:ConsolePanelWidth) -ForegroundColor DarkGray
    Write-Host "  Azure onboarding for Spotto AI" -ForegroundColor White
    Write-Host "  Creates, repairs, or checks the Azure access Spotto needs." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Safe to rerun:" -ForegroundColor Green -NoNewline
    Write-Host " existing apps, secrets, and role assignments are reused where possible." -ForegroundColor White
    Write-Host "  Transcript: $TranscriptPath" -ForegroundColor DarkGray
    Write-Host ("=" * $script:ConsolePanelWidth) -ForegroundColor Cyan
    Write-Host ""
}

Show-StartupSplash -TranscriptPath $logPath

function Select-SetupMode {
    Write-Host "Choose a setup mode:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Recommended read-only access (default)" -ForegroundColor White
    Write-Host "      Adds read access across all subscriptions and offers recommended billing exports." -ForegroundColor DarkGray
    Write-Host "  [2] Custom setup" -ForegroundColor White
    Write-Host "      Choose permissions individually, including optional write access." -ForegroundColor DarkGray
    Write-Host "  [3] Check prerequisites" -ForegroundColor White
    Write-Host "      Assess access; optionally fix Cost Management export access with explicit approval." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Safe to rerun: existing Spotto resources are reused and missing access is added." -ForegroundColor Green
    Write-Host "The wizard does not remove access that is already assigned." -ForegroundColor DarkGray

    while ($true) {
        $setupModeSelection = Read-Host "Select setup mode (1/2/3, default 1)"
        if ([string]::IsNullOrWhiteSpace($setupModeSelection) -or $setupModeSelection.Trim() -in @("1", "r", "read-only", "recommended")) {
            Write-Host "`n✓ Recommended read-only access selected" -ForegroundColor Green
            return "recommended-read-only"
        }

        if ($setupModeSelection.Trim() -in @("2", "c", "custom")) {
            Write-Host "`n✓ Custom setup selected" -ForegroundColor Green
            return "custom"
        }

        if ($setupModeSelection.Trim() -in @("3", "p", "check", "prerequisite", "prerequisites", "dry-run")) {
            Write-Host "`n✓ Prerequisite check selected" -ForegroundColor Green
            return "prerequisite-check"
        }

        Write-Host "Invalid option. Enter 1 for recommended read-only access, 2 for custom setup, or 3 to check prerequisites." -ForegroundColor Red
    }
}

$script:setupMode = Select-SetupMode
$script:useRecommendedReadOnlySetup = $script:setupMode -eq "recommended-read-only"
$script:usePrerequisiteCheck = $script:setupMode -eq "prerequisite-check"
$script:totalWizardSteps = if ($script:usePrerequisiteCheck) { 3 } else { 13 }

function Get-OnboardingScopeSelection {
    if ($script:useRecommendedReadOnlySetup -or $script:usePrerequisiteCheck) {
        if ($script:usePrerequisiteCheck) {
            Write-Info "Prerequisite check: assessing all visible subscriptions."
        } else {
            Write-Info "Recommended read-only access: selecting all subscriptions."
        }
        return "1"
    }

    $selection = Read-Host "`nSelect onboarding scope (1/2, default 1)"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        return "1"
    }

    return $selection.Trim()
}

# ============================================================================
# CHECK AND INSTALL REQUIRED MODULES
# ============================================================================

function Ensure-PowerShellModules {
    param(
        [object[]]$Modules,
        [string]$ModuleSetName,
        [string[]]$ManualInstallCommands,
        [bool]$Required = $true,
        [bool]$InstallMissingByDefault = $false
    )

    Write-Host "Checking $ModuleSetName PowerShell modules..." -ForegroundColor Cyan

    $missingModules = @()

    foreach ($module in $Modules) {
        $installed = Get-Module -ListAvailable -Name $module.Name | Where-Object { $_.Version -ge $module.MinVersion }

        if (-not $installed) {
            $missingModules += $module.Name
            Write-Host "✗ Missing: $($module.Name)" -ForegroundColor Red
        } else {
            Write-Host "✓ Found: $($module.Name)" -ForegroundColor Green
        }
    }

    if ($missingModules.Count -gt 0) {
        Write-Host "`nThe following $ModuleSetName modules need to be installed:" -ForegroundColor Yellow
        foreach ($module in $missingModules) {
            Write-Host "  - $module" -ForegroundColor Yellow
        }

        if ($InstallMissingByDefault) {
            $install = "yes"
            $automaticModeLabel = if ($script:usePrerequisiteCheck) { "The prerequisite check" } else { "Recommended read-only access" }
            Write-Host "`n$automaticModeLabel requires these modules; installing them automatically." -ForegroundColor Cyan
        } else {
            $install = Read-Host "`nWould you like to install missing $ModuleSetName modules now? (yes/no, default no)"
        }

        if ($install -eq "yes") {
            Write-Host "`nInstalling modules... This may take a few minutes." -ForegroundColor Cyan

            foreach ($module in $missingModules) {
                try {
                    Write-Host "Installing $module..." -ForegroundColor Yellow
                    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
                    Write-Host "✓ Installed $module" -ForegroundColor Green
                } catch {
                    Write-Host "✗ Failed to install $module : $_" -ForegroundColor Red
                    Write-Host "`nPlease install manually using:" -ForegroundColor Yellow
                    foreach ($command in $ManualInstallCommands) {
                        Write-Host $command -ForegroundColor White
                    }

                    if ($Required) {
                        exit 1
                    }

                    return $false
                }
            }

            Write-Host "`n✓ All $ModuleSetName modules installed successfully!`n" -ForegroundColor Green
            return $true
        }

        Write-Host "`nPlease install the missing modules manually:" -ForegroundColor Yellow
        foreach ($command in $ManualInstallCommands) {
            Write-Host $command -ForegroundColor White
        }

        if ($Required) {
            exit 1
        }

        return $false
    }

    Write-Host "✓ All $ModuleSetName PowerShell modules are available`n" -ForegroundColor Green
    return $true
}

$requiredModules = @(
    @{ Name = "Az.Accounts"; MinVersion = "2.0.0" },
    @{ Name = "Az.Resources"; MinVersion = "6.0.0" },
    @{ Name = "Az.Storage"; MinVersion = "5.0.0" }
)

$graphRequiredModules = @(
    @{ Name = "Microsoft.Graph.Authentication"; MinVersion = "2.0.0" },
    @{ Name = "Microsoft.Graph.Applications"; MinVersion = "2.0.0" }
)

Ensure-PowerShellModules -Modules $requiredModules -ModuleSetName "Azure" -ManualInstallCommands @(
    "Install-Module -Name Az -Scope CurrentUser -Force"
) -Required $true -InstallMissingByDefault ($script:useRecommendedReadOnlySetup -or $script:usePrerequisiteCheck) | Out-Null

# Global variables to track credentials
$script:clientId = $null
$script:tenantId = $null
$script:clientSecret = $null
$script:secretExpiry = $null
$script:appDisplayName = $APP_NAME
$script:isNewSecret = $false
$script:shouldCreateClientSecret = $false
$script:newClientSecretKeyId = $null
$script:useTenantRootReader = $false
$script:selectedAllSubscriptions = $false
$script:usedSubscriptionReaderFallback = $false
$script:rootReaderAssignmentStatus = "not-applicable"
$script:subscriptionMonitoringReaderStatus = "not-run"
$script:subscriptionSecurityReaderStatus = "not-run"
$script:subscriptionLogAnalyticsReaderStatus = "not-run"
$script:managementGroupAzureReaderStatus = "not-run"
$script:managementGroupReaderStatus = "not-run"
$script:managementGroupMonitoringReaderStatus = "not-run"
$script:managementGroupLogAnalyticsReaderStatus = "not-run"
$script:keyVaultReaderStatus = "not-run"
$script:keyVaultReaderScope = "not-run"
$script:usedSubscriptionKeyVaultReaderFallback = $false
$script:visibleManagementGroups = @()
$script:managementGroupDiscoveryStatus = "not-run"
$script:managementGroupDiscoveryMessage = ""
$script:reservationReaderStatus = "not-run"
$script:reservationContributorStatus = "not-run"
$script:savingsPlanReaderStatus = "not-run"
$script:graphPermissionStatus = "not-run"
$script:graphPermissionSummary = ""
$script:billingExportSetupStatus = "not-run"
$script:billingScopeExportStatus = "not-run"
$script:billingExportResults = @()
$script:acceptedBillingScopeExports = @()
$script:acceptedBillingExportSources = @()
$script:onboardingJsonPath = $null

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Divider {
    param(
        [string]$Character = "=",
        [ConsoleColor]$Color = "Cyan"
    )

    Write-Host ($Character * $script:ConsolePanelWidth) -ForegroundColor $Color
}

function Get-CenteredText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -ge $script:ConsolePanelWidth) {
        return $Text
    }

    $padding = [Math]::Floor(($script:ConsolePanelWidth - $Text.Length) / 2)
    return (" " * $padding) + $Text
}

function Write-Header {
    param(
        [string]$Message,
        [string]$Subtitle = ""
    )

    Write-Host ""
    Write-Divider -Color Cyan
    Write-Host (Get-CenteredText $Message) -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host (Get-CenteredText $Subtitle) -ForegroundColor DarkGray
    }
    Write-Divider -Color Cyan
    Write-Host ""
}

function Write-PanelTitle {
    param(
        [string]$Title,
        [string]$Subtitle = "",
        [ConsoleColor]$Color = "Cyan"
    )

    Write-Host ""
    Write-Divider -Color $Color
    Write-Host (Get-CenteredText $Title) -ForegroundColor $Color
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host (Get-CenteredText $Subtitle) -ForegroundColor $Color
    }
    Write-Divider -Color $Color
}

function Write-SectionLabel {
    param([string]$Title)

    Write-Host $Title -ForegroundColor Cyan
    Write-Divider -Character "-" -Color DarkGray
}

function Write-DetailRow {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = "White"
    )

    $labelText = "  {0,-30}" -f ($Label + ":")
    Write-Host $labelText -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-NumberedStep {
    param(
        [int]$Number,
        [string]$Message
    )

    Write-Host ("  {0,2}. {1}" -f $Number, $Message)
}

function Write-OptionRow {
    param(
        [string]$Key,
        [string]$Label,
        [string]$Description = ""
    )

    Write-Host ("  [{0}] " -f $Key) -ForegroundColor Cyan -NoNewline
    Write-Host $Label -NoNewline
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        Write-Host " - $Description" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Cyan
}

function Write-Warning-Custom {
    param([string]$Message)
    Write-Host "! $Message" -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Write-Skipped {
    param([string]$Message)
    Write-Host "• $Message" -ForegroundColor DarkGray
}

function Show-Credentials {
    $subtitle = if ($script:onboardingJsonPath -and $script:isNewSecret) { "Paste the JSON contents into a new manual Azure account" } elseif ($script:isNewSecret) { "Copy each value into the matching Spotto field" } else { "Keep the existing secret and review the generated handoff details" }
    Write-PanelTitle -Title "SPOTTO PORTAL VALUES" -Subtitle $subtitle -Color Yellow
    Write-Host ""
    Write-DetailRow -Label "Tenant ID" -Value $script:tenantId -ValueColor Green
    Write-DetailRow -Label "Client ID" -Value $script:clientId -ValueColor Green
    if ($script:isNewSecret) {
        Write-DetailRow -Label "Client Secret Value" -Value $script:clientSecret -ValueColor Green
    } else {
        Write-DetailRow -Label "Client Secret Value" -Value "Existing value cannot be shown" -ValueColor Green
    }
    Write-DetailRow -Label "Secret Expires At" -Value $script:secretExpiry -ValueColor Green
    if ($script:onboardingJsonPath) {
        Write-DetailRow -Label "JSON Import File" -Value $script:onboardingJsonPath -ValueColor Green
    }
    Write-Host ""
    if ($script:isNewSecret) {
        Write-Host "Copy the Client Secret Value now. Azure only shows it once." -ForegroundColor Cyan
        if ($script:onboardingJsonPath) {
            Write-Warning-Custom "The JSON file contains the client secret. Use it promptly, store it securely, and delete it when it is no longer needed."
        }
    } else {
        Write-Host "Keep using the Client Secret Value already saved in Spotto." -ForegroundColor Cyan
        Write-Host "If it is not saved, rerun with Custom setup and create a new value." -ForegroundColor DarkGray
    }
    Write-Divider -Color Yellow
    Write-Host ""
}

function Show-NextSteps {
    Write-PanelTitle -Title "NEXT STEPS" -Subtitle "Finish the connection in Spotto" -Color Cyan
    Write-Host ""
    if ($script:isNewSecret) {
        Write-NumberedStep -Number 1 -Message "Go to the Spotto Portal: https://portal.spotto.ai"
        Write-NumberedStep -Number 2 -Message "Navigate to: Connectors > Cloud Accounts"
        Write-NumberedStep -Number 3 -Message "Add or update the Azure cloud account."
        if ($script:onboardingJsonPath) {
            Write-NumberedStep -Number 4 -Message "For a new account, open the generated file and paste its complete contents into Import PowerShell Setup Details. For an existing account, retain its saved secret and copy any required billing source details manually."
        } else {
            Write-NumberedStep -Number 4 -Message "The JSON file could not be created. Copy each value above into the matching field."
        }
        Write-NumberedStep -Number 5 -Message "Validate the credentials, then save the cloud account."
    } else {
        Write-NumberedStep -Number 1 -Message "Keep using the existing secret already stored in Spotto."
        Write-NumberedStep -Number 2 -Message "Go to the Spotto Portal: https://portal.spotto.ai"
        if ($script:onboardingJsonPath) {
            Write-NumberedStep -Number 3 -Message "Open the existing Azure cloud account, retain its saved credential values, and copy any required billing source details from the generated JSON manually. JSON import is available only while adding a new account."
        } else {
            Write-NumberedStep -Number 3 -Message "Open the Azure cloud account and retain its existing onboarding values."
        }
        Write-NumberedStep -Number 4 -Message "Retain the saved client secret, then run validation or sync again."
        Write-Info "If Spotto does not already have the secret, rerun with Custom setup and create a new one."
    }
    Write-Host ""
    Write-Info "It is safe to rerun this script later if validation needs more time or access changes."
    Write-Host ""
    Write-Divider -Color Cyan
    Write-Host ""
}

function Write-PimTroubleshootingHint {
    Write-Info "Confirm the required role from the upfront access checklist is active for the failed scope."
    Write-Info "If access was activated after signing in, let this script reconnect the Azure session when prompted or rerun it and answer yes to the session refresh prompt."
    Write-Info "Azure RBAC changes are eventually consistent. If Azure Portal shows the role but commands still return Forbidden, wait a few minutes and rerun this idempotent script."
}

function Write-SubscriptionPimTroubleshootingHint {
    param([object]$Subscription)

    Write-Warning-Custom "Spotto cannot continue with this subscription until your Azure session has active access."
    if ($Subscription) {
        Write-Info "Subscription: $($Subscription.Name) ($($Subscription.Id))"
    }
    Write-Info "Required access: Owner, or Contributor plus User Access Administrator, on each selected subscription."
    Write-Info "After activating access, let this script reconnect the Azure session when prompted or rerun it and answer yes to the session refresh prompt."
    Write-Info "The script is idempotent and will reuse existing Spotto resources where possible."
}

function Write-TenantWidePimTroubleshootingHint {
    param([string]$ScopeLabel)

    Write-Warning-Custom "This step needs Azure access at the listed tenant, management-group, or provider scope from the upfront checklist."
    if (-not [string]::IsNullOrWhiteSpace($ScopeLabel)) {
        Write-Info "Scope: $ScopeLabel"
    }
    Write-Info "Activate the relevant role for this scope, then reconnect the Azure session or rerun the script if the current session predates that activation."
    Write-Info "If your organization does not allow this access, continue with subscription onboarding and complete this role manually later."
}

function Write-NoAccessibleSubscriptionsHint {
    param(
        [string]$TenantId,
        [object[]]$VisibleSubscriptions = @()
    )

    $currentContext = Get-AzContext -ErrorAction SilentlyContinue
    $accountId = if ($currentContext -and $currentContext.Account) { $currentContext.Account.Id } else { "current Azure account" }

    Write-Error-Custom "No accessible subscriptions were found for tenant $TenantId."
    Write-Info "Signed-in account: $accountId"
    Write-Info "Nothing has been changed yet; the service principal has not been created."
    Write-Info "Check the upfront access checklist, activate the required subscription access, wait until Azure shows it as active, then rerun this script."
    Write-Info "If your company uses PIM, make sure the Azure resource role is active for the target subscription or inherited parent scope before rerunning."
    Write-Info "If you activated access after signing in, answer yes to the Azure session refresh prompt on the next run."

    if ($VisibleSubscriptions.Count -gt 0) {
        Write-Host ""
        Write-SectionLabel "Subscriptions visible to this account in other tenants"
        foreach ($subscription in $VisibleSubscriptions | Select-Object -First 10) {
            $tenantLabel = if ($subscription.TenantId) { $subscription.TenantId } else { "unknown tenant" }
            Write-Info "$($subscription.Name) ($($subscription.Id)) - tenant $tenantLabel"
        }

        if ($VisibleSubscriptions.Count -gt 10) {
            Write-Info "Showing 10 of $($VisibleSubscriptions.Count) visible subscriptions."
        }

        Write-Info "If the target subscription is listed above, rerun the script and select that subscription's tenant in Step 2."
    }
}

function Connect-AzForTenantAndSubscription {
    param(
        [string]$TenantId,
        [string]$SubscriptionId
    )

    $connectParameters = @{}
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectParameters.TenantId = $TenantId
    }
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and (Get-Command Connect-AzAccount).Parameters.ContainsKey("Subscription")) {
        $connectParameters.Subscription = $SubscriptionId
    }

    if ($connectParameters.Count -gt 0) {
        Connect-AzAccount @connectParameters | Out-Null
    } else {
        Connect-AzAccount | Out-Null
    }
}

function Disconnect-CurrentAzSession {
    try {
        $disconnectParameters = @{ ErrorAction = "SilentlyContinue" }
        if ((Get-Command Disconnect-AzAccount).Parameters.ContainsKey("Scope")) {
            $disconnectParameters.Scope = "Process"
        }
        Disconnect-AzAccount @disconnectParameters | Out-Null
    } catch {
        Write-Info "Could not clear the existing Azure session automatically. Continuing with a fresh sign-in attempt."
    }
}

function Invoke-PimAzReconnect {
    param(
        [string]$TenantId,
        [string]$SubscriptionId,
        [string]$Reason = "Azure may still be using a token from before your temporary access was activated."
    )

    Write-Warning-Custom $Reason
    Write-Info "The script can disconnect this PowerShell Azure session and sign you in again so Microsoft issues fresh tokens."
    $reconnect = Read-Host "Reconnect to Azure now? (yes/no, default yes)"
    if (-not (Test-YesResponse -Value $reconnect)) {
        return $false
    }

    Disconnect-CurrentAzSession
    Connect-AzForTenantAndSubscription -TenantId $TenantId -SubscriptionId $SubscriptionId
    return $true
}

function Set-SubscriptionContext {
    param([object]$Subscription)

    if (-not $Subscription -or -not $Subscription.Id) {
        Write-Error-Custom "Subscription details were missing. Unable to set context."
        return $false
    }

    $tenantId = if ($Subscription.TenantId) { $Subscription.TenantId } else { $script:tenantId }
    try {
        Set-AzContext -SubscriptionId $Subscription.Id -TenantId $tenantId | Out-Null
        return $true
    } catch {
        try {
            $reconnected = Invoke-PimAzReconnect `
                -TenantId $tenantId `
                -SubscriptionId $Subscription.Id `
                -Reason "Could not set Azure context for '$($Subscription.Name)'. If you just activated temporary access, your current session probably needs fresh tokens."
            if (-not $reconnected) {
                throw "Azure session reconnect was declined."
            }
            Set-AzContext -SubscriptionId $Subscription.Id -TenantId $tenantId | Out-Null
            return $true
        } catch {
            Write-Error-Custom "Failed to set context for $($Subscription.Name): $_"
            if ($tenantId) {
                Write-Info "Try: Connect-AzAccount -TenantId $tenantId"
            }
            Write-SubscriptionPimTroubleshootingHint -Subscription $Subscription
            return $false
        }
    }
}

function Test-SelectedSubscriptionAccess {
    param([object[]]$Subscriptions)

    Write-SectionLabel "Validating selected subscription access"

    $failedSubscriptions = @()
    foreach ($sub in $Subscriptions) {
        if (Set-SubscriptionContext -Subscription $sub) {
            Write-Success "Validated access to: $($sub.Name)"
        } else {
            $failedSubscriptions += $sub
        }
    }

    if ($failedSubscriptions.Count -eq 0) {
        return $true
    }

    Write-Host ""
    Write-Error-Custom "Cannot continue because $($failedSubscriptions.Count) selected subscription(s) are not accessible with the current Azure session."
    foreach ($failedSubscription in $failedSubscriptions) {
        Write-Error-Custom "  - $($failedSubscription.Name) ($($failedSubscription.Id))"
    }
    Write-SubscriptionPimTroubleshootingHint
    return $false
}

function Test-AzureActionMatchesPattern {
    param(
        [string]$RequiredAction,
        [string]$ActionPattern
    )

    return -not [string]::IsNullOrWhiteSpace($RequiredAction) `
        -and -not [string]::IsNullOrWhiteSpace($ActionPattern) `
        -and $RequiredAction -like $ActionPattern
}

function Test-AzurePermissionActionAtScope {
    param(
        [string]$Scope,
        [string]$RequiredAction
    )

    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($RequiredAction)) {
        return $false
    }

    $normalizedScope = $Scope.Trim().TrimEnd("/")
    $permissionsPath = if ([string]::IsNullOrWhiteSpace($normalizedScope)) {
        "/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    } else {
        "$normalizedScope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    }

    try {
        $permissionsResponse = Invoke-AzRestGetJson -Path $permissionsPath
        foreach ($permission in @($permissionsResponse.value)) {
            $isAllowed = $false
            foreach ($action in @($permission.actions)) {
                if (Test-AzureActionMatchesPattern -RequiredAction $RequiredAction -ActionPattern $action) {
                    $isAllowed = $true
                    break
                }
            }

            if (-not $isAllowed) {
                continue
            }

            foreach ($notAction in @($permission.notActions)) {
                if (Test-AzureActionMatchesPattern -RequiredAction $RequiredAction -ActionPattern $notAction) {
                    $isAllowed = $false
                    break
                }
            }

            if ($isAllowed) {
                return $true
            }
        }
    } catch {
        Write-Info "Unable to confirm '$RequiredAction' at scope '$Scope'. $_"
    }

    return $false
}

function Test-SelectedSubscriptionRoleAssignmentAccess {
    param([object[]]$Subscriptions)

    Write-SectionLabel "Validating selected subscription role-assignment access"

    $failedSubscriptions = @()
    foreach ($sub in $Subscriptions) {
        if (-not (Set-SubscriptionContext -Subscription $sub)) {
            $failedSubscriptions += $sub
            continue
        }

        $scope = "/subscriptions/$($sub.Id)"
        if (Test-AzurePermissionActionAtScope -Scope $scope -RequiredAction "Microsoft.Authorization/roleAssignments/write") {
            Write-Success "Validated role assignment access on: $($sub.Name)"
        } else {
            Write-Error-Custom "Missing role assignment access on: $($sub.Name)"
            $failedSubscriptions += $sub
        }
    }

    if ($failedSubscriptions.Count -eq 0) {
        return $true
    }

    Write-Host ""
    Write-Error-Custom "Cannot continue because the current Azure session cannot assign Reader access on $($failedSubscriptions.Count) selected subscription(s)."
    foreach ($failedSubscription in $failedSubscriptions) {
        Write-Error-Custom "  - $($failedSubscription.Name) ($($failedSubscription.Id))"
    }
    Write-SubscriptionPimTroubleshootingHint
    return $false
}

function Get-SignedInPrincipalObjectId {
    try {
        $context = Get-AzContext
        if ($context -and $context.Account -and $context.Account.Type -eq "ServicePrincipal") {
            $servicePrincipal = Get-AzADServicePrincipal -ApplicationId $context.Account.Id -ErrorAction Stop
            if ($servicePrincipal) {
                return $servicePrincipal.Id
            }
        }

        $signedInUser = Get-AzADUser -SignedIn -ErrorAction Stop
        if ($signedInUser) {
            return $signedInUser.Id
        }
    } catch {
        Write-Info "Unable to resolve the signed-in principal object ID. $_"
    }

    return $null
}

function Test-RootScopeRoleAssignmentGrantsAction {
    param(
        [string]$PrincipalObjectId,
        [string]$RequiredAction
    )

    if ([string]::IsNullOrWhiteSpace($PrincipalObjectId) -or [string]::IsNullOrWhiteSpace($RequiredAction)) {
        return $false
    }

    try {
        # assignedTo() includes transitive group-based assignments for users.
        $filter = [uri]::EscapeDataString("atScope() and assignedTo('$PrincipalObjectId')")
        $assignmentPath = "/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$filter"
        $assignments = @(Get-AzRestCollection -Path $assignmentPath)
        $roleDefinitions = @{}

        foreach ($assignment in $assignments) {
            if (-not $assignment.properties -or $assignment.properties.scope -ne "/") {
                continue
            }

            # Azure RBAC conditions can constrain which roles or principal types may be assigned.
            # Evaluating arbitrary ABAC expressions locally would be unsafe, so fail closed.
            if (-not [string]::IsNullOrWhiteSpace($assignment.properties.condition)) {
                Write-Info "Ignoring a conditional tenant-root role assignment because its effective role-assignment access cannot be confirmed safely."
                continue
            }

            $roleDefinitionId = $assignment.properties.roleDefinitionId
            if ([string]::IsNullOrWhiteSpace($roleDefinitionId)) {
                continue
            }

            if (-not $roleDefinitions.ContainsKey($roleDefinitionId)) {
                $roleDefinitions[$roleDefinitionId] = Invoke-AzRestGetJson -Path "${roleDefinitionId}?api-version=2022-04-01"
            }

            $roleDefinition = $roleDefinitions[$roleDefinitionId]
            if (-not $roleDefinition -or -not $roleDefinition.properties) {
                continue
            }

            foreach ($permission in @($roleDefinition.properties.permissions)) {
                $isAllowed = $false
                foreach ($action in @($permission.actions)) {
                    if (Test-AzureActionMatchesPattern -RequiredAction $RequiredAction -ActionPattern $action) {
                        $isAllowed = $true
                        break
                    }
                }

                if (-not $isAllowed) {
                    continue
                }

                foreach ($notAction in @($permission.notActions)) {
                    if (Test-AzureActionMatchesPattern -RequiredAction $RequiredAction -ActionPattern $notAction) {
                        $isAllowed = $false
                        break
                    }
                }

                if ($isAllowed) {
                    return $true
                }
            }
        }
    } catch {
        Write-Info "Unable to confirm '$RequiredAction' at tenant root scope (/). $_"
    }

    return $false
}

function Test-TenantRootRoleAssignmentAccess {
    Write-SectionLabel "Validating tenant root role-assignment access"

    # Microsoft.Authorization/permissions is not available at tenant root scope (/).
    # Inspect the signed-in principal's unrestricted root role assignments instead.
    $principalObjectId = Get-SignedInPrincipalObjectId
    if (Test-RootScopeRoleAssignmentGrantsAction -PrincipalObjectId $principalObjectId -RequiredAction "Microsoft.Authorization/roleAssignments/write") {
        Write-Success "Validated role assignment access at tenant root scope (/)"
        return $true
    }

    Write-Warning-Custom "Cannot confirm role assignment access at tenant root scope (/)."
    Write-Info "The wizard will try assigning Reader separately on each selected subscription."
    return $false
}

function Use-SubscriptionReaderFallback {
    param(
        [object[]]$Subscriptions,
        [string]$Reason
    )

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Warning-Custom $Reason
    }
    Write-Info "Trying the same idempotent Reader setup one subscription at a time."

    if (-not $Subscriptions -or $Subscriptions.Count -eq 0) {
        Write-Error-Custom "No subscriptions are available for the Reader fallback."
        return $false
    }

    if (-not (Test-SelectedSubscriptionAccess -Subscriptions $Subscriptions)) {
        Write-Error-Custom "The subscription-by-subscription Reader fallback is not available with the current Azure session."
        return $false
    }

    if (-not (Test-SelectedSubscriptionRoleAssignmentAccess -Subscriptions $Subscriptions)) {
        Write-Error-Custom "The current Azure session cannot assign Reader on every selected subscription."
        return $false
    }

    $script:useTenantRootReader = $false
    $script:usedSubscriptionReaderFallback = $true
    Write-Success "Validated subscription-by-subscription Reader assignment for all $($Subscriptions.Count) subscription(s)."
    return $true
}

function Ensure-SubscriptionRoleAssignments {
    param(
        [string]$PrincipalId,
        [object[]]$Subscriptions,
        [string]$RoleDefinitionName,
        [string]$RoleLabel
    )

    $successCount = 0
    $skipCount = 0
    $failureCount = 0

    foreach ($sub in $Subscriptions) {
        try {
            if (-not (Set-SubscriptionContext -Subscription $sub)) {
                $failureCount++
                continue
            }

            $scope = "/subscriptions/$($sub.Id)"
            $existingAssignment = Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleDefinitionName -Scope $scope -ErrorAction SilentlyContinue

            if ($existingAssignment) {
                Write-Info "$RoleLabel already assigned on: $($sub.Name)"
                $skipCount++
            } else {
                New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleDefinitionName -Scope $scope | Out-Null
                Write-Success "Assigned $RoleLabel on: $($sub.Name)"
                $successCount++
            }
        } catch {
            $failureCount++
            Write-Error-Custom "Failed to assign $RoleLabel on $($sub.Name): $_"
            if ($_.Exception.Message -match "Forbidden") {
                Write-Info "Requires Owner or User Access Administrator on the subscription."
                Write-PimTroubleshootingHint
                Write-SubscriptionPimTroubleshootingHint -Subscription $sub
            }
        }
    }

    Write-Info "Summary: $successCount new assignments, $skipCount already existed, $failureCount failed"
    return ($failureCount -eq 0)
}

function Ensure-TenantRootReaderAssignment {
    param([string]$PrincipalId)

    $rootScope = "/"

    try {
        $existingRootReader = Get-AzRoleAssignment -ObjectId $PrincipalId -Scope $rootScope -RoleDefinitionName "Reader" -ErrorAction SilentlyContinue

        if ($existingRootReader) {
            Write-Info "Reader role already assigned at tenant root scope (/)"
            return "existing"
        }

        New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName "Reader" -Scope $rootScope | Out-Null
        Write-Success "Assigned Reader role at tenant root scope (/)"
        return "created"
    } catch {
        Write-Warning-Custom "Tenant-root Reader assignment was not available: $_"

        if ($_.Exception.Message -match "Forbidden|AuthorizationFailed|does not have authorization") {
            Write-Info "This requires Owner or User Access Administrator at tenant root scope (/)."
            Write-Info "If you are a Global Administrator, enable Microsoft Entra ID > Properties > Access management for Azure resources."
            Write-Info "After enabling it, sign out, sign back in, and rerun the script."
            Write-PimTroubleshootingHint
        }

        Write-Info "The wizard will try assigning Reader separately on each selected subscription."
        return "failed"
    }
}

function Test-TenantRootManagementGroup {
    param(
        [object]$ManagementGroup,
        [string]$TenantId
    )

    if (-not $ManagementGroup -or [string]::IsNullOrWhiteSpace($TenantId)) {
        return $false
    }

    $normalizedTenantId = $TenantId.Trim()
    $expectedRootScope = "/providers/Microsoft.Management/managementGroups/$normalizedTenantId"
    $managementGroupName = ([string]$ManagementGroup.Name).Trim()
    $managementGroupScope = ([string]$ManagementGroup.Id).TrimEnd("/")

    if (-not [string]::IsNullOrWhiteSpace($managementGroupName)) {
        return $managementGroupName -ieq $normalizedTenantId
    }

    return $managementGroupScope -ieq $expectedRootScope
}

function Get-ManagementGroupScope {
    param([object]$ManagementGroup)

    if (-not $ManagementGroup -or [string]::IsNullOrWhiteSpace([string]$ManagementGroup.Name)) {
        throw "Management group ID is missing."
    }

    $managementGroupName = ([string]$ManagementGroup.Name).Trim()
    return "/providers/Microsoft.Management/managementGroups/$managementGroupName"
}

function Get-ManagementGroupDisplayLabel {
    param(
        [object]$ManagementGroup,
        [string]$TenantId
    )

    $managementGroupName = ([string]$ManagementGroup.Name).Trim()
    $displayName = ([string]$ManagementGroup.DisplayName).Trim()
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = $managementGroupName
    }

    if (Test-TenantRootManagementGroup -ManagementGroup $ManagementGroup -TenantId $TenantId) {
        return "$displayName (tenant root: $managementGroupName)"
    }

    if ($displayName -ieq $managementGroupName) {
        return $managementGroupName
    }

    return "$displayName ($managementGroupName)"
}

function Get-ManagementGroupParentScope {
    param([object]$ManagementGroup)

    if (-not $ManagementGroup) {
        return ""
    }

    $parentScope = [string]$ManagementGroup.ParentId
    if ([string]::IsNullOrWhiteSpace($parentScope) -and $ManagementGroup.Parent) {
        $parentScope = [string]$ManagementGroup.Parent.Id
    }
    if ([string]::IsNullOrWhiteSpace($parentScope) -and $ManagementGroup.Details -and $ManagementGroup.Details.Parent) {
        $parentScope = [string]$ManagementGroup.Details.Parent.Id
    }

    return $parentScope.Trim().TrimEnd("/")
}

function Get-PreferredManagementGroupExportTargets {
    param(
        [object[]]$ManagementGroups,
        [string]$TenantId
    )

    $visibleGroups = @($ManagementGroups | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Name) })
    $tenantRoot = @($visibleGroups |
        Where-Object { Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $TenantId } |
        Select-Object -First 1)
    if ($tenantRoot.Count -gt 0) {
        return @($tenantRoot[0])
    }

    $visibleScopes = @{}
    foreach ($managementGroup in $visibleGroups) {
        $visibleScopes[(Get-ManagementGroupScope -ManagementGroup $managementGroup).ToLowerInvariant()] = $true
    }

    return @($visibleGroups |
        Where-Object {
            $parentScope = Get-ManagementGroupParentScope -ManagementGroup $_
            [string]::IsNullOrWhiteSpace($parentScope) -or -not $visibleScopes.ContainsKey($parentScope.ToLowerInvariant())
        } |
        Sort-Object -Property @{ Expression = { [string]$_.Name } })
}

function Get-ManagementGroupExportDiscoveryTargets {
    param(
        [object[]]$ManagementGroups,
        [string]$TenantId
    )

    $visibleGroups = @($ManagementGroups | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Name) })
    $tenantRoot = @($visibleGroups |
        Where-Object { Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $TenantId } |
        Select-Object -First 1)
    $nonRootGroups = @($visibleGroups |
        Where-Object { -not (Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $TenantId) })

    $targets = @()
    if ($tenantRoot.Count -gt 0) {
        $targets += $tenantRoot[0]
    }
    $targets += @(Get-PreferredManagementGroupExportTargets `
        -ManagementGroups $nonRootGroups `
        -TenantId $TenantId)

    $seenScopes = @{}
    return @($targets | Where-Object {
        $scope = Get-ManagementGroupScope -ManagementGroup $_
        $key = $scope.ToLowerInvariant()
        if ($seenScopes.ContainsKey($key)) {
            return $false
        }

        $seenScopes[$key] = $true
        return $true
    })
}

function Get-ExistingManagementGroupExportTargets {
    param(
        [object[]]$DiscoveryResults,
        [string]$TenantId
    )

    $existingTargets = @($DiscoveryResults | Where-Object {
        $_ -and $_.Discovery -and @($_.Discovery.MatchesByDataset["Usage"]).Count -gt 0
    })
    $existingTenantRoot = @($existingTargets |
        Where-Object { Test-TenantRootManagementGroup -ManagementGroup $_.ManagementGroup -TenantId $TenantId } |
        Select-Object -First 1)
    if ($existingTenantRoot.Count -gt 0) {
        return @($existingTenantRoot[0])
    }

    return @($existingTargets)
}

function Get-VisibleManagementGroupTargets {
    param([string]$TenantId)

    $script:managementGroupDiscoveryStatus = "unconfirmed"
    $script:managementGroupDiscoveryMessage = ""
    try {
        $managementGroups = @(Get-AzManagementGroup -ErrorAction Stop)
    } catch {
        $script:managementGroupDiscoveryMessage = Get-SafeAzureAssessmentFailure -ErrorRecord $_
        Write-Warning-Custom "Management groups visible to the current Azure session could not be listed: $_"
        return @()
    }

    $script:managementGroupDiscoveryStatus = "ready"

    $managementGroupsByName = @{}
    foreach ($managementGroup in $managementGroups) {
        $managementGroupName = ([string]$managementGroup.Name).Trim()
        if ([string]::IsNullOrWhiteSpace($managementGroupName)) {
            continue
        }

        $managementGroupTenantId = ([string]$managementGroup.TenantId).Trim()
        if (-not [string]::IsNullOrWhiteSpace($managementGroupTenantId) -and $managementGroupTenantId -ine $TenantId) {
            continue
        }

        if (-not $managementGroupsByName.ContainsKey($managementGroupName)) {
            $managementGroupsByName[$managementGroupName] = $managementGroup
        }
    }

    $visibleManagementGroups = @($managementGroupsByName.Values |
        Sort-Object `
            @{ Expression = { if (Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $TenantId) { 0 } else { 1 } } }, `
            @{ Expression = { [string]$_.DisplayName } }, `
            @{ Expression = { [string]$_.Name } })

    if ($visibleManagementGroups.Count -eq 0) {
        $script:managementGroupDiscoveryMessage = "Azure returned no management groups visible to the signed-in account."
        Write-Warning-Custom "No management groups are visible to the current Azure session."
        return @()
    }

    $tenantRootManagementGroup = @($visibleManagementGroups |
        Where-Object { Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $TenantId } |
        Select-Object -First 1)

    if ($tenantRootManagementGroup.Count -gt 0) {
        $rootLabel = Get-ManagementGroupDisplayLabel -ManagementGroup $tenantRootManagementGroup[0] -TenantId $TenantId
        Write-Success "Tenant root management group is visible: $rootLabel"
    } else {
        Write-Warning-Custom "The tenant root management group is not available to the current Azure session."
        Write-Info "The wizard will use the $($visibleManagementGroups.Count) visible management group(s) instead."
    }

    $script:managementGroupDiscoveryMessage = "Azure returned $($visibleManagementGroups.Count) visible management group(s)."

    return $visibleManagementGroups
}

function Ensure-ManagementGroupRoleAssignments {
    param(
        [string]$PrincipalId,
        [object[]]$ManagementGroups,
        [string]$TenantId,
        [string]$RoleDefinitionName,
        [string]$RoleLabel
    )

    $targets = @($ManagementGroups |
        Sort-Object `
            @{ Expression = { if (Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $TenantId) { 0 } else { 1 } } }, `
            @{ Expression = { [string]$_.DisplayName } }, `
            @{ Expression = { [string]$_.Name } })
    if ($targets.Count -eq 0) {
        Write-Warning-Custom "$RoleLabel was not assigned because no management groups are visible."
        return [PSCustomObject]@{
            Status              = "unavailable"
            Created             = 0
            Existing            = 0
            Failed              = 0
            Attempted           = 0
            Visible             = 0
            CoveredByTenantRoot = $false
        }
    }

    $createdCount = 0
    $existingCount = 0
    $failureCount = 0
    $attemptedCount = 0
    $coveredByTenantRoot = $false

    foreach ($managementGroup in $targets) {
        $attemptedCount++
        $isTenantRoot = Test-TenantRootManagementGroup -ManagementGroup $managementGroup -TenantId $TenantId
        $managementGroupLabel = Get-ManagementGroupDisplayLabel -ManagementGroup $managementGroup -TenantId $TenantId

        try {
            $managementGroupScope = Get-ManagementGroupScope -ManagementGroup $managementGroup
            $existingAssignment = @(Get-AzRoleAssignment `
                -ObjectId $PrincipalId `
                -Scope $managementGroupScope `
                -RoleDefinitionName $RoleDefinitionName `
                -ErrorAction Stop)

            if ($existingAssignment.Count -gt 0) {
                Write-Info "$RoleLabel already assigned on: $managementGroupLabel"
                $existingCount++
            } else {
                New-AzRoleAssignment `
                    -ObjectId $PrincipalId `
                    -RoleDefinitionName $RoleDefinitionName `
                    -Scope $managementGroupScope `
                    -ErrorAction Stop | Out-Null
                Write-Success "Assigned $RoleLabel on: $managementGroupLabel"
                $createdCount++
            }

            if ($isTenantRoot) {
                $coveredByTenantRoot = $true
                $remainingVisibleCount = $targets.Count - $attemptedCount
                if ($remainingVisibleCount -gt 0) {
                    Write-Info "$RoleLabel at tenant root covers the remaining $remainingVisibleCount visible management group(s)."
                }
                break
            }
        } catch {
            $failureCount++
            Write-Warning-Custom "Failed to assign $RoleLabel on ${managementGroupLabel}: $_"
            if ($_.Exception.Message -match "Forbidden|AuthorizationFailed|does not have authorization") {
                Write-TenantWidePimTroubleshootingHint -ScopeLabel $managementGroupLabel
            }
        }
    }

    $status = if ($failureCount -gt 0 -and ($createdCount + $existingCount) -gt 0) {
        "partial"
    } elseif ($failureCount -gt 0) {
        "failed"
    } elseif ($createdCount -gt 0 -and $existingCount -eq 0) {
        "created"
    } elseif ($createdCount -eq 0 -and $existingCount -gt 0) {
        "existing"
    } else {
        "processed"
    }

    Write-Info "Management group summary for ${RoleLabel}: $createdCount new, $existingCount already existed, $failureCount failed"
    return [PSCustomObject]@{
        Status              = $status
        Created             = $createdCount
        Existing            = $existingCount
        Failed              = $failureCount
        Attempted           = $attemptedCount
        Visible             = $targets.Count
        CoveredByTenantRoot = $coveredByTenantRoot
    }
}

function Ensure-KeyVaultReaderAssignments {
    param(
        [string]$PrincipalId,
        [object[]]$Subscriptions,
        [string]$TenantId,
        [object[]]$ManagementGroups,
        [bool]$PreferTenantRootManagementGroup
    )

    if ($PreferTenantRootManagementGroup) {
        $tenantRootManagementGroup = @($ManagementGroups |
            Where-Object { Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $TenantId } |
            Select-Object -First 1)

        if ($tenantRootManagementGroup.Count -gt 0) {
            $managementGroupResult = Ensure-ManagementGroupRoleAssignments `
                -PrincipalId $PrincipalId `
                -ManagementGroups $tenantRootManagementGroup `
                -TenantId $TenantId `
                -RoleDefinitionName $KEY_VAULT_READER_ROLE_NAME `
                -RoleLabel "Key Vault Reader role"

            if ($managementGroupResult.CoveredByTenantRoot) {
                return [PSCustomObject]@{
                    Status       = $managementGroupResult.Status
                    Scope        = "tenant-root-management-group"
                    UsedFallback = $false
                }
            }

            Write-Warning-Custom "Key Vault Reader could not be confirmed at the tenant-root management group."
        } else {
            Write-Warning-Custom "The tenant-root management group is not visible, so Key Vault Reader cannot be assigned there."
        }

        Write-Info "Falling back to Key Vault Reader assignments on every selected subscription."
    }

    $subscriptionAssignmentsSucceeded = Ensure-SubscriptionRoleAssignments `
        -PrincipalId $PrincipalId `
        -Subscriptions $Subscriptions `
        -RoleDefinitionName $KEY_VAULT_READER_ROLE_NAME `
        -RoleLabel "Key Vault Reader role"

    return [PSCustomObject]@{
        Status       = if ($subscriptionAssignmentsSucceeded) { "processed" } else { "failed" }
        Scope        = "subscriptions"
        UsedFallback = $PreferTenantRootManagementGroup
    }
}

function Write-ManagementGroupRoleSummary {
    param(
        [string]$Status,
        [string]$RoleLabel
    )

    switch ($Status) {
        "created" { Write-Success "$RoleLabel assigned on visible management group scope(s)" }
        "existing" { Write-Success "$RoleLabel already existed on visible management group scope(s)" }
        "processed" { Write-Success "$RoleLabel processed on visible management group scope(s)" }
        "partial" { Write-Warning-Custom "$RoleLabel was assigned on some visible management groups but failed on others" }
        "failed" { Write-Error-Custom "$RoleLabel could not be assigned on visible management groups" }
        "unavailable" { Write-Warning-Custom "$RoleLabel was not assigned because no management groups were visible" }
        "skipped" { Write-Skipped "$RoleLabel skipped" }
        default { Write-Skipped "$RoleLabel was not processed on management groups" }
    }
}

function Get-DefaultedInput {
    param(
        [string]$Prompt,
        [string]$DefaultValue
    )

    if ($script:useRecommendedReadOnlySetup) {
        Write-Info "Recommended read-only access: using $Prompt '$DefaultValue'."
        return $DefaultValue
    }

    $value = Read-Host "$Prompt [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value.Trim()
}

function Test-YesResponse {
    param(
        [string]$Value,
        [bool]$DefaultYes = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultYes
    }

    return $Value -match "^(?i:y|yes)$"
}

function Get-ClientSecretPlan {
    param(
        [object[]]$Credentials,
        [datetime]$ReferenceTime = (Get-Date),
        [int]$MinimumRemainingMonths = 3
    )

    if ($MinimumRemainingMonths -lt 0) {
        throw "Minimum remaining client-secret months cannot be negative."
    }

    $validCredentials = @(
        $Credentials |
            Where-Object {
                if ($null -eq $_ -or $null -eq $_.EndDateTime) {
                    return $false
                }

                $startDateProperty = $_.PSObject.Properties["StartDateTime"]
                $isActive = $null -eq $startDateProperty -or
                    $null -eq $startDateProperty.Value -or
                    ([datetime]$startDateProperty.Value) -le $ReferenceTime

                return $isActive -and ([datetime]$_.EndDateTime) -gt $ReferenceTime
            } |
            Sort-Object -Property EndDateTime -Descending
    )
    $latestCredential = $validCredentials | Select-Object -First 1
    $rotationThreshold = $ReferenceTime.AddMonths($MinimumRemainingMonths)
    $action = if (
        $null -eq $latestCredential -or
        ([datetime]$latestCredential.EndDateTime) -lt $rotationThreshold
    ) {
        "create"
    } else {
        "reuse"
    }

    return [pscustomobject]@{
        Action = $action
        ValidCredentials = @($validCredentials)
        LatestCredential = $latestCredential
        RotationThreshold = $rotationThreshold
    }
}

function Get-ApplicationPasswordCredentials {
    param([object[]]$Credentials)

    return @(
        $Credentials | Where-Object {
            $null -ne $_ -and
            @($_.PSObject.TypeNames | Where-Object { $_ -match "PasswordCredential" }).Count -gt 0
        }
    )
}

function Get-SpottoApplicationTags {
    param([object]$Application)

    if (-not $Application) {
        return @()
    }

    $tagProperty = $Application.PSObject.Properties["Tag"]
    if (-not $tagProperty) {
        $tagProperty = $Application.PSObject.Properties["Tags"]
    }

    if (-not $tagProperty -or $null -eq $tagProperty.Value) {
        return @()
    }

    return @($tagProperty.Value | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
}

function Get-SpottoApplicationObjectId {
    param([object]$Application)

    foreach ($propertyName in @("Id", "ObjectId")) {
        $property = $Application.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace("$($property.Value)")) {
            return "$($property.Value)"
        }
    }

    return $null
}

function Get-SpottoApplicationOwnershipTags {
    param([string]$TenantId)

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "Tenant ID is required to identify a Spotto application."
    }

    return @(
        $SPOTTO_APP_OWNERSHIP_TAG,
        "$SPOTTO_APP_TENANT_TAG_PREFIX$TenantId"
    )
}

function Test-SpottoAzureOnboardingApplicationOwnership {
    param(
        [object]$Application,
        [string]$TenantId
    )

    $tags = @(Get-SpottoApplicationTags -Application $Application)
    $requiredTags = @(Get-SpottoApplicationOwnershipTags -TenantId $TenantId)
    return @($requiredTags | Where-Object { $_ -notin $tags }).Count -eq 0
}

function Resolve-SpottoAzureApplication {
    param([string]$TenantId)

    $applicationsByClientId = @{}
    foreach ($appLookupName in $APP_LOOKUP_NAMES) {
        foreach ($candidate in @(Get-AzADApplication -DisplayName $appLookupName -ErrorAction SilentlyContinue)) {
            if (-not $candidate -or [string]::IsNullOrWhiteSpace("$($candidate.AppId)")) {
                continue
            }
            if (-not [string]::Equals("$($candidate.DisplayName)", $appLookupName, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $applicationsByClientId["$($candidate.AppId)"] = $candidate
        }
    }

    $candidates = @($applicationsByClientId.Values)
    $ownedCandidates = @(
        $candidates | Where-Object {
            Test-SpottoAzureOnboardingApplicationOwnership -Application $_ -TenantId $TenantId
        }
    )

    if ($ownedCandidates.Count -eq 1) {
        return $ownedCandidates[0]
    }
    if ($ownedCandidates.Count -gt 1) {
        $ownedClientIds = @($ownedCandidates | ForEach-Object { $_.AppId }) -join ", "
        throw "Multiple Spotto applications are tagged for this tenant ($ownedClientIds). Resolve the duplicate application registrations before rerunning."
    }
    if ($candidates.Count -eq 0) {
        return $null
    }

    Write-Host ""
    Write-Warning-Custom "Existing applications have a Spotto display name but are not marked as created by this onboarding script."
    Write-Info "To reuse one, enter its exact Application (client) ID. Leave blank to create a new tagged Spotto application."
    foreach ($candidate in ($candidates | Sort-Object -Property DisplayName, AppId)) {
        Write-DetailRow -Label $candidate.DisplayName -Value "Client ID $($candidate.AppId); Object ID $(Get-SpottoApplicationObjectId -Application $candidate)"
    }

    $selectedClientId = (Read-Host "Application (client) ID to reuse (default create new)").Trim()
    if ([string]::IsNullOrWhiteSpace($selectedClientId)) {
        return $null
    }

    $selectedApplication = @(
        $candidates | Where-Object {
            [string]::Equals("$($_.AppId)", $selectedClientId, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
    if ($selectedApplication.Count -ne 1) {
        throw "The entered Application (client) ID does not exactly match one of the displayed candidates. No application was changed."
    }

    $selectedApplication = $selectedApplication[0]
    $objectId = Get-SpottoApplicationObjectId -Application $selectedApplication
    if ([string]::IsNullOrWhiteSpace($objectId)) {
        throw "The selected application has no object ID and cannot be marked for safe reuse."
    }

    $updatedTags = @(
        @(Get-SpottoApplicationTags -Application $selectedApplication) +
        @(Get-SpottoApplicationOwnershipTags -TenantId $TenantId) |
            Sort-Object -Unique
    )
    Update-AzADApplication -ObjectId $objectId -Tag $updatedTags -ErrorAction Stop | Out-Null
    Write-Success "Marked the explicitly selected application for safe Spotto onboarding reruns"
    return $selectedApplication
}

function Ensure-SpottoServicePrincipal {
    param([object]$Application)

    if (-not $Application -or [string]::IsNullOrWhiteSpace("$($Application.AppId)")) {
        throw "A valid application is required to resolve its service principal."
    }

    $servicePrincipals = @(
        Get-AzADServicePrincipal -ApplicationId $Application.AppId -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_ }
    )
    if ($servicePrincipals.Count -gt 1) {
        throw "Multiple service principals were returned for application $($Application.AppId). Resolve the directory inconsistency before rerunning."
    }
    if ($servicePrincipals.Count -eq 1) {
        return $servicePrincipals[0]
    }

    $servicePrincipal = New-AzADServicePrincipal -ApplicationId $Application.AppId -ErrorAction Stop
    Write-Success "Created the missing service principal"
    Write-Info "Waiting for the service principal to propagate (30 seconds)..."
    Start-Sleep -Seconds 30
    return $servicePrincipal
}

function Read-SetupConfirmation {
    param(
        [string]$Prompt,
        [bool]$DefaultYes
    )

    $defaultLabel = if ($DefaultYes) { "yes" } else { "no" }
    $response = Read-Host "$Prompt (yes/no, default $defaultLabel)"
    if (Test-YesResponse -Value $response -DefaultYes $DefaultYes) {
        return "yes"
    }

    return "no"
}

function Get-SetupCapabilityResponse {
    param(
        [string]$Capability,
        [string]$Prompt,
        [bool]$RecommendedReadOnlyValue,
        [bool]$CustomDefaultYes = $true
    )

    if ($script:useRecommendedReadOnlySetup) {
        if ($RecommendedReadOnlyValue) {
            Write-Info "Recommended read-only access: including $Capability."
            return "yes"
        }

        Write-Info "Recommended read-only access: skipping $Capability because it grants write access or exceeds the selected-subscription scope."
        return "no"
    }

    return Read-SetupConfirmation -Prompt $Prompt -DefaultYes $CustomDefaultYes
}

function Resolve-IndexedSelectionToken {
    param(
        [string]$Token,
        [int]$MaxValue,
        [bool]$AllowAll = $true
    )

    $result = [pscustomobject]@{
        IsIndexToken = $false
        IsValid = $false
        Indexes = @()
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $result
    }

    $trimmedToken = $Token.Trim()
    if ($trimmedToken -match "^(?i:all)$") {
        $result.IsIndexToken = $true
        if ($AllowAll -and $MaxValue -ge 1) {
            $result.IsValid = $true
            $result.Indexes = @(1..$MaxValue)
        }

        return $result
    }

    if ($trimmedToken -match "^(\d+)\s*-\s*(\d+)$") {
        $result.IsIndexToken = $true
        $rangeStart = 0
        $rangeEnd = 0
        if (-not [int]::TryParse($Matches[1], [ref]$rangeStart) -or -not [int]::TryParse($Matches[2], [ref]$rangeEnd)) {
            return $result
        }

        if ($rangeStart -lt 1 -or $rangeEnd -gt $MaxValue -or $rangeStart -gt $rangeEnd) {
            return $result
        }

        $result.IsValid = $true
        $result.Indexes = @($rangeStart..$rangeEnd)
        return $result
    }

    if ($trimmedToken -match "^\d+$") {
        $result.IsIndexToken = $true
        $selectedIndex = 0
        if ([int]::TryParse($trimmedToken, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $MaxValue) {
            $result.IsValid = $true
            $result.Indexes = @($selectedIndex)
        }

        return $result
    }

    return $result
}

function ConvertFrom-IndexedSelection {
    param(
        [string]$Selection,
        [int]$MaxValue,
        [bool]$AllowAll = $true
    )

    $indexes = @()
    $invalidTokens = @()
    foreach ($entry in ($Selection -split ",")) {
        $resolvedToken = Resolve-IndexedSelectionToken -Token $entry -MaxValue $MaxValue -AllowAll $AllowAll
        if (-not $resolvedToken.IsIndexToken -or -not $resolvedToken.IsValid) {
            $invalidTokens += $entry.Trim()
            continue
        }

        $indexes += @($resolvedToken.Indexes)
    }

    $uniqueIndexes = @($indexes | Sort-Object -Unique)
    return [pscustomobject]@{
        IsValid = $invalidTokens.Count -eq 0 -and $uniqueIndexes.Count -gt 0
        Indexes = $uniqueIndexes
        InvalidTokens = @($invalidTokens)
    }
}

function Read-IndexedSelection {
    param(
        [string]$Prompt,
        [int]$MaxValue,
        [bool]$AllowEmpty = $false
    )

    while ($true) {
        $selection = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($selection)) {
            if ($AllowEmpty) {
                return $null
            }

            Write-Error-Custom "A selection is required. Enter a number between 1 and $MaxValue."
            continue
        }

        $selectedIndex = 0
        if ([int]::TryParse($selection.Trim(), [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $MaxValue) {
            return ($selectedIndex - 1)
        }

        Write-Error-Custom "Invalid selection '$selection'. Enter a number between 1 and $MaxValue."
    }
}

function Resolve-AzureLocationName {
    param([string]$Location)

    if ([string]::IsNullOrWhiteSpace($Location)) {
        return $BILLING_EXPORT_DEFAULT_LOCATION
    }

    $normalized = $Location.Trim().ToLowerInvariant() -replace "[\s_-]", ""
    $aliases = @{
        "aueast" = "australiaeast"
        "auseast" = "australiaeast"
        "australiaeast" = "australiaeast"
        "ausoutheast" = "australiasoutheast"
        "australiasoutheast" = "australiasoutheast"
        "nzealandnorth" = "newzealandnorth"
        "nzorth" = "newzealandnorth"
        "nznorth" = "newzealandnorth"
        "newzealandnorth" = "newzealandnorth"
    }

    if ($aliases.ContainsKey($normalized)) {
        return $aliases[$normalized]
    }

    return $normalized
}

function Get-AvailableAzureLocationNames {
    try {
        return @(
            Get-AzLocation -ErrorAction Stop |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.Location) } |
                ForEach-Object { $_.Location.ToLowerInvariant() } |
                Sort-Object -Unique
        )
    } catch {
        Write-Info "Unable to retrieve Azure region list for validation. Continuing with basic location normalization. $_"
        return @()
    }
}

function Read-AzureLocationInput {
    param(
        [string]$Prompt,
        [string]$DefaultValue,
        [string[]]$AvailableLocations
    )

    while ($true) {
        $locationInput = Get-DefaultedInput -Prompt $Prompt -DefaultValue $DefaultValue
        $location = Resolve-AzureLocationName -Location $locationInput

        if ($AvailableLocations.Count -eq 0 -or $AvailableLocations -contains $location) {
            if ($locationInput.Trim().ToLowerInvariant() -ne $location) {
                Write-Info "Using Azure region '$location' for input '$locationInput'."
            }
            return $location
        }

        Write-Error-Custom "Azure region '$locationInput' is not valid or not available for this subscription."
        Write-Info "Use Azure location names such as 'australiaeast', 'australiasoutheast', 'newzealandnorth', 'eastus', or 'westeurope'."
    }
}

function Get-StorageAccountParts {
    param([string]$StorageAccountId)

    if ($StorageAccountId -notmatch "^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/]+)$") {
        throw "Storage account resource ID is not in the expected format: $StorageAccountId"
    }

    return [pscustomobject]@{
        SubscriptionId = $Matches[1]
        ResourceGroupName = $Matches[2]
        Name = $Matches[3]
    }
}

function Get-StorageAccountResource {
    param([string]$StorageAccountId)

    $storageParts = Get-StorageAccountParts -StorageAccountId $StorageAccountId
    Set-AzContext -SubscriptionId $storageParts.SubscriptionId -TenantId $script:tenantId | Out-Null
    return Get-AzStorageAccount -ResourceGroupName $storageParts.ResourceGroupName -Name $storageParts.Name -ErrorAction Stop
}

function Ensure-ResourceProviderRegistered {
    param(
        [string]$SubscriptionId,
        [string]$ProviderNamespace,
        [int]$MaxAttempts = 24,
        [int]$PollSeconds = 5
    )

    try {
        Set-AzContext -SubscriptionId $SubscriptionId -TenantId $script:tenantId | Out-Null
        $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction SilentlyContinue
        if ($provider -and $provider.RegistrationState -eq "Registered") {
            Write-Info "$ProviderNamespace is already registered in subscription $SubscriptionId"
            return $true
        }

        Register-AzResourceProvider -ProviderNamespace $ProviderNamespace | Out-Null
        Write-Success "Requested registration for $ProviderNamespace in subscription $SubscriptionId"
        for ($attempt = 0; $attempt -lt $MaxAttempts; $attempt++) {
            Start-Sleep -Seconds $PollSeconds
            $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction SilentlyContinue
            if ($provider -and $provider.RegistrationState -eq "Registered") {
                Write-Success "$ProviderNamespace is registered in subscription $SubscriptionId"
                return $true
            }
        }

        Write-Info "$ProviderNamespace registration is still pending. Azure may finish it in the background."
        return $false
    } catch {
        Write-Error-Custom "Failed to register ${ProviderNamespace}: $_"
        Write-Info "You can register it manually and rerun this script."
        return $false
    }
}

function Test-StorageAccountNameAvailable {
    param(
        [string]$SubscriptionId,
        [string]$Name
    )

    Set-AzContext -SubscriptionId $SubscriptionId -TenantId $script:tenantId | Out-Null
    $result = Get-AzStorageAccountNameAvailability -Name $Name -ErrorAction Stop
    return [bool]$result.nameAvailable
}

function Test-BillingStorageAccountNameFormat {
    param([string]$Name)

    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name -match "^[a-z0-9]{3,24}$"
}

function Assert-ResourceProviderRegistered {
    param(
        [string]$SubscriptionId,
        [string]$ProviderNamespace,
        [int]$MaxAttempts = 24,
        [int]$PollSeconds = 5
    )

    $registered = Ensure-ResourceProviderRegistered `
        -SubscriptionId $SubscriptionId `
        -ProviderNamespace $ProviderNamespace `
        -MaxAttempts $MaxAttempts `
        -PollSeconds $PollSeconds
    if (-not $registered) {
        throw "$ProviderNamespace registration did not reach Registered state in subscription $SubscriptionId. Wait for Azure provider registration to finish, then rerun setup."
    }
}

function Get-StableHashSuffix {
    param(
        [string]$Value,
        [int]$Length
    )

    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $valueBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($hasher.ComputeHash($valueBytes))).Replace("-", "").ToLowerInvariant().Substring(0, $Length)
    } finally {
        $hasher.Dispose()
    }
}

function Get-BillingStorageAccountNameCandidates {
    param(
        [string]$TenantId,
        [string]$SubscriptionId
    )

    $normalizedTenantId = ($TenantId -replace "[^a-zA-Z0-9]", "").ToLowerInvariant()
    if ($normalizedTenantId.Length -lt 10) {
        $normalizedTenantId = Get-StableHashSuffix -Value $TenantId -Length 10
    }

    $tenantSuffix = $normalizedTenantId.Substring($normalizedTenantId.Length - 10)
    $candidates = @("$BILLING_EXPORT_STORAGE_NAME_PREFIX$tenantSuffix")
    for ($attempt = 1; $attempt -lt 20; $attempt++) {
        $collisionSuffix = Get-StableHashSuffix -Value "$TenantId|$SubscriptionId|$attempt" -Length 10
        $candidates += "$BILLING_EXPORT_STORAGE_NAME_PREFIX$collisionSuffix"
    }

    return @($candidates)
}

function Find-BillingExportStorageAccountByName {
    param(
        [string]$SubscriptionId,
        [string]$Name
    )

    Set-AzContext -SubscriptionId $SubscriptionId -TenantId $script:tenantId | Out-Null
    try {
        $resource = @(Get-AzResource `
            -ResourceType "Microsoft.Storage/storageAccounts" `
            -Name $Name `
            -ErrorAction Stop) | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    } catch {
        throw "Unable to determine whether storage account '$Name' exists in subscription '$SubscriptionId'. No replacement account will be selected from an incomplete lookup. $_"
    }
    if (-not $resource) {
        return $null
    }

    return [pscustomobject]@{
        ResourceId = $resource.ResourceId
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $resource.ResourceGroupName
        Name = $resource.Name
        Tags = $resource.Tags
    }
}

function Find-PreferredBillingExportStorageAccount {
    param(
        [object[]]$Subscriptions,
        [string]$TenantId
    )

    $eligibleSubscriptions = @($Subscriptions |
        Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) } |
        Sort-Object -Property Id -Unique)
    if ($eligibleSubscriptions.Count -eq 0) {
        return $null
    }

    $preferredName = @(Get-BillingStorageAccountNameCandidates `
        -TenantId $TenantId `
        -SubscriptionId $eligibleSubscriptions[0].Id)[0]
    $matches = @()
    foreach ($subscription in $eligibleSubscriptions) {
        $match = Find-BillingExportStorageAccountByName `
            -SubscriptionId $subscription.Id `
            -Name $preferredName
        if ($match) {
            $matches += $match
        }
    }

    if ($matches.Count -gt 1) {
        throw "Multiple selected subscriptions reported the globally unique storage account name '$preferredName'. Resolve the Azure inventory inconsistency before continuing."
    }

    return $matches | Select-Object -First 1
}

function Test-SpottoBillingStorageAccountOwnership {
    param([object]$StorageAccount)

    if (-not $StorageAccount -or -not $StorageAccount.Tags) {
        return $false
    }

    return $StorageAccount.Tags[$BILLING_EXPORT_STORAGE_PURPOSE_TAG] -eq $BILLING_EXPORT_STORAGE_PURPOSE_VALUE -and
        $StorageAccount.Tags[$BILLING_EXPORT_STORAGE_TENANT_TAG] -eq $script:tenantId
}

function Confirm-BillingStorageAccountReuse {
    param([object]$StorageAccount)

    if (Test-SpottoBillingStorageAccountOwnership -StorageAccount $StorageAccount) {
        return $true
    }

    Write-Warning-Custom "A storage account named '$($StorageAccount.Name)' already exists in the selected subscription, but it is not tagged as Spotto billing export storage for this tenant."
    Write-Info "The script will change billing export storage settings only if you explicitly approve reusing this account."
    if (Test-BillingStorageAccountHasConflictingOwnership -StorageAccount $StorageAccount) {
        Write-Info "Existing conflicting Spotto ownership tags will not be overwritten."
    } else {
        Write-Info "If approved, canonical Spotto billing-export ownership tags will be added for safer future reruns."
    }
    $reuseResponse = Read-Host "Reuse this existing storage account? (yes/no, default no)"
    return Test-YesResponse -Value $reuseResponse -DefaultYes $false
}

function Test-BillingStorageAccountHasConflictingOwnership {
    param([object]$StorageAccount)

    if (-not $StorageAccount -or -not $StorageAccount.Tags) {
        return $false
    }

    $purpose = [string]$StorageAccount.Tags[$BILLING_EXPORT_STORAGE_PURPOSE_TAG]
    $tenantId = [string]$StorageAccount.Tags[$BILLING_EXPORT_STORAGE_TENANT_TAG]
    return (-not [string]::IsNullOrWhiteSpace($purpose) -and $purpose -ne $BILLING_EXPORT_STORAGE_PURPOSE_VALUE) -or
        (-not [string]::IsNullOrWhiteSpace($tenantId) -and $tenantId -ne $script:tenantId)
}

function Add-SpottoBillingStorageAccountOwnershipTags {
    param([object]$StorageAccount)

    if (Test-BillingStorageAccountHasConflictingOwnership -StorageAccount $StorageAccount) {
        throw "Storage account '$($StorageAccount.Name)' has conflicting Spotto ownership tags and cannot be adopted automatically."
    }

    Update-AzTag `
        -ResourceId $StorageAccount.ResourceId `
        -Operation Merge `
        -Tag @{
            $BILLING_EXPORT_STORAGE_PURPOSE_TAG = $BILLING_EXPORT_STORAGE_PURPOSE_VALUE
            $BILLING_EXPORT_STORAGE_TENANT_TAG = $script:tenantId
            spotto = $BILLING_EXPORT_STORAGE_ALIAS_VALUE
        } `
        -ErrorAction Stop | Out-Null

    $updatedTags = @{}
    if ($StorageAccount.Tags -is [System.Collections.IDictionary]) {
        foreach ($key in $StorageAccount.Tags.Keys) {
            $updatedTags[$key] = $StorageAccount.Tags[$key]
        }
    }
    $updatedTags[$BILLING_EXPORT_STORAGE_PURPOSE_TAG] = $BILLING_EXPORT_STORAGE_PURPOSE_VALUE
    $updatedTags[$BILLING_EXPORT_STORAGE_TENANT_TAG] = $script:tenantId
    $updatedTags["spotto"] = $BILLING_EXPORT_STORAGE_ALIAS_VALUE
    $StorageAccount.Tags = $updatedTags
    Write-Success "Added Spotto billing-export ownership tags to $($StorageAccount.Name)"
}

function Confirm-AndPrepareBillingStorageAccountReuse {
    param([object]$StorageAccount)

    if (Test-SpottoBillingStorageAccountOwnership -StorageAccount $StorageAccount) {
        return $true
    }

    if (-not (Confirm-BillingStorageAccountReuse -StorageAccount $StorageAccount)) {
        return $false
    }

    if (-not (Test-BillingStorageAccountHasConflictingOwnership -StorageAccount $StorageAccount)) {
        try {
            Add-SpottoBillingStorageAccountOwnershipTags -StorageAccount $StorageAccount
        } catch {
            Write-Warning-Custom "The storage account was approved for this run, but Spotto ownership tags could not be added. A future rerun will ask again. $_"
        }
    }

    return $true
}

function Resolve-BillingExportStorageAccountName {
    param(
        [string]$SubscriptionId,
        [string]$TenantId,
        [string[]]$ExcludedNames = @()
    )

    foreach ($name in @(Get-BillingStorageAccountNameCandidates -TenantId $TenantId -SubscriptionId $SubscriptionId)) {
        if ($ExcludedNames -contains $name) {
            continue
        }

        $existingStorageAccount = Find-BillingExportStorageAccountByName -SubscriptionId $SubscriptionId -Name $name
        if ($existingStorageAccount) {
            return [pscustomobject]@{
                Name = $name
                ExistingStorageAccount = $existingStorageAccount
            }
        }

        if (Test-StorageAccountNameAvailable -SubscriptionId $SubscriptionId -Name $name) {
            return [pscustomobject]@{
                Name = $name
                ExistingStorageAccount = $null
            }
        }
    }

    throw "Unable to find an available deterministic billing export storage account name. Please rerun and provide one manually."
}

function Wait-StorageAccountReady {
    param(
        [string]$StorageAccountId,
        [int]$MaxAttempts = 60,
        [int]$PollSeconds = 10
    )

    $lastState = "unknown"
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $account = Get-StorageAccountResource -StorageAccountId $StorageAccountId
            if ($account) {
                $lastState = if ($account.ProvisioningState) { $account.ProvisioningState } else { $account.properties.provisioningState }
                if ($lastState -eq "Succeeded") {
                    return $account
                }

                if ($lastState -in @("Failed", "Canceled")) {
                    throw "Storage account provisioning ended with state '$lastState'."
                }

                if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
                    Write-Info "Waiting for storage account provisioning. Current state: $lastState"
                }
            }
        } catch {
            if ($_.Exception.Message -match "ended with state") {
                throw
            }

            if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
                Write-Info "Waiting for storage account to become visible in Azure Resource Manager. $_"
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $PollSeconds
        }
    }

    throw "Timed out waiting for storage account provisioning to complete. Last provisioning state: $lastState."
}

function Get-AzureProvisioningFailureCategory {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return "unknown" }
    if ($Message -match "(?i)LocationNotAvailableForResourceType|InvalidResourceLocation|InvalidLocation|SkuNotAvailable|RegionNotAvailable|not available in (?:the )?(?:requested )?(?:location|region)") { return "location-or-sku" }
    if ($Message -match "(?i)AuthorizationFailed|DenyAssignmentAuthorizationFailed|Forbidden|\b403\b") { return "authorization" }
    if ($Message -match "(?i)RequestDisallowedByPolicy|PolicyViolation|denied by policy") { return "policy" }
    if ($Message -match "(?i)QuotaExceeded|SubscriptionIsOverQuotaForSku|quota") { return "quota" }
    if ($Message -match "(?i)StorageAccountAlreadyTaken|AccountNameInvalid|InvalidResourceName|name.+(?:unavailable|already exists|invalid)") { return "name" }
    return "unknown"
}

function Test-ShouldRetryAzureProvisioningInAnotherLocation {
    param([string]$Message)

    return (Get-AzureProvisioningFailureCategory -Message $Message) -eq "location-or-sku"
}

function Select-BillingStorageSubscription {
    param(
        [object[]]$Subscriptions,
        [string]$Prompt = "Select subscription for the billing export storage account"
    )

    $eligibleSubscriptions = @($Subscriptions | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) })
    if ($eligibleSubscriptions.Count -eq 0) {
        throw "No eligible subscription is available for billing export storage."
    }

    Write-SectionLabel "Storage account subscription"
    for ($i = 0; $i -lt $eligibleSubscriptions.Count; $i++) {
        Write-Host ("  [{0,2}] {1} ({2})" -f ($i + 1), $eligibleSubscriptions[$i].Name, $eligibleSubscriptions[$i].Id)
    }

    if ($eligibleSubscriptions.Count -eq 1) {
        return $eligibleSubscriptions[0]
    }

    $selectedIndex = Read-IndexedSelection `
        -Prompt "$Prompt (1-$($eligibleSubscriptions.Count))" `
        -MaxValue $eligibleSubscriptions.Count
    return $eligibleSubscriptions[$selectedIndex]
}

function New-BillingExportStorageAccount {
    param(
        [object[]]$Subscriptions,
        [string[]]$ExcludedNames = @()
    )

    $hostSubscription = Select-BillingStorageSubscription -Subscriptions $Subscriptions

    Set-AzContext -SubscriptionId $hostSubscription.Id -TenantId $script:tenantId | Out-Null
    Assert-ResourceProviderRegistered -SubscriptionId $hostSubscription.Id -ProviderNamespace "Microsoft.Storage"
    Assert-ResourceProviderRegistered -SubscriptionId $hostSubscription.Id -ProviderNamespace "Microsoft.CostManagementExports" -MaxAttempts 60 -PollSeconds 5
    $availableLocations = Get-AvailableAzureLocationNames

    $excludedStorageNames = @($ExcludedNames)
    while ($true) {
        $storageNameResolution = Resolve-BillingExportStorageAccountName `
            -SubscriptionId $hostSubscription.Id `
            -TenantId $script:tenantId `
            -ExcludedNames $excludedStorageNames
        if (-not $storageNameResolution.ExistingStorageAccount) {
            break
        }

        if (Confirm-AndPrepareBillingStorageAccountReuse -StorageAccount $storageNameResolution.ExistingStorageAccount) {
            Write-Info "Using deterministic billing export storage account $($storageNameResolution.Name) from the selected subscription."
            return $storageNameResolution.ExistingStorageAccount
        }

        $excludedStorageNames += $storageNameResolution.Name
        Write-Info "Selecting the next deterministic storage account name."
    }

    $defaultResourceGroupName = "rg-spotto-cost-exports"
    $resourceGroupName = Get-DefaultedInput -Prompt "Resource group for the billing export storage account" -DefaultValue $defaultResourceGroupName
    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        $resourceGroupCreated = $false
        while (-not $resourceGroupCreated) {
            $location = Read-AzureLocationInput -Prompt "Azure region for the new resource group" -DefaultValue $BILLING_EXPORT_DEFAULT_LOCATION -AvailableLocations $availableLocations
            try {
                $resourceGroup = New-AzResourceGroup -Name $resourceGroupName -Location $location -ErrorAction Stop
                $resourceGroupCreated = $true
                Write-Success "Created resource group $resourceGroupName in $location"
            } catch {
                $failureMessage = $_.Exception.Message
                $failureCategory = Get-AzureProvisioningFailureCategory -Message $failureMessage
                Write-Error-Custom "Failed to create resource group '$resourceGroupName' in '$location' ($failureCategory): $failureMessage"
                if (-not (Test-ShouldRetryAzureProvisioningInAnotherLocation -Message $failureMessage)) {
                    throw "Billing export resource group creation stopped because Azure reported a $failureCategory failure. Correct that issue, then rerun setup."
                }
                $retryLocation = Read-Host "Try another region for the billing export resource group? (yes/no, default yes)"
                if (-not (Test-YesResponse -Value $retryLocation)) {
                    throw "Billing export storage setup could not create resource group '$resourceGroupName'."
                }
            }
        }
    } else {
        Write-Info "Using existing resource group $resourceGroupName"
    }

    $storageAccountNameReady = $false
    $suggestedName = $storageNameResolution.Name
    while (-not $storageAccountNameReady) {
        $storageAccountName = Get-DefaultedInput -Prompt "Storage account name" -DefaultValue $suggestedName
        $existingStorageAccount = Find-BillingExportStorageAccountByName -SubscriptionId $hostSubscription.Id -Name $storageAccountName

        if ($existingStorageAccount) {
            if (Confirm-AndPrepareBillingStorageAccountReuse -StorageAccount $existingStorageAccount) {
                Write-Info "Using existing storage account $storageAccountName in $($existingStorageAccount.ResourceGroupName)"
                return $existingStorageAccount
            }

            Write-Info "Choose another storage account name or use the suggested dedicated name."
        } elseif (-not (Test-BillingStorageAccountNameFormat -Name $storageAccountName)) {
            Write-Error-Custom "Storage account name '$storageAccountName' is invalid. Use 3-24 lowercase letters and numbers only."
        } elseif (Test-StorageAccountNameAvailable -SubscriptionId $hostSubscription.Id -Name $storageAccountName) {
            $storageAccountNameReady = $true
        } else {
            Write-Error-Custom "Storage account name '$storageAccountName' is not available."
        }
    }

    $storageAccountId = "/subscriptions/$($hostSubscription.Id)/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
    $storageAccountCreated = $false
    while (-not $storageAccountCreated) {
        $storageAccountLocation = Read-AzureLocationInput -Prompt "Azure region for the billing export storage account" -DefaultValue $BILLING_EXPORT_DEFAULT_LOCATION -AvailableLocations $availableLocations
        try {
            New-AzStorageAccount `
                -ResourceGroupName $resourceGroupName `
                -Name $storageAccountName `
                -Location $storageAccountLocation `
                -SkuName "Standard_LRS" `
                -Kind "StorageV2" `
                -AccessTier "Hot" `
                -MinimumTlsVersion "TLS1_2" `
                -AllowBlobPublicAccess $false `
                -EnableHttpsTrafficOnly $true `
                -PublicNetworkAccess "Enabled" `
                -NetworkRuleSet @{ bypass = "AzureServices"; defaultAction = "Allow" } `
                -Tag @{
                    SpottoPurpose = $BILLING_EXPORT_STORAGE_PURPOSE_VALUE
                    SpottoTenantId = $script:tenantId
                    spotto = $BILLING_EXPORT_STORAGE_ALIAS_VALUE
                } `
                -ErrorAction Stop | Out-Null

            $waitingForStorageAccount = $true
            while ($waitingForStorageAccount) {
                try {
                    Wait-StorageAccountReady -StorageAccountId $storageAccountId | Out-Null
                    $waitingForStorageAccount = $false
                } catch {
                    if ($_.Exception.Message -match "Timed out waiting for storage account provisioning") {
                        Write-Info "Azure accepted the storage account create request, but provisioning is taking longer than expected."
                        $keepWaiting = Read-Host "Keep waiting for storage account provisioning? (yes/no, default yes)"
                        if (Test-YesResponse -Value $keepWaiting) {
                            continue
                        }
                    }

                    throw
                }
            }
            $storageAccountCreated = $true
            Write-Success "Created storage account $storageAccountName in $storageAccountLocation"
        } catch {
            $failureMessage = $_.Exception.Message
            $failureCategory = Get-AzureProvisioningFailureCategory -Message $failureMessage
            Write-Error-Custom "Failed to create storage account '$storageAccountName' in '$storageAccountLocation' ($failureCategory): $failureMessage"
            if (-not (Test-ShouldRetryAzureProvisioningInAnotherLocation -Message $failureMessage)) {
                throw "Billing export storage account creation stopped because Azure reported a $failureCategory failure. Correct that issue, then rerun setup."
            }
            $retryLocation = Read-Host "Try another region for the billing export storage account? (yes/no, default yes)"
            if (-not (Test-YesResponse -Value $retryLocation)) {
                throw "Billing export storage setup could not create storage account '$storageAccountName'."
            }
        }
    }

    return [pscustomobject]@{
        ResourceId = $storageAccountId
        SubscriptionId = $hostSubscription.Id
        ResourceGroupName = $resourceGroupName
        Name = $storageAccountName
        IsNew = $true
    }
}

function Select-ExistingBillingStorageAccount {
    param([object[]]$Subscriptions)

    $selectedSubscription = Select-BillingStorageSubscription `
        -Subscriptions $Subscriptions `
        -Prompt "Select subscription containing the existing storage account"
    $storageAccounts = @()
    try {
        Set-AzContext -SubscriptionId $selectedSubscription.Id -TenantId $script:tenantId | Out-Null
        $resources = @(Get-AzResource -ResourceType "Microsoft.Storage/storageAccounts" -ErrorAction Stop)
        foreach ($resource in $resources) {
            $storageAccounts += [pscustomobject]@{
                ResourceId = $resource.ResourceId
                SubscriptionId = $selectedSubscription.Id
                ResourceGroupName = $resource.ResourceGroupName
                Name = $resource.Name
                SubscriptionName = $selectedSubscription.Name
            }
        }
    } catch {
        Write-Info "Unable to list storage accounts in $($selectedSubscription.Name): $_"
    }

    if ($storageAccounts.Count -eq 0) {
        Write-Info "No existing storage accounts were found in $($selectedSubscription.Name)."
        return $null
    }

    Write-Host ""
    Write-SectionLabel "Existing storage accounts"
    for ($i = 0; $i -lt $storageAccounts.Count; $i++) {
        $account = $storageAccounts[$i]
        Write-Host ("  [{0,2}] {1} ({2}, {3})" -f ($i + 1), $account.Name, $account.ResourceGroupName, $account.SubscriptionName)
    }

    while ($true) {
        $selection = Read-Host "Select storage account number, type a storage account name, or press Enter to create a new one"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return $null
        }

        $selection = $selection.Trim()
        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex)) {
            if ($selectedIndex -ge 1 -and $selectedIndex -le $storageAccounts.Count) {
                return $storageAccounts[$selectedIndex - 1]
            }

            Write-Error-Custom "Invalid storage account number '$selection'. Enter a number between 1 and $($storageAccounts.Count), or press Enter to create a new one."
            continue
        }

        $matches = @($storageAccounts | Where-Object { $_.Name -eq $selection })
        if ($matches.Count -eq 1) {
            return $matches[0]
        }

        if ($matches.Count -gt 1) {
            Write-Error-Custom "Multiple storage accounts named '$selection' were returned for the selected subscription. Select by number instead."
            continue
        }

        Write-Error-Custom "Storage account '$selection' was not found. Select an account from the list, or press Enter to create a new one."
    }
}

function Select-BillingExportStorageAccount {
    param(
        [object[]]$Subscriptions,
        [hashtable]$NetworkMutationApprovalCache = $null
    )

    if (-not $NetworkMutationApprovalCache) {
        $NetworkMutationApprovalCache = @{}
    }

    $excludedDedicatedNames = @()
    $preferredStorageAccount = Find-PreferredBillingExportStorageAccount `
        -Subscriptions $Subscriptions `
        -TenantId $script:tenantId
    if ($preferredStorageAccount) {
        if (Test-SpottoBillingStorageAccountOwnership -StorageAccount $preferredStorageAccount) {
            Write-Info "Reusing Spotto's dedicated billing export storage account $($preferredStorageAccount.Name) from subscription $($preferredStorageAccount.SubscriptionId)."
            return $preferredStorageAccount
        }

        Write-Warning-Custom "A deterministic billing export storage account from an earlier setup was found: $($preferredStorageAccount.Name)."
        if (Confirm-AndPrepareBillingStorageAccountReuse -StorageAccount $preferredStorageAccount) {
            Write-Info "Reusing the approved deterministic billing export storage account."
            return $preferredStorageAccount
        }

        $excludedDedicatedNames += $preferredStorageAccount.Name
    }

    Write-SectionLabel "Billing export storage"
    Write-OptionRow -Key "1" -Label "Create or reuse Spotto's dedicated storage account (recommended, default)" -Description "Use the deterministic tenant-specific export destination."
    Write-OptionRow -Key "2" -Label "Use an existing storage account" -Description "Restricted network settings require separate approval before they are broadened."

    while ($true) {
        $storageSelection = Read-Host "Select storage option (1/2, default 1)"
        if ([string]::IsNullOrWhiteSpace($storageSelection) -or $storageSelection.Trim() -eq "1") {
            return New-BillingExportStorageAccount -Subscriptions $Subscriptions -ExcludedNames $excludedDedicatedNames
        }

        if ($storageSelection.Trim() -eq "2") {
            break
        }

        Write-Error-Custom "Invalid selection '$storageSelection'. Enter 1 or 2."
    }

    $existing = Select-ExistingBillingStorageAccount -Subscriptions $Subscriptions
    if ($existing) {
        if (Confirm-ExistingBillingStorageMutation -StorageAccountId $existing.ResourceId -ApprovalCache $NetworkMutationApprovalCache) {
            return $existing
        }

        Write-Info "Existing storage network changes were not approved. Continuing with the recommended dedicated account."
        return New-BillingExportStorageAccount -Subscriptions $Subscriptions -ExcludedNames $excludedDedicatedNames
    }

    Write-Info "No existing storage account was selected. Continuing with the recommended dedicated account."
    return New-BillingExportStorageAccount -Subscriptions $Subscriptions -ExcludedNames $excludedDedicatedNames
}

function Confirm-ExistingBillingStorageNetworkChanges {
    param([object]$StorageAccount)

    $account = Get-StorageAccountResource -StorageAccountId $StorageAccount.ResourceId
    $requiresPublicEndpointChange = $account.PublicNetworkAccess -ne "Enabled" -or
        -not $account.NetworkRuleSet -or
        $account.NetworkRuleSet.DefaultAction -ne "Allow"
    if (-not $requiresPublicEndpointChange) {
        return $true
    }

    Write-Warning-Custom "This existing storage account currently restricts its public endpoint or firewall."
    Write-Info "Spotto cloud-engine requires the public blob endpoint to be enabled and the default network action set to Allow. Blob containers remain private and anonymous access remains disabled."
    $approval = Read-Host "Allow the script to broaden this existing account's network settings? (yes/no, default no)"
    return Test-YesResponse -Value $approval -DefaultYes $false
}

function Confirm-ExistingBillingStorageMutation {
    param(
        [string]$StorageAccountId,
        [hashtable]$ApprovalCache
    )

    if ([string]::IsNullOrWhiteSpace($StorageAccountId)) {
        return $false
    }

    $cacheKey = $StorageAccountId.Trim().ToLowerInvariant()
    if ($ApprovalCache.ContainsKey($cacheKey)) {
        return [bool]$ApprovalCache[$cacheKey]
    }

    $approved = Confirm-ExistingBillingStorageNetworkChanges `
        -StorageAccount ([pscustomobject]@{ ResourceId = $StorageAccountId })
    $ApprovalCache[$cacheKey] = $approved
    return $approved
}

function Ensure-BillingExportStorageSettings {
    param([string]$StorageAccountId)

    $account = Get-StorageAccountResource -StorageAccountId $StorageAccountId
    $storageParts = Get-StorageAccountParts -StorageAccountId $StorageAccountId
    $needsUpdate = $false

    if ($account.AllowBlobPublicAccess -ne $false) {
        $needsUpdate = $true
    }

    if ($account.EnableHttpsTrafficOnly -ne $true) {
        $needsUpdate = $true
    }

    if ($account.PublicNetworkAccess -ne "Enabled") {
        $needsUpdate = $true
    }

    if (-not $account.NetworkRuleSet -or $account.NetworkRuleSet.DefaultAction -ne "Allow") {
        $needsUpdate = $true
    }

    if ($account.MinimumTlsVersion -ne "TLS1_2") {
        $needsUpdate = $true
    }

    if ($needsUpdate) {
        Set-AzStorageAccount `
            -ResourceGroupName $storageParts.ResourceGroupName `
            -Name $storageParts.Name `
            -AllowBlobPublicAccess $false `
            -EnableHttpsTrafficOnly $true `
            -MinimumTlsVersion "TLS1_2" `
            -PublicNetworkAccess "Enabled" `
            -NetworkRuleSet @{ bypass = "AzureServices"; defaultAction = "Allow" } `
            -ErrorAction Stop | Out-Null
        Write-Success "Updated storage account settings for billing exports"
    } else {
        Write-Info "Storage account already meets billing export access settings"
    }
}

function Ensure-BillingExportContainer {
    param(
        [string]$StorageAccountId,
        [string]$ContainerName
    )

    $containerId = "$StorageAccountId/blobServices/default/containers/$ContainerName"
    $storageParts = Get-StorageAccountParts -StorageAccountId $StorageAccountId
    $account = Get-StorageAccountResource -StorageAccountId $StorageAccountId

    $existingContainer = Get-AzRmStorageContainer -ResourceGroupName $storageParts.ResourceGroupName -StorageAccountName $storageParts.Name -Name $ContainerName -ErrorAction SilentlyContinue
    if ($existingContainer) {
        Update-AzRmStorageContainer -StorageAccount $account -Name $ContainerName -PublicAccess None -ErrorAction Stop | Out-Null
    } else {
        New-AzRmStorageContainer -StorageAccount $account -Name $ContainerName -PublicAccess None -ErrorAction Stop | Out-Null
    }
    Write-Success "Ensured private blob container '$ContainerName'"
    return $containerId
}

function Ensure-StorageBlobDataReaderAssignment {
    param(
        [string]$PrincipalId,
        [string]$Scope
    )

    try {
        $existingAssignment = Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName "Storage Blob Data Reader" -Scope $Scope -ErrorAction SilentlyContinue
        if ($existingAssignment) {
            Write-Info "Storage Blob Data Reader already assigned on export container"
            return "existing"
        }

        New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName "Storage Blob Data Reader" -Scope $Scope | Out-Null
        Write-Success "Assigned Storage Blob Data Reader on export container"
        return "created"
    } catch {
        Write-Error-Custom "Failed to assign Storage Blob Data Reader on ${Scope}: $_"
        return "failed"
    }
}

function Get-AzRestStatusCodeFromError {
    param([object]$ErrorRecord)

    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [System.Exception]) {
        $ErrorRecord
    } else {
        $null
    }

    while ($exception) {
        if ($exception.Data -and $exception.Data.Contains("SpottoAzRestStatusCode")) {
            $statusCode = 0
            if ([int]::TryParse([string]$exception.Data["SpottoAzRestStatusCode"], [ref]$statusCode)) {
                return $statusCode
            }
        }

        if ($exception.PSObject.Properties.Name -contains "Response" -and $exception.Response) {
            $responseStatus = $exception.Response.StatusCode
            if ($responseStatus -and $responseStatus.PSObject.Properties.Name -contains "value__") {
                return [int]$responseStatus.value__
            }

            $statusCode = 0
            if ([int]::TryParse([string]$responseStatus, [ref]$statusCode)) {
                return $statusCode
            }
        }

        $exception = $exception.InnerException
    }

    return $null
}

function Invoke-AzRestGetJson {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ($Path -match "^https://management\.azure\.com(/.+)$") {
        $Path = $Matches[1]
    }

    $safePath = ($Path -split "\?", 2)[0]
    try {
        $response = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
    } catch {
        $statusCode = Get-AzRestStatusCodeFromError -ErrorRecord $_
        $safeMessage = if ($null -ne $statusCode) {
            "Azure REST GET failed with HTTP $statusCode at '$safePath'."
        } else {
            "Azure REST GET failed before a response was received at '$safePath'."
        }
        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList $safeMessage
        if ($null -ne $statusCode) {
            $exception.Data["SpottoAzRestStatusCode"] = $statusCode
        }
        throw $exception
    }

    $statusCode = 0
    $hasStatusCode = $false
    if ($response -and $response.StatusCode -is [System.Enum]) {
        $statusCode = [int]$response.StatusCode
        $hasStatusCode = $true
    } elseif ($response) {
        $hasStatusCode = [int]::TryParse([string]$response.StatusCode, [ref]$statusCode)
    }
    if ($hasStatusCode -and ($statusCode -lt 200 -or $statusCode -ge 300)) {
        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList "Azure REST GET failed with HTTP $statusCode at '$safePath'."
        $exception.Data["SpottoAzRestStatusCode"] = $statusCode
        throw $exception
    }

    if (-not $response -or [string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json -ErrorAction Stop
}

function Get-AzRestCollection {
    param(
        [string]$Path,
        [bool]$Quiet = $false,
        [bool]$ThrowOnError = $false
    )

    $items = @()
    $nextPath = $Path

    try {
        while (-not [string]::IsNullOrWhiteSpace($nextPath)) {
            $result = Invoke-AzRestGetJson -Path $nextPath
            if ($result -and $result.value) {
                $items += @($result.value)
            }

            $nextPath = if ($result -and $result.nextLink) { $result.nextLink } else { "" }
        }
    } catch {
        if ($ThrowOnError) {
            throw
        }

        if (-not $Quiet) {
            Write-Info "Unable to query Azure Resource Manager path '$Path'. $_"
        }
    }

    return @($items)
}

function New-PrerequisiteCheckResult {
    param(
        [string]$Name,
        [ValidateSet("ready", "action", "pim", "unconfirmed", "manual", "info")]
        [string]$Status,
        [string]$Scope = "",
        [string]$Detail = "",
        [string]$Category = "General",
        [bool]$Required = $true
    )

    return [pscustomobject]@{
        Name = $Name
        Status = $Status
        Scope = $Scope
        Detail = $Detail
        Category = $Category
        Required = $Required
    }
}

function Get-SafeAzureAssessmentFailure {
    param([object]$ErrorRecord)

    $message = if ($ErrorRecord -and $ErrorRecord.Exception) { [string]$ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    if ($message -match "AadPremiumLicenseRequired") {
        return "Azure could not return PIM eligibility because the tenant license does not include this capability."
    }
    if ($message -match "Forbidden|AuthorizationFailed|does not have authorization|status code.? 403|Response status code does not indicate success: 403") {
        return "Azure denied this read request."
    }
    if ($message -match "Unauthorized|status code.? 401|Response status code does not indicate success: 401") {
        return "The Azure session was not authorized for this read request."
    }
    if ($message -match "NotFound|status code.? 404|Response status code does not indicate success: 404") {
        return "Azure does not expose this check at the requested scope."
    }

    return "Azure did not return a usable result for this read request."
}

function Test-AzurePermissionSetGrantsAction {
    param(
        [object[]]$Permissions,
        [string]$RequiredAction
    )

    foreach ($permission in @($Permissions)) {
        $isAllowed = $false
        foreach ($action in @($permission.actions)) {
            if (Test-AzureActionMatchesPattern -RequiredAction $RequiredAction -ActionPattern $action) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            continue
        }

        foreach ($notAction in @($permission.notActions)) {
            if (Test-AzureActionMatchesPattern -RequiredAction $RequiredAction -ActionPattern $notAction) {
                $isAllowed = $false
                break
            }
        }

        if ($isAllowed) {
            return $true
        }
    }

    return $false
}

function Get-AzurePermissionActionAssessmentAtScope {
    param(
        [string]$Scope,
        [string]$RequiredAction
    )

    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($RequiredAction)) {
        return New-PrerequisiteCheckResult -Name "Azure permission" -Status "unconfirmed" -Scope $Scope -Detail "The scope or required action was missing."
    }

    $normalizedScope = $Scope.Trim().TrimEnd("/")
    $permissionsPath = if ([string]::IsNullOrWhiteSpace($normalizedScope)) {
        "/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    } else {
        "$normalizedScope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    }

    try {
        $permissionsResponse = Invoke-AzRestGetJson -Path $permissionsPath
        if (-not $permissionsResponse -or -not $permissionsResponse.PSObject.Properties["value"]) {
            return New-PrerequisiteCheckResult -Name "Azure permission" -Status "unconfirmed" -Scope $Scope -Detail "Azure returned no effective-permissions result."
        }

        if (Test-AzurePermissionSetGrantsAction -Permissions @($permissionsResponse.value) -RequiredAction $RequiredAction) {
            return New-PrerequisiteCheckResult -Name "Azure permission" -Status "ready" -Scope $Scope -Detail "Active effective permission confirmed."
        }

        return New-PrerequisiteCheckResult -Name "Azure permission" -Status "action" -Scope $Scope -Detail "No active effective permission grants $RequiredAction."
    } catch {
        return New-PrerequisiteCheckResult `
            -Name "Azure permission" `
            -Status "unconfirmed" `
            -Scope $Scope `
            -Detail (Get-SafeAzureAssessmentFailure -ErrorRecord $_)
    }
}

function Get-ExactScopeRoleAssignmentActionAssessment {
    param(
        [string]$Scope,
        [string]$PrincipalObjectId,
        [string]$RequiredAction
    )

    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($PrincipalObjectId) -or [string]::IsNullOrWhiteSpace($RequiredAction)) {
        return New-PrerequisiteCheckResult -Name "Azure role assignment" -Status "unconfirmed" -Scope $Scope -Detail "The signed-in principal or target scope could not be resolved."
    }

    $normalizedScope = if ($Scope.Trim() -eq "/") { "/" } else { $Scope.Trim().TrimEnd("/") }
    $scopePrefix = if ($normalizedScope -eq "/") { "" } else { $normalizedScope }
    $filter = [uri]::EscapeDataString("atScope() and assignedTo('$PrincipalObjectId')")
    $assignmentPath = "$scopePrefix/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$filter"
    $conditionalAssignmentFound = $false
    $unresolvedRoleDefinitionFound = $false

    try {
        $assignments = @(Get-AzRestCollection -Path $assignmentPath -Quiet $true -ThrowOnError $true)
        $roleDefinitions = @{}

        foreach ($assignment in $assignments) {
            if (-not $assignment.properties -or ([string]$assignment.properties.scope).TrimEnd("/") -ine $normalizedScope.TrimEnd("/")) {
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$assignment.properties.condition)) {
                $conditionalAssignmentFound = $true
                continue
            }

            $roleDefinitionId = [string]$assignment.properties.roleDefinitionId
            if ([string]::IsNullOrWhiteSpace($roleDefinitionId) -or $roleDefinitionId -notmatch "^/") {
                $unresolvedRoleDefinitionFound = $true
                continue
            }

            if (-not $roleDefinitions.ContainsKey($roleDefinitionId)) {
                try {
                    $roleDefinitions[$roleDefinitionId] = Invoke-AzRestGetJson -Path "${roleDefinitionId}?api-version=2022-04-01"
                } catch {
                    $roleDefinitions[$roleDefinitionId] = $null
                }
            }

            $roleDefinition = $roleDefinitions[$roleDefinitionId]
            if (-not $roleDefinition -or -not $roleDefinition.properties) {
                $unresolvedRoleDefinitionFound = $true
                continue
            }

            if (Test-AzurePermissionSetGrantsAction -Permissions @($roleDefinition.properties.permissions) -RequiredAction $RequiredAction) {
                $roleName = [string]$roleDefinition.properties.roleName
                $detail = if ([string]::IsNullOrWhiteSpace($roleName)) { "Active unrestricted role assignment confirmed." } else { "Active through $roleName." }
                return New-PrerequisiteCheckResult -Name "Azure role assignment" -Status "ready" -Scope $Scope -Detail $detail
            }
        }

        if ($conditionalAssignmentFound -or $unresolvedRoleDefinitionFound) {
            return New-PrerequisiteCheckResult `
                -Name "Azure role assignment" `
                -Status "unconfirmed" `
                -Scope $Scope `
                -Detail "A conditional or unresolved role assignment exists, so effective assignment authority cannot be confirmed safely."
        }

        return New-PrerequisiteCheckResult -Name "Azure role assignment" -Status "action" -Scope $Scope -Detail "No active unrestricted role grants $RequiredAction at this exact scope."
    } catch {
        return New-PrerequisiteCheckResult `
            -Name "Azure role assignment" `
            -Status "unconfirmed" `
            -Scope $Scope `
            -Detail (Get-SafeAzureAssessmentFailure -ErrorRecord $_)
    }
}

function Get-ProviderScopeRoleAssignmentAssessment {
    param(
        [string]$Scope,
        [string]$PrincipalObjectId,
        [string]$RequiredAction,
        [object]$TenantRootAssessment
    )

    if ($TenantRootAssessment -and $TenantRootAssessment.Status -eq "ready") {
        return New-PrerequisiteCheckResult -Name "Provider role assignment" -Status "ready" -Scope $Scope -Detail "Active authority is inherited from tenant root scope (/)."
    }

    $providerAssessment = Get-ExactScopeRoleAssignmentActionAssessment `
        -Scope $Scope `
        -PrincipalObjectId $PrincipalObjectId `
        -RequiredAction $RequiredAction

    if ($providerAssessment.Status -eq "ready") {
        return $providerAssessment
    }

    if ($providerAssessment.Status -eq "unconfirmed" -or ($TenantRootAssessment -and $TenantRootAssessment.Status -eq "unconfirmed")) {
        return New-PrerequisiteCheckResult -Name "Provider role assignment" -Status "unconfirmed" -Scope $Scope -Detail "Neither inherited tenant-root nor exact provider-scope authority could be fully confirmed."
    }

    return New-PrerequisiteCheckResult -Name "Provider role assignment" -Status "action" -Scope $Scope -Detail "No active tenant-root or exact provider-scope role can assign access here."
}

function ConvertTo-AzureDateTimeOrNull {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        return ([datetime]$Value).ToUniversalTime()
    } catch {
        return $null
    }
}

function Get-AzureResourcePimEligibility {
    param(
        [string]$RequiredAction = "Microsoft.Authorization/roleAssignments/write",
        [datetime]$ReferenceTime = (Get-Date)
    )

    $eligibilityPath = "/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=asTarget()"
    try {
        $scheduleInstances = @(Get-AzRestCollection -Path $eligibilityPath -Quiet $true -ThrowOnError $true)
    } catch {
        return [pscustomobject]@{
            QueryStatus = "unconfirmed"
            QueryMessage = Get-SafeAzureAssessmentFailure -ErrorRecord $_
            Items = @()
        }
    }

    $roleDefinitions = @{}
    $eligibilityItems = @()
    $referenceUtc = $ReferenceTime.ToUniversalTime()
    $inactiveStatuses = @("Denied", "Revoked", "Canceled", "Failed", "Invalid", "TimedOut", "AdminDenied")

    foreach ($scheduleInstance in $scheduleInstances) {
        if (-not $scheduleInstance.properties) {
            continue
        }

        $status = [string]$scheduleInstance.properties.status
        if ($status -in $inactiveStatuses) {
            continue
        }

        $startDateTime = ConvertTo-AzureDateTimeOrNull -Value $scheduleInstance.properties.startDateTime
        $endDateTime = ConvertTo-AzureDateTimeOrNull -Value $scheduleInstance.properties.endDateTime
        if ($endDateTime -and $endDateTime -le $referenceUtc) {
            continue
        }

        $roleDefinitionId = [string]$scheduleInstance.properties.roleDefinitionId
        $roleName = [string]$scheduleInstance.properties.expandedProperties.roleDefinition.displayName
        $roleDefinitionResolved = $false
        $grantsRequiredAction = $false

        if (-not [string]::IsNullOrWhiteSpace($roleDefinitionId) -and $roleDefinitionId -match "^/") {
            if (-not $roleDefinitions.ContainsKey($roleDefinitionId)) {
                try {
                    $roleDefinitions[$roleDefinitionId] = Invoke-AzRestGetJson -Path "${roleDefinitionId}?api-version=2022-04-01"
                } catch {
                    $roleDefinitions[$roleDefinitionId] = $null
                }
            }

            $roleDefinition = $roleDefinitions[$roleDefinitionId]
            if ($roleDefinition -and $roleDefinition.properties) {
                $roleDefinitionResolved = $true
                if ([string]::IsNullOrWhiteSpace($roleName)) {
                    $roleName = [string]$roleDefinition.properties.roleName
                }
                $grantsRequiredAction = Test-AzurePermissionSetGrantsAction `
                    -Permissions @($roleDefinition.properties.permissions) `
                    -RequiredAction $RequiredAction
            }
        }

        if ([string]::IsNullOrWhiteSpace($roleName)) {
            $roleName = if ([string]::IsNullOrWhiteSpace($roleDefinitionId)) { "Unknown Azure role" } else { $roleDefinitionId.Split("/")[-1] }
        }

        $condition = [string]$scheduleInstance.properties.condition
        $permissionStatus = if (-not $roleDefinitionResolved) {
            "unconfirmed"
        } elseif ($grantsRequiredAction -and -not [string]::IsNullOrWhiteSpace($condition)) {
            "conditional"
        } elseif ($grantsRequiredAction) {
            "action"
        } else {
            "not-relevant"
        }

        $currentlyActivatable = (-not $startDateTime -or $startDateTime -le $referenceUtc) -and (-not $endDateTime -or $endDateTime -gt $referenceUtc)
        $eligibilityItems += [pscustomobject]@{
            RoleName = $roleName
            Scope = [string]$scheduleInstance.properties.scope
            MemberType = [string]$scheduleInstance.properties.memberType
            StartDateTime = $startDateTime
            EndDateTime = $endDateTime
            CurrentlyActivatable = $currentlyActivatable
            PermissionStatus = $permissionStatus
            Condition = $condition
        }
    }

    return [pscustomobject]@{
        QueryStatus = "ready"
        QueryMessage = "Azure resource-role PIM eligibility query completed."
        Items = @($eligibilityItems)
    }
}

function Test-PimEligibilityCoversScope {
    param(
        [object]$Eligibility,
        [string]$TargetScope,
        [string]$TenantId
    )

    if (-not $Eligibility -or -not $Eligibility.CurrentlyActivatable -or $Eligibility.PermissionStatus -ne "action") {
        return $false
    }

    $eligibilityScope = ([string]$Eligibility.Scope).Trim().TrimEnd("/")
    $normalizedTargetScope = $TargetScope.Trim().TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($eligibilityScope)) {
        $eligibilityScope = "/"
    }
    if ([string]::IsNullOrWhiteSpace($normalizedTargetScope)) {
        $normalizedTargetScope = "/"
    }

    if ($eligibilityScope -eq "/" -or $eligibilityScope -ieq $normalizedTargetScope) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $tenantRootManagementGroupScope = "/providers/Microsoft.Management/managementGroups/$TenantId"
        if ($eligibilityScope -ieq $tenantRootManagementGroupScope -and (
            $normalizedTargetScope -match "^/subscriptions/" -or
            $normalizedTargetScope -match "^/providers/Microsoft\.Management/managementGroups/"
        )) {
            return $true
        }
    }

    return $false
}

function ConvertTo-PrerequisiteResultWithPim {
    param(
        [object]$ActiveAssessment,
        [object[]]$PimEligibilityItems,
        [string]$Name,
        [string]$Scope,
        [string]$TenantId,
        [string]$Category,
        [bool]$Required = $true
    )

    if ($ActiveAssessment.Status -ne "action") {
        return New-PrerequisiteCheckResult `
            -Name $Name `
            -Status $ActiveAssessment.Status `
            -Scope $Scope `
            -Detail $ActiveAssessment.Detail `
            -Category $Category `
            -Required $Required
    }

    $matchingPimRoles = @($PimEligibilityItems | Where-Object {
        Test-PimEligibilityCoversScope -Eligibility $_ -TargetScope $Scope -TenantId $TenantId
    })
    if ($matchingPimRoles.Count -gt 0) {
        $firstMatch = $matchingPimRoles[0]
        $extraCount = $matchingPimRoles.Count - 1
        $extraText = if ($extraCount -gt 0) { " and $extraCount other eligible role(s)" } else { "" }
        return New-PrerequisiteCheckResult `
            -Name $Name `
            -Status "pim" `
            -Scope $Scope `
            -Detail "Activate $($firstMatch.RoleName) at $($firstMatch.Scope)$extraText, reconnect, and rerun this check." `
            -Category $Category `
            -Required $Required
    }

    return New-PrerequisiteCheckResult `
        -Name $Name `
        -Status "action" `
        -Scope $Scope `
        -Detail $ActiveAssessment.Detail `
        -Category $Category `
        -Required $Required
}

function Get-ReservationReadAssessment {
    try {
        $reservationOrders = @(Get-AzRestCollection `
            -Path "/providers/Microsoft.Capacity/reservationOrders?api-version=2022-11-01" `
            -Quiet $true `
            -ThrowOnError $true)
        return New-PrerequisiteCheckResult `
            -Name "Operator reservation inventory" `
            -Status "ready" `
            -Scope "/providers/Microsoft.Capacity" `
            -Detail "Reservation inventory read succeeded; $($reservationOrders.Count) accessible order(s) returned." `
            -Category "ProviderRead" `
            -Required $false
    } catch {
        $safeFailure = Get-SafeAzureAssessmentFailure -ErrorRecord $_
        $status = if ($safeFailure -match "denied") { "info" } else { "unconfirmed" }
        $operatorVisibilityDetail = if ($status -eq "info") {
            "The signed-in operator cannot currently read reservation inventory."
        } else {
            $safeFailure
        }
        return New-PrerequisiteCheckResult `
            -Name "Operator reservation inventory" `
            -Status $status `
            -Scope "/providers/Microsoft.Capacity" `
            -Detail "$operatorVisibilityDetail This does not replace the separate check for authority to grant Spotto Reservations Reader." `
            -Category "ProviderRead" `
            -Required $false
    }
}

function Write-PrerequisiteCheckResultLine {
    param([object]$Result)

    $message = $Result.Name
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Scope)) {
        $message += " - $($Result.Scope)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Detail)) {
        $message += ": $($Result.Detail)"
    }

    switch ($Result.Status) {
        "ready" { Write-Success $message }
        "pim" { Write-Warning-Custom "PIM eligible: $message" }
        "action" { Write-Error-Custom "Action needed: $message" }
        "unconfirmed" { Write-Warning-Custom "Unconfirmed: $message" }
        "manual" { Write-Info "Manual check: $message" }
        default { Write-Info $message }
    }
}

function Write-PrerequisiteScopeCategory {
    param(
        [object[]]$Results,
        [string]$Category,
        [string]$ReadyLabel
    )

    $categoryResults = @($Results | Where-Object { $_.Category -eq $Category })
    if ($categoryResults.Count -eq 0) {
        return
    }

    $readyCount = @($categoryResults | Where-Object { $_.Status -eq "ready" }).Count
    if ($readyCount -gt 0) {
        Write-Success "${ReadyLabel}: $readyCount of $($categoryResults.Count) ready"
    }

    foreach ($result in @($categoryResults | Where-Object { $_.Status -ne "ready" })) {
        Write-PrerequisiteCheckResultLine -Result $result
    }
}

function Get-AzureOnboardingPrerequisiteActionChecks {
    param([ValidateSet("Subscription", "ManagementGroup")][string]$ScopeType)

    if ($ScopeType -eq "Subscription") {
        return @(
            [pscustomobject]@{ Name = "RBAC role assignment"; Action = "Microsoft.Authorization/roleAssignments/write"; Category = "SubscriptionRbac"; PimAware = $true },
            [pscustomobject]@{ Name = "Cost Management export write"; Action = "Microsoft.CostManagement/exports/write"; Category = "BillingExport"; PimAware = $false; RemediationRole = $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME },
            [pscustomobject]@{ Name = "Storage account write"; Action = "Microsoft.Storage/storageAccounts/write"; Category = "StorageAccount"; PimAware = $false },
            [pscustomobject]@{ Name = "Blob container write"; Action = "Microsoft.Storage/storageAccounts/blobServices/containers/write"; Category = "StorageContainer"; PimAware = $false }
        )
    }

    return @(
        [pscustomobject]@{ Name = "Broad-scope RBAC role assignment"; Action = "Microsoft.Authorization/roleAssignments/write"; Category = "BroadScopeRbac"; PimAware = $true },
        [pscustomobject]@{ Name = "Broad-scope Cost Management export write"; Action = "Microsoft.CostManagement/exports/write"; Category = "BroadScopeExport"; PimAware = $false; RemediationRole = $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME }
    )
}

function Get-AzureOnboardingPrerequisiteActionDetail {
    param(
        [object]$Assessment,
        [object]$ActionCheck
    )

    $detail = [string]$Assessment.Detail
    if (
        $Assessment.Status -eq "action" -and
        -not [string]::IsNullOrWhiteSpace([string]$ActionCheck.RemediationRole)
    ) {
        return "$detail Assign $($ActionCheck.RemediationRole) at this exact scope, or accept the optional self-remediation prompt below if it is offered."
    }

    return $detail
}

function Get-CostManagementContributorSelfRemediationTargets {
    param([object[]]$Results)

    $assignmentCategoryByExportCategory = @{
        BillingExport = "SubscriptionRbac"
        BroadScopeExport = "BroadScopeRbac"
    }
    $targetScopes = @{}
    $targets = @()

    foreach ($exportResult in @($Results | Where-Object {
        $_.Status -eq "action" -and $assignmentCategoryByExportCategory.ContainsKey([string]$_.Category)
    })) {
        $scope = ([string]$exportResult.Scope).Trim().TrimEnd("/")
        if ([string]::IsNullOrWhiteSpace($scope)) {
            continue
        }

        $assignmentCategory = $assignmentCategoryByExportCategory[[string]$exportResult.Category]
        $canAssignAtScope = @($Results | Where-Object {
            $_.Status -eq "ready" -and
            $_.Category -eq $assignmentCategory -and
            ([string]$_.Scope).Trim().TrimEnd("/") -ieq $scope
        }).Count -gt 0
        if (-not $canAssignAtScope) {
            continue
        }

        $scopeKey = $scope.ToLowerInvariant()
        if ($targetScopes.ContainsKey($scopeKey)) {
            continue
        }

        $targetScopes[$scopeKey] = $true
        $targets += [pscustomobject]@{
            Scope = $scope
            Name = [string]$exportResult.Name
            Category = [string]$exportResult.Category
        }
    }

    return @($targets)
}

function Invoke-CostManagementContributorSelfRemediation {
    param(
        [string]$PrincipalObjectId,
        [string]$AccountId,
        [object[]]$Targets,
        [string]$TenantId = ""
    )

    $targetRows = @($Targets)
    if ([string]::IsNullOrWhiteSpace($PrincipalObjectId) -or $targetRows.Count -eq 0) {
        return [pscustomobject]@{ Status = "not-offered"; Created = 0; Existing = 0; Failed = 0 }
    }

    Write-Host ""
    Write-SectionLabel "Optional Cost Management permission fix"
    Write-Warning-Custom "The signed-in principal can assign roles at the affected scope but cannot create Cost Management exports there."
    Write-Info "Proposed role: $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME"
    Write-Info "Principal: $AccountId ($PrincipalObjectId)"
    foreach ($target in $targetRows) {
        Write-Info "Scope: $($target.Scope)"
    }
    Write-Info "This grants cost-management configuration access at the listed scopes. It does not grant Owner or general resource-write access."

    $approval = Read-Host "Assign $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME to this principal at all listed scopes? (yes/no, default no)"
    if (-not (Test-YesResponse -Value $approval -DefaultYes $false)) {
        Write-Info "Cost Management permission assignment was not approved. No role assignment was changed."
        return [pscustomobject]@{ Status = "declined"; Created = 0; Existing = 0; Failed = 0 }
    }

    $createdCount = 0
    $existingCount = 0
    $failedCount = 0
    $originalContext = Get-AzContext -ErrorAction SilentlyContinue
    try {
        foreach ($target in $targetRows) {
            $scope = ([string]$target.Scope).Trim().TrimEnd("/")
            try {
                if ($scope -match "^/subscriptions/([^/]+)$") {
                    Set-AzContext -SubscriptionId $Matches[1] -TenantId $TenantId -ErrorAction Stop | Out-Null
                }

                $existingAssignment = @(Get-AzRoleAssignment `
                    -ObjectId $PrincipalObjectId `
                    -RoleDefinitionName $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME `
                    -Scope $scope `
                    -ErrorAction Stop | Where-Object {
                        ([string]$_.Scope).Trim().TrimEnd("/") -ieq $scope
                    })
                if ($existingAssignment.Count -gt 0) {
                    $existingCount++
                    Write-Info "$COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME already exists at $scope"
                    continue
                }

                New-AzRoleAssignment `
                    -ObjectId $PrincipalObjectId `
                    -RoleDefinitionName $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME `
                    -Scope $scope `
                    -ErrorAction Stop | Out-Null
                $createdCount++
                Write-Success "Assigned $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME at $scope"
            } catch {
                $failedCount++
                Write-Error-Custom "Could not assign $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME at ${scope}: $($_.Exception.Message)"
            }
        }
    } finally {
        if ($originalContext) {
            try {
                Set-AzContext -Context $originalContext -ErrorAction Stop | Out-Null
            } catch {
                Write-Info "The original local Azure context could not be restored after role assignment."
            }
        }
    }

    $status = if ($failedCount -eq 0) {
        "complete"
    } elseif (($createdCount + $existingCount) -gt 0) {
        "partial"
    } else {
        "failed"
    }
    return [pscustomobject]@{
        Status = $status
        Created = $createdCount
        Existing = $existingCount
        Failed = $failedCount
    }
}

function Invoke-SpottoAzurePrerequisiteCheck {
    param(
        [string]$TenantId,
        [object[]]$Subscriptions
    )

    Write-Header -Message "Azure Prerequisite Check" -Subtitle "Read-only assessment with an explicit optional Cost Management role fix"

    $results = @()
    $originalContext = Get-AzContext -ErrorAction SilentlyContinue
    $currentContext = $originalContext
    $accountId = if ($currentContext -and $currentContext.Account) { [string]$currentContext.Account.Id } else { "Unknown account" }
    Write-DetailRow -Label "Signed-in account" -Value $accountId
    Write-DetailRow -Label "Tenant ID" -Value $TenantId
    Write-DetailRow -Label "Subscriptions visible" -Value "$($Subscriptions.Count)"
    Write-Host ""

    $principalObjectId = Get-SignedInPrincipalObjectId
    $pimEligibility = Get-AzureResourcePimEligibility
    $pimItems = if ($pimEligibility.QueryStatus -eq "ready") { @($pimEligibility.Items) } else { @() }

    $rootAssessment = if ([string]::IsNullOrWhiteSpace($principalObjectId)) {
        New-PrerequisiteCheckResult -Name "Tenant-root role assignment" -Status "unconfirmed" -Scope "/" -Detail "The signed-in principal object ID could not be resolved."
    } else {
        Get-ExactScopeRoleAssignmentActionAssessment `
            -Scope "/" `
            -PrincipalObjectId $principalObjectId `
            -RequiredAction "Microsoft.Authorization/roleAssignments/write"
    }
    $rootResult = ConvertTo-PrerequisiteResultWithPim `
        -ActiveAssessment $rootAssessment `
        -PimEligibilityItems $pimItems `
        -Name "Tenant-root assignment fast path" `
        -Scope "/" `
        -TenantId $TenantId `
        -Category "General" `
        -Required $false
    if ($rootResult.Status -eq "action") {
        $rootResult.Status = "info"
        $rootResult.Detail = "Not active; Recommended setup can still use the subscription-by-subscription fallback."
    }
    $results += $rootResult

    foreach ($subscription in @($Subscriptions)) {
        $scope = "/subscriptions/$($subscription.Id)"
        $contextFailure = ""
        try {
            Set-AzContext -SubscriptionId $subscription.Id -TenantId $TenantId -ErrorAction Stop | Out-Null
        } catch {
            $contextFailure = Get-SafeAzureAssessmentFailure -ErrorRecord $_
        }

        foreach ($actionCheck in @(Get-AzureOnboardingPrerequisiteActionChecks -ScopeType "Subscription")) {
            $activeAssessment = if ($contextFailure) {
                New-PrerequisiteCheckResult -Name $actionCheck.Name -Status "unconfirmed" -Scope $scope -Detail $contextFailure
            } else {
                Get-AzurePermissionActionAssessmentAtScope -Scope $scope -RequiredAction $actionCheck.Action
            }

            if ($actionCheck.PimAware) {
                $results += ConvertTo-PrerequisiteResultWithPim `
                    -ActiveAssessment $activeAssessment `
                    -PimEligibilityItems $pimItems `
                    -Name "$($subscription.Name) - $($actionCheck.Name)" `
                    -Scope $scope `
                    -TenantId $TenantId `
                    -Category $actionCheck.Category
            } else {
                $results += New-PrerequisiteCheckResult `
                    -Name "$($subscription.Name) - $($actionCheck.Name)" `
                    -Status $activeAssessment.Status `
                    -Scope $scope `
                    -Detail (Get-AzureOnboardingPrerequisiteActionDetail -Assessment $activeAssessment -ActionCheck $actionCheck) `
                    -Category $actionCheck.Category
            }
        }
    }

    $visibleManagementGroups = @(Get-VisibleManagementGroupTargets -TenantId $TenantId)
    if ($visibleManagementGroups.Count -eq 0) {
        $managementGroupDiscoveryResultStatus = if ($script:managementGroupDiscoveryStatus -eq "ready") { "action" } else { "unconfirmed" }
        $managementGroupDiscoveryDetail = if ([string]::IsNullOrWhiteSpace($script:managementGroupDiscoveryMessage)) {
            "Management-group visibility could not be determined."
        } else {
            $script:managementGroupDiscoveryMessage
        }
        $results += New-PrerequisiteCheckResult `
            -Name "Management group discovery" `
            -Status $managementGroupDiscoveryResultStatus `
            -Detail $managementGroupDiscoveryDetail `
            -Category "ManagementGroup"
    } else {
        foreach ($managementGroup in $visibleManagementGroups) {
            $managementGroupScope = Get-ManagementGroupScope -ManagementGroup $managementGroup
            $managementGroupLabel = Get-ManagementGroupDisplayLabel -ManagementGroup $managementGroup -TenantId $TenantId
            foreach ($actionCheck in @(Get-AzureOnboardingPrerequisiteActionChecks -ScopeType "ManagementGroup")) {
                $activeAssessment = Get-AzurePermissionActionAssessmentAtScope `
                    -Scope $managementGroupScope `
                    -RequiredAction $actionCheck.Action
                if ($actionCheck.PimAware) {
                    $results += ConvertTo-PrerequisiteResultWithPim `
                        -ActiveAssessment $activeAssessment `
                        -PimEligibilityItems $pimItems `
                        -Name "$managementGroupLabel - $($actionCheck.Name)" `
                        -Scope $managementGroupScope `
                        -TenantId $TenantId `
                        -Category $actionCheck.Category
                } else {
                    $results += New-PrerequisiteCheckResult `
                        -Name "$managementGroupLabel - $($actionCheck.Name)" `
                        -Status $activeAssessment.Status `
                        -Scope $managementGroupScope `
                        -Detail (Get-AzureOnboardingPrerequisiteActionDetail -Assessment $activeAssessment -ActionCheck $actionCheck) `
                        -Category $actionCheck.Category
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($principalObjectId)) {
        foreach ($providerScope in @("/providers/Microsoft.Capacity", "/providers/Microsoft.BillingBenefits")) {
            $results += New-PrerequisiteCheckResult `
                -Name "Provider role assignment" `
                -Status "unconfirmed" `
                -Scope $providerScope `
                -Detail "The signed-in principal object ID could not be resolved." `
                -Category "Provider"
        }
    } else {
        $reservationProviderAssessment = Get-ProviderScopeRoleAssignmentAssessment `
            -Scope "/providers/Microsoft.Capacity" `
            -PrincipalObjectId $principalObjectId `
            -RequiredAction "Microsoft.Authorization/roleAssignments/write" `
            -TenantRootAssessment $rootAssessment
        $results += ConvertTo-PrerequisiteResultWithPim `
            -ActiveAssessment $reservationProviderAssessment `
            -PimEligibilityItems $pimItems `
            -Name "Grant Reservations Reader" `
            -Scope "/providers/Microsoft.Capacity" `
            -TenantId $TenantId `
            -Category "Provider"

        $savingsPlanProviderAssessment = Get-ProviderScopeRoleAssignmentAssessment `
            -Scope "/providers/Microsoft.BillingBenefits" `
            -PrincipalObjectId $principalObjectId `
            -RequiredAction "Microsoft.Authorization/roleAssignments/write" `
            -TenantRootAssessment $rootAssessment
        $results += ConvertTo-PrerequisiteResultWithPim `
            -ActiveAssessment $savingsPlanProviderAssessment `
            -PimEligibilityItems $pimItems `
            -Name "Grant Savings plan Reader" `
            -Scope "/providers/Microsoft.BillingBenefits" `
            -TenantId $TenantId `
            -Category "Provider"
    }

    $results += Get-ReservationReadAssessment
    $results += New-PrerequisiteCheckResult `
        -Name "Entra app registration and Microsoft Graph admin consent" `
        -Status "manual" `
        -Detail "Confirm an active app-management role and a role allowed to grant Graph application admin consent. This check does not request extra Graph access to inspect Entra roles or Entra PIM." `
        -Category "Manual" `
        -Required $false

    if ($originalContext) {
        try {
            Set-AzContext -Context $originalContext -ErrorAction Stop | Out-Null
        } catch {
            Write-Info "The original local Azure context could not be restored automatically."
        }
    }

    Write-SectionLabel "Assessment results"
    Write-PrerequisiteScopeCategory -Results $results -Category "SubscriptionRbac" -ReadyLabel "Subscription role-assignment authority"
    Write-PrerequisiteScopeCategory -Results $results -Category "BillingExport" -ReadyLabel "Subscription export-write authority"
    Write-PrerequisiteScopeCategory -Results $results -Category "StorageAccount" -ReadyLabel "Storage-account write authority"
    Write-PrerequisiteScopeCategory -Results $results -Category "StorageContainer" -ReadyLabel "Blob-container write authority"
    Write-PrerequisiteScopeCategory -Results $results -Category "BroadScopeRbac" -ReadyLabel "Broad-scope role-assignment authority"
    Write-PrerequisiteScopeCategory -Results $results -Category "BroadScopeExport" -ReadyLabel "Broad-scope export-write authority"
    $groupedCategories = @("SubscriptionRbac", "BillingExport", "StorageAccount", "StorageContainer", "BroadScopeRbac", "BroadScopeExport")
    foreach ($result in @($results | Where-Object { $_.Category -notin $groupedCategories })) {
        Write-PrerequisiteCheckResultLine -Result $result
    }

    Write-Host ""
    Write-SectionLabel "Azure resource PIM"
    if ($pimEligibility.QueryStatus -ne "ready") {
        Write-Warning-Custom "PIM eligibility unconfirmed: $($pimEligibility.QueryMessage)"
        Write-Info "This does not prove that PIM is disabled or that the signed-in account has no eligible roles."
    } elseif ($pimItems.Count -eq 0) {
        Write-Info "Azure returned no current or upcoming eligible resource roles for the signed-in account."
        Write-Info "This does not prove that PIM is disabled; it only describes this account's returned eligibility."
    } else {
        Write-Info "Azure returned $($pimItems.Count) current or upcoming eligible resource role(s). Eligible does not mean active."
        foreach ($pimItem in ($pimItems | Select-Object -First 10)) {
            $availability = if (-not $pimItem.CurrentlyActivatable) {
                "not active yet"
            } elseif ($pimItem.PermissionStatus -eq "action") {
                "can provide role-assignment authority after activation"
            } elseif ($pimItem.PermissionStatus -eq "conditional") {
                "conditional; authority is unconfirmed"
            } else {
                "does not provide the required role-assignment action"
            }
            $membership = if ([string]::IsNullOrWhiteSpace($pimItem.MemberType)) { "unknown membership" } else { "$($pimItem.MemberType.ToLowerInvariant()) membership" }
            Write-Info "$($pimItem.RoleName) at $($pimItem.Scope) - $availability; $membership"
        }
        if ($pimItems.Count -gt 10) {
            Write-Info "Showing 10 of $($pimItems.Count) eligible roles; the transcript contains the same concise assessment output."
        }
    }

    $requiredResults = @($results | Where-Object { $_.Required })
    $actionCount = @($requiredResults | Where-Object { $_.Status -eq "action" }).Count
    $pimCount = @($requiredResults | Where-Object { $_.Status -eq "pim" }).Count
    $unconfirmedCount = @($requiredResults | Where-Object { $_.Status -eq "unconfirmed" }).Count
    $readyCount = @($requiredResults | Where-Object { $_.Status -eq "ready" }).Count

    Write-Host ""
    Write-SectionLabel "Prerequisite summary"
    Write-DetailRow -Label "Ready" -Value "$readyCount"
    Write-DetailRow -Label "PIM activation needed" -Value "$pimCount"
    Write-DetailRow -Label "Action needed" -Value "$actionCount"
    Write-DetailRow -Label "Unconfirmed" -Value "$unconfirmedCount"

    $outcome = if ($actionCount -gt 0) {
        Write-Error-Custom "Azure RBAC prerequisites are not ready. Review the action-needed items; an eligible Cost Management permission fix may be offered below."
        "action"
    } elseif ($pimCount -gt 0) {
        Write-Warning-Custom "Eligible PIM access was found but is not active. Activate it, reconnect, and rerun this check."
        "pim"
    } elseif ($unconfirmedCount -gt 0) {
        Write-Warning-Custom "No confirmed Azure RBAC blocker was found, but some required checks could not be confirmed."
        "unconfirmed"
    } else {
        Write-Success "Active Azure RBAC prerequisites are ready for Recommended read-only setup."
        "ready"
    }

    $selfRemediationTargets = @(Get-CostManagementContributorSelfRemediationTargets -Results $requiredResults)
    $selfRemediation = [pscustomobject]@{ Status = "not-offered"; Created = 0; Existing = 0; Failed = 0 }
    if ($actionCount -gt 0 -and $selfRemediationTargets.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($principalObjectId)) {
        $selfRemediation = Invoke-CostManagementContributorSelfRemediation `
            -PrincipalObjectId $principalObjectId `
            -AccountId $accountId `
            -Targets $selfRemediationTargets `
            -TenantId $TenantId
        if ($selfRemediation.Status -eq "complete") {
            $outcome = "remediation-pending"
            Write-Warning-Custom "Cost Management role access was assigned or already exists. Azure RBAC propagation and the current token may still be stale. Reconnect and rerun this prerequisite check."
        } elseif ($selfRemediation.Status -eq "partial") {
            Write-Warning-Custom "Some Cost Management role assignments succeeded and some failed. Review the errors, reconnect, and rerun this prerequisite check."
        }
    }

    if ($selfRemediation.Created -gt 0) {
        Write-Info "Azure changes made with approval: $($selfRemediation.Created) $COST_MANAGEMENT_CONTRIBUTOR_ROLE_NAME assignment(s) created."
        Write-Info "No Azure applications, secrets, exports, storage, policies, or provider registrations were changed."
    } else {
        Write-Info "No Azure resources, applications, secrets, permissions, role assignments, exports, storage, or provider registrations were changed."
    }
    Write-Info "Local PowerShell modules may have been installed. The Azure assessment itself used read-only requests."

    return [pscustomobject]@{
        Outcome = $outcome
        Results = @($results)
        PimEligibility = $pimEligibility
        SelfRemediation = $selfRemediation
    }
}

function Test-BillingCostExportScope {
    param([string]$Scope)

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        return $false
    }

    $normalizedScope = $Scope.Trim().TrimEnd("/")
    return $normalizedScope -match "^/providers/Microsoft\.Billing/billingAccounts/[^/]+(/billingProfiles/[^/]+)?(/invoiceSections/[^/]+)?$" -or
        $normalizedScope -match "^/providers/Microsoft\.Billing/billingAccounts/[^/]+/(departments|enrollmentAccounts|customers|invoiceSections)/[^/]+$"
}

function Test-ManagementGroupCostExportScope {
    param([string]$Scope)

    return -not [string]::IsNullOrWhiteSpace($Scope) -and
        $Scope.Trim().TrimEnd("/") -match "^/providers/Microsoft\.Management/managementGroups/[^/]+$"
}

function Get-AzureBillingExportScopeType {
    param([string]$Scope)

    $normalizedScope = Normalize-CostExportScope -Scope $Scope
    switch -Regex ($normalizedScope) {
        "^/subscriptions/[^/]+/resourceGroups/[^/]+$" { return "resourceGroup" }
        "^/subscriptions/[^/]+$" { return "subscription" }
        "^/providers/Microsoft\.Management/managementGroups/[^/]+$" { return "managementGroup" }
        "/billingProfiles/[^/]+/invoiceSections/[^/]+$" { return "invoiceSection" }
        "/billingProfiles/[^/]+$" { return "billingProfile" }
        "/invoiceSections/[^/]+$" { return "invoiceSection" }
        "/departments/[^/]+$" { return "department" }
        "/enrollmentAccounts/[^/]+$" { return "enrollmentAccount" }
        "/customers/[^/]+$" { return "partnerCustomer" }
        "^/providers/Microsoft\.Billing/billingAccounts/[^/]+$" { return "billingAccount" }
        default { throw "Azure billing export scope is not supported by the onboarding contract: $Scope" }
    }
}

function Get-AzureBillingExportDatasetType {
    param([string]$DatasetType)

    switch ($DatasetType) {
        "ActualCost" { return "actual" }
        "Usage" { return "actual" }
        "AmortizedCost" { return "amortized" }
        default { throw "Azure billing export dataset type is not supported by the onboarding contract: $DatasetType" }
    }
}

function Test-SubscriptionCostExportScope {
    param([string]$Scope)

    return -not [string]::IsNullOrWhiteSpace($Scope) -and $Scope.Trim() -match "^/subscriptions/([^/]+)$"
}

function Get-SubscriptionIdFromCostExportScope {
    param([string]$Scope)

    if (-not [string]::IsNullOrWhiteSpace($Scope) -and $Scope.Trim() -match "^/subscriptions/([^/]+)$") {
        return $Matches[1]
    }

    return ""
}

function Normalize-CostExportScope {
    param([string]$Scope)

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        return ""
    }

    $normalizedScope = $Scope.Trim()
    if ($normalizedScope -match "^https://management\.azure\.com(/.+)$") {
        $normalizedScope = $Matches[1]
    }

    $normalizedScope = ($normalizedScope -split "\?")[0].TrimEnd("/")
    if ($normalizedScope -match "(.+)/providers/Microsoft\.CostManagement/exports(/.*)?$") {
        $normalizedScope = $Matches[1]
    }

    return $normalizedScope
}

function Get-CostExportScopeLabel {
    param([string]$Scope)

    $subscriptionId = Get-SubscriptionIdFromCostExportScope -Scope $Scope
    if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
        $subscription = $selectedSubscriptions | Where-Object { $_.Id -eq $subscriptionId } | Select-Object -First 1
        if ($subscription) {
            return $subscription.Name
        }

        return $subscriptionId
    }

    if (Test-BillingCostExportScope -Scope $Scope) {
        if ($Scope -match "/billingProfiles/([^/]+)/invoiceSections/([^/]+)$") {
            return "Invoice section $($Matches[2])"
        }

        if ($Scope -match "/billingProfiles/([^/]+)$") {
            return "Billing profile $($Matches[1])"
        }

        if ($Scope -match "/departments/([^/]+)$") {
            return "EA department $($Matches[1])"
        }

        if ($Scope -match "/enrollmentAccounts/([^/]+)$") {
            return "EA enrollment account $($Matches[1])"
        }

        if ($Scope -match "/customers/([^/]+)$") {
            return "Billing customer $($Matches[1])"
        }

        if ($Scope -match "/invoiceSections/([^/]+)$") {
            return "Invoice section $($Matches[1])"
        }

        if ($Scope -match "/billingAccounts/([^/]+)$") {
            return "Billing account $($Matches[1])"
        }
    }

    return $Scope
}

function Get-BillingResourceDisplayName {
    param([object]$Resource)

    if (-not $Resource) {
        return ""
    }

    if ($Resource.properties -and $Resource.properties.displayName) {
        return $Resource.properties.displayName
    }

    if ($Resource.name) {
        return $Resource.name
    }

    return $Resource.id
}

function Add-UniqueBillingScope {
    param(
        [hashtable]$SeenScopes,
        [object[]]$Scopes,
        [string]$Scope,
        [string]$Label,
        [string]$Type
    )

    $normalizedScope = Normalize-CostExportScope -Scope $Scope
    if (-not (Test-BillingCostExportScope -Scope $normalizedScope)) {
        return $Scopes
    }

    $key = $normalizedScope.ToLowerInvariant()
    if ($SeenScopes.ContainsKey($key)) {
        return $Scopes
    }

    $SeenScopes[$key] = $true
    return @($Scopes + [pscustomobject]@{
        Scope = $normalizedScope
        Label = $Label
        Type = $Type
    })
}

function Get-AccessibleBillingCostScopes {
    $scopes = @()
    $seenScopes = @{}

    Write-Info "Checking accessible billing scopes for existing billing-level exports..."
    $billingAccounts = @(Get-AzRestCollection -Path "/providers/Microsoft.Billing/billingAccounts?api-version=$BILLING_API_VERSION")

    foreach ($billingAccount in $billingAccounts) {
        $accountId = Normalize-CostExportScope -Scope $billingAccount.id
        $accountLabel = Get-BillingResourceDisplayName -Resource $billingAccount
        $scopes = Add-UniqueBillingScope -SeenScopes $seenScopes -Scopes $scopes -Scope $accountId -Label $accountLabel -Type "Billing account"

        foreach ($childType in @("departments", "enrollmentAccounts", "customers")) {
            $children = @(Get-AzRestCollection -Path "$accountId/$childType?api-version=$BILLING_API_VERSION" -Quiet $true)
            foreach ($child in $children) {
                $label = Get-BillingResourceDisplayName -Resource $child
                $scopes = Add-UniqueBillingScope -SeenScopes $seenScopes -Scopes $scopes -Scope $child.id -Label $label -Type $childType
            }
        }

        $billingProfiles = @(Get-AzRestCollection -Path "$accountId/billingProfiles?api-version=$BILLING_API_VERSION" -Quiet $true)
        foreach ($billingProfile in $billingProfiles) {
            $profileId = Normalize-CostExportScope -Scope $billingProfile.id
            $profileLabel = Get-BillingResourceDisplayName -Resource $billingProfile
            $scopes = Add-UniqueBillingScope -SeenScopes $seenScopes -Scopes $scopes -Scope $profileId -Label $profileLabel -Type "Billing profile"

            $invoiceSections = @(Get-AzRestCollection -Path "$profileId/invoiceSections?api-version=$BILLING_API_VERSION" -Quiet $true)
            foreach ($invoiceSection in $invoiceSections) {
                $sectionLabel = Get-BillingResourceDisplayName -Resource $invoiceSection
                $scopes = Add-UniqueBillingScope -SeenScopes $seenScopes -Scopes $scopes -Scope $invoiceSection.id -Label $sectionLabel -Type "Invoice section"
            }
        }
    }

    return @($scopes)
}

function Write-BillingCostScopeDiscoverySummary {
    param([object[]]$Scopes)

    Write-Host ""
    Write-SectionLabel "Billing scope discovery"
    Write-DetailRow -Label "Discovered" -Value "$($Scopes.Count) accessible billing scope(s)"

    $scopeTypeSummary = @(
        $Scopes |
            Group-Object -Property Type |
            Sort-Object -Property Name |
            ForEach-Object { "$($_.Count) $($_.Name)" }
    ) -join ", "
    Write-DetailRow -Label "Breakdown" -Value $scopeTypeSummary
    Write-Info "Scanning these scopes only reads export definitions. Nothing is changed unless you later accept a compatible export."
}

function Write-BillingCostScopeSelectionList {
    param([object[]]$Scopes)

    Write-Host ""
    Write-SectionLabel "Accessible billing scopes"
    for ($i = 0; $i -lt $Scopes.Count; $i++) {
        $scope = $Scopes[$i]
        $scopeIdentifier = ($scope.Scope.TrimEnd("/") -split "/")[-1]
        if ($scopeIdentifier.Length -gt 36) {
            $scopeIdentifier = "{0}...{1}" -f $scopeIdentifier.Substring(0, 16), $scopeIdentifier.Substring($scopeIdentifier.Length - 16)
        }

        Write-Host ("  [{0,2}] {1}: {2} [{3}]" -f ($i + 1), $scope.Type, $scope.Label, $scopeIdentifier)
    }
}

function ConvertFrom-BillingCostScopeSelection {
    param(
        [object[]]$AccessibleScopes,
        [string]$Selection
    )

    $selectedScopes = @()
    foreach ($entry in ($Selection -split ",")) {
        $trimmedEntry = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedEntry)) {
            continue
        }

        $resolvedToken = Resolve-IndexedSelectionToken -Token $trimmedEntry -MaxValue $AccessibleScopes.Count
        if ($resolvedToken.IsIndexToken) {
            if (-not $resolvedToken.IsValid) {
                Write-Warning-Custom "Ignoring selection '$trimmedEntry' because it is outside 1-$($AccessibleScopes.Count)."
                continue
            }

            foreach ($selectedIndex in @($resolvedToken.Indexes)) {
                $selectedScopes += $AccessibleScopes[$selectedIndex - 1]
            }
            continue
        }

        $scope = Normalize-CostExportScope -Scope $trimmedEntry
        if (Test-BillingCostExportScope -Scope $scope) {
            $selectedScopes += [pscustomobject]@{
                Scope = $scope
                Label = Get-CostExportScopeLabel -Scope $scope
                Type = "Billing scope"
            }
            continue
        }

        Write-Warning-Custom "Ignoring invalid billing scope '$trimmedEntry'."
    }

    return @($selectedScopes | Where-Object { $_ } | Sort-Object -Property Scope -Unique)
}

function Select-BillingCostExportScopes {
    if ($script:useRecommendedReadOnlySetup) {
        $script:billingScopeExportStatus = "skipped"
        Write-Info "Recommended read-only access: skipping billing-account scope discovery; selected-subscription and separately approved management-group exports remain enabled."
        return @()
    }

    $checkBillingScopes = Read-Host "Check for existing billing-scope exports that may cover multiple subscriptions? (yes/no, default yes)"
    if (-not (Test-YesResponse -Value $checkBillingScopes)) {
        $script:billingScopeExportStatus = "skipped"
        return @()
    }

    $accessibleScopes = @(Get-AccessibleBillingCostScopes)
    $selectedScopes = @()

    if ($accessibleScopes.Count -gt 0) {
        Write-BillingCostScopeDiscoverySummary -Scopes $accessibleScopes
        Write-Host ""

        $selection = Read-Host "Press Enter to scan all $($accessibleScopes.Count) scopes, type 'list' to choose, paste scope IDs, or type 'skip'"
        $normalizedSelection = if ($null -eq $selection) { "" } else { $selection.Trim() }

        if ($normalizedSelection -ieq "list" -or $normalizedSelection -ieq "l") {
            Write-BillingCostScopeSelectionList -Scopes $accessibleScopes
            Write-Host ""
            $selection = Read-Host "Enter scope numbers or ranges (for example 1,3,5-9), or paste scope IDs; press Enter to scan all"
            $normalizedSelection = if ($null -eq $selection) { "" } else { $selection.Trim() }
        }

        if ([string]::IsNullOrWhiteSpace($normalizedSelection) -or $normalizedSelection -ieq "all" -or $normalizedSelection -ieq "a") {
            $selectedScopes = @($accessibleScopes)
            Write-Info "Scanning all $($accessibleScopes.Count) discovered billing scopes for compatible exports."
        } elseif ($normalizedSelection -ieq "skip" -or $normalizedSelection -ieq "s") {
            $script:billingScopeExportStatus = "skipped"
            return @()
        } else {
            $selectedScopes = @(ConvertFrom-BillingCostScopeSelection -AccessibleScopes $accessibleScopes -Selection $selection)
        }
    } else {
        Write-Info "No billing scopes were automatically discovered for this signed-in user."
        Write-Info "If you already know the billing scope, paste it in the format /providers/Microsoft.Billing/billingAccounts/..."
        $selection = Read-Host "Paste billing scope IDs to check, comma-separated, or press Enter to skip"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $script:billingScopeExportStatus = "skipped"
            return @()
        }

        $selectedScopes = @(ConvertFrom-BillingCostScopeSelection -AccessibleScopes $accessibleScopes -Selection $selection)
    }

    if ($selectedScopes.Count -gt 0) {
        $script:billingScopeExportStatus = "processed"
    } else {
        $script:billingScopeExportStatus = "skipped"
    }

    return $selectedScopes
}

function Write-BillingScopeReaderGuidance {
    param(
        [string]$PrincipalId,
        [string]$Scope
    )

    Write-Warning-Custom "Billing-scope export detected. Spotto also needs read access at this billing scope to discover the export later."
    Write-DetailRow -Label "Billing scope" -Value $Scope
    Write-DetailRow -Label "Service principal object" -Value $PrincipalId
    Write-Info "Cost Management Reader is the read-only role for Azure RBAC cost scopes, but EA/MCA billing hierarchy scopes use billing reader roles."
    Write-Info "For Microsoft Customer Agreement scopes, assign the matching Billing account/profile/invoice section reader role to the Spotto enterprise application at this billing scope."
    Write-Info "For Enterprise Agreement scopes, assign the equivalent EA read role to the Spotto service principal with the Azure Billing role assignment API."
}

function Get-CostExportsForScopeResult {
    param([string]$Scope)

    $normalizedScope = Normalize-CostExportScope -Scope $Scope

    try {
        $subscriptionId = Get-SubscriptionIdFromCostExportScope -Scope $normalizedScope
        if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
            Set-AzContext -SubscriptionId $subscriptionId -TenantId $script:tenantId | Out-Null
        }

        if (-not ((Test-SubscriptionCostExportScope -Scope $normalizedScope) -or (Test-BillingCostExportScope -Scope $normalizedScope) -or (Test-ManagementGroupCostExportScope -Scope $normalizedScope))) {
            throw "Cost export scope is not supported: $Scope"
        }

        $exports = @(Invoke-WithCostManagementThrottleRetry -OperationLabel "export discovery at '$normalizedScope'" -Operation {
            Get-AzRestCollection `
                -Path "$normalizedScope/providers/Microsoft.CostManagement/exports?api-version=$COST_EXPORT_API_VERSION" `
                -ThrowOnError $true
        })

        return [pscustomobject]@{
            Succeeded = $true
            Exports = @($exports)
            ErrorMessage = ""
        }
    } catch {
        return [pscustomobject]@{
            Succeeded = $false
            Exports = @()
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-CostExport {
    param(
        [string]$Scope,
        [string]$ExportName
    )

    $normalizedScope = Normalize-CostExportScope -Scope $Scope

    try {
        $subscriptionId = Get-SubscriptionIdFromCostExportScope -Scope $normalizedScope
        if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
            Set-AzContext -SubscriptionId $subscriptionId -TenantId $script:tenantId | Out-Null
        }

        return Invoke-WithCostManagementThrottleRetry -OperationLabel "export definition '$ExportName' lookup" -Operation {
            Invoke-AzRestGetJson -Path "$(Get-CostExportResourceId -Scope $normalizedScope -ExportName $ExportName)?api-version=$COST_EXPORT_API_VERSION"
        }
    } catch {
        if ((Get-AzRestStatusCodeFromError -ErrorRecord $_) -eq 404) {
            return $null
        }

        throw
    }
}

function Get-CostExportResourceId {
    param(
        [string]$Scope,
        [string]$ExportName
    )

    return "$(Normalize-CostExportScope -Scope $Scope)/providers/Microsoft.CostManagement/exports/$ExportName"
}

function Get-CostExportProperties {
    param([object]$Export)

    if (-not $Export) {
        return $null
    }

    $properties = $Export.Properties
    if (-not $properties) {
        $properties = $Export.properties
    }

    if ($properties -is [string]) {
        try {
            return $properties | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Info "Unable to parse Cost Management export properties for '$($Export.Name)'. $_"
            return $null
        }
    }

    return $properties
}

function Test-CostExportIsRecurringCandidate {
    param([object]$Export)

    $properties = Get-CostExportProperties -Export $Export
    if (-not $properties) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$properties.schedule.recurrence)) {
        return $true
    }

    return [string]$Export.Name -in @(
        "spotto-actual-daily",
        "spotto-amortized-daily",
        "spotto-usage-daily"
    )
}

function Get-RecurringCostExportAssessment {
    param(
        [object]$Export,
        [string[]]$DatasetTypes,
        [bool]$AllowUsageFallback = $false
    )

    $exportName = if ($Export -and -not [string]::IsNullOrWhiteSpace([string]$Export.Name)) { [string]$Export.Name } else { "<unnamed>" }
    $properties = Get-CostExportProperties -Export $Export
    $reasons = @()
    if (-not $properties) {
        $reasons += "Export properties are missing or could not be parsed."
        return [pscustomobject]@{
            Export = $Export
            ExportName = $exportName
            Classification = "incompatible"
            RequestedDatasetType = ""
            EffectiveDatasetType = ""
            Reasons = $reasons
        }
    }

    $destination = $properties.deliveryInfo.destination
    $effectiveDatasetType = [string]$properties.definition.type
    $requestedDatasetType = ""
    $classification = "incompatible"

    if ($properties.schedule.status -ne "Active") {
        $reasons += "Schedule status must be Active; found '$($properties.schedule.status)'."
    }
    if ($properties.schedule.recurrence -ne "Daily") {
        $reasons += "Schedule recurrence must be Daily; found '$($properties.schedule.recurrence)'."
    }

    $exactDatasetMatch = @($DatasetTypes | Where-Object {
        Test-CostExportDefinitionTypeMatches `
            -RequestedDatasetType $_ `
            -ExportDefinitionType $effectiveDatasetType
    } | Select-Object -First 1)
    if ($exactDatasetMatch.Count -gt 0) {
        $requestedDatasetType = [string]$exactDatasetMatch[0]
        $classification = "compatible"
    } elseif ($AllowUsageFallback -and $effectiveDatasetType -eq "Usage" -and $DatasetTypes -contains "ActualCost") {
        $requestedDatasetType = "ActualCost"
        $classification = "usable-fallback"
    } else {
        $requestedTypesLabel = @($DatasetTypes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ", "
        $reasons += "Definition type '$effectiveDatasetType' does not match the requested dataset(s): $requestedTypesLabel."
    }

    if ($properties.definition.timeframe -notin @("MonthToDate", "BillingMonthToDate", "TheCurrentMonth")) {
        $reasons += "Timeframe must be month-to-date; found '$($properties.definition.timeframe)'."
    }
    if ($properties.format -ne "Csv") {
        $reasons += "Format must be Csv; found '$($properties.format)'."
    }
    $compression = [string]$properties.compressionMode
    if (-not [string]::IsNullOrWhiteSpace($compression) -and $compression -notin @("none", "gzip")) {
        $reasons += "Compression must be None or Gzip; found '$compression'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$destination.resourceId)) {
        $reasons += "Destination storage account resource ID is missing."
    }
    if ([string]::IsNullOrWhiteSpace([string]$destination.container)) {
        $reasons += "Destination container is missing."
    }
    if ([string]::IsNullOrWhiteSpace([string]$destination.rootFolderPath)) {
        $reasons += "Destination root folder path is missing."
    }

    if ($reasons.Count -gt 0) {
        $classification = "incompatible"
    }

    return [pscustomobject]@{
        Export = $Export
        ExportName = $exportName
        Classification = $classification
        RequestedDatasetType = $requestedDatasetType
        EffectiveDatasetType = $effectiveDatasetType
        Reasons = @($reasons)
    }
}

function Test-RecurringCostExportMeetsRequirements {
    param(
        [object]$Export,
        [string]$DatasetType
    )

    $assessment = Get-RecurringCostExportAssessment `
        -Export $Export `
        -DatasetTypes @($DatasetType)
    return $assessment.Classification -eq "compatible"
}

function Test-CostExportDefinitionTypeMatches {
    param(
        [string]$RequestedDatasetType,
        [string]$ExportDefinitionType
    )

    return $ExportDefinitionType -eq $RequestedDatasetType
}

function Get-CostExportDefinitionTypeCandidates {
    param([string]$DatasetType)

    if ($DatasetType -eq "ActualCost") {
        return @("ActualCost", "Usage")
    }

    return @($DatasetType)
}

function Test-ShouldRetryActualCostAsUsage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return $Message -match "(?i)ActualCost" -and
        $Message -match "(?i)not\s+supported|unsupported" -and
        $Message -notmatch "(?i)AuthorizationFailed|Forbidden|RequestDisallowedByPolicy|QuotaExceeded"
}

function Test-CostExportTypeNotSupported {
    param(
        [string]$Message,
        [string]$DatasetType
    )

    return $Message -match [regex]::Escape($DatasetType) -and $Message -match "not supported"
}

function Test-CostManagementUnavailableMessage {
    param(
        [string]$Message,
        [string]$DatasetType = ""
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($DatasetType) -and (Test-CostExportTypeNotSupported -Message $Message -DatasetType $DatasetType)) {
        return $true
    }

    return $Message -match "SubscriptionTypeNotSupported|UnsupportedSubscriptionType|DisallowedOperation|AccountCostDisabled|DepartmentCostDisabled|IndirectCostDisabled|Cost Management is not supported|not supported for this account type|not supported for this subscription|not supported for this offer|does not have any charges|doesn't have any charges"
}

function Test-CostManagementExportsRegistrationMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return $Message -match "Microsoft\.CostManagementExports|CostManagementExports|ServiceUnavailable|503" -and $Message -match "register|registration|registered|503|ServiceUnavailable"
}

function Get-CostManagementUnavailableMessage {
    param(
        [string]$SubscriptionName,
        [string]$DatasetType,
        [string]$Operation
    )

    if ([string]::IsNullOrWhiteSpace($DatasetType) -or $DatasetType -eq "All") {
        return "Cost Management exports are not available for $SubscriptionName on this Azure agreement, subscription offer, or billing scope. Skipping billing export setup for this subscription."
    }

    return "$DatasetType $Operation exports are not available for $SubscriptionName on this Azure agreement, subscription offer, or billing scope. Continuing with any other available billing export datasets."
}

function Test-CostExportScopeAvailable {
    param([object]$Subscription)

    $scope = "/subscriptions/$($Subscription.Id)"

    try {
        Set-AzContext -SubscriptionId $Subscription.Id -TenantId $script:tenantId | Out-Null
        Get-AzResource -ResourceType "Microsoft.CostManagement/exports" -ApiVersion $COST_EXPORT_API_VERSION -ExpandProperties -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $message = $_.Exception.Message
        if (Test-CostManagementUnavailableMessage -Message $message) {
            $friendlyMessage = Get-CostManagementUnavailableMessage -SubscriptionName $Subscription.Name -DatasetType "All" -Operation "billing"
            Write-Warning-Custom $friendlyMessage
            Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType "All" -ExportKind "Preflight" -ExportName "" -Status "unavailable" -StorageAccountId "" -ContainerName "" -RootFolderPath "" -Message $friendlyMessage
            return $false
        }

        Write-Info "Unable to confirm Cost Management export availability at $scope. The script will still try to configure exports. $message"
        return $true
    }
}

function Get-SpottoRecurringExportName {
    param([string]$DatasetType)

    if ($DatasetType -eq "ActualCost") {
        return "spotto-actual-daily"
    }

    if ($DatasetType -eq "AmortizedCost") {
        return "spotto-amortized-daily"
    }

    throw "Unsupported dataset type for Spotto recurring export: $DatasetType"
}

function Find-ExistingRecurringBillingExportsAtScope {
    param(
        [string]$Scope,
        [string]$DatasetType,
        [object[]]$Exports
    )

    $scope = Normalize-CostExportScope -Scope $Scope
    if (-not $PSBoundParameters.ContainsKey("Exports")) {
        $discoveryResult = Get-CostExportsForScopeResult -Scope $scope
        if (-not $discoveryResult.Succeeded) {
            Write-Info "Unable to find recurring Cost Management exports at $scope. $($discoveryResult.ErrorMessage)"
            return @()
        }

        $Exports = @($discoveryResult.Exports)
    }

    $allowUsageFallback = (Test-SubscriptionCostExportScope -Scope $scope) -and $DatasetType -eq "ActualCost"
    $uniqueExports = @($Exports | Where-Object { $_ } | Sort-Object -Property ResourceId, Id, Name -Unique)
    return @($uniqueExports | Where-Object {
        $assessment = Get-RecurringCostExportAssessment `
            -Export $_ `
            -DatasetTypes @($DatasetType) `
            -AllowUsageFallback $allowUsageFallback
        $assessment.Classification -in @("compatible", "usable-fallback")
    })
}

function Get-RecurringCostExportDiscoveryForScope {
    param(
        [string]$Scope,
        [string[]]$DatasetTypes = @("ActualCost", "AmortizedCost")
    )

    $normalizedScope = Normalize-CostExportScope -Scope $Scope
    $listResult = Get-CostExportsForScopeResult -Scope $normalizedScope
    $matchesByDataset = @{}

    foreach ($datasetType in $DatasetTypes) {
        $matchesByDataset[$datasetType] = @()
    }

    $assessments = @()
    if ($listResult.Succeeded) {
        $allowUsageFallback = Test-SubscriptionCostExportScope -Scope $normalizedScope
        $uniqueExports = @($listResult.Exports |
            Where-Object { $_ -and (Test-CostExportIsRecurringCandidate -Export $_) } |
            Sort-Object -Property ResourceId, Id, Name -Unique)
        foreach ($export in $uniqueExports) {
            $assessment = Get-RecurringCostExportAssessment `
                -Export $export `
                -DatasetTypes $DatasetTypes `
                -AllowUsageFallback $allowUsageFallback
            $assessments += $assessment
        }

        foreach ($datasetType in $DatasetTypes) {
            $matchesByDataset[$datasetType] = @($assessments |
                Where-Object {
                    $_.RequestedDatasetType -eq $datasetType -and
                    $_.Classification -in @("compatible", "usable-fallback")
                } |
                Sort-Object `
                    -Property @{ Expression = { if ($_.Classification -eq "compatible") { 0 } else { 1 } } }, ExportName |
                ForEach-Object { $_.Export })
        }
    }

    return [pscustomobject]@{
        Succeeded = $listResult.Succeeded
        Scope = $normalizedScope
        MatchesByDataset = $matchesByDataset
        Assessments = @($assessments)
        ErrorMessage = $listResult.ErrorMessage
    }
}

function Get-RecurringCostExportDiscoveries {
    param([object[]]$Targets)

    $results = @()
    foreach ($target in $Targets) {
        $datasetTypes = if ($target.DatasetTypes) { @($target.DatasetTypes) } else { @("ActualCost", "AmortizedCost") }
        $discovery = Get-RecurringCostExportDiscoveryForScope -Scope $target.Scope -DatasetTypes $datasetTypes
        $results += [pscustomobject]@{
            Target = $target
            Discovery = $discovery
        }

        if (-not $discovery.Succeeded -and -not $target.OptionalDiscovery) {
            break
        }
    }

    return @($results)
}

function Get-ExportDestinationInfo {
    param([object]$Export)

    $properties = Get-CostExportProperties -Export $Export
    $destination = $properties.deliveryInfo.destination
    return [pscustomobject]@{
        StorageAccountId = $destination.resourceId
        Container = $destination.container
        RootFolderPath = $destination.rootFolderPath
    }
}

function Get-BackfillMonthPeriods {
    param([int]$MonthCount)

    $todayUtc = [DateTime]::UtcNow
    $currentMonth = [DateTime]::SpecifyKind((Get-Date -Year $todayUtc.Year -Month $todayUtc.Month -Day 1 -Hour 0 -Minute 0 -Second 0), [DateTimeKind]::Utc)
    $periods = @()

    for ($offset = $MonthCount; $offset -ge 1; $offset--) {
        $start = $currentMonth.AddMonths(-$offset)
        $lastDay = [DateTime]::DaysInMonth($start.Year, $start.Month)
        $end = [DateTime]::SpecifyKind((Get-Date -Year $start.Year -Month $start.Month -Day $lastDay -Hour 23 -Minute 59 -Second 59), [DateTimeKind]::Utc)
        $periods += [pscustomobject]@{
            Name = $start.ToString("yyyyMM")
            From = $start.ToString("yyyy-MM-ddTHH:mm:ssZ")
            To = $end.ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }

    return $periods
}

function Get-SpottoBackfillQueuedDescription {
    param([string]$PeriodName)

    return "$SPOTTO_BACKFILL_QUEUED_PREFIX $PeriodName"
}

function Test-SpottoBackfillQueued {
    param(
        [object]$Export,
        [string]$PeriodName
    )

    $properties = Get-CostExportProperties -Export $Export
    if (-not $properties -or [string]::IsNullOrWhiteSpace($properties.exportDescription)) {
        return $false
    }

    return $properties.exportDescription -eq (Get-SpottoBackfillQueuedDescription -PeriodName $PeriodName)
}

function Test-SpottoBackfillPending {
    param(
        [object]$Export,
        [string]$PeriodName
    )

    $properties = Get-CostExportProperties -Export $Export
    if (-not $properties -or [string]::IsNullOrWhiteSpace($properties.exportDescription)) {
        return $false
    }

    return $properties.exportDescription -eq "$SPOTTO_BACKFILL_PENDING_PREFIX $PeriodName"
}

function New-CostExportBody {
    param(
        [string]$DatasetType,
        [string]$Timeframe,
        [string]$StorageAccountId,
        [string]$ContainerName,
        [string]$RootFolderPath,
        [hashtable]$Schedule,
        [hashtable]$TimePeriod = $null,
        [string]$ExportDescription = "",
        [string]$CompressionMode = "gzip"
    )

    $definition = @{
        type = $DatasetType
        timeframe = $Timeframe
        dataSet = @{
            granularity = "Daily"
        }
    }

    if ($TimePeriod) {
        $definition.timePeriod = $TimePeriod
    }

    $body = @{
        properties = @{
            format = "Csv"
            compressionMode = $CompressionMode
            dataOverwriteBehavior = "OverwritePreviousReport"
            partitionData = $true
            definition = $definition
            deliveryInfo = @{
                destination = @{
                    type = "AzureBlob"
                    resourceId = $StorageAccountId
                    container = $ContainerName
                    rootFolderPath = $RootFolderPath
                }
            }
            schedule = $Schedule
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExportDescription)) {
        $body.properties.exportDescription = $ExportDescription
    }

    return $body
}

function Test-CostManagementThrottleError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    if (-not $ErrorRecord -or -not $ErrorRecord.Exception) {
        return $false
    }

    try {
        $statusCode = $ErrorRecord.Exception.Response.StatusCode
        $numericStatusCode = 0
        if ($statusCode -and $statusCode.PSObject.Properties["value__"]) {
            $numericStatusCode = [int]$statusCode.value__
        } elseif ($null -ne $statusCode) {
            [void][int]::TryParse("$statusCode", [ref]$numericStatusCode)
        }

        if ($numericStatusCode -eq 429) {
            return $true
        }
    } catch {
        # Azure cmdlet exception types vary; fall back to the service error text below.
    }

    $message = $ErrorRecord.Exception.Message
    return -not [string]::IsNullOrWhiteSpace($message) -and
        $message -match "(?i)too\s*many\s*requests|TooManyRequests|\b429\b"
}

function Get-AzureResponseHeaderValue {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string[]]$HeaderNames
    )

    if (-not $ErrorRecord -or -not $ErrorRecord.Exception -or -not $ErrorRecord.Exception.Response) {
        return $null
    }

    $headers = $ErrorRecord.Exception.Response.Headers
    if (-not $headers) {
        return $null
    }

    foreach ($headerName in $HeaderNames) {
        try {
            $directValue = $headers[$headerName]
            if ($null -ne $directValue -and @($directValue).Count -gt 0) {
                return "$( @($directValue)[0] )".Trim()
            }
        } catch {
            # Some HttpResponseHeaders implementations do not expose an indexer to PowerShell.
        }

        try {
            if ($headers.PSObject.Methods["GetValues"]) {
                $values = @($headers.GetValues($headerName))
                if ($values.Count -gt 0) {
                    return "$($values[0])".Trim()
                }
            }
        } catch {
            # GetValues throws when the requested header is absent.
        }

        $matchingProperty = $headers.PSObject.Properties |
            Where-Object { $_.Name -ieq $headerName } |
            Select-Object -First 1
        if ($matchingProperty -and $null -ne $matchingProperty.Value) {
            return "$( @($matchingProperty.Value)[0] )".Trim()
        }
    }

    return $null
}

function Get-CostManagementRetryDelaySeconds {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [int]$DefaultSeconds = 60,
        [int]$MaximumSeconds = 300
    )

    $headerValue = Get-AzureResponseHeaderValue -ErrorRecord $ErrorRecord -HeaderNames @(
        "x-ms-ratelimit-microsoft.consumption-retry-after",
        "Retry-After"
    )

    $delaySeconds = 0
    if (-not [string]::IsNullOrWhiteSpace($headerValue) -and [int]::TryParse($headerValue, [ref]$delaySeconds)) {
        return [Math]::Min([Math]::Max($delaySeconds, 1), $MaximumSeconds)
    }

    $message = if ($ErrorRecord -and $ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { "" }
    if ($message -match "(?i)retry(?:\s*|-)after\s+(\d+)\s*(?:seconds?|s)\b") {
        $messageDelay = 0
        if ([int]::TryParse($Matches[1], [ref]$messageDelay)) {
            return [Math]::Min([Math]::Max($messageDelay, 1), $MaximumSeconds)
        }
    }

    return [Math]::Min([Math]::Max($DefaultSeconds, 1), $MaximumSeconds)
}

function Invoke-WithCostManagementThrottleRetry {
    param(
        [scriptblock]$Operation,
        [string]$OperationLabel,
        [int]$MaxRetries = 5
    )

    $retryCount = 0
    while ($true) {
        try {
            return & $Operation
        } catch {
            if (-not (Test-CostManagementThrottleError -ErrorRecord $_) -or $retryCount -ge $MaxRetries) {
                throw
            }

            $retryCount++
            $delaySeconds = Get-CostManagementRetryDelaySeconds -ErrorRecord $_
            Write-Info "Azure rate-limited $OperationLabel. Waiting $delaySeconds seconds before retry $retryCount of $MaxRetries."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Test-PartitionDataUnsupportedMessage {
    param([string]$Message)

    return -not [string]::IsNullOrWhiteSpace($Message) -and
        $Message -match "(?i)partitionData" -and
        $Message -match "(?i)not\s+supported|unsupported|invalid(?:\s+request|\s+input|\s+property)?|unknown\s+property|unrecognized|could\s+not\s+find\s+member"
}

function Ensure-CostExport {
    param(
        [string]$Scope,
        [string]$ExportName,
        [hashtable]$Body
    )

    $existingExport = Get-CostExport -Scope $Scope -ExportName $ExportName
    if ($existingExport -and $existingExport.eTag) {
        $Body.eTag = $existingExport.eTag
    }

    $resourceId = Get-CostExportResourceId -Scope $Scope -ExportName $ExportName

    $registrationRetryCount = 0
    while ($true) {
        try {
            Invoke-WithCostManagementThrottleRetry -OperationLabel "export definition '$ExportName'" -Operation {
                New-AzResource -ResourceId $resourceId -ApiVersion $COST_EXPORT_API_VERSION -Properties $Body.properties -Force -ErrorAction Stop | Out-Null
            }
            break
        } catch {
            $message = $_.Exception.Message

            if ($Body.properties.ContainsKey("partitionData") -and (Test-PartitionDataUnsupportedMessage -Message $message)) {
                Write-Info "Retrying export '$ExportName' without explicit partitionData because this scope may not support that property."
                $Body.properties.Remove("partitionData")
                continue
            }

            if ((Test-CostManagementExportsRegistrationMessage -Message $message) -and $registrationRetryCount -lt 5) {
                $registrationRetryCount++
                Write-Info "Azure is still preparing the Microsoft.CostManagementExports resource provider for export storage access. Waiting 60 seconds before retry $registrationRetryCount of 5."
                Start-Sleep -Seconds 60
                continue
            }

            throw
        }
    }

    if ($existingExport) {
        return "updated"
    }

    return "created"
}

function Invoke-CostExportRun {
    param(
        [string]$Scope,
        [string]$ExportName,
        [hashtable]$TimePeriod = $null
    )

    $resourceId = Get-CostExportResourceId -Scope $Scope -ExportName $ExportName
    Invoke-WithCostManagementThrottleRetry -OperationLabel "export run '$ExportName'" -Operation {
        if ($TimePeriod) {
            Invoke-AzResourceAction -ResourceId $resourceId -Action "run" -ApiVersion $COST_EXPORT_API_VERSION -Parameters @{ timePeriod = $TimePeriod } -Force -ErrorAction Stop | Out-Null
        } else {
            Invoke-AzResourceAction -ResourceId $resourceId -Action "run" -ApiVersion $COST_EXPORT_API_VERSION -Force -ErrorAction Stop | Out-Null
        }
    }
}

function Add-BillingExportResult {
    param(
        [string]$SubscriptionName,
        [string]$SubscriptionId,
        [string]$DatasetType,
        [string]$ExportKind,
        [string]$ExportName,
        [string]$Status,
        [string]$StorageAccountId,
        [string]$ContainerName,
        [string]$RootFolderPath,
        [string]$Message = ""
    )

    $script:billingExportResults += [pscustomobject]@{
        SubscriptionName = $SubscriptionName
        SubscriptionId = $SubscriptionId
        DatasetType = $DatasetType
        ExportKind = $ExportKind
        ExportName = $ExportName
        Status = $Status
        StorageAccountId = $StorageAccountId
        ContainerName = $ContainerName
        RootFolderPath = $RootFolderPath
        Message = $Message
    }
}

function Get-BillingExportSetupOutcome {
    param(
        [object[]]$Results,
        [string]$PriorStatus = ""
    )

    $resultRows = @($Results)
    $successfulRows = @($resultRows | Where-Object { $_.Status -in $BILLING_EXPORT_SUCCESS_STATUSES })
    $problemRows = @($resultRows | Where-Object { $_.Status -notin $BILLING_EXPORT_SUCCESS_STATUSES })

    if ($problemRows.Count -eq 0 -and $successfulRows.Count -gt 0 -and $PriorStatus -notin @("failed", "unavailable")) {
        return "complete"
    }
    if ($successfulRows.Count -gt 0) {
        return "partial"
    }
    return "failed"
}

function ConvertTo-AzureManualOnboardingBillingExportSource {
    param(
        [string]$Scope,
        [string]$DatasetType,
        [string]$ExportName,
        [object]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($ExportName)) {
        throw "Billing export source scope and export name are required."
    }

    $source = [ordered]@{
        datasetType = Get-AzureBillingExportDatasetType -DatasetType $DatasetType
        scopeType = Get-AzureBillingExportScopeType -Scope $Scope
        scopePath = Normalize-CostExportScope -Scope $Scope
        exportName = $ExportName.Trim()
    }

    if (
        $Destination -and
        -not [string]::IsNullOrWhiteSpace([string]$Destination.StorageAccountId) -and
        -not [string]::IsNullOrWhiteSpace([string]$Destination.Container)
    ) {
        $destinationJson = [ordered]@{
            container = $Destination.Container
            rootFolderPath = if ($null -eq $Destination.RootFolderPath) { "" } else { [string]$Destination.RootFolderPath }
        }

        try {
            $storageParts = Get-StorageAccountParts -StorageAccountId $Destination.StorageAccountId
            $destinationJson["storageAccountName"] = $storageParts.Name
        } catch {
            Write-Info "The onboarding JSON will use the storage resource ID because its account name could not be parsed."
            $destinationJson["storageAccountResourceId"] = $Destination.StorageAccountId
        }

        $source["destination"] = $destinationJson
    }

    return $source
}

function Get-AzureManualOnboardingBillingExportSourcesForHandoff {
    param([object[]]$Sources)

    $maximumSourceCount = 50
    $maximumConfigurationBytes = 24 * 1024
    $orderedSources = @($Sources | Sort-Object -Property `
        @{ Expression = {
                $normalizedScopePath = ([string]$_.scopePath).Trim().TrimEnd("/")
                $normalizedExportName = ([string]$_.exportName).Trim().ToLowerInvariant()
                $isCanonicalSubscriptionExport = $_.scopeType -eq "subscription" -and
                    $normalizedExportName -in @("spotto-actual-daily", "spotto-amortized-daily")
                $isTenantRootManagementGroup = $_.scopeType -eq "managementGroup" -and
                    -not [string]::IsNullOrWhiteSpace($script:tenantId) -and
                    $normalizedScopePath -ieq "/providers/Microsoft.Management/managementGroups/$($script:tenantId)"
                $isBillingAccountRoot = $_.scopeType -eq "billingAccount"

                if ($isCanonicalSubscriptionExport -or $isTenantRootManagementGroup -or $isBillingAccountRoot) { 1 } else { 0 }
            } }, `
        @{ Expression = {
                switch ($_.scopeType) {
                    "subscription" { 0 }
                    "resourceGroup" { 1 }
                    "billingProfile" { 2 }
                    "invoiceSection" { 3 }
                    "billingAccount" { 4 }
                    "managementGroup" { 5 }
                    default { 6 }
                }
            } }, `
        scopePath, `
        @{ Expression = { if ($_.datasetType -eq "actual") { 0 } else { 1 } } }, `
        exportName)

    $selected = @()
    foreach ($source in $orderedSources) {
        if ($selected.Count -ge $maximumSourceCount) {
            break
        }

        $candidate = @($selected) + @($source)
        $candidateJson = [ordered]@{ sources = $candidate } | ConvertTo-Json -Depth 12 -Compress
        if ([System.Text.Encoding]::UTF8.GetByteCount($candidateJson) -gt $maximumConfigurationBytes) {
            continue
        }

        $selected = $candidate
    }

    $omittedCount = $orderedSources.Count - $selected.Count
    if ($omittedCount -gt 0) {
        Write-Warning-Custom "$omittedCount billing export source locator(s) were omitted from the portal handoff to keep the configuration within its 50-source and 24-KiB limits. Non-conventional omitted locators may require manual review; Spotto automatically discovers only supported conventional export scopes and names."
    }

    return $selected
}

function Add-AzureManualOnboardingBillingExportSource {
    param(
        [string]$Scope,
        [string]$DatasetType,
        [string]$ExportName,
        [object]$Destination
    )

    $source = ConvertTo-AzureManualOnboardingBillingExportSource `
        -Scope $Scope `
        -DatasetType $DatasetType `
        -ExportName $ExportName `
        -Destination $Destination

    if ($null -eq $script:acceptedBillingExportSources) {
        $script:acceptedBillingExportSources = @()
    }

    $sourceIdentity = "$($source.datasetType)|$($source.scopeType)|$($source.scopePath)|$($source.exportName)".ToLowerInvariant()
    $alreadyAccepted = @($script:acceptedBillingExportSources | Where-Object {
        "$($_.datasetType)|$($_.scopeType)|$($_.scopePath)|$($_.exportName)".ToLowerInvariant() -eq $sourceIdentity
    }).Count -gt 0
    if (-not $alreadyAccepted) {
        $script:acceptedBillingExportSources += [pscustomobject]$source
    }
}

function Set-OnboardingJsonOwnerOnlyPermissions {
    param([string]$Path)

    if ($env:OS -eq "Windows_NT") {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $fileSecurity = New-Object System.Security.AccessControl.FileSecurity
        $fileSecurity.SetOwner($currentIdentity.User)
        $fileSecurity.SetAccessRuleProtection($true, $false)
        $ownerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentIdentity.User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $fileSecurity.AddAccessRule($ownerRule)
        Set-Acl -LiteralPath $Path -AclObject $fileSecurity -ErrorAction Stop
        return
    }

    $chmodCommand = Get-Command chmod -CommandType Application -ErrorAction SilentlyContinue
    if (-not $chmodCommand) {
        throw "The local chmod command is required to protect the onboarding JSON on this platform."
    }

    & $chmodCommand.Source "600" $Path
    if ($LASTEXITCODE -ne 0) {
        throw "chmod could not apply owner-only permissions to the onboarding JSON."
    }
}

function Export-AzureManualOnboardingJson {
    $credentials = [ordered]@{
        tenantId = $script:tenantId
        clientId = $script:clientId
    }

    if ($script:isNewSecret -and -not [string]::IsNullOrWhiteSpace($script:clientSecret)) {
        $credentials["clientSecret"] = $script:clientSecret
    }
    if (-not [string]::IsNullOrWhiteSpace($script:secretExpiry)) {
        $credentials["clientSecretExpiresAt"] = $script:secretExpiry
    }

    $payload = [ordered]@{
        schemaVersion = $AZURE_MANUAL_ONBOARDING_IMPORT_SCHEMA_VERSION
        kind = $AZURE_MANUAL_ONBOARDING_IMPORT_KIND
        credentials = $credentials
    }

    $acceptedSources = @(Get-AzureManualOnboardingBillingExportSourcesForHandoff -Sources $script:acceptedBillingExportSources)
    if ($acceptedSources.Count -gt 0) {
        $payload["billingExports"] = [ordered]@{
            sources = $acceptedSources
        }
    }

    $normalizedTenantId = ($script:tenantId -replace "[^a-zA-Z0-9]", "").ToLowerInvariant()
    $tenantFileSuffix = if ($normalizedTenantId.Length -ge 10) {
        $normalizedTenantId.Substring($normalizedTenantId.Length - 10)
    } else {
        Get-StableHashSuffix -Value $script:tenantId -Length 10
    }
    $outputDirectory = (Get-Location).Path
    $outputTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $outputPath = $null
    $fileStream = $null
    try {
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            $attemptSuffix = if ($attempt -eq 0) { "" } else { "-$attempt" }
            $candidatePath = Join-Path -Path $outputDirectory -ChildPath "SpottoAzureOnboarding-$tenantFileSuffix-$outputTimestamp$attemptSuffix.json"
            try {
                $fileStream = New-Object System.IO.FileStream(
                    $candidatePath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
                $outputPath = $candidatePath
                break
            } catch [System.IO.IOException] {
                continue
            }
        }

        if (-not $fileStream -or [string]::IsNullOrWhiteSpace($outputPath)) {
            throw "Unable to reserve a unique onboarding JSON filename in '$outputDirectory'."
        }

        Set-OnboardingJsonOwnerOnlyPermissions -Path $outputPath
        $jsonText = $payload | ConvertTo-Json -Depth 10
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        $jsonBytes = $utf8WithoutBom.GetBytes($jsonText)
        $fileStream.Write($jsonBytes, 0, $jsonBytes.Length)
        $fileStream.Flush()
        $fileStream.Dispose()
        $fileStream = $null

        $script:onboardingJsonPath = (Resolve-Path -LiteralPath $outputPath).Path
        Write-Success "Created Spotto onboarding JSON: $script:onboardingJsonPath"
        return $script:onboardingJsonPath
    } catch {
        if ($fileStream) {
            $fileStream.Dispose()
            $fileStream = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($outputPath) -and [System.IO.File]::Exists($outputPath)) {
            [System.IO.File]::Delete($outputPath)
        }
        Write-Error-Custom "Unable to write the Spotto onboarding JSON file: $($_.Exception.Message)"
        return $null
    } finally {
        if ($fileStream) {
            $fileStream.Dispose()
        }
    }
}

function New-SpottoClientSecret {
    param([object]$Application)

    $secretDurationMonthsToTry = @(24, 12, 6)
    $lastSecretError = $null
    foreach ($durationMonths in $secretDurationMonthsToTry) {
        $secretEndDate = (Get-Date).AddMonths($durationMonths)
        try {
            Write-Info "Creating a $durationMonths-month client secret..."
            $credential = New-AzADAppCredential `
                -ApplicationId $Application.AppId `
                -EndDate $secretEndDate `
                -ErrorAction Stop
        } catch {
            $lastSecretError = $_
            if ($durationMonths -ne $secretDurationMonthsToTry[-1]) {
                Write-Warning-Custom "The $durationMonths-month client secret attempt failed. Trying a shorter duration in case tenant policy limits secret lifetime..."
                Write-Info "Azure response: $($_.Exception.Message)"
            }
            continue
        }

        if (-not $credential -or [string]::IsNullOrWhiteSpace("$($credential.SecretText)")) {
            if ($credential -and -not [string]::IsNullOrWhiteSpace("$($credential.KeyId)")) {
                try {
                    Remove-AzADAppCredential -ApplicationId $Application.AppId -KeyId $credential.KeyId -Confirm:$false -ErrorAction Stop
                } catch {
                    throw "Azure returned no retrievable client-secret value, and exact cleanup of credential key '$($credential.KeyId)' failed. Remove that credential manually before rerunning. $($_.Exception.Message)"
                }
            }
            throw "Azure returned no retrievable client-secret value. Any identifiable credential was removed; no shorter-duration secret was attempted."
        }

        if (-not $credential.EndDateTime) {
            $credential | Add-Member -NotePropertyName EndDateTime -NotePropertyValue $secretEndDate -Force
        }

        Write-Success "Created new $durationMonths-month client secret"
        return $credential
    }

    if ($lastSecretError) {
        throw $lastSecretError
    }
    throw "Failed to create a client secret at 24, 12, or 6 months."
}

function Complete-SpottoClientSecretHandoff {
    param([object]$Application)

    $newCredential = $null
    if ($script:shouldCreateClientSecret) {
        $newCredential = New-SpottoClientSecret -Application $Application
        $script:clientSecret = "$($newCredential.SecretText)"
        $actualSecretEndDate = if ($newCredential.EndDateTime) { [datetime]$newCredential.EndDateTime } else { (Get-Date).AddMonths(6) }
        $script:secretExpiry = $actualSecretEndDate.ToString("yyyy-MM-dd")
        $script:newClientSecretKeyId = "$($newCredential.KeyId)"
        $script:isNewSecret = $true
        $script:shouldCreateClientSecret = $false
        Write-Info "Secret Expires At: $script:secretExpiry"
    }

    $handoffPath = Export-AzureManualOnboardingJson
    if (-not $newCredential -or -not [string]::IsNullOrWhiteSpace($handoffPath)) {
        return $handoffPath
    }

    if ([string]::IsNullOrWhiteSpace($script:newClientSecretKeyId)) {
        throw "The protected onboarding JSON could not be created, and Azure returned no credential key ID for exact rollback. The new secret remains active and must be copied from the emergency display below or removed manually."
    }

    try {
        Remove-AzADAppCredential `
            -ApplicationId $Application.AppId `
            -KeyId $script:newClientSecretKeyId `
            -Confirm:$false `
            -ErrorAction Stop
    } catch {
        throw "The protected onboarding JSON could not be created, and exact rollback of credential key '$script:newClientSecretKeyId' failed. The new secret remains active and must be copied from the emergency display below or removed manually. $($_.Exception.Message)"
    }

    $script:clientSecret = $null
    $script:secretExpiry = $null
    $script:newClientSecretKeyId = $null
    $script:isNewSecret = $false
    Write-Warning-Custom "Removed the newly generated Azure credential because its protected onboarding JSON could not be saved."
    throw "The client secret was rolled back safely because the protected onboarding JSON could not be created. Rerun setup to create a replacement."
}

function Remove-OnboardingJsonAfterConfirmedImport {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) {
        return $false
    }

    $deleteResponse = Read-Host "After Spotto has successfully imported and saved this file, delete the local onboarding JSON now? (yes/no, default no)"
    if (-not (Test-YesResponse -Value $deleteResponse -DefaultYes $false)) {
        Write-Info "Kept the onboarding JSON at $Path. Delete it securely after the portal import succeeds."
        return $false
    }

    [System.IO.File]::Delete($Path)
    if ([System.IO.File]::Exists($Path)) {
        throw "The onboarding JSON could not be deleted from '$Path'."
    }

    if ([string]::Equals("$script:onboardingJsonPath", $Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:onboardingJsonPath = $null
    }
    $script:clientSecret = $null
    Write-Success "Deleted the local onboarding JSON after explicit confirmation"
    return $true
}

function Ensure-ManagementGroupRecurringExport {
    param(
        [object]$ManagementGroup,
        [object]$StorageDestination,
        [string]$ContainerName,
        [string]$TenantId
    )

    $scope = Get-ManagementGroupScope -ManagementGroup $ManagementGroup
    $scopeLabel = Get-ManagementGroupDisplayLabel -ManagementGroup $ManagementGroup -TenantId $TenantId
    $storageAccountId = $StorageDestination.ResourceId
    $exportName = "spotto-usage-daily"
    $rootFolderPath = "$BILLING_EXPORT_ROOT_PATH/management-groups/$($ManagementGroup.Name)/actual/recurring"
    $from = (Get-Date).ToUniversalTime().Date.AddDays(1).ToString("yyyy-MM-ddT00:00:00Z")
    $to = (Get-Date).ToUniversalTime().Date.AddYears(10).ToString("yyyy-MM-ddT00:00:00Z")
    $schedule = @{
        status = "Active"
        recurrence = "Daily"
        recurrencePeriod = @{
            from = $from
            to = $to
        }
    }
    $body = New-CostExportBody `
        -DatasetType "Usage" `
        -Timeframe "MonthToDate" `
        -StorageAccountId $storageAccountId `
        -ContainerName $ContainerName `
        -RootFolderPath $rootFolderPath `
        -Schedule $schedule `
        -CompressionMode "None"

    $status = Ensure-CostExport -Scope $scope -ExportName $exportName -Body $body
    $resultStatus = $status
    $resultMessage = "Management-group exports contain EA usage charges only; subscription Actual and Amortized exports remain the completeness fallback."
    if ($status -eq "created") {
        try {
            Invoke-CostExportRun -Scope $scope -ExportName $exportName
            $resultStatus = "created-run-queued"
            Write-Success "Created the management-group Usage export and queued an immediate run at $scopeLabel."
        } catch {
            $resultStatus = "created-run-failed"
            $resultMessage = "$resultMessage Immediate run failed: $($_.Exception.Message)"
            Write-Info "The management-group export was created at $scopeLabel, but Azure did not queue an immediate run. It will run on its daily schedule. $($_.Exception.Message)"
        }
    } else {
        Write-Success "$status the management-group Usage export at $scopeLabel."
    }

    $destination = [pscustomobject]@{
        StorageAccountId = $storageAccountId
        Container = $ContainerName
        RootFolderPath = $rootFolderPath
    }
    Add-BillingExportResult -SubscriptionName $scopeLabel -SubscriptionId $scope -DatasetType "Usage" -ExportKind "ManagementGroupRecurring" -ExportName $exportName -Status $resultStatus -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $rootFolderPath -Message $resultMessage
    Add-AzureManualOnboardingBillingExportSource -Scope $scope -DatasetType "Usage" -ExportName $exportName -Destination $destination
}

function Ensure-RecurringAndBackfillExports {
    param(
        [object]$Subscription,
        [object]$StorageDestination,
        [string]$ContainerName,
        [hashtable]$ExistingRecurringExports
    )

    $scope = "/subscriptions/$($Subscription.Id)"
    $storageAccountId = $StorageDestination.ResourceId
    $datasets = @("ActualCost", "AmortizedCost")
    $backfillPeriods = Get-BackfillMonthPeriods -MonthCount 13

    Assert-ResourceProviderRegistered -SubscriptionId $Subscription.Id -ProviderNamespace "Microsoft.CostManagement"

    foreach ($datasetType in $datasets) {
        $datasetName = if ($datasetType -eq "ActualCost") { "actual" } else { "amortized" }
        $recurringExportName = Get-SpottoRecurringExportName -DatasetType $datasetType
        $recurringRootPath = "$BILLING_EXPORT_ROOT_PATH/$($Subscription.Id)/$datasetName/recurring"
        $existingKey = "$($Subscription.Id)|$datasetType"
        $effectiveDefinitionType = $datasetType

        if ($ExistingRecurringExports.ContainsKey($existingKey)) {
            $existingExport = $ExistingRecurringExports[$existingKey]
            $existingExportProperties = Get-CostExportProperties -Export $existingExport
            $destination = Get-ExportDestinationInfo -Export $existingExport
            $effectiveDefinitionType = $existingExportProperties.definition.type
            $existingResultMessage = ""
            if ($effectiveDefinitionType -ne $datasetType) {
                $existingResultMessage = "Reused Azure definition type '$effectiveDefinitionType' as the constrained fallback for '$datasetType'; it remains labelled with its effective type."
                Write-Success "Using existing $effectiveDefinitionType fallback for $datasetType on $($Subscription.Name): $($existingExport.name)"
            } else {
                Write-Success "Using existing $datasetType daily export on $($Subscription.Name): $($existingExport.name)"
            }
            Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $effectiveDefinitionType -ExportKind "Recurring" -ExportName $existingExport.name -Status "existing" -StorageAccountId $destination.StorageAccountId -ContainerName $destination.Container -RootFolderPath $destination.RootFolderPath -Message $existingResultMessage
            Add-AzureManualOnboardingBillingExportSource -Scope $scope -DatasetType $effectiveDefinitionType -ExportName $existingExport.name -Destination $destination
        } else {
            try {
                $from = (Get-Date).ToUniversalTime().Date.AddDays(1).ToString("yyyy-MM-ddT00:00:00Z")
                $to = (Get-Date).ToUniversalTime().Date.AddYears(10).ToString("yyyy-MM-ddT00:00:00Z")
                $schedule = @{
                    status = "Active"
                    recurrence = "Daily"
                    recurrencePeriod = @{
                        from = $from
                        to = $to
                    }
                }

                $resultStatus = ""
                $resultMessage = ""
                $createdOrUpdatedRecurring = $false
                foreach ($definitionType in (Get-CostExportDefinitionTypeCandidates -DatasetType $datasetType)) {
                    try {
                        $body = New-CostExportBody -DatasetType $definitionType -Timeframe "MonthToDate" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $recurringRootPath -Schedule $schedule
                        $status = Ensure-CostExport -Scope $scope -ExportName $recurringExportName -Body $body
                        $resultStatus = $status
                        if ($definitionType -ne $datasetType) {
                            $resultMessage = "Used export definition type '$definitionType' because '$datasetType' is not supported for this agreement/scope."
                            Write-Info $resultMessage
                        }
                        $effectiveDefinitionType = $definitionType

                        if ($status -eq "created") {
                            try {
                                Invoke-CostExportRun -Scope $scope -ExportName $recurringExportName
                                $resultStatus = "created-run-queued"
                                Write-Success "created $datasetType daily export and queued an immediate run on $($Subscription.Name)"
                            } catch {
                                $resultStatus = "created-run-failed"
                                $runMessage = "Immediate run failed: $($_.Exception.Message)"
                                $resultMessage = if ($resultMessage) { "$resultMessage $runMessage" } else { $runMessage }
                                Write-Info "$datasetType daily export was created, but Azure did not queue an immediate run. It will run on its daily schedule. $runMessage"
                            }
                        } else {
                            Write-Success "$status $datasetType daily export on $($Subscription.Name)"
                        }

                        $createdOrUpdatedRecurring = $true
                        break
                    } catch {
                        $candidateMessage = $_.Exception.Message
                        if ($definitionType -eq "ActualCost" -and (Test-ShouldRetryActualCostAsUsage -Message $candidateMessage)) {
                            Write-Info "ActualCost exports are not supported for $($Subscription.Name). Retrying with export definition type 'Usage'."
                            continue
                        }

                        throw
                    }
                }

                if (-not $createdOrUpdatedRecurring) {
                    throw "Unable to create $datasetType daily export using supported definition types."
                }
                Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Recurring" -ExportName $recurringExportName -Status $resultStatus -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $recurringRootPath -Message $resultMessage
                Add-AzureManualOnboardingBillingExportSource `
                    -Scope $scope `
                    -DatasetType $effectiveDefinitionType `
                    -ExportName $recurringExportName `
                    -Destination ([pscustomobject]@{
                        StorageAccountId = $storageAccountId
                        Container = $ContainerName
                        RootFolderPath = $recurringRootPath
                    })
            } catch {
                $message = $_.Exception.Message

                if (Test-CostManagementUnavailableMessage -Message $message -DatasetType $datasetType) {
                    $friendlyMessage = Get-CostManagementUnavailableMessage -SubscriptionName $Subscription.Name -DatasetType $datasetType -Operation "daily"
                    Write-Warning-Custom $friendlyMessage
                    Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Recurring" -ExportName $recurringExportName -Status "unavailable" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $recurringRootPath -Message $friendlyMessage
                    continue
                }

                Write-Error-Custom "Failed to create $datasetType daily export on $($Subscription.Name): $message"
                Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Recurring" -ExportName $recurringExportName -Status "failed" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $recurringRootPath -Message $message
                continue
            }
        }

        foreach ($period in $backfillPeriods) {
            $backfillExportName = "spotto-$datasetName-backfill-$($period.Name)"
            $backfillRootPath = "$BILLING_EXPORT_ROOT_PATH/$($Subscription.Id)/$datasetName/backfill/$($period.Name)"
            $existingBackfillExport = Get-CostExport -Scope $scope -ExportName $backfillExportName
            $backfillAlreadyQueued = Test-SpottoBackfillQueued -Export $existingBackfillExport -PeriodName $period.Name
            if ($backfillAlreadyQueued) {
                Write-Info "$DatasetType backfill export $($period.Name) already exists on $($Subscription.Name); not re-queued"
                Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "existing" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath
                continue
            }
            if (Test-SpottoBackfillPending -Export $existingBackfillExport -PeriodName $period.Name) {
                $ambiguousMessage = "A prior run saved the pending marker for this backfill, so Azure may already have accepted the run. It was not queued again. Inspect the export run history before retrying manually."
                Write-Warning-Custom "$DatasetType backfill export $($period.Name) on $($Subscription.Name) is in an ambiguous pending state; not re-queued."
                Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "ambiguous" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath -Message $ambiguousMessage
                continue
            }
            $backfillDescription = "$SPOTTO_BACKFILL_PENDING_PREFIX $($period.Name)"
            $timePeriod = @{
                from = $period.From
                to = $period.To
            }
            $schedule = @{
                status = "Inactive"
            }

            try {
                $body = New-CostExportBody -DatasetType $effectiveDefinitionType -Timeframe "Custom" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath -Schedule $schedule -TimePeriod $timePeriod -ExportDescription $backfillDescription
                $status = Ensure-CostExport -Scope $scope -ExportName $backfillExportName -Body $body
                if ($status -eq "created" -or -not $backfillAlreadyQueued) {
                    Invoke-CostExportRun -Scope $scope -ExportName $backfillExportName -TimePeriod $timePeriod
                    $body.properties.exportDescription = Get-SpottoBackfillQueuedDescription -PeriodName $period.Name
                    try {
                        Ensure-CostExport -Scope $scope -ExportName $backfillExportName -Body $body | Out-Null
                    } catch {
                        $markerFailureMessage = "Azure accepted the backfill run, but the queued marker could not be saved. The pending marker remains, so later reruns will not queue it blindly. $($_.Exception.Message)"
                        Write-Warning-Custom "$DatasetType backfill export $($period.Name) was queued, but the idempotency marker could not be saved."
                        Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "queued-marker-failed" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath -Message $markerFailureMessage
                        continue
                    }

                    if ($status -eq "created") {
                        Write-Success "created and queued $DatasetType backfill export $($period.Name) on $($Subscription.Name)"
                        Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "queued" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath
                    } else {
                        Write-Success "re-queued $DatasetType backfill export $($period.Name) on $($Subscription.Name) because no queued marker was found"
                        Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "requeued" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath
                    }
                } else {
                    Write-Info "$DatasetType backfill export $($period.Name) already exists on $($Subscription.Name); not re-queued"
                    Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "existing" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath
                }
            } catch {
                $message = $_.Exception.Message
                if (Test-CostManagementUnavailableMessage -Message $message -DatasetType $datasetType) {
                    $friendlyMessage = Get-CostManagementUnavailableMessage -SubscriptionName $Subscription.Name -DatasetType $datasetType -Operation "backfill"
                    Write-Warning-Custom $friendlyMessage
                    Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "unavailable" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath -Message $friendlyMessage
                    break
                }

                Write-Error-Custom "Failed to queue $DatasetType backfill $($period.Name) on $($Subscription.Name): $message"
                Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Backfill" -ExportName $backfillExportName -Status "failed" -StorageAccountId $storageAccountId -ContainerName $ContainerName -RootFolderPath $backfillRootPath -Message $message
                if ($datasetType -eq "AmortizedCost") {
                    break
                }
            }
        }
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

$mainHeaderMessage = if ($script:usePrerequisiteCheck) { "Spotto Azure Prerequisite Check" } else { "Spotto Azure Setup" }
$mainHeaderSubtitle = if ($script:usePrerequisiteCheck) { "Checks access; changes Cost Management RBAC only with approval" } else { "Creates or repairs your Spotto connection" }
Write-Header -Message $mainHeaderMessage -Subtitle $mainHeaderSubtitle

Write-Host "This wizard is safe to rerun. It reuses existing resources where possible and"
Write-Host "adds any missing access."
Write-Host ""

Write-SectionLabel "Setup mode"
if ($script:useRecommendedReadOnlySetup) {
    Write-DetailRow -Label "Selected" -Value "Recommended read-only access"
    Write-DetailRow -Label "Scope" -Value "All subscriptions"
    Write-DetailRow -Label "Includes" -Value "Spotto reader permissions"
    Write-DetailRow -Label "Excludes" -Value "Billing exports and optional write access"
} elseif ($script:usePrerequisiteCheck) {
    Write-DetailRow -Label "Selected" -Value "Check prerequisites"
    Write-DetailRow -Label "Scope" -Value "All subscriptions and visible management groups"
    Write-DetailRow -Label "Includes" -Value "Active Azure RBAC, Reservations, Savings Plans, and Azure resource PIM checks"
    Write-DetailRow -Label "Azure changes" -Value "None unless you explicitly approve the optional Cost Management role fix"
} else {
    Write-DetailRow -Label "Selected" -Value "Custom setup"
    Write-DetailRow -Label "Choices" -Value "The wizard asks which read and optional write capabilities to add"
}
Write-Host ""

if ($script:usePrerequisiteCheck) {
    Write-Info "Next, choose the Azure account and tenant to assess. All visible subscriptions are checked."
} else {
    Write-Info "Next, choose the Azure account, tenant, and subscriptions to connect."
}
if ($script:usePrerequisiteCheck) {
    Write-Info "The check distinguishes active access from eligible Azure resource PIM roles."
} else {
    Write-Info "If you use PIM, activate the required admin roles before continuing."
}
Write-Info "Detailed requirements: https://docs.spotto.ai/portal/cloud-account-azure/powershell"

# ============================================================================
# Step 1: Connect to Azure
# ============================================================================

Write-Header -Message ("Step 1 of {0}: Connect to Azure" -f $script:totalWizardSteps)

try {
    $currentContext = Get-AzContext
    if ($null -eq $currentContext) {
        Write-Info "Not logged in. Initiating login..."
        Connect-AzAccount
    } else {
        Write-Info "Already logged in as: $($currentContext.Account.Id)"
        $useCurrentAccount = Read-Host "Use this account? (yes/no, default yes)"
        if (-not (Test-YesResponse -Value $useCurrentAccount)) {
            Connect-AzAccount
        }
    }
    Write-Success "Connected to Azure"
} catch {
    Write-Error-Custom "Failed to connect to Azure: $_"
    exit 1
}

# ============================================================================
# Step 2: Select Tenant
# ============================================================================

Write-Header -Message ("Step 2 of {0}: Select Tenant" -f $script:totalWizardSteps)

try {
    # Get all tenants the user has access to
    $allTenants = Get-AzTenant
    
    if ($allTenants.Count -eq 0) {
        Write-Error-Custom "No tenants found for this account."
        exit 1
    } elseif ($allTenants.Count -eq 1) {
        # Only one tenant, use it automatically
        $script:tenantId = $allTenants[0].Id
        Write-Success "Using tenant: $($allTenants[0].Name) ($script:tenantId)"
    } else {
        # Multiple tenants, let user choose
        Write-Host "You have access to $($allTenants.Count) tenant(s):`n"
        
        for ($i = 0; $i -lt $allTenants.Count; $i++) {
            $tenant = $allTenants[$i]
            $tenantName = if ($tenant.Name) { $tenant.Name } else { "Unnamed Tenant" }
            Write-Host ("  [{0,2}] {1}" -f ($i + 1), $tenantName)
            Write-DetailRow -Label "Tenant ID" -Value $tenant.Id
            Write-DetailRow -Label "Domains" -Value ($tenant.Domains -join ', ')
            Write-Host ""
        }
        
        $validSelection = $false
        while (-not $validSelection) {
            $selection = Read-Host "Select tenant number (1-$($allTenants.Count))"
            $selectedIndex = [int]$selection - 1
            
            if ($selectedIndex -ge 0 -and $selectedIndex -lt $allTenants.Count) {
                $validSelection = $true
                $selectedTenant = $allTenants[$selectedIndex]
                $script:tenantId = $selectedTenant.Id
                
                # Switch to the selected tenant
                Write-Info "Switching to selected tenant..."
                Set-AzContext -TenantId $script:tenantId | Out-Null
                
                $tenantName = if ($selectedTenant.Name) { $selectedTenant.Name } else { "Unnamed Tenant" }
                Write-Success "Selected tenant: $tenantName ($script:tenantId)"
            } else {
                Write-Error-Custom "Invalid selection. Please enter a number between 1 and $($allTenants.Count)"
            }
        }
    }
} catch {
    Write-Error-Custom "Failed to select tenant: $_"
    exit 1
}

if ($script:usePrerequisiteCheck) {
    Write-Info "The prerequisite check uses the current Azure session so it can show which PIM access is eligible but not active."
} else {
    Write-SectionLabel "Azure session refresh"
    Write-Info "If you activated temporary access after this PowerShell session signed in, Azure may still be using old tokens."
    $refreshPimSession = Read-Host "Have you just activated temporary Azure access and want the script to reconnect now? (yes/no, default no)"
    if (Test-YesResponse -Value $refreshPimSession -DefaultYes $false) {
        try {
            Invoke-PimAzReconnect `
                -TenantId $script:tenantId `
                -Reason "Refreshing the Azure session after temporary access activation." |
                Out-Null
            Set-AzContext -TenantId $script:tenantId | Out-Null
            Write-Success "Azure session refreshed for tenant $script:tenantId"
        } catch {
            Write-Error-Custom "Failed to refresh Azure session after temporary access activation: $_"
            Write-PimTroubleshootingHint
            exit 1
        }
    }
}

# ============================================================================
# Step 3: Select Subscriptions
# ============================================================================

Write-Header -Message ("Step 3 of {0}: Select Subscriptions" -f $script:totalWizardSteps)

try {
    $subscriptions = @(Get-AzSubscription -TenantId $script:tenantId -WarningAction SilentlyContinue -ErrorAction Stop)
} catch {
    Write-Error-Custom ("Could not list subscriptions for tenant {0}: {1}" -f $script:tenantId, $_)
    Write-PimTroubleshootingHint
    exit 1
}

Write-Host "Found $($subscriptions.Count) subscription(s) in your tenant."

if ($subscriptions.Count -eq 0) {
    $visibleSubscriptions = @()
    try {
        $visibleSubscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
            Where-Object { $_.TenantId -ne $script:tenantId })
    } catch {
        $visibleSubscriptions = @()
    }

    Write-NoAccessibleSubscriptionsHint -TenantId $script:tenantId -VisibleSubscriptions $visibleSubscriptions
    exit 1
}

Write-Host ""
Write-SectionLabel "Onboarding scope"
if ($script:useRecommendedReadOnlySetup) {
    Write-DetailRow -Label "Selected" -Value "All subscriptions"
} elseif ($script:usePrerequisiteCheck) {
    Write-DetailRow -Label "Selected" -Value "Check all visible subscriptions"
} else {
    Write-OptionRow -Key "1" -Label "All subscriptions (default)" -Description "Try tenant-root Reader, then fall back to each subscription if needed."
    Write-OptionRow -Key "2" -Label "Specific subscriptions" -Description "Choose one or more subscriptions by number."
}

$selectedSubscriptions = @()
$scopeSelected = $false

while (-not $scopeSelected) {
    $selection = Get-OnboardingScopeSelection
    $normalizedSelection = $selection.Trim().ToLowerInvariant()

    if ($normalizedSelection -in @("1", "a", "all")) {
        $selectedSubscriptions = $subscriptions
        $script:useTenantRootReader = $true
        $script:selectedAllSubscriptions = $true
        $scopeSelected = $true
        Write-Success "Selected all $($selectedSubscriptions.Count) subscriptions"
        if ($script:usePrerequisiteCheck) {
            Write-Info "The assessment is read-only. If Cost Management export access is missing but self-remediable, the script may offer a separate default-no role assignment."
        } else {
            Write-Info "Reader access will first be attempted once at tenant root scope (/)."
        }
    } elseif ($normalizedSelection -in @("2", "s", "specific")) {
        $script:useTenantRootReader = $false
        $script:selectedAllSubscriptions = $false

        Write-Host ""
        Write-SectionLabel "Available subscriptions"
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host ("  [{0,2}] {1} ({2})" -f ($i + 1), $subscriptions[$i].Name, $subscriptions[$i].Id)
        }
        Write-Host ""

        while ($selectedSubscriptions.Count -eq 0) {
            $subscriptionSelection = Read-Host "Enter subscription numbers or ranges (for example 1,3,5-9 or 'all')"
            $selectedSubscriptions = @()
            $seenSubscriptionIds = @{}
            $resolvedSelection = ConvertFrom-IndexedSelection -Selection $subscriptionSelection -MaxValue $subscriptions.Count

            foreach ($subscriptionNumber in @($resolvedSelection.Indexes)) {
                $subscription = $subscriptions[$subscriptionNumber - 1]
                if (-not $seenSubscriptionIds.ContainsKey($subscription.Id)) {
                    $selectedSubscriptions += $subscription
                    $seenSubscriptionIds[$subscription.Id] = $true
                }
            }

            if (-not $resolvedSelection.IsValid -or $selectedSubscriptions.Count -eq 0) {
                Write-Error-Custom "Invalid subscription selection. Enter numbers or ranges between 1 and $($subscriptions.Count), or 'all'."
                $selectedSubscriptions = @()
            }
        }

        $scopeSelected = $true
        Write-Success "Selected $($selectedSubscriptions.Count) subscription(s)"
    } else {
        Write-Error-Custom "Invalid option. Enter 1 for all subscriptions or 2 to choose specific subscriptions."
    }
}

if ($script:usePrerequisiteCheck) {
    $prerequisiteCheckResult = Invoke-SpottoAzurePrerequisiteCheck `
        -TenantId $script:tenantId `
        -Subscriptions $selectedSubscriptions

    Write-Host ""
    Write-Info "Stopping transcript. Prerequisite result: $($prerequisiteCheckResult.Outcome)."
    try {
        Stop-Transcript | Out-Null
    } catch {
        Write-Info "The PowerShell transcript was already stopped."
    }
    Write-Host "Prerequisite check complete. Review the results above or in $logPath." -ForegroundColor Cyan
    Read-Host "Press Enter to exit"
    exit 0
}

if ($script:useTenantRootReader) {
    if (-not (Test-TenantRootRoleAssignmentAccess)) {
        if (-not (Use-SubscriptionReaderFallback `
            -Subscriptions $selectedSubscriptions `
            -Reason "Tenant-root role assignment is unavailable. Falling back automatically.")) {
            Write-Error-Custom "Reader access requires tenant-root authority or role-assignment authority on every selected subscription."
            exit 1
        }
    }
} else {
    if (-not (Test-SelectedSubscriptionAccess -Subscriptions $selectedSubscriptions)) {
        exit 1
    }

    if (-not (Test-SelectedSubscriptionRoleAssignmentAccess -Subscriptions $selectedSubscriptions)) {
        exit 1
    }
}

# ============================================================================
# Step 4: Create Service Principal
# ============================================================================

Write-Header -Message "Step 4 of 13: Create Service Principal"

try {
    $existingApp = Resolve-SpottoAzureApplication -TenantId $script:tenantId
    if ($existingApp) {
        $script:appDisplayName = $existingApp.DisplayName
        $app = $existingApp
        Write-Success "Using the tenant-tagged or explicitly selected application '$script:appDisplayName'"
    } else {
        $ownershipTags = @(Get-SpottoApplicationOwnershipTags -TenantId $script:tenantId)
        $app = New-AzADApplication `
            -DisplayName $APP_NAME `
            -Description "Spotto Azure onboarding application for tenant $script:tenantId" `
            -Tag $ownershipTags `
            -ErrorAction Stop
        $script:appDisplayName = $APP_NAME
        Write-Success "Created new application: $APP_NAME"
    }

    $sp = Ensure-SpottoServicePrincipal -Application $app
    $script:clientId = $app.AppId
    Write-Success "Client ID: $script:clientId"
    Write-Info "Object ID: $($sp.Id)"
    
} catch {
    Write-Error-Custom "Failed to create service principal: $_"
    exit 1
}

# ============================================================================
# Step 5: Check Client Secret
# ============================================================================

Write-Header -Message "Step 5 of 13: Check Client Secret"

try {
    $credentialReferenceTime = Get-Date
    $applicationCredentials = @(Get-AzADAppCredential -ApplicationId $app.AppId)
    $existingCredentials = @(Get-ApplicationPasswordCredentials -Credentials $applicationCredentials)
    $clientSecretPlan = Get-ClientSecretPlan `
        -Credentials @($existingCredentials) `
        -ReferenceTime $credentialReferenceTime
    $validCredentials = @($clientSecretPlan.ValidCredentials)
    $latestCredential = $clientSecretPlan.LatestCredential
    $createNewSecret = $clientSecretPlan.Action -eq "create"
    
    if ($validCredentials.Count -gt 0) {
        Write-Info "Found $($validCredentials.Count) existing valid credential(s)."
        Write-Host "Expiry dates:"
        foreach ($cred in $validCredentials) {
            Write-Host "  - $($cred.EndDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC'))"
        }

        if ($script:useRecommendedReadOnlySetup) {
            if ($createNewSecret) {
                Write-Info "The latest credential expires in less than three months. A replacement secret will be created."
            } else {
                Write-Info "The latest credential has at least three months remaining. No new secret is needed."
            }
        } else {
            $defaultCreateNew = $createNewSecret
            $defaultLabel = if ($defaultCreateNew) { "yes" } else { "no" }
            $createNewResponse = Read-Host "`nDo you want to create a new secret? (yes/no, default $defaultLabel)"
            $createNewSecret = Test-YesResponse -Value $createNewResponse -DefaultYes $defaultCreateNew
        }
    }

    if (-not $createNewSecret) {
        Write-Info "Reusing the existing credential. Its secret value cannot be retrieved from Azure."
        $script:clientSecret = "<USE_EXISTING_SECRET>"
        $script:secretExpiry = $latestCredential.EndDateTime.ToString("yyyy-MM-dd")
        $script:isNewSecret = $false
        $script:shouldCreateClientSecret = $false
    } else {
        $script:clientSecret = $null
        $script:secretExpiry = $null
        $script:isNewSecret = $false
        $script:shouldCreateClientSecret = $true
        Write-Info "A new client secret is planned. It will be created only after all required setup steps succeed."
        Write-Info "The transcript will be stopped before Azure returns the one-time secret value."
    }
    
} catch {
    Write-Error-Custom "Failed to inspect or plan the client secret: $_"
    exit 1
}

# ============================================================================
# Step 6: Assign Reader Access
# ============================================================================

Write-Header -Message "Step 6 of 13: Assign Reader Access"

if ($script:useTenantRootReader) {
    Write-Info "All subscriptions were selected, so Reader will be assigned at tenant root scope (/)."
    $script:rootReaderAssignmentStatus = Ensure-TenantRootReaderAssignment -PrincipalId $sp.Id
    if ($script:rootReaderAssignmentStatus -eq "failed") {
        if (-not (Use-SubscriptionReaderFallback `
            -Subscriptions $selectedSubscriptions `
            -Reason "The tenant-root Reader assignment failed. Falling back automatically.")) {
            Write-Error-Custom "Reader access requires tenant-root authority or role-assignment authority on every selected subscription."
            Write-PimTroubleshootingHint
            exit 1
        }
    }
}

if (-not $script:useTenantRootReader) {
    $readerAssignmentsSucceeded = Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Reader" -RoleLabel "Reader role"
    if (-not $readerAssignmentsSucceeded) {
        Write-Error-Custom "Reader access is required for every selected subscription. Activate the required role from the upfront checklist and rerun this script."
        exit 1
    }
}

# ============================================================================
# Step 7: Recommended Monitoring and Security Roles
# ============================================================================

Write-Header -Message "Step 7 of 13: Recommended Monitoring and Security Roles"

Write-SectionLabel "Recommended read permissions"
Write-DetailRow -Label "Monitoring Reader" -Value "Application Insights query access on selected subscriptions."
Write-DetailRow -Label "Log Analytics Reader" -Value "Workspace log access for current and future analysis scenarios."
Write-DetailRow -Label "Security Reader" -Value "Defender for Cloud assessments, secure score, and security posture on selected subscriptions."
Write-DetailRow -Label "Subscription coverage" -Value "All three roles are checked on every selected subscription."
Write-DetailRow -Label "All subscriptions" -Value "Monitoring Reader and Log Analytics Reader are also checked on visible management groups."
Write-Host ""
$grantMonitoringReadPerms = Get-SetupCapabilityResponse `
    -Capability "Monitoring Reader, Log Analytics Reader, and Security Reader" `
    -Prompt "Do you want to grant these recommended monitoring and security roles?" `
    -RecommendedReadOnlyValue $true

$monitoringReadRolesEnabled = $false
if ([string]::IsNullOrWhiteSpace($grantMonitoringReadPerms) -or $grantMonitoringReadPerms -match "^(?i:yes)$") {
    $monitoringReadRolesEnabled = $true
    $monitoringReaderAssignmentsSucceeded = Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Monitoring Reader" -RoleLabel "Monitoring Reader role"
    $securityReaderAssignmentsSucceeded = Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Security Reader" -RoleLabel "Security Reader role"
    $logAnalyticsReaderAssignmentsSucceeded = Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Log Analytics Reader" -RoleLabel "Log Analytics Reader role"
    $script:subscriptionMonitoringReaderStatus = if ($monitoringReaderAssignmentsSucceeded) { "processed" } else { "failed" }
    $script:subscriptionSecurityReaderStatus = if ($securityReaderAssignmentsSucceeded) { "processed" } else { "failed" }
    $script:subscriptionLogAnalyticsReaderStatus = if ($logAnalyticsReaderAssignmentsSucceeded) { "processed" } else { "failed" }
} elseif ($grantMonitoringReadPerms -match "^(?i:no)$") {
    Write-Info "Skipping recommended monitoring and security roles"
    $script:subscriptionMonitoringReaderStatus = "skipped"
    $script:subscriptionSecurityReaderStatus = "skipped"
    $script:subscriptionLogAnalyticsReaderStatus = "skipped"
} else {
    Write-Info "Unrecognized response. Defaulting to no for the optional recommended monitoring roles."
    $script:subscriptionMonitoringReaderStatus = "skipped"
    $script:subscriptionSecurityReaderStatus = "skipped"
    $script:subscriptionLogAnalyticsReaderStatus = "skipped"
}

# ============================================================================
# Step 8: Assign Management Group and Key Vault Reader Roles
# ============================================================================

Write-Header -Message "Step 8 of 13: Assign Management Group and Key Vault Reader Roles"

Write-SectionLabel "Visible management group permissions"
Write-DetailRow -Label "Scope" -Value "Tenant root when available; otherwise every management group visible to this Azure session."
Write-DetailRow -Label "Governance" -Value "Reader and Management Group Reader."
Write-DetailRow -Label "Monitoring" -Value "Monitoring Reader and Log Analytics Reader in the all-subscriptions setup."
Write-DetailRow -Label "Key Vault metadata" -Value "Key Vault Reader lists expiry metadata but cannot read secret values or private key material."
Write-DetailRow -Label "Key Vault scope" -Value "Tenant-root management group for all subscriptions when available; otherwise selected subscriptions."
Write-DetailRow -Label "Vault model" -Value "Inherited access applies to vaults using Azure RBAC; legacy access-policy vaults require per-vault policies."
Write-DetailRow -Label "Requires" -Value "Role-assignment authority at each management group. A failed scope does not stop the remaining groups."
Write-Host ""
$grantGovernanceReaderRoles = Get-SetupCapabilityResponse `
    -Capability "visible management group Reader and Management Group Reader" `
    -Prompt "Do you want to grant governance reader roles on every visible management group now?" `
    -RecommendedReadOnlyValue $true `
    -CustomDefaultYes $script:selectedAllSubscriptions

$governanceReaderRolesEnabled = Test-YesResponse -Value $grantGovernanceReaderRoles
$managementGroupMonitoringRolesEnabled = $monitoringReadRolesEnabled -and $script:selectedAllSubscriptions
if ($governanceReaderRolesEnabled -or $managementGroupMonitoringRolesEnabled -or $script:selectedAllSubscriptions) {
    $script:visibleManagementGroups = @(Get-VisibleManagementGroupTargets -TenantId $script:tenantId)
}

$keyVaultReaderResult = Ensure-KeyVaultReaderAssignments `
    -PrincipalId $sp.Id `
    -Subscriptions $selectedSubscriptions `
    -TenantId $script:tenantId `
    -ManagementGroups $script:visibleManagementGroups `
    -PreferTenantRootManagementGroup $script:selectedAllSubscriptions
$script:keyVaultReaderStatus = $keyVaultReaderResult.Status
$script:keyVaultReaderScope = $keyVaultReaderResult.Scope
$script:usedSubscriptionKeyVaultReaderFallback = $keyVaultReaderResult.UsedFallback

if ($script:keyVaultReaderStatus -eq "failed") {
    Write-Warning-Custom "Key Vault Reader access could not be assigned across every selected scope. The remaining onboarding permissions will still be attempted."
    Write-PimTroubleshootingHint
}

if ($governanceReaderRolesEnabled) {
    $managementGroupAzureReaderResult = Ensure-ManagementGroupRoleAssignments `
        -PrincipalId $sp.Id `
        -ManagementGroups $script:visibleManagementGroups `
        -TenantId $script:tenantId `
        -RoleDefinitionName "Reader" `
        -RoleLabel "Reader role"
    $script:managementGroupAzureReaderStatus = $managementGroupAzureReaderResult.Status

    $managementGroupReaderResult = Ensure-ManagementGroupRoleAssignments `
        -PrincipalId $sp.Id `
        -ManagementGroups $script:visibleManagementGroups `
        -TenantId $script:tenantId `
        -RoleDefinitionName "Management Group Reader" `
        -RoleLabel "Management Group Reader role"
    $script:managementGroupReaderStatus = $managementGroupReaderResult.Status
} else {
    $script:managementGroupAzureReaderStatus = "skipped"
    $script:managementGroupReaderStatus = "skipped"
    Write-Info "Skipping management group governance reader roles. Tenant hierarchy and management group governance analysis may be limited."
}

if ($managementGroupMonitoringRolesEnabled) {
    $managementGroupMonitoringReaderResult = Ensure-ManagementGroupRoleAssignments `
        -PrincipalId $sp.Id `
        -ManagementGroups $script:visibleManagementGroups `
        -TenantId $script:tenantId `
        -RoleDefinitionName "Monitoring Reader" `
        -RoleLabel "Monitoring Reader role"
    $script:managementGroupMonitoringReaderStatus = $managementGroupMonitoringReaderResult.Status

    $managementGroupLogAnalyticsReaderResult = Ensure-ManagementGroupRoleAssignments `
        -PrincipalId $sp.Id `
        -ManagementGroups $script:visibleManagementGroups `
        -TenantId $script:tenantId `
        -RoleDefinitionName "Log Analytics Reader" `
        -RoleLabel "Log Analytics Reader role"
    $script:managementGroupLogAnalyticsReaderStatus = $managementGroupLogAnalyticsReaderResult.Status
} else {
    $script:managementGroupMonitoringReaderStatus = "skipped"
    $script:managementGroupLogAnalyticsReaderStatus = "skipped"
    if ($monitoringReadRolesEnabled -and -not $script:selectedAllSubscriptions) {
        Write-Info "Management-group monitoring roles were not added because Custom setup is limited to specific subscriptions."
    }
}

# ============================================================================
# Step 9: Assign Reservations Reader and optional Reservations Contributor
# ============================================================================

Write-Header -Message "Step 9 of 13: Assign Reservation Roles"

Write-SectionLabel "Reservation permissions"
Write-DetailRow -Label "Scope" -Value "/providers/Microsoft.Capacity."
Write-DetailRow -Label "Reader role" -Value "Read reservation benefits for savings analysis."
Write-DetailRow -Label "Recommended contributor" -Value "Calculate reservation refund quotes and support future reservation management workflows."
Write-DetailRow -Label "Requires" -Value "Permission to assign roles at the Microsoft.Capacity provider scope."
Write-Host ""
$grantReservationRoles = Get-SetupCapabilityResponse `
    -Capability "Reservations Reader" `
    -Prompt "Do you want to grant reservation roles now?" `
    -RecommendedReadOnlyValue $true

if (Test-YesResponse -Value $grantReservationRoles) {
    try {
        $reservationScope = "/providers/Microsoft.Capacity"

        # Check if role assignment already exists
        $existingReservation = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $reservationScope -RoleDefinitionName "Reservations Reader" -ErrorAction SilentlyContinue

        if ($existingReservation) {
            Write-Info "Reservations Reader role already assigned"
            $script:reservationReaderStatus = "existing"
        } else {
            New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Reservations Reader" -Scope $reservationScope | Out-Null
            Write-Success "Assigned Reservations Reader role at /providers/Microsoft.Capacity"
            $script:reservationReaderStatus = "created"
        }
    } catch {
        $script:reservationReaderStatus = "failed"
        Write-Error-Custom "Failed to assign Reservations Reader role: $_"
        Write-TenantWidePimTroubleshootingHint -ScopeLabel "/providers/Microsoft.Capacity"
    }

    if ($script:reservationReaderStatus -in @("created", "existing")) {
        Write-SectionLabel "Optional reservation management permission"
        Write-DetailRow -Label "Role" -Value "Reservations Contributor at /providers/Microsoft.Capacity."
        Write-DetailRow -Label "Impact" -Value "Can manage reservations in the tenant but cannot delegate reservation RBAC roles."
        Write-Host ""

        $existingReservationContributor = $null
        try {
            $existingReservationContributor = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $reservationScope -RoleDefinitionName "Reservations Contributor" -ErrorAction SilentlyContinue
        } catch {
            Write-Info "Could not check for an existing Reservations Contributor assignment. The assignment attempt can still be tried if you choose yes."
        }

        if ($existingReservationContributor) {
            Write-Info "Reservations Contributor role already assigned"
            $script:reservationContributorStatus = "existing"
        } else {
            $grantReservationsContributor = Get-SetupCapabilityResponse `
                -Capability "Reservations Contributor" `
                -Prompt "Do you want to grant recommended Reservations Contributor?" `
                -RecommendedReadOnlyValue $false
        }

        if (-not $existingReservationContributor -and (Test-YesResponse -Value $grantReservationsContributor)) {
            try {
                New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Reservations Contributor" -Scope $reservationScope | Out-Null
                Write-Success "Assigned Reservations Contributor role at /providers/Microsoft.Capacity"
                $script:reservationContributorStatus = "created"
            } catch {
                $script:reservationContributorStatus = "failed"
                Write-Error-Custom "Failed to assign Reservations Contributor role: $_"
                Write-Info "Continuing with Reservations Reader access only. Reservation refund quotes and management may not work until this role is assigned."
                Write-TenantWidePimTroubleshootingHint -ScopeLabel "/providers/Microsoft.Capacity"
            }
        } elseif (-not $existingReservationContributor) {
            $script:reservationContributorStatus = "skipped"
            Write-Info "Skipping optional Reservations Contributor role. Reservation refund quote and management features may be limited."
        }
    } else {
        $script:reservationContributorStatus = "skipped"
        Write-Info "Skipping Reservations Contributor because Reservations Reader was not assigned."
    }
} else {
    $script:reservationReaderStatus = "skipped"
    $script:reservationContributorStatus = "skipped"
    Write-Info "Skipping reservation provider-scope roles. Reservation benefit and refund quote features may be limited."
}

# ============================================================================
# Step 10: Assign Savings plan Reader
# ============================================================================

Write-Header -Message "Step 10 of 13: Assign Savings Plan Reader"

Write-SectionLabel "Savings plan permission"
Write-DetailRow -Label "Scope" -Value "/providers/Microsoft.BillingBenefits."
Write-DetailRow -Label "Role" -Value "Savings plan Reader."
Write-DetailRow -Label "Requires" -Value "Permission to assign roles at the Microsoft.BillingBenefits provider scope."
Write-Host ""
$grantSavingsPlanReader = Get-SetupCapabilityResponse `
    -Capability "Savings plan Reader" `
    -Prompt "Do you want to grant Savings plan Reader now?" `
    -RecommendedReadOnlyValue $true

if (Test-YesResponse -Value $grantSavingsPlanReader) {
    try {
        $savingsPlanScope = "/providers/Microsoft.BillingBenefits"

        # Check if role assignment already exists
        $existingSavingsPlan = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $savingsPlanScope -RoleDefinitionName "Savings plan Reader" -ErrorAction SilentlyContinue

        if ($existingSavingsPlan) {
            Write-Info "Savings plan Reader role already assigned"
            $script:savingsPlanReaderStatus = "existing"
        } else {
            New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Savings plan Reader" -Scope $savingsPlanScope | Out-Null
            Write-Success "Assigned Savings plan Reader role at /providers/Microsoft.BillingBenefits"
            $script:savingsPlanReaderStatus = "created"
        }
    } catch {
        $script:savingsPlanReaderStatus = "failed"
        Write-Error-Custom "Failed to assign Savings plan Reader role: $_"
        Write-TenantWidePimTroubleshootingHint -ScopeLabel "/providers/Microsoft.BillingBenefits"
    }
} else {
    $script:savingsPlanReaderStatus = "skipped"
    Write-Info "Skipping Savings plan Reader. Savings plan benefit analysis may be limited."
}

# ============================================================================
# Step 11: Grant Microsoft Graph Governance Permissions
# ============================================================================

Write-Header -Message "Step 11 of 13: Grant Microsoft Graph Governance Permissions"

Write-SectionLabel "Microsoft Graph governance permission"
Write-DetailRow -Label "Permissions" -Value "$($GRAPH_GOVERNANCE_PERMISSION_VALUES.Count) Microsoft Graph application permissions with admin consent."
Write-DetailRow -Label "Purpose" -Value "Read app posture, tenant policies, subscribed licensing, Global Admin/PIM schedules, groups, users, and audit logs."
Write-DetailRow -Label "Requires" -Value "Tenant admin consent and Microsoft Graph authentication."
Write-DetailRow -Label "Admin sign-in scopes" -Value "Application.ReadWrite.All and AppRoleAssignment.ReadWrite.All."
Write-Host ""
Write-SectionLabel "Permissions requested"
foreach ($permissionValue in $GRAPH_GOVERNANCE_PERMISSION_VALUES) {
    Write-Host "  - $permissionValue" -ForegroundColor White
}
Write-Host ""
$grantGraphPermission = Get-SetupCapabilityResponse `
    -Capability "the complete Microsoft Graph governance reader permission set" `
    -Prompt "Do you want to connect to Microsoft Graph and grant these governance permissions?" `
    -RecommendedReadOnlyValue $true

if (Test-YesResponse -Value $grantGraphPermission) {
    if (Ensure-PowerShellModules -Modules $graphRequiredModules -ModuleSetName "Microsoft Graph" -ManualInstallCommands @(
        "Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force"
    ) -Required $false -InstallMissingByDefault $script:useRecommendedReadOnlySetup) {
        $graphConnected = $false

        try {
            Write-Info "Connecting to Microsoft Graph to grant governance permissions with admin consent..."
            Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -TenantId $script:tenantId -NoWelcome
            $graphConnected = $true

            # Get Microsoft Graph service principal
            $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -Property "id", "appId", "appRoles"

            $graphAppRolesByValue = @{}
            foreach ($graphAppRole in $graphSp.AppRoles) {
                if ($graphAppRole.AllowedMemberTypes -contains "Application") {
                    $graphAppRolesByValue[$graphAppRole.Value] = $graphAppRole
                }
            }

            $existingAssignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All |
                Where-Object { $_.ResourceId -eq $graphSp.Id })
            $existingAppRoleIds = @{}
            foreach ($existingAssignment in $existingAssignments) {
                $existingAppRoleIds[[string]$existingAssignment.AppRoleId] = $true
            }

            $createdPermissionCount = 0
            $existingPermissionCount = 0
            $failedGraphPermissions = @()

            foreach ($permissionValue in $GRAPH_GOVERNANCE_PERMISSION_VALUES) {
                if (-not $graphAppRolesByValue.ContainsKey($permissionValue)) {
                    $failedGraphPermissions += $permissionValue
                    Write-Warning-Custom "Microsoft Graph application permission '$permissionValue' was not available and could not be granted."
                    continue
                }

                $graphAppRole = $graphAppRolesByValue[$permissionValue]
                if ($existingAppRoleIds.ContainsKey([string]$graphAppRole.Id)) {
                    Write-Info "$permissionValue already granted"
                    $existingPermissionCount++
                    continue
                }

                try {
                    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graphSp.Id -AppRoleId $graphAppRole.Id | Out-Null
                    Write-Success "Granted $permissionValue"
                    $createdPermissionCount++
                } catch {
                    $failedGraphPermissions += $permissionValue
                    Write-Warning-Custom "Could not grant Microsoft Graph application permission '$permissionValue': $_"
                }
            }

            $failedPermissionCount = $failedGraphPermissions.Count
            $script:graphPermissionSummary = "$createdPermissionCount granted, $existingPermissionCount already existed, $failedPermissionCount could not be granted"
            if ($failedPermissionCount -gt 0) {
                if (($createdPermissionCount + $existingPermissionCount) -gt 0) {
                    $script:graphPermissionStatus = "partial"
                } else {
                    $script:graphPermissionStatus = "failed"
                }
                Write-Warning-Custom "Microsoft Graph permissions needing administrator follow-up: $($failedGraphPermissions -join ', ')"
            } elseif ($createdPermissionCount -gt 0 -and $existingPermissionCount -gt 0) {
                $script:graphPermissionStatus = "processed"
            } elseif ($createdPermissionCount -gt 0) {
                $script:graphPermissionStatus = "created"
            } else {
                $script:graphPermissionStatus = "existing"
            }

            if ($script:graphPermissionStatus -eq "partial") {
                Write-Warning-Custom "Microsoft Graph governance permissions were partially processed: $script:graphPermissionSummary"
            } else {
                Write-Success "Microsoft Graph governance permissions processed: $script:graphPermissionSummary"
            }

        } catch {
            $script:graphPermissionStatus = "failed"
            Write-Error-Custom "Failed to grant Microsoft Graph governance permissions: $_"
            Write-Info "You may need a tenant admin to grant admin consent."
            Write-Info "You can also grant this manually through Azure Portal > App Registrations > API Permissions"
        } finally {
            if ($graphConnected) {
                try {
                    Disconnect-MgGraph | Out-Null
                    $graphConnected = $false
                } catch {
                    # Silently ignore if already disconnected
                }
            }
        }
    } else {
        $script:graphPermissionStatus = "skipped"
        Write-Info "Skipping Microsoft Graph governance permissions because the Microsoft Graph modules are unavailable."
    }
} else {
    $script:graphPermissionStatus = "skipped"
    Write-Info "Skipping Microsoft Graph governance permissions. You can grant them later in Azure Portal or rerun this script."
}

# ============================================================================
# Step 12: Cost Management Billing Exports
# ============================================================================

Write-Header -Message "Step 12 of 13: Cost Management Billing Exports"

Write-SectionLabel "Recommended billing export setup"
Write-NumberedStep -Number 1 -Message "Classify existing recurring exports at billing, management-group, and subscription scope."
Write-NumberedStep -Number 2 -Message "Grant the Spotto service principal Storage Blob Data Reader on export containers."
Write-NumberedStep -Number 3 -Message "Reuse approved broad exports before creating tenant-root (or topmost child) Usage, then retain subscription datasets and backfills for completeness."
Write-Host ""
Write-Info "Exports are written to customer-owned Azure Storage. Spotto cloud-engine reads them later."
Write-Info "Exports reduce Cost Management API calls and Azure rate limiting."
Write-Info "The Spotto service principal remains read-only; the signed-in operator authorizes setup-time export, storage, and RBAC changes."
Write-Info "The script keeps anonymous blob access disabled and containers private."
Write-Info "Spotto still needs the storage account public network endpoint reachable; RBAC alone cannot bypass a disabled public endpoint or blocking firewall."
Write-Info "Creating or updating exports and storage needs Owner, or Contributor plus User Access Administrator, on the selected subscription/storage scope."
Write-Info "User Access Administrator alone can grant RBAC roles but cannot create Cost Management exports, resource groups, storage accounts, or containers."
Write-Info "New daily recurring exports are run immediately when Azure accepts the run request."
Write-Info "Historical backfill exports are queued once and marked so reruns can recover interrupted backfills without repeated queueing."
Write-Info "Azure management-group exports are EA-only and Usage-only; they do not replace subscription Actual and Amortized exports."
Write-Info "When a billing-scope export is reused, assign Spotto read access at that billing scope so it can discover the export later."
Write-Host ""

$configureBillingExports = Read-SetupConfirmation `
    -Prompt "Set up the recommended Cost Management exports and export storage for Spotto?" `
    -DefaultYes $true

if (Test-YesResponse -Value $configureBillingExports) {
    $script:billingExportSetupStatus = "in-progress"
    $existingRecurringExports = @{}
    $existingStorageMutationApprovals = @{}
    $acceptedBillingScopeExports = @()
    $acceptedManagementGroupScopes = @{}
    $detectedExistingExports = @()
    $rejectedExistingExports = @()
    $billingExportSubscriptions = @()
    $managementGroupExportTargets = @()
    $managementGroupDiscoveryTargets = @()
    $managementGroupDiscoveryResults = @()
    $managementGroupDiscoveryIncomplete = $false
    $script:acceptedBillingExportSources = @()
    $selectedBillingScopes = @(Select-BillingCostExportScopes)

    if ($script:visibleManagementGroups.Count -eq 0) {
        $script:visibleManagementGroups = @(Get-VisibleManagementGroupTargets -TenantId $script:tenantId)
    }

    $preferredManagementGroups = @(Get-PreferredManagementGroupExportTargets `
        -ManagementGroups $script:visibleManagementGroups `
        -TenantId $script:tenantId)
    if ($preferredManagementGroups.Count -gt 0) {
        Write-Host ""
        Write-SectionLabel "Broad management-group export scope"
        Write-Warning-Custom "A management-group export can include cost data for subscriptions beyond the subscriptions selected in this wizard."
        $managementGroupConsentTargets = @(Get-ManagementGroupExportDiscoveryTargets `
            -ManagementGroups $script:visibleManagementGroups `
            -TenantId $script:tenantId)
        foreach ($managementGroup in $managementGroupConsentTargets) {
            $scopeLabel = if (Test-TenantRootManagementGroup -ManagementGroup $managementGroup -TenantId $script:tenantId) { "Preferred scope" } else { "Possible scope" }
            Write-DetailRow -Label $scopeLabel -Value (Get-ManagementGroupDisplayLabel -ManagementGroup $managementGroup -TenantId $script:tenantId)
        }
        $tryManagementGroupExports = Read-SetupConfirmation `
            -Prompt "Try the management-group scope(s) shown above for broader future-subscription coverage?" `
            -DefaultYes $script:selectedAllSubscriptions
        if (-not (Test-YesResponse -Value $tryManagementGroupExports -DefaultYes $script:selectedAllSubscriptions)) {
            $preferredManagementGroups = @()
            Write-Info "Management-group exports were not approved. Continuing with billing-scope reuse and selected-subscription exports."
        } else {
            $managementGroupDiscoveryTargets = @($managementGroupConsentTargets)
        }
    }

    foreach ($managementGroup in $managementGroupDiscoveryTargets) {
        $managementGroupScope = Get-ManagementGroupScope -ManagementGroup $managementGroup
        $managementGroupLabel = Get-ManagementGroupDisplayLabel -ManagementGroup $managementGroup -TenantId $script:tenantId
        $managementGroupDiscovery = Get-RecurringCostExportDiscoveryForScope -Scope $managementGroupScope -DatasetTypes @("Usage")
        if ($managementGroupDiscovery.Succeeded) {
            $managementGroupDiscoveryResults += [pscustomobject]@{
                ManagementGroup = $managementGroup
                Scope = $managementGroupScope
                ScopeLabel = $managementGroupLabel
                Discovery = $managementGroupDiscovery
            }
        } else {
            $managementGroupDiscoveryIncomplete = $true
            Write-Warning-Custom "Cost Management exports are not available at management group '$managementGroupLabel'."
            Write-Info "Azure response: $($managementGroupDiscovery.ErrorMessage)"
        }
    }

    $existingManagementGroupTargets = @(Get-ExistingManagementGroupExportTargets `
        -DiscoveryResults $managementGroupDiscoveryResults `
        -TenantId $script:tenantId)
    if ($existingManagementGroupTargets.Count -gt 0) {
        $managementGroupExportTargets = @($existingManagementGroupTargets)
        Write-Info "Existing management-group Usage export(s) take precedence over creating an overlapping broader export."
    } elseif ($managementGroupDiscoveryIncomplete) {
        Write-Warning-Custom "Management-group export creation is skipped because discovery was incomplete and could hide an existing overlapping export. Subscription export setup will continue."
    } elseif ($preferredManagementGroups.Count -gt 0) {
        $preferredTenantRoot = @($preferredManagementGroups |
            Where-Object { Test-TenantRootManagementGroup -ManagementGroup $_ -TenantId $script:tenantId }).Count -gt 0
        $creationCandidates = @($preferredManagementGroups)

        foreach ($managementGroup in $creationCandidates) {
            $scope = Get-ManagementGroupScope -ManagementGroup $managementGroup
            $discoveryTarget = $managementGroupDiscoveryResults |
                Where-Object { $_.Scope -ieq $scope } |
                Select-Object -First 1
            if (-not $discoveryTarget) {
                continue
            }

            $writeAssessment = Get-AzurePermissionActionAssessmentAtScope `
                -Scope $scope `
                -RequiredAction "Microsoft.CostManagement/exports/write"
            if ($writeAssessment.Status -eq "ready") {
                $managementGroupExportTargets += $discoveryTarget
            } else {
                Write-Warning-Custom "The signed-in operator can read management group '$($discoveryTarget.ScopeLabel)', but export-create access could not be confirmed there."
            }
        }

        if ($managementGroupExportTargets.Count -eq 0 -and $preferredTenantRoot) {
            $fallbackTargets = @($managementGroupDiscoveryResults | Where-Object {
                -not (Test-TenantRootManagementGroup -ManagementGroup $_.ManagementGroup -TenantId $script:tenantId)
            })
            if ($fallbackTargets.Count -gt 0) {
                Write-Info "Tenant-root export access was unavailable. Trying the approved topmost visible child management group(s)."
            }
            foreach ($fallbackTarget in $fallbackTargets) {
                $writeAssessment = Get-AzurePermissionActionAssessmentAtScope `
                    -Scope $fallbackTarget.Scope `
                    -RequiredAction "Microsoft.CostManagement/exports/write"
                if ($writeAssessment.Status -eq "ready") {
                    $managementGroupExportTargets += $fallbackTarget
                } else {
                    Write-Warning-Custom "The signed-in operator can read management group '$($fallbackTarget.ScopeLabel)', but export-create access could not be confirmed there."
                }
            }
        }
    }

    Write-Info "Checking Cost Management export availability on selected subscriptions..."
    foreach ($sub in $selectedSubscriptions) {
        if (Test-CostExportScopeAvailable -Subscription $sub) {
            $billingExportSubscriptions += $sub
        }
    }

    if ($billingExportSubscriptions.Count -eq 0 -and $selectedBillingScopes.Count -eq 0 -and $managementGroupExportTargets.Count -eq 0) {
        $script:billingExportSetupStatus = "unavailable"
        Write-Warning-Custom "Cost Management billing exports are not available for any selected subscription or billing scope. Skipping storage setup and continuing onboarding."
    }

    if ($script:billingExportSetupStatus -ne "unavailable") {
        $exportDiscoveryTargets = @()
        foreach ($billingScope in $selectedBillingScopes) {
            $exportDiscoveryTargets += [pscustomobject]@{
                Scope = $billingScope.Scope
                ScopeLabel = $billingScope.Label
                ScopeType = $billingScope.Type
                IsBillingScope = $true
                IsManagementGroupScope = $false
                Subscription = $null
            }
        }

        foreach ($sub in $billingExportSubscriptions) {
            $exportDiscoveryTargets += [pscustomobject]@{
                Scope = "/subscriptions/$($sub.Id)"
                ScopeLabel = $sub.Name
                ScopeType = "Subscription"
                IsBillingScope = $false
                IsManagementGroupScope = $false
                Subscription = $sub
            }
        }

        if ($exportDiscoveryTargets.Count -gt 0) {
            Write-Info "Checking each selected billing and subscription scope once for existing daily Cost Management exports..."
        }

        $exportDiscoveries = @(Get-RecurringCostExportDiscoveries -Targets $exportDiscoveryTargets)
        foreach ($exportDiscovery in $exportDiscoveries) {
            $discoveryTarget = $exportDiscovery.Target
            $discovery = $exportDiscovery.Discovery
            if (-not $discovery.Succeeded) {
                $script:billingExportSetupStatus = "failed"
                Write-Error-Custom "Could not complete Cost Management export discovery at $($discoveryTarget.ScopeLabel) ($($discoveryTarget.Scope))."
                Write-Info "Azure response: $($discovery.ErrorMessage)"
                Write-Info "No export or storage changes will be made because an incomplete discovery result could hide an existing export. Rerun the wizard after Azure access or throttling recovers."
                break
            }

            foreach ($assessment in @($discovery.Assessments | Where-Object Classification -eq "incompatible")) {
                $rejectedExistingExports += [pscustomobject]@{
                    Scope = $discoveryTarget.Scope
                    ScopeLabel = $discoveryTarget.ScopeLabel
                    ScopeType = $discoveryTarget.ScopeType
                    Assessment = $assessment
                }
            }

            foreach ($datasetType in @("ActualCost", "AmortizedCost")) {
                $matches = @($discovery.MatchesByDataset[$datasetType])
                if ($matches.Count -gt 0) {
                    $export = $matches | Select-Object -First 1
                    $assessment = $discovery.Assessments |
                        Where-Object {
                            $_.ExportName -eq $export.name -and
                            $_.RequestedDatasetType -eq $datasetType -and
                            $_.Classification -in @("compatible", "usable-fallback")
                        } |
                        Select-Object -First 1
                    $destination = Get-ExportDestinationInfo -Export $export
                    $detectedExistingExports += [pscustomobject]@{
                        Scope = $discoveryTarget.Scope
                        ScopeLabel = $discoveryTarget.ScopeLabel
                        ScopeType = $discoveryTarget.ScopeType
                        IsBillingScope = $discoveryTarget.IsBillingScope
                        IsManagementGroupScope = $discoveryTarget.IsManagementGroupScope
                        Subscription = $discoveryTarget.Subscription
                        DatasetType = $datasetType
                        EffectiveDatasetType = $assessment.EffectiveDatasetType
                        Classification = $assessment.Classification
                        Export = $export
                        Destination = $destination
                    }
                }
            }
        }

        $selectedExistingManagementGroupScopes = @{}
        foreach ($managementGroupTarget in $existingManagementGroupTargets) {
            $selectedExistingManagementGroupScopes[$managementGroupTarget.Scope.ToLowerInvariant()] = $true
        }

        foreach ($managementGroupTarget in $managementGroupDiscoveryResults) {
            foreach ($assessment in @($managementGroupTarget.Discovery.Assessments | Where-Object Classification -eq "incompatible")) {
                $rejectedExistingExports += [pscustomobject]@{
                    Scope = $managementGroupTarget.Scope
                    ScopeLabel = $managementGroupTarget.ScopeLabel
                    ScopeType = "Management group"
                    Assessment = $assessment
                }
            }

            $matches = if ($selectedExistingManagementGroupScopes.ContainsKey($managementGroupTarget.Scope.ToLowerInvariant())) {
                @($managementGroupTarget.Discovery.MatchesByDataset["Usage"])
            } else {
                @()
            }
            if ($matches.Count -gt 0) {
                $export = $matches | Select-Object -First 1
                $assessment = $managementGroupTarget.Discovery.Assessments |
                    Where-Object {
                        $_.ExportName -eq $export.name -and
                        $_.RequestedDatasetType -eq "Usage" -and
                        $_.Classification -eq "compatible"
                    } |
                    Select-Object -First 1
                $destination = Get-ExportDestinationInfo -Export $export
                $detectedExistingExports += [pscustomobject]@{
                    Scope = $managementGroupTarget.Scope
                    ScopeLabel = $managementGroupTarget.ScopeLabel
                    ScopeType = "Management group"
                    IsBillingScope = $false
                    IsManagementGroupScope = $true
                    ManagementGroup = $managementGroupTarget.ManagementGroup
                    Subscription = $null
                    DatasetType = "Usage"
                    EffectiveDatasetType = $assessment.EffectiveDatasetType
                    Classification = $assessment.Classification
                    Export = $export
                    Destination = $destination
                }
            }
        }
    }

    if ($script:billingExportSetupStatus -notin @("failed", "unavailable")) {
        if ($detectedExistingExports.Count -gt 0) {
            Write-Host ""
            Write-SectionLabel "Detected reusable recurring exports"
            foreach ($detected in $detectedExistingExports) {
                Write-DetailRow -Label "Scope" -Value "$($detected.ScopeLabel) ($($detected.ScopeType))"
                $datasetLabel = if ($detected.Classification -eq "usable-fallback") {
                    "$($detected.DatasetType) request using Azure $($detected.EffectiveDatasetType) fallback"
                } else {
                    $detected.EffectiveDatasetType
                }
                Write-DetailRow -Label "Dataset" -Value $datasetLabel
                Write-DetailRow -Label "Export" -Value $detected.Export.name
                Write-DetailRow -Label "Container" -Value $detected.Destination.Container
                if ($detected.Classification -eq "usable-fallback") {
                    Write-DetailRow -Label "Compatibility" -Value "Usable fallback; retained as Usage and not presented as full modern Actual Cost coverage."
                }
                if ($detected.IsBillingScope) {
                    Write-DetailRow -Label "Billing scope" -Value $detected.Scope
                }
                Write-Host ""
            }

            Write-Info "If accepted, subscription-scope export storage may be updated to keep the public endpoint enabled with anonymous blob access disabled."
            Write-Info "Billing- and management-group-scope export storage is not changed; the script only grants Spotto blob read access on the existing container."
            Write-Info "If broad-scope export storage has public network access disabled or a blocking firewall, Spotto cannot read it over the internet even with Storage Blob Data Reader."
            $useExistingExports = Get-SetupCapabilityResponse `
                -Capability "reusable existing recurring exports" `
                -Prompt "Use reusable existing recurring exports where found?" `
                -RecommendedReadOnlyValue $true
            if (Test-YesResponse -Value $useExistingExports) {
                foreach ($detected in $detectedExistingExports) {
                    try {
                        $storageAccountId = $detected.Destination.StorageAccountId
                        $containerName = $detected.Destination.Container

                        if ($detected.IsBillingScope -or $detected.IsManagementGroupScope) {
                            Write-Info "Preparing Spotto blob read access for an existing broad-scope export without changing storage account network settings."
                            $storageParts = Get-StorageAccountParts -StorageAccountId $storageAccountId
                            Set-AzContext -SubscriptionId $storageParts.SubscriptionId -TenantId $script:tenantId | Out-Null
                            try {
                                $account = Get-StorageAccountResource -StorageAccountId $storageAccountId
                                if ($account.PublicNetworkAccess -ne "Enabled" -or (-not $account.NetworkRuleSet -or $account.NetworkRuleSet.DefaultAction -ne "Allow")) {
                                    Write-Warning-Custom "The broad-scope export storage account may not be reachable by Spotto cloud-engine through the public endpoint."
                                    Write-Info "Storage Blob Data Reader grants identity access only; it does not bypass a disabled public endpoint or storage firewall."
                                    Write-Info "The script does not change broad-scope export storage networking. Update it manually if Spotto cannot read the export, or keep the subscription-level export fallback."
                                }
                            } catch {
                                Write-Info "Unable to verify billing-scope export storage network settings. The script will still try to assign blob read access. $_"
                            }
                            $containerScope = "$storageAccountId/blobServices/default/containers/$containerName"
                        } else {
                            if (-not (Confirm-ExistingBillingStorageMutation -StorageAccountId $storageAccountId -ApprovalCache $existingStorageMutationApprovals)) {
                                $message = "Existing storage network changes were not approved; the export was left unchanged and was not accepted for Spotto."
                                Write-Warning-Custom $message
                                Add-BillingExportResult -SubscriptionName $detected.ScopeLabel -SubscriptionId $detected.Scope -DatasetType $detected.DatasetType -ExportKind "Recurring" -ExportName $detected.Export.name -Status "unavailable" -StorageAccountId $storageAccountId -ContainerName $containerName -RootFolderPath $detected.Destination.RootFolderPath -Message $message
                                continue
                            }
                            Ensure-BillingExportStorageSettings -StorageAccountId $storageAccountId
                            $containerScope = Ensure-BillingExportContainer -StorageAccountId $storageAccountId -ContainerName $containerName
                        }

                        $storageReaderStatus = Ensure-StorageBlobDataReaderAssignment -PrincipalId $sp.Id -Scope $containerScope
                        if ($storageReaderStatus -eq "failed") {
                            throw "Storage Blob Data Reader could not be assigned on export container '$containerName'."
                        }

                        if ($detected.IsBillingScope) {
                            Write-BillingScopeReaderGuidance -PrincipalId $sp.Id -Scope $detected.Scope
                            $acceptedBillingScopeExports += $detected
                            $script:acceptedBillingScopeExports += $detected
                            Add-BillingExportResult -SubscriptionName $detected.ScopeLabel -SubscriptionId $detected.Scope -DatasetType $detected.DatasetType -ExportKind "BillingScopeRecurring" -ExportName $detected.Export.name -Status "existing" -StorageAccountId $storageAccountId -ContainerName $containerName -RootFolderPath $detected.Destination.RootFolderPath -Message "Billing-scope export reused; billing-scope reader access must be granted separately if Spotto cannot already read this scope."
                            Add-AzureManualOnboardingBillingExportSource -Scope $detected.Scope -DatasetType $detected.DatasetType -ExportName $detected.Export.name -Destination $detected.Destination
                        } elseif ($detected.IsManagementGroupScope) {
                            $acceptedManagementGroupScopes[$detected.Scope.ToLowerInvariant()] = $true
                            Add-BillingExportResult -SubscriptionName $detected.ScopeLabel -SubscriptionId $detected.Scope -DatasetType "Usage" -ExportKind "ManagementGroupRecurring" -ExportName $detected.Export.name -Status "existing" -StorageAccountId $storageAccountId -ContainerName $containerName -RootFolderPath $detected.Destination.RootFolderPath -Message "Existing management-group Usage export reused; subscription Actual and Amortized exports remain the completeness fallback."
                            Add-AzureManualOnboardingBillingExportSource -Scope $detected.Scope -DatasetType "Usage" -ExportName $detected.Export.name -Destination $detected.Destination
                        } else {
                            $key = "$($detected.Subscription.Id)|$($detected.DatasetType)"
                            $existingRecurringExports[$key] = $detected.Export
                            $existingDefinitionType = (Get-CostExportProperties -Export $detected.Export).definition.type
                            Add-AzureManualOnboardingBillingExportSource -Scope $detected.Scope -DatasetType $existingDefinitionType -ExportName $detected.Export.name -Destination $detected.Destination
                        }
                    } catch {
                        $failureMessage = $_.Exception.Message
                        Write-Error-Custom "Existing export '$($detected.Export.name)' could not be prepared for Spotto: $failureMessage"
                        Add-BillingExportResult `
                            -SubscriptionName $detected.ScopeLabel `
                            -SubscriptionId $detected.Scope `
                            -DatasetType $detected.DatasetType `
                            -ExportKind $(if ($detected.IsBillingScope) { "BillingScopeRecurring" } elseif ($detected.IsManagementGroupScope) { "ManagementGroupRecurring" } else { "Recurring" }) `
                            -ExportName $detected.Export.name `
                            -Status "failed" `
                            -StorageAccountId $detected.Destination.StorageAccountId `
                            -ContainerName $detected.Destination.Container `
                            -RootFolderPath $detected.Destination.RootFolderPath `
                            -Message $failureMessage
                    }
                }
            }
        } else {
            if ($rejectedExistingExports.Count -gt 0) {
                Write-Info "Recurring exports were found, but none met the Spotto reuse requirements. Review the reasons below before choosing storage."
            } else {
                Write-Info "No recurring exports were found on the selected billing, management-group, or subscription scopes."
            }
        }

        if ($rejectedExistingExports.Count -gt 0) {
            Write-Host ""
            Write-SectionLabel "Recurring exports not reused"
            foreach ($rejected in @($rejectedExistingExports | Select-Object -First 10)) {
                Write-DetailRow -Label "Scope" -Value "$($rejected.ScopeLabel) ($($rejected.ScopeType))"
                Write-DetailRow -Label "Export" -Value $rejected.Assessment.ExportName
                foreach ($reason in @($rejected.Assessment.Reasons)) {
                    Write-DetailRow -Label "Reason" -Value $reason
                }
                Write-Host ""
            }
            if ($rejectedExistingExports.Count -gt 10) {
                Write-Info "$($rejectedExistingExports.Count - 10) additional incompatible recurring export(s) are omitted from the console summary; the Azure scopes above can be inspected manually."
            }
        }

        $storageDestination = $null
        $billingExportContainerName = $BILLING_EXPORT_CONTAINER_NAME
        $skipSubscriptionLevelExports = $false

        if ($acceptedBillingScopeExports.Count -gt 0) {
            Write-Info "Billing-scope export(s) were accepted."
            Write-Info "Per-subscription exports can still be created as a fallback when the billing-scope export does not cover every selected subscription or dataset."
            $skipSubscriptionExports = Get-SetupCapabilityResponse `
                -Capability "skipping subscription-level export fallback" `
                -Prompt "Skip subscription-level exports because the accepted billing-scope export covers all selected subscriptions and datasets?" `
                -RecommendedReadOnlyValue $false `
                -CustomDefaultYes $false
            $skipSubscriptionLevelExports = Test-YesResponse -Value $skipSubscriptionExports -DefaultYes $false
            if ($skipSubscriptionLevelExports) {
                Write-Info "Skipping subscription-level export creation because you confirmed the billing-scope export is sufficient."
            } else {
                Write-Info "Continuing with subscription-level export setup where supported."
            }
        }

        if (-not $skipSubscriptionLevelExports -and $billingExportSubscriptions.Count -eq 0) {
            if ($acceptedBillingScopeExports.Count -gt 0) {
                Write-Warning-Custom "No selected subscription supports subscription-level export fallback. Continuing with the accepted billing-scope export(s)."
                $skipSubscriptionLevelExports = $true
            } elseif ($managementGroupExportTargets.Count -gt 0) {
                Write-Warning-Custom "No selected subscription supports subscription-level export fallback. Continuing with management-group Usage export setup only."
                $skipSubscriptionLevelExports = $true
            } else {
                $script:billingExportSetupStatus = "unavailable"
                Write-Warning-Custom "No compatible billing-scope exports were accepted and no selected subscription supports subscription-level exports. Skipping export creation."
            }
        } elseif (-not $skipSubscriptionLevelExports -and $existingRecurringExports.Count -gt 0) {
            $firstExistingExport = $existingRecurringExports.Values | Select-Object -First 1
            $firstDestination = Get-ExportDestinationInfo -Export $firstExistingExport
            $useExistingStorageForNewExports = Get-SetupCapabilityResponse `
                -Capability "the first reusable existing export storage account" `
                -Prompt "Use the first existing export storage account for backfill and missing exports?" `
                -RecommendedReadOnlyValue $true

            if (Test-YesResponse -Value $useExistingStorageForNewExports) {
                try {
                    $storageParts = Get-StorageAccountParts -StorageAccountId $firstDestination.StorageAccountId
                    $storageDestination = [pscustomobject]@{
                        ResourceId = $firstDestination.StorageAccountId
                        SubscriptionId = $storageParts.SubscriptionId
                        ResourceGroupName = $storageParts.ResourceGroupName
                        Name = $storageParts.Name
                    }
                    $billingExportContainerName = $firstDestination.Container
                } catch {
                    Write-Info "Unable to reuse existing export storage. A storage account selection is required. $_"
                }
            }
        }

        $pendingManagementGroupTargets = @($managementGroupExportTargets | Where-Object {
            -not $acceptedManagementGroupScopes.ContainsKey($_.Scope.ToLowerInvariant())
        })
        $needsManagedExportStorage = $pendingManagementGroupTargets.Count -gt 0 -or
            (-not $skipSubscriptionLevelExports -and $billingExportSubscriptions.Count -gt 0)

        if ($needsManagedExportStorage -and $script:billingExportSetupStatus -ne "unavailable" -and -not $storageDestination) {
            try {
                $storageHostSubscriptions = if ($billingExportSubscriptions.Count -gt 0) { @($billingExportSubscriptions) } else { @($selectedSubscriptions) }
                $storageDestination = Select-BillingExportStorageAccount `
                    -Subscriptions $storageHostSubscriptions `
                    -NetworkMutationApprovalCache $existingStorageMutationApprovals
                $billingExportContainerName = Get-DefaultedInput -Prompt "Blob container for Spotto billing exports" -DefaultValue $BILLING_EXPORT_CONTAINER_NAME
            } catch {
                $script:billingExportSetupStatus = "failed"
                Write-Error-Custom "Failed to select or create billing export storage: $($_.Exception.Message)"
                Write-Info "Continuing with the remaining onboarding steps. You can rerun the script after fixing the storage/export prerequisite."
            }
        }

        if ($needsManagedExportStorage -and $script:billingExportSetupStatus -notin @("failed", "unavailable")) {
            try {
                Assert-ResourceProviderRegistered -SubscriptionId $storageDestination.SubscriptionId -ProviderNamespace "Microsoft.CostManagementExports" -MaxAttempts 60 -PollSeconds 5
                if (-not $storageDestination.IsNew -and -not (Confirm-ExistingBillingStorageMutation -StorageAccountId $storageDestination.ResourceId -ApprovalCache $existingStorageMutationApprovals)) {
                    throw "Existing storage account network changes were not approved. Select a dedicated export account or explicitly approve the required settings."
                }
                Ensure-BillingExportStorageSettings -StorageAccountId $storageDestination.ResourceId
                $billingContainerScope = Ensure-BillingExportContainer -StorageAccountId $storageDestination.ResourceId -ContainerName $billingExportContainerName
                $storageReaderStatus = Ensure-StorageBlobDataReaderAssignment -PrincipalId $sp.Id -Scope $billingContainerScope
                if ($storageReaderStatus -eq "failed") {
                    throw "Storage Blob Data Reader could not be assigned on export container '$billingExportContainerName'."
                }
            } catch {
                $script:billingExportSetupStatus = "failed"
                Write-Error-Custom "Failed to prepare billing export storage: $_"
            }
        }

        if ($pendingManagementGroupTargets.Count -gt 0 -and $script:billingExportSetupStatus -notin @("failed", "unavailable")) {
            foreach ($managementGroupTarget in $pendingManagementGroupTargets) {
                Write-Header -Message "Management-group billing export: $($managementGroupTarget.ScopeLabel)" -Subtitle "Daily EA Usage; subscription exports remain enabled for completeness"
                try {
                    Ensure-ManagementGroupRecurringExport `
                        -ManagementGroup $managementGroupTarget.ManagementGroup `
                        -StorageDestination $storageDestination `
                        -ContainerName $billingExportContainerName `
                        -TenantId $script:tenantId

                    $costReaderResult = Ensure-ManagementGroupRoleAssignments `
                        -PrincipalId $sp.Id `
                        -ManagementGroups @($managementGroupTarget.ManagementGroup) `
                        -TenantId $script:tenantId `
                        -RoleDefinitionName "Cost Management Reader" `
                        -RoleLabel "Cost Management Reader role"
                    if ($costReaderResult.Status -in @("failed", "partial", "unavailable")) {
                        $readerMessage = "The export was configured, but Spotto Cost Management Reader access at '$($managementGroupTarget.ScopeLabel)' needs manual review."
                        Write-Warning-Custom $readerMessage
                        Add-BillingExportResult `
                            -SubscriptionName $managementGroupTarget.ScopeLabel `
                            -SubscriptionId $managementGroupTarget.Scope `
                            -DatasetType "Usage" `
                            -ExportKind "ManagementGroupReader" `
                            -ExportName "spotto-usage-daily" `
                            -Status "unavailable" `
                            -StorageAccountId $storageDestination.ResourceId `
                            -ContainerName $billingExportContainerName `
                            -RootFolderPath "$BILLING_EXPORT_ROOT_PATH/management-groups/$($managementGroupTarget.ManagementGroup.Name)/actual/recurring" `
                            -Message $readerMessage
                    }
                } catch {
                    Write-Warning-Custom "Management-group Usage export setup was not available at '$($managementGroupTarget.ScopeLabel)': $($_.Exception.Message)"
                    Add-BillingExportResult -SubscriptionName $managementGroupTarget.ScopeLabel -SubscriptionId $managementGroupTarget.Scope -DatasetType "Usage" -ExportKind "ManagementGroupRecurring" -ExportName "spotto-usage-daily" -Status "unavailable" -StorageAccountId $storageDestination.ResourceId -ContainerName $billingExportContainerName -RootFolderPath "$BILLING_EXPORT_ROOT_PATH/management-groups/$($managementGroupTarget.ManagementGroup.Name)/actual/recurring" -Message $_.Exception.Message
                    Write-Info "Continuing with subscription Actual and Amortized export setup."
                }
            }
        }

        if (-not $skipSubscriptionLevelExports -and $script:billingExportSetupStatus -notin @("failed", "unavailable")) {
            foreach ($sub in $billingExportSubscriptions) {
                Write-Header -Message "Billing exports: $($sub.Name)" -Subtitle "Daily recurring plus 13-month backfill"
                try {
                    Ensure-RecurringAndBackfillExports -Subscription $sub -StorageDestination $storageDestination -ContainerName $billingExportContainerName -ExistingRecurringExports $existingRecurringExports
                } catch {
                    Write-Error-Custom "Billing export setup failed for $($sub.Name): $_"
                    Add-BillingExportResult -SubscriptionName $sub.Name -SubscriptionId $sub.Id -DatasetType "All" -ExportKind "Setup" -ExportName "" -Status "failed" -StorageAccountId $storageDestination.ResourceId -ContainerName $billingExportContainerName -RootFolderPath $BILLING_EXPORT_ROOT_PATH -Message $_.Exception.Message
                }
            }
        }
    }
    $script:billingExportSetupStatus = Get-BillingExportSetupOutcome `
        -Results @($script:billingExportResults) `
        -PriorStatus $script:billingExportSetupStatus
} else {
    $script:billingExportSetupStatus = "skipped"
    Write-Info "Cost Management billing export and storage setup skipped."
}

# ============================================================================
# Step 13: Optional Custom Roles
# ============================================================================

function Get-ScopedCustomRoleName {
    param(
        [string]$BaseName,
        [string]$Scope
    )

    $normalizedScope = $Scope.Trim().TrimEnd('/').ToLowerInvariant()
    $scopeHash = Get-StableHashSuffix -Value $normalizedScope -Length 10

    return "$BaseName - $scopeHash"
}

function Get-PolicyExemptionRoleName {
    param([string]$Scope)

    return Get-ScopedCustomRoleName -BaseName $POLICY_EXEMPTION_ROLE_NAME -Scope $Scope
}

function Find-CustomRoleDefinition {
    param(
        [string]$RoleName,
        [string[]]$Scopes
    )

    foreach ($lookupScope in $Scopes) {
        $role = Get-AzRoleDefinition `
            -Name $RoleName `
            -Scope $lookupScope `
            -SkipClientSideScopeValidation `
            -WarningAction SilentlyContinue `
            -ErrorAction SilentlyContinue
        if ($role) {
            return $role
        }
    }

    return $null
}

function Test-RoleDefinitionConflict {
    param($ErrorRecord)

    $statusCode = $ErrorRecord.Exception.Response.StatusCode
    return $statusCode -eq 409 -or $statusCode.value__ -eq 409 -or $ErrorRecord.Exception.Message -match '(?i)\bConflict\b'
}

function Ensure-SpottoCustomRoleAssignments {
    param(
        [string]$RoleName,
        [string]$Description,
        [string[]]$Actions,
        [string[]]$Scopes,
        [string]$PrincipalId,
        [switch]$RejectUnexpectedActions,
        [switch]$RejectUnexpectedScopes
    )

    $normalizedScopes = @($Scopes |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().TrimEnd('/') } |
        Sort-Object -Unique)
    if ($normalizedScopes.Count -eq 0) {
        return [PSCustomObject]@{ Status = "skipped"; Created = 0; Existing = 0; Failed = 0 }
    }

    try {
        $role = Find-CustomRoleDefinition -RoleName $RoleName -Scopes $normalizedScopes
        if (-not $role) {
            try {
                $role = New-AzRoleDefinition -Role @{
                    Name = $RoleName
                    Description = $Description
                    Actions = @($Actions)
                    AssignableScopes = $normalizedScopes
                }
                Write-Success "Created custom role '$RoleName'."
            } catch {
                if (-not (Test-RoleDefinitionConflict -ErrorRecord $_)) {
                    throw
                }

                Write-Info "Custom role '$RoleName' exists but is still propagating. Waiting for Azure to return it."
                for ($attempt = 1; $attempt -le 12 -and -not $role; $attempt++) {
                    Start-Sleep -Seconds 5
                    $role = Find-CustomRoleDefinition -RoleName $RoleName -Scopes $normalizedScopes
                }
                if (-not $role) {
                    throw
                }
            }
        }

        if ($role) {
            $unexpectedActions = @($role.Actions |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $Actions -notcontains $_ })
            $unexpectedDataActions = @($role.DataActions |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $unexpectedNotActions = @($role.NotActions |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $unexpectedNotDataActions = @($role.NotDataActions |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($RejectUnexpectedActions -and ($unexpectedActions.Count -gt 0 -or $unexpectedDataActions.Count -gt 0 -or $unexpectedNotActions.Count -gt 0 -or $unexpectedNotDataActions.Count -gt 0)) {
                Write-Error-Custom "Custom role '$RoleName' contains permissions or exclusions outside the requested Spotto action set."
                Write-Info "Review the existing role manually. The script will not extend or assign a broader role to additional scopes."
                return [PSCustomObject]@{ Status = "failed"; Created = 0; Existing = 0; Failed = $normalizedScopes.Count }
            }

            $normalizedExistingScopes = @($role.AssignableScopes |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim().TrimEnd('/') } |
                Sort-Object -Unique)
            $unexpectedScopes = @($normalizedExistingScopes |
                Where-Object { $normalizedScopes -notcontains $_ })
            if ($RejectUnexpectedScopes -and $unexpectedScopes.Count -gt 0) {
                Write-Error-Custom "Custom role '$RoleName' contains an unexpected assignable scope."
                Write-Info "Review the existing role manually. Each inherited-assignment role must remain bound to one exact management group."
                return [PSCustomObject]@{ Status = "failed"; Created = 0; Existing = 0; Failed = $normalizedScopes.Count }
            }

            $mergedActions = @(@($role.Actions) + $Actions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            $mergedScopes = @($normalizedExistingScopes + $normalizedScopes | Sort-Object -Unique)
            $actionsChanged = @(Compare-Object -ReferenceObject @($role.Actions | Sort-Object) -DifferenceObject @($mergedActions | Sort-Object)).Count -gt 0
            $scopesChanged = @(Compare-Object -ReferenceObject @($normalizedExistingScopes | Sort-Object) -DifferenceObject @($mergedScopes | Sort-Object)).Count -gt 0
            if ($actionsChanged -or $scopesChanged) {
                $role.Actions = $mergedActions
                $role.AssignableScopes = $mergedScopes
                $role.Description = $Description
                Set-AzRoleDefinition -Role $role | Out-Null
                Write-Success "Updated custom role '$RoleName' without removing existing actions or scopes."
                Start-Sleep -Seconds 5
            } else {
                Write-Info "Custom role '$RoleName' already has the requested actions and scopes."
            }
        }
    } catch {
        Write-Error-Custom "Failed to create or reconcile custom role '$RoleName': $_"
        Write-Info "Creating custom roles requires Owner or equivalent role-definition permissions at the definition scope."
        return [PSCustomObject]@{ Status = "failed"; Created = 0; Existing = 0; Failed = $normalizedScopes.Count }
    }

    $created = 0
    $existing = 0
    $failed = 0
    $roleDefinitionId = ([string]$role.Id).Trim().TrimEnd('/').Split('/')[-1]
    if ([string]::IsNullOrWhiteSpace($roleDefinitionId)) {
        Write-Error-Custom "Custom role '$RoleName' did not return a usable role definition ID."
        return [PSCustomObject]@{ Status = "failed"; Created = 0; Existing = 0; Failed = $normalizedScopes.Count }
    }
    foreach ($scope in $normalizedScopes) {
        try {
            $assignment = Get-AzRoleAssignment `
                -ObjectId $PrincipalId `
                -RoleDefinitionId $roleDefinitionId `
                -Scope $scope `
                -AtScope `
                -SkipClientSideScopeValidation `
                -ErrorAction SilentlyContinue
            if ($assignment) {
                Write-Info "Custom role '$RoleName' is already assigned at $scope."
                $existing++
            } else {
                $assignmentCreated = $false
                $assignmentAlreadyExists = $false
                for ($attempt = 1; $attempt -le 12 -and -not $assignmentCreated; $attempt++) {
                    try {
                        New-AzRoleAssignment `
                            -ObjectId $PrincipalId `
                            -RoleDefinitionId $roleDefinitionId `
                            -Scope $scope `
                            -SkipClientSideScopeValidation | Out-Null
                        $assignmentCreated = $true
                    } catch {
                        if ($_.Exception.Message -match '(?i)(RoleAssignmentExists|role assignment already exists)') {
                            $assignmentAlreadyExists = $true
                            $assignmentCreated = $true
                        } elseif ($attempt -eq 12 -or $_.Exception.Message -notmatch '(?i)(cannot find role definition|could not be found|not found)') {
                            throw
                        } else {
                            Start-Sleep -Seconds 5
                        }
                    }
                }
                if ($assignmentAlreadyExists) {
                    Write-Info "Custom role '$RoleName' is already assigned at $scope."
                    $existing++
                } else {
                    Write-Success "Assigned '$RoleName' at $scope."
                    $created++
                }
            }
        } catch {
            Write-Error-Custom "Failed to assign '$RoleName' at ${scope}: $_"
            Write-Info "Role assignment requires Owner, User Access Administrator, or Role Based Access Control Administrator at that scope."
            $failed++
        }
    }

    $status = if ($failed -eq 0) { "processed" } elseif (($created + $existing) -gt 0) { "partial" } else { "failed" }
    return [PSCustomObject]@{ Status = $status; Created = $created; Existing = $existing; Failed = $failed }
}

function Select-PolicyAssignmentManagementGroupScopes {
    try {
        $managementGroups = @(Get-AzManagementGroup -ErrorAction Stop |
            Sort-Object @{ Expression = { $_.DisplayName } }, @{ Expression = { $_.Name } } |
            Select-Object -First 50)
    } catch {
        Write-Error-Custom "Visible management groups could not be listed: $_"
        Write-Info "Continue without inherited-assignment access, then rerun after management-group visibility is available."
        return @()
    }

    if ($managementGroups.Count -eq 0) {
        Write-Warning-Custom "No visible management groups are available for selection."
        return @()
    }

    Write-Info "Select only management groups that own inherited initiatives Spotto must exempt."
    for ($index = 0; $index -lt $managementGroups.Count; $index++) {
        $group = $managementGroups[$index]
        $label = if ([string]::IsNullOrWhiteSpace($group.DisplayName)) { $group.Name } else { $group.DisplayName }
        Write-Host "  $($index + 1). $label ($($group.Name))" -ForegroundColor White
    }

    while ($true) {
        $selection = Read-Host "Enter management group numbers or ranges (for example 1,3,5-9), or press Enter for none"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return @()
        }

        # Selecting every policy-assignment scope must remain an explicit, deliberate choice.
        $resolvedSelection = ConvertFrom-IndexedSelection -Selection $selection -MaxValue $managementGroups.Count -AllowAll $false
        if (-not $resolvedSelection.IsValid) {
            Write-Error-Custom "Invalid selection. Enter numbers or ranges between 1 and $($managementGroups.Count); 'all' is not accepted here."
            continue
        }

        return @($resolvedSelection.Indexes | ForEach-Object {
            $group = $managementGroups[$_ - 1]
            if ($group.Id -match '^/providers/Microsoft.Management/managementGroups/[^/]+$') {
                $group.Id
            } else {
                "/providers/Microsoft.Management/managementGroups/$($group.Name)"
            }
        })
    }
}

Write-Header -Message "Step 13 of 13: Optional Write Permissions"

Write-SectionLabel "Optional write capabilities"
Write-NumberedStep -Number 1 -Message "Dismiss Azure Advisor recommendations."
Write-NumberedStep -Number 2 -Message "Enable Storage Inventory reports."
Write-Host ""

$grantWritePerms = Get-SetupCapabilityResponse `
    -Capability "Advisor and Storage Inventory write permissions" `
    -Prompt "Do you want to grant these optional write permissions?" `
    -RecommendedReadOnlyValue $false `
    -CustomDefaultYes $false

if ($grantWritePerms -eq "yes") {
    $subscriptionWriteScopes = @($selectedSubscriptions | ForEach-Object { "/subscriptions/$($_.Id)" })
    $optionalWriteRoleResults = foreach ($scope in $subscriptionWriteScopes) {
        Ensure-SpottoCustomRoleAssignments `
            -RoleName (Get-ScopedCustomRoleName -BaseName $CUSTOM_ROLE_NAME -Scope $scope) `
            -Description "Custom role for Spotto to manage Azure Advisor recommendations and Storage inventory" `
            -Actions @(
                "Microsoft.Advisor/recommendations/write",
                "Microsoft.Advisor/recommendations/suppressions/write",
                "Microsoft.Advisor/recommendations/suppressions/delete",
                "Microsoft.Storage/storageAccounts/inventoryPolicies/write",
                "Microsoft.Storage/storageAccounts/inventoryPolicies/read"
            ) `
            -Scopes @($scope) `
            -PrincipalId $sp.Id `
            -RejectUnexpectedActions `
            -RejectUnexpectedScopes
    }
    $optionalWriteCreated = [int](($optionalWriteRoleResults | Measure-Object -Property Created -Sum).Sum)
    $optionalWriteExisting = [int](($optionalWriteRoleResults | Measure-Object -Property Existing -Sum).Sum)
    $optionalWriteFailed = [int](($optionalWriteRoleResults | Measure-Object -Property Failed -Sum).Sum)
    $optionalWriteStatus = if ($optionalWriteFailed -eq 0) { "processed" } elseif (($optionalWriteCreated + $optionalWriteExisting) -gt 0) { "partial" } else { "failed" }
    $script:optionalWriteRoleResult = [PSCustomObject]@{
        Status = $optionalWriteStatus
        Created = $optionalWriteCreated
        Existing = $optionalWriteExisting
        Failed = $optionalWriteFailed
    }
    Write-Info "Summary: $($script:optionalWriteRoleResult.Created) new assignments, $($script:optionalWriteRoleResult.Existing) already existed, $($script:optionalWriteRoleResult.Failed) failed"
} else {
    Write-Info "Skipping optional write permissions"
}

Write-SectionLabel "Azure Policy exemption capability (separate consent)"
Write-DetailRow -Label "Target action" -Value "Microsoft.Authorization/policyExemptions/write at selected subscriptions/resources."
Write-DetailRow -Label "Assignment action" -Value "Microsoft.Authorization/policyAssignments/exempt/action at the policy assignment scope."
Write-Info "This does not grant policy assignment, definition, remediation, or exemption-delete permissions."
$grantPolicyExemptionPerms = Get-SetupCapabilityResponse `
    -Capability "Azure Policy exemption write permissions" `
    -Prompt "Do you want to grant subscription policy exemption permissions?" `
    -RecommendedReadOnlyValue $false `
    -CustomDefaultYes $false
$script:policyExemptionRoleResult = [PSCustomObject]@{ Status = "skipped"; Created = 0; Existing = 0; Failed = 0 }
$script:policyAssignmentExemptRoleResult = [PSCustomObject]@{ Status = "skipped"; Created = 0; Existing = 0; Failed = 0 }

if ($grantPolicyExemptionPerms -eq "yes") {
    $subscriptionPolicyScopes = @($selectedSubscriptions | ForEach-Object { "/subscriptions/$($_.Id)" })
    $subscriptionPolicyRoleResults = foreach ($scope in $subscriptionPolicyScopes) {
        Ensure-SpottoCustomRoleAssignments `
            -RoleName (Get-PolicyExemptionRoleName -Scope $scope) `
            -Description "Custom role for Spotto to create narrowly scoped Azure Policy exemptions" `
            -Actions @(
                "Microsoft.Authorization/policyExemptions/write",
                "Microsoft.Authorization/policyAssignments/exempt/action"
            ) `
            -Scopes @($scope) `
            -PrincipalId $sp.Id `
            -RejectUnexpectedActions `
            -RejectUnexpectedScopes
    }
    $subscriptionPolicyCreated = [int](($subscriptionPolicyRoleResults | Measure-Object -Property Created -Sum).Sum)
    $subscriptionPolicyExisting = [int](($subscriptionPolicyRoleResults | Measure-Object -Property Existing -Sum).Sum)
    $subscriptionPolicyFailed = [int](($subscriptionPolicyRoleResults | Measure-Object -Property Failed -Sum).Sum)
    $subscriptionPolicyStatus = if ($subscriptionPolicyFailed -eq 0) {
        "processed"
    } elseif (($subscriptionPolicyCreated + $subscriptionPolicyExisting) -gt 0) {
        "partial"
    } else {
        "failed"
    }
    $script:policyExemptionRoleResult = [PSCustomObject]@{
        Status = $subscriptionPolicyStatus
        Created = $subscriptionPolicyCreated
        Existing = $subscriptionPolicyExisting
        Failed = $subscriptionPolicyFailed
    }

    Write-Host ""
    Write-Info "Initiatives inherited from a management group need the assignment action at that exact management-group scope."
    $grantInheritedPolicyExemptions = Get-SetupCapabilityResponse `
        -Capability "inherited Azure Policy assignment write scopes" `
        -Prompt "Do you want to select management-group assignment scopes now?" `
        -RecommendedReadOnlyValue $false `
        -CustomDefaultYes $false
    if ($grantInheritedPolicyExemptions -eq "yes") {
        $managementGroupScopes = @(Select-PolicyAssignmentManagementGroupScopes)
        if ($managementGroupScopes.Count -gt 0) {
            Write-SectionLabel "Confirm inherited-assignment scopes"
            foreach ($scope in $managementGroupScopes) {
                Write-DetailRow -Label "Scope" -Value $scope
            }
            Write-DetailRow -Label "Only action" -Value "Microsoft.Authorization/policyAssignments/exempt/action"
            $confirmManagementGroupScopes = Get-SetupCapabilityResponse `
                -Capability "the selected management-group policy assignment action" `
                -Prompt "Grant this action at the listed scopes?" `
                -RecommendedReadOnlyValue $false `
                -CustomDefaultYes $false
            if ($confirmManagementGroupScopes -eq "yes") {
                $managementGroupRoleResults = foreach ($scope in $managementGroupScopes) {
                    # Azure allows only one management group in a custom role's assignable scopes.
                    Ensure-SpottoCustomRoleAssignments `
                        -RoleName (Get-PolicyExemptionRoleName -Scope $scope) `
                        -Description "Allows Spotto to exempt explicitly selected inherited Azure Policy assignments" `
                        -Actions @("Microsoft.Authorization/policyAssignments/exempt/action") `
                        -Scopes @($scope) `
                        -PrincipalId $sp.Id `
                        -RejectUnexpectedActions `
                        -RejectUnexpectedScopes
                }
                $createdAssignments = [int](($managementGroupRoleResults | Measure-Object -Property Created -Sum).Sum)
                $existingAssignments = [int](($managementGroupRoleResults | Measure-Object -Property Existing -Sum).Sum)
                $failedAssignments = [int](($managementGroupRoleResults | Measure-Object -Property Failed -Sum).Sum)
                $processedAssignments = $createdAssignments + $existingAssignments
                $aggregateStatus = if ($failedAssignments -eq 0) {
                    "processed"
                } elseif ($processedAssignments -gt 0) {
                    "partial"
                } else {
                    "failed"
                }
                $script:policyAssignmentExemptRoleResult = [PSCustomObject]@{
                    Status = $aggregateStatus
                    Created = $createdAssignments
                    Existing = $existingAssignments
                    Failed = $failedAssignments
                }
            } else {
                Write-Info "Management-group policy assignment access was not granted."
            }
        }
    }
} else {
    Write-Info "Skipping Azure Policy exemption permissions. Regulatory compliance remains read-only."
}

# ============================================================================
# SUMMARY & CREDENTIALS
# ============================================================================

Write-Header -Message "Setup Complete" -Subtitle "Review the results, then copy the credentials into Spotto"

Write-Success "Service Principal: $script:appDisplayName ($script:clientId)"
if ($script:usedSubscriptionReaderFallback) {
    Write-Success "Reader role processed separately on all $($selectedSubscriptions.Count) subscription(s) after tenant-root fallback"
} elseif ($script:useTenantRootReader) {
    switch ($script:rootReaderAssignmentStatus) {
        "created" { Write-Success "Reader role assigned at tenant root scope (/), covering all subscriptions" }
        "existing" { Write-Success "Reader role already existed at tenant root scope (/), covering all subscriptions" }
        "failed" { Write-Error-Custom "Reader role was not assigned at tenant root scope (/)" }
        default { Write-Skipped "Reader role at tenant root scope (/) was not processed" }
    }
} else {
    Write-Success "Reader role processed on $($selectedSubscriptions.Count) selected subscription(s)"
}
switch ($script:subscriptionMonitoringReaderStatus) {
    "processed" { Write-Success "Monitoring Reader processed on selected subscription(s)" }
    "failed" { Write-Error-Custom "Monitoring Reader was not assigned on every selected subscription" }
    "skipped" { Write-Skipped "Monitoring Reader skipped (optional)" }
    default { Write-Skipped "Monitoring Reader was not processed on selected subscriptions" }
}
switch ($script:subscriptionSecurityReaderStatus) {
    "processed" { Write-Success "Security Reader processed on selected subscription(s)" }
    "failed" { Write-Error-Custom "Security Reader was not assigned on every selected subscription" }
    "skipped" { Write-Skipped "Security Reader skipped (optional)" }
    default { Write-Skipped "Security Reader was not processed on selected subscriptions" }
}
switch ($script:subscriptionLogAnalyticsReaderStatus) {
    "processed" { Write-Success "Log Analytics Reader processed on selected subscription(s)" }
    "failed" { Write-Error-Custom "Log Analytics Reader was not assigned on every selected subscription" }
    "skipped" { Write-Skipped "Log Analytics Reader skipped (optional)" }
    default { Write-Skipped "Log Analytics Reader was not processed on selected subscriptions" }
}
Write-ManagementGroupRoleSummary -Status $script:managementGroupAzureReaderStatus -RoleLabel "Reader on management groups"
Write-ManagementGroupRoleSummary -Status $script:managementGroupReaderStatus -RoleLabel "Management Group Reader"
Write-ManagementGroupRoleSummary -Status $script:managementGroupMonitoringReaderStatus -RoleLabel "Monitoring Reader on management groups"
Write-ManagementGroupRoleSummary -Status $script:managementGroupLogAnalyticsReaderStatus -RoleLabel "Log Analytics Reader on management groups"
if ($script:keyVaultReaderStatus -eq "failed") {
    Write-Error-Custom "Key Vault Reader was not processed across every selected scope"
} elseif ($script:keyVaultReaderScope -eq "tenant-root-management-group") {
    Write-Success "Key Vault Reader processed at the tenant-root management group, covering current and future child subscriptions"
} elseif ($script:usedSubscriptionKeyVaultReaderFallback) {
    Write-Success "Key Vault Reader processed on all $($selectedSubscriptions.Count) subscription(s) after management-group fallback"
} elseif ($script:keyVaultReaderStatus -eq "processed") {
    Write-Success "Key Vault Reader processed on $($selectedSubscriptions.Count) selected subscription(s)"
} else {
    Write-Error-Custom "Key Vault Reader was not processed across the selected scope"
}
switch ($script:reservationReaderStatus) {
    "created" { Write-Success "Reservations Reader assigned at /providers/Microsoft.Capacity" }
    "existing" { Write-Success "Reservations Reader already existed at /providers/Microsoft.Capacity" }
    "failed" { Write-Error-Custom "Reservations Reader was not assigned at /providers/Microsoft.Capacity" }
    "skipped" { Write-Skipped "Reservations Reader skipped" }
    default { Write-Skipped "Reservations Reader was not processed" }
}
switch ($script:reservationContributorStatus) {
    "created" { Write-Success "Reservations Contributor assigned at /providers/Microsoft.Capacity" }
    "existing" { Write-Success "Reservations Contributor already existed at /providers/Microsoft.Capacity" }
    "failed" { Write-Error-Custom "Reservations Contributor was not assigned at /providers/Microsoft.Capacity" }
    "skipped" { Write-Skipped "Reservations Contributor skipped (optional)" }
    default { Write-Skipped "Reservations Contributor was not processed" }
}
switch ($script:savingsPlanReaderStatus) {
    "created" { Write-Success "Savings plan Reader assigned at /providers/Microsoft.BillingBenefits" }
    "existing" { Write-Success "Savings plan Reader already existed at /providers/Microsoft.BillingBenefits" }
    "failed" { Write-Error-Custom "Savings plan Reader was not assigned at /providers/Microsoft.BillingBenefits" }
    "skipped" { Write-Skipped "Savings plan Reader skipped" }
    default { Write-Skipped "Savings plan Reader was not processed" }
}
switch ($script:graphPermissionStatus) {
    "created" { Write-Success "Microsoft Graph governance permissions granted for tenant policy, licensing, Global Admin/PIM, audit, and posture visibility ($script:graphPermissionSummary)" }
    "existing" { Write-Success "Microsoft Graph governance permissions already existed for tenant policy, licensing, Global Admin/PIM, audit, and posture visibility ($script:graphPermissionSummary)" }
    "processed" { Write-Success "Microsoft Graph governance permissions processed for tenant policy, licensing, Global Admin/PIM, audit, and posture visibility ($script:graphPermissionSummary)" }
    "partial" { Write-Warning-Custom "Microsoft Graph governance permissions were only partially granted ($script:graphPermissionSummary)" }
    "failed" { Write-Error-Custom "Microsoft Graph governance permissions were not fully granted" }
    "skipped" { Write-Skipped "Microsoft Graph governance permissions skipped" }
    default { Write-Skipped "Microsoft Graph governance permissions were not processed" }
}
switch ($script:billingExportSetupStatus) {
    "complete" { Write-Success "Cost Management billing export setup completed for every attempted export" }
    "partial" { Write-Warning-Custom "Cost Management billing export setup completed only partially; review the named export failures below" }
    "failed" { Write-Error-Custom "Cost Management billing export setup failed; review the named targets and remediation below" }
    "skipped" { Write-Skipped "Cost Management billing export setup skipped (rerun and accept the billing export option to enable)" }
    default { Write-Skipped "Cost Management billing export setup was not processed" }
}
switch ($script:billingScopeExportStatus) {
    "processed" { Write-Success "Billing-scope export discovery processed" }
    "skipped" { Write-Skipped "Billing-scope export discovery skipped" }
    default { Write-Skipped "Billing-scope export discovery was not processed" }
}
if ($script:billingExportResults.Count -gt 0) {
    $unavailableBillingExports = @($script:billingExportResults | Where-Object { $_.Status -eq "unavailable" })
    $failedBillingExports = @($script:billingExportResults | Where-Object {
        $_.Status -ne "unavailable" -and $_.Status -notin $BILLING_EXPORT_SUCCESS_STATUSES
    })
    $processedBillingExports = @($script:billingExportResults | Where-Object { $_.Status -in $BILLING_EXPORT_SUCCESS_STATUSES })
    $billingDestinations = @($script:billingExportResults |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.StorageAccountId) } |
        Select-Object -Property StorageAccountId, ContainerName -Unique)

    Write-Host ""
    Write-SectionLabel "Billing export summary"
    Write-DetailRow -Label "Processed" -Value "$($processedBillingExports.Count) export operation(s)"
    Write-DetailRow -Label "Unavailable" -Value "$($unavailableBillingExports.Count) export operation(s)"
    Write-DetailRow -Label "Failures" -Value "$($failedBillingExports.Count) export operation(s)"
    foreach ($destination in ($billingDestinations | Select-Object -First 5)) {
        Write-DetailRow -Label "Storage" -Value "$($destination.StorageAccountId) / containers/$($destination.ContainerName)"
    }
    if ($billingDestinations.Count -gt 5) {
        Write-Info "Additional billing export storage destinations are listed in the transcript."
    }
    if ($unavailableBillingExports.Count -gt 0) {
        Write-Warning-Custom "Some export operations are unavailable for this Azure agreement/scope."
        foreach ($unavailableExport in ($unavailableBillingExports | Select-Object -First 5)) {
            Write-Warning-Custom "$($unavailableExport.SubscriptionName) $($unavailableExport.DatasetType) $($unavailableExport.ExportKind): $($unavailableExport.Message)"
        }
    }
    if ($failedBillingExports.Count -gt 0) {
        Write-Info "Remediation: correct the reported Azure permission, policy, quota, storage, or scope issue and rerun Custom setup. Existing successful exports are reused."
        foreach ($failedExport in ($failedBillingExports | Select-Object -First 5)) {
            Write-Error-Custom "$($failedExport.SubscriptionName) $($failedExport.DatasetType) $($failedExport.ExportKind): $($failedExport.Message)"
        }
    }
}
if ($grantWritePerms -eq "yes") {
    Write-Success "Custom role with write permissions created and assigned"
}
switch ($script:policyExemptionRoleResult.Status) {
    "processed" { Write-Success "Subscription Azure Policy exemption permissions processed" }
    "partial" { Write-Warning-Custom "Subscription Azure Policy exemption permissions were only partially assigned" }
    "failed" { Write-Error-Custom "Subscription Azure Policy exemption permissions were not assigned" }
    default { Write-Skipped "Subscription Azure Policy exemption permissions skipped (optional)" }
}
switch ($script:policyAssignmentExemptRoleResult.Status) {
    "processed" { Write-Success "Inherited policy assignment exempt scopes processed" }
    "partial" { Write-Warning-Custom "Inherited policy assignment exempt scopes were only partially assigned" }
    "failed" { Write-Error-Custom "Inherited policy assignment exempt scopes were not assigned" }
    default { Write-Skipped "Inherited policy assignment exempt scopes skipped (optional)" }
}
Write-Host ""
Write-Host "Propagation note:" -ForegroundColor Yellow
if ($script:graphPermissionStatus -in @("created", "existing", "processed", "partial")) {
    Write-Host "  Azure RBAC changes and Microsoft Graph admin consent can take 5-15 minutes to apply." -ForegroundColor Yellow
    Write-Host "  During that time, Spotto may validate the account or list subscriptions while Global Admin/PIM, audit, or governance data still shows access denied." -ForegroundColor Yellow
    Write-Host "  If that happens, wait a few minutes and rerun validation or retry the tenant sync." -ForegroundColor Yellow
} else {
    Write-Host "  Azure RBAC changes can take 5-15 minutes to apply." -ForegroundColor Yellow
    Write-Host "  Microsoft Graph governance permissions were not granted, so tenant policy, licensing, Global Admin/PIM, audit, group, user, and posture data may show access denied." -ForegroundColor Yellow
    Write-Host "  You can grant Graph consent manually or rerun this script and choose yes for Step 11." -ForegroundColor Yellow
}

# Stop logging before showing credentials so the client secret is not written to the transcript.
Write-Host ""
Write-Info "Stopping transcript before showing credentials. Client secrets are intentionally not written to the setup log."
Stop-Transcript | Out-Null

# Create a planned secret only now, then immediately persist the versioned UI handoff.
# If protected-file creation fails, the exact new Azure credential is rolled back.
try {
    Complete-SpottoClientSecretHandoff -Application $app | Out-Null
} catch {
    Write-Error-Custom $_.Exception.Message
    if ($script:isNewSecret -and -not [string]::IsNullOrWhiteSpace($script:clientSecret)) {
        Write-Warning-Custom "Emergency recovery: the Azure credential remains active because exact rollback was not possible. Copy it now, then remove or rotate it after access is restored."
        Show-Credentials
    }
    Read-Host "Press Enter to exit"
    exit 1
}

# Display credentials for copy/paste
Show-Credentials

Show-NextSteps

if ($script:onboardingJsonPath) {
    Remove-OnboardingJsonAfterConfirmedImport -Path $script:onboardingJsonPath | Out-Null
}

Write-Host "For support, visit: https://docs.spotto.ai`n"

# Keep credentials visible
Read-Host "Press Enter to exit"
