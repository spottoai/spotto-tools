<#
.SYNOPSIS
    Sets up Azure service principal with appropriate permissions for Spotto AI.

.DESCRIPTION
    This script creates a service principal, assigns the governance and billing permissions Spotto
    uses to analyze your Azure environment, recommends billing exports to reduce billing API calls,
    and optionally grants recommended monitoring roles and specific write permissions.
    
    Permissions granted:
    - Reader role at tenant root scope when all subscriptions are selected
      (inherits to all current and future subscriptions in the tenant)
    - Reader role on selected subscriptions when specific subscriptions are chosen
    - Optional: Monitoring Reader role on selected subscriptions (includes Microsoft.Insights/Components/Query/Read)
    - Optional: Log Analytics Reader role
      (assigned at the root management group when all subscriptions are selected,
       otherwise on selected subscriptions)
      (includes workspace query access plus broader monitoring read access)
    - Management Group Reader at the root management group
      (read management group hierarchy plus management-group policy and RBAC metadata)
    - Reservations Reader at /providers/Microsoft.Capacity
    - Savings plan Reader at /providers/Microsoft.BillingBenefits
    - Optional prompt: Application.Read.All in Microsoft Graph with admin consent
      (read applications and service principals for governance and credential posture)
    - Highly recommended: Cost Management exports to customer-owned Azure Storage
      (daily actual/amortized exports plus one-time historical backfill where supported)
    - Optional: Custom role for dismissing Azure Advisor recommendations
    - Optional: Custom role for enabling Storage Inventory Reports
    
    This script is idempotent - it can be run multiple times safely.

.NOTES
    Prerequisites:
    - PowerShell 5.1 or PowerShell 7+
    - Azure PowerShell module (will be installed if missing)
    - Microsoft Graph PowerShell module if granting Application.Read.All (will be installed if missing)
    - Global Administrator, Application Administrator, or appropriate permissions to create service principals
    - Owner or User Access Administrator on subscriptions, or at tenant root scope (/)
    - Tenant admin consent for Microsoft Graph Application.Read.All if granting Graph governance permissions
    - Management Group Contributor or Owner role for management group access
    - If assigning Reader at tenant root scope (/), Global Administrators typically need
      to enable Microsoft Entra ID > Properties > Access management for Azure resources
      and then sign out and sign back in before running this script
    
.EXAMPLE
    .\Setup-SpottoAzure.ps1
#>

# Script configuration
$ErrorActionPreference = "Stop"
$APP_NAME = "Spotto AI"
$CUSTOM_ROLE_NAME = "Spotto Access"
$BILLING_EXPORT_CONTAINER_NAME = "spotto-cost-exports"
$BILLING_EXPORT_ROOT_PATH = "spotto"
$BILLING_EXPORT_DEFAULT_LOCATION = "australiaeast"
$COST_EXPORT_API_VERSION = "2025-03-01"
$SPOTTO_BACKFILL_QUEUED_PREFIX = "Spotto backfill queued"
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
    Write-Host "  Creates the service principal and assigns the Azure access Spotto needs." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Safe to rerun:" -ForegroundColor Green -NoNewline
    Write-Host " existing apps, secrets, and role assignments are reused where possible." -ForegroundColor White
    Write-Host "  Transcript: $TranscriptPath" -ForegroundColor DarkGray
    Write-Host ("=" * $script:ConsolePanelWidth) -ForegroundColor Cyan
    Write-Host ""
}

Show-StartupSplash -TranscriptPath $logPath

# ============================================================================
# CHECK AND INSTALL REQUIRED MODULES
# ============================================================================

function Ensure-PowerShellModules {
    param(
        [object[]]$Modules,
        [string]$ModuleSetName,
        [string[]]$ManualInstallCommands,
        [bool]$Required = $true
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

        $install = Read-Host "`nWould you like to install missing $ModuleSetName modules now? (yes/no, default no)"

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
) -Required $true | Out-Null

# Global variables to track credentials
$script:clientId = $null
$script:tenantId = $null
$script:clientSecret = $null
$script:secretExpiry = $null
$script:isNewSecret = $false
$script:useTenantRootReader = $false
$script:rootManagementGroup = $null
$script:rootReaderAssignmentStatus = "not-applicable"
$script:rootManagementGroupReaderStatus = "not-run"
$script:managementGroupReaderStatus = "not-run"
$script:logAnalyticsReaderStatus = "not-run"
$script:reservationReaderStatus = "not-run"
$script:savingsPlanReaderStatus = "not-run"
$script:graphPermissionStatus = "not-run"
$script:billingExportSetupStatus = "not-run"
$script:billingExportResults = @()

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
    Write-PanelTitle -Title "SPOTTO CREDENTIALS" -Subtitle "Copy these values into the Spotto Portal" -Color Yellow
    Write-Host ""
    Write-DetailRow -Label "Application (Client) ID" -Value $script:clientId -ValueColor Green
    Write-DetailRow -Label "Directory (Tenant) ID" -Value $script:tenantId -ValueColor Green
    Write-DetailRow -Label "Client Secret" -Value $script:clientSecret -ValueColor Green
    Write-DetailRow -Label "Secret Expiry Date" -Value $script:secretExpiry -ValueColor Green
    Write-Host ""
    if ($script:isNewSecret) {
        Write-Host "⚠ IMPORTANT: This secret will not be shown again! Save it now." -ForegroundColor Red
    }
    Write-Divider -Color Yellow
    Write-Host ""
}

function Show-NextSteps {
    Write-PanelTitle -Title "NEXT STEPS" -Subtitle "Finish the connection in Spotto" -Color Cyan
    Write-Host ""
    Write-NumberedStep -Number 1 -Message "Copy the credentials shown above."
    Write-NumberedStep -Number 2 -Message "Go to the Spotto Portal: https://portal.spotto.ai"
    Write-NumberedStep -Number 3 -Message "Navigate to: Connectors > Cloud Accounts"
    Write-NumberedStep -Number 4 -Message "Add a cloud account and paste the credentials into the form."
    Write-NumberedStep -Number 5 -Message "Click 'Validate Credentials', then click 'Create'."
    Write-Host ""
    Write-Info "It is safe to rerun this script later if validation needs more time or access changes."
    Write-Host ""
    Write-Divider -Color Cyan
    Write-Host ""
}

function Set-SubscriptionContext {
    param([object]$Subscription)

    if (-not $Subscription -or -not $Subscription.Id) {
        Write-Error-Custom "Subscription details were missing. Unable to set context."
        return $false
    }

    $tenantId = $Subscription.TenantId
    try {
        Set-AzContext -SubscriptionId $Subscription.Id -TenantId $tenantId | Out-Null
        return $true
    } catch {
        Write-Info "Re-authentication required for tenant $tenantId. You may see an MFA prompt."
        try {
            if ($tenantId) {
                Connect-AzAccount -TenantId $tenantId | Out-Null
            } else {
                Connect-AzAccount | Out-Null
            }
            Set-AzContext -SubscriptionId $Subscription.Id -TenantId $tenantId | Out-Null
            return $true
        } catch {
            Write-Error-Custom "Failed to set context for $($Subscription.Name): $_"
            if ($tenantId) {
                Write-Info "Try: Connect-AzAccount -TenantId $tenantId"
            }
            return $false
        }
    }
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
            }
        }
    }

    Write-Info "Summary: $successCount new assignments, $skipCount already existed, $failureCount failed"
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
        Write-Error-Custom "Failed to assign Reader role at tenant root scope (/): $_"

        if ($_.Exception.Message -match "Forbidden|AuthorizationFailed|does not have authorization") {
            Write-Info "This requires Owner or User Access Administrator at tenant root scope (/)."
            Write-Info "If you are a Global Administrator, enable Microsoft Entra ID > Properties > Access management for Azure resources."
            Write-Info "After enabling it, sign out, sign back in, and rerun the script."
        }

        Write-Info "If you cannot get root-scope access, rerun the script and choose specific subscriptions to use per-subscription Reader assignments."
        return "failed"
    }
}

function Resolve-RootManagementGroup {
    param([string]$TenantId)

    if ($script:rootManagementGroup) {
        return $script:rootManagementGroup
    }

    $rootManagementGroup = $null

    try {
        $rootManagementGroup = Get-AzManagementGroup -GroupName $TenantId -ErrorAction SilentlyContinue

        if (-not $rootManagementGroup) {
            $managementGroups = @(Get-AzManagementGroup -ErrorAction Stop)
            $rootManagementGroup = $managementGroups |
                Sort-Object @{ Expression = { if ($_.Name -eq $TenantId) { 0 } else { 1 } } } |
                Where-Object { $_.Name -eq $TenantId -or [string]::IsNullOrWhiteSpace($_.ParentId) } |
                Select-Object -First 1
        }
    } catch {
        throw "Unable to query management groups for tenant $TenantId. $_"
    }

    if (-not $rootManagementGroup) {
        throw "Unable to resolve the root management group for tenant $TenantId."
    }

    $script:rootManagementGroup = $rootManagementGroup
    return $rootManagementGroup
}

function Ensure-RootManagementGroupRoleAssignment {
    param(
        [string]$PrincipalId,
        [string]$RoleDefinitionName,
        [string]$RoleLabel
    )

    try {
        $rootManagementGroup = Resolve-RootManagementGroup -TenantId $script:tenantId
        $rootManagementGroupScope = if ($rootManagementGroup.Id) {
            $rootManagementGroup.Id
        } else {
            "/providers/Microsoft.Management/managementGroups/$($rootManagementGroup.Name)"
        }
        $rootManagementGroupName = if ($rootManagementGroup.DisplayName) {
            $rootManagementGroup.DisplayName
        } elseif ($rootManagementGroup.Name) {
            $rootManagementGroup.Name
        } else {
            $script:tenantId
        }

        Write-Info "Attempting to assign $RoleLabel at the root management group..."
        Write-Info "Resolved root management group: $rootManagementGroupName"
        Write-Info "Management Group Scope: $rootManagementGroupScope"

        $existingAssignment = Get-AzRoleAssignment -ObjectId $PrincipalId -Scope $rootManagementGroupScope -RoleDefinitionName $RoleDefinitionName -ErrorAction SilentlyContinue

        if ($existingAssignment) {
            Write-Info "$RoleLabel already assigned"
            return "existing"
        }

        New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleDefinitionName -Scope $rootManagementGroupScope | Out-Null
        Write-Success "Assigned $RoleLabel at the root management group"
        return "created"
    } catch {
        Write-Error-Custom "Failed to assign ${RoleLabel}: $_"
        Write-Info "This may occur if:"
        Write-Info "  - You don't have sufficient permissions at the root management group"
        Write-Info "  - Management Groups are not enabled in your tenant"
        Write-Info "  - The root management group could not be resolved in the selected tenant"
        Write-Info "  - You need to manually assign this at the root management group in Azure Portal > Management Groups"
        return "failed"
    }
}

function Get-DefaultedInput {
    param(
        [string]$Prompt,
        [string]$DefaultValue
    )

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

function New-AvailableBillingStorageAccountName {
    param([string]$SubscriptionId)

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $suffix = ([guid]::NewGuid().ToString("N")).Substring(0, 13)
        $name = "spotto$suffix"
        if (Test-StorageAccountNameAvailable -SubscriptionId $SubscriptionId -Name $name) {
            return $name
        }
    }

    throw "Unable to generate an available storage account name. Please rerun and provide one manually."
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

function New-BillingExportStorageAccount {
    param([object[]]$Subscriptions)

    Write-SectionLabel "Storage account subscription"
    for ($i = 0; $i -lt $Subscriptions.Count; $i++) {
        Write-Host ("  [{0,2}] {1} ({2})" -f ($i + 1), $Subscriptions[$i].Name, $Subscriptions[$i].Id)
    }

    $hostSubscription = $Subscriptions[0]
    if ($Subscriptions.Count -gt 1) {
        $selectedIndex = Read-IndexedSelection -Prompt "Select subscription for the billing export storage account (1-$($Subscriptions.Count))" -MaxValue $Subscriptions.Count
        $hostSubscription = $Subscriptions[$selectedIndex]
    }

    Set-AzContext -SubscriptionId $hostSubscription.Id -TenantId $script:tenantId | Out-Null
    Ensure-ResourceProviderRegistered -SubscriptionId $hostSubscription.Id -ProviderNamespace "Microsoft.Storage" | Out-Null
    Ensure-ResourceProviderRegistered -SubscriptionId $hostSubscription.Id -ProviderNamespace "Microsoft.CostManagement" | Out-Null
    Ensure-ResourceProviderRegistered -SubscriptionId $hostSubscription.Id -ProviderNamespace "Microsoft.CostManagementExports" -MaxAttempts 60 -PollSeconds 5 | Out-Null
    $availableLocations = Get-AvailableAzureLocationNames

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
                Write-Error-Custom "Failed to create resource group '$resourceGroupName' in '$location': $($_.Exception.Message)"
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
    while (-not $storageAccountNameReady) {
        $suggestedName = New-AvailableBillingStorageAccountName -SubscriptionId $hostSubscription.Id
        $storageAccountName = Get-DefaultedInput -Prompt "Storage account name" -DefaultValue $suggestedName
        $storageAccountId = "/subscriptions/$($hostSubscription.Id)/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
        $existingStorageAccount = Get-AzResource -ResourceId $storageAccountId -ErrorAction SilentlyContinue

        if ($existingStorageAccount) {
            $storageAccountNameReady = $true
        } elseif (-not (Test-BillingStorageAccountNameFormat -Name $storageAccountName)) {
            Write-Error-Custom "Storage account name '$storageAccountName' is invalid. Use 3-24 lowercase letters and numbers only."
        } elseif (Test-StorageAccountNameAvailable -SubscriptionId $hostSubscription.Id -Name $storageAccountName) {
            $storageAccountNameReady = $true
        } else {
            Write-Error-Custom "Storage account name '$storageAccountName' is not available."
        }
    }

    if ($existingStorageAccount) {
        Write-Info "Using existing storage account $storageAccountName in $resourceGroupName"
        return [pscustomobject]@{
            ResourceId = $storageAccountId
            SubscriptionId = $hostSubscription.Id
            ResourceGroupName = $resourceGroupName
            Name = $storageAccountName
        }
    }

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
            Write-Error-Custom "Failed to create storage account '$storageAccountName' in '$storageAccountLocation': $($_.Exception.Message)"
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
    }
}

function Select-ExistingBillingStorageAccount {
    param([object[]]$Subscriptions)

    $storageAccounts = @()
    foreach ($sub in $Subscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id -TenantId $script:tenantId | Out-Null
            $resources = @(Get-AzResource -ResourceType "Microsoft.Storage/storageAccounts" -ErrorAction Stop)
            foreach ($resource in $resources) {
                $storageAccounts += [pscustomobject]@{
                    ResourceId = $resource.ResourceId
                    SubscriptionId = $sub.Id
                    ResourceGroupName = $resource.ResourceGroupName
                    Name = $resource.Name
                    SubscriptionName = $sub.Name
                }
            }
        } catch {
            Write-Info "Unable to list storage accounts in $($sub.Name): $_"
        }
    }

    if ($storageAccounts.Count -eq 0) {
        Write-Info "No existing storage accounts were found in the selected subscriptions."
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
            Write-Error-Custom "Multiple storage accounts named '$selection' were found in the selected subscriptions. Select by number instead."
            continue
        }

        Write-Error-Custom "Storage account '$selection' was not found. Select an account from the list, or press Enter to create a new one."
    }
}

function Select-BillingExportStorageAccount {
    param([object[]]$Subscriptions)

    Write-SectionLabel "Billing export storage"
    Write-OptionRow -Key "1" -Label "Create a new storage account" -Description "Recommended when no suitable export storage exists."
    Write-OptionRow -Key "2" -Label "Use an existing storage account" -Description "The script will keep anonymous access off and grant Spotto blob read access."

    $selectedOptionIndex = Read-IndexedSelection -Prompt "Select storage option (1/2)" -MaxValue 2
    if ($selectedOptionIndex -eq 1) {
        $existing = Select-ExistingBillingStorageAccount -Subscriptions $Subscriptions
        if ($existing) {
            return $existing
        }
    }

    return New-BillingExportStorageAccount -Subscriptions $Subscriptions
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

function Get-CostExportsForScope {
    param([string]$Scope)

    try {
        if ($Scope -notmatch "^/subscriptions/([^/]+)$") {
            throw "Cost export scope is not a subscription scope: $Scope"
        }

        Set-AzContext -SubscriptionId $Matches[1] -TenantId $script:tenantId | Out-Null
        return @(Get-AzResource -ResourceType "Microsoft.CostManagement/exports" -ApiVersion $COST_EXPORT_API_VERSION -ExpandProperties -ErrorAction Stop)
    } catch {
        Write-Info "Unable to list Cost Management exports at $Scope. $_"
    }

    return @()
}

function Get-CostExport {
    param(
        [string]$Scope,
        [string]$ExportName
    )

    try {
        return Get-AzResource -ResourceId (Get-CostExportResourceId -Scope $Scope -ExportName $ExportName) -ApiVersion $COST_EXPORT_API_VERSION -ExpandProperties -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-CostExportResourceId {
    param(
        [string]$Scope,
        [string]$ExportName
    )

    return "$Scope/providers/Microsoft.CostManagement/exports/$ExportName"
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

function Test-RecurringCostExportMeetsRequirements {
    param(
        [object]$Export,
        [string]$DatasetType
    )

    $properties = Get-CostExportProperties -Export $Export
    if (-not $properties) {
        return $false
    }

    $destination = $properties.deliveryInfo.destination
    $compression = $properties.compressionMode

    if ($properties.schedule.status -ne "Active") { return $false }
    if ($properties.schedule.recurrence -ne "Daily") { return $false }
    if (-not (Test-CostExportDefinitionTypeMatches -RequestedDatasetType $DatasetType -ExportDefinitionType $properties.definition.type)) { return $false }
    if ($properties.definition.timeframe -notin @("MonthToDate", "BillingMonthToDate", "TheCurrentMonth")) { return $false }
    if ($properties.format -ne "Csv") { return $false }
    if ($compression -and $compression -notin @("none", "gzip", "None", "Gzip")) { return $false }
    if (-not $destination.resourceId -or -not $destination.container) { return $false }

    return $true
}

function Test-CostExportDefinitionTypeMatches {
    param(
        [string]$RequestedDatasetType,
        [string]$ExportDefinitionType
    )

    if ($RequestedDatasetType -eq "ActualCost") {
        return $ExportDefinitionType -in @("ActualCost", "Usage")
    }

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

    return $Message -match "ActualCost" -and $Message -match "not supported"
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

function Find-ExistingRecurringBillingExports {
    param(
        [object]$Subscription,
        [string]$DatasetType
    )

    $scope = "/subscriptions/$($Subscription.Id)"
    $exports = @()

    $spottoExportName = Get-SpottoRecurringExportName -DatasetType $DatasetType
    $spottoExport = Get-CostExport -Scope $scope -ExportName $spottoExportName
    if ($spottoExport) {
        $exports += $spottoExport
    }

    $exports += @(Get-CostExportsForScope -Scope $scope)
    $uniqueExports = @($exports | Where-Object { $_ } | Sort-Object -Property ResourceId, Id, Name -Unique)
    return @($uniqueExports | Where-Object { Test-RecurringCostExportMeetsRequirements -Export $_ -DatasetType $DatasetType })
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

function New-CostExportBody {
    param(
        [string]$DatasetType,
        [string]$Timeframe,
        [string]$StorageAccountId,
        [string]$ContainerName,
        [string]$RootFolderPath,
        [hashtable]$Schedule,
        [hashtable]$TimePeriod = $null,
        [string]$ExportDescription = ""
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
            compressionMode = "gzip"
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
            New-AzResource -ResourceId $resourceId -ApiVersion $COST_EXPORT_API_VERSION -Properties $Body.properties -Force -ErrorAction Stop | Out-Null
            break
        } catch {
            $message = $_.Exception.Message

            if ($Body.properties.ContainsKey("partitionData")) {
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
    if ($TimePeriod) {
        Invoke-AzResourceAction -ResourceId $resourceId -Action "run" -ApiVersion $COST_EXPORT_API_VERSION -Parameters @{ timePeriod = $TimePeriod } -Force -ErrorAction Stop | Out-Null
    } else {
        Invoke-AzResourceAction -ResourceId $resourceId -Action "run" -ApiVersion $COST_EXPORT_API_VERSION -Force -ErrorAction Stop | Out-Null
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

    Ensure-ResourceProviderRegistered -SubscriptionId $Subscription.Id -ProviderNamespace "Microsoft.CostManagement" | Out-Null

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
            Write-Success "Using existing $datasetType daily export on $($Subscription.Name): $($existingExport.name)"
            Add-BillingExportResult -SubscriptionName $Subscription.Name -SubscriptionId $Subscription.Id -DatasetType $datasetType -ExportKind "Recurring" -ExportName $existingExport.name -Status "existing" -StorageAccountId $destination.StorageAccountId -ContainerName $destination.Container -RootFolderPath $destination.RootFolderPath
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
            $backfillDescription = if ($backfillAlreadyQueued) {
                Get-SpottoBackfillQueuedDescription -PeriodName $period.Name
            } else {
                "Spotto backfill pending $($period.Name)"
            }
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
                        Write-Warning-Custom "$DatasetType backfill export $($period.Name) was queued, but the idempotency marker could not be saved. A later rerun may queue it again. $_"
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

Write-Header -Message "Spotto AI Azure Setup" -Subtitle "Creates the service principal and assigns required Azure access"

Write-Host "You can run this script more than once. It checks for existing Spotto resources"
Write-Host "and reuses them where possible, so rerunning is the normal way to retry or update access."
Write-Host ""

Write-SectionLabel "Required access"
Write-DetailRow -Label "Service principal" -Value "Create or reuse '$APP_NAME'."
Write-DetailRow -Label "Client secret" -Value "Create a 12-month secret or use an existing credential."
Write-DetailRow -Label "Azure Reader" -Value "Assign at tenant root for all subscriptions, or on selected subscriptions."
Write-DetailRow -Label "Governance" -Value "Assign Reader and Management Group Reader at the root management group."
Write-DetailRow -Label "Billing" -Value "Assign Reservations Reader and Savings plan Reader provider-scope access."
Write-Host ""

Write-SectionLabel "Recommended and optional prompts"
Write-DetailRow -Label "Microsoft Graph" -Value "Application.Read.All admin consent for governance and credential posture."
Write-DetailRow -Label "Monitoring" -Value "Monitoring Reader and Log Analytics Reader for richer telemetry analysis."
Write-DetailRow -Label "Billing exports" -Value "Highly recommended daily exports plus 13-month backfill to reduce billing API calls."
Write-DetailRow -Label "Write permissions" -Value "Custom role for Advisor dismissals and Storage Inventory reports."
Write-Host ""

Write-SectionLabel "Important for all subscriptions"
Write-Host "  - Reader is assigned once at tenant root scope (/)." -ForegroundColor Yellow
Write-Host "  - This needs Owner or User Access Administrator at root scope." -ForegroundColor Yellow
Write-Host "  - Global Administrators usually need to enable Microsoft Entra ID > Properties >" -ForegroundColor Yellow
Write-Host "    Access management for Azure resources, then sign out and sign back in." -ForegroundColor Yellow
Write-Host "  - Microsoft Graph Application.Read.All requires tenant admin consent if granted." -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Do you want to continue? (yes/no, default yes)"
if (-not (Test-YesResponse -Value $confirmation)) {
    Write-Info "Setup cancelled by user."
    exit
}

# ============================================================================
# Step 1: Connect to Azure
# ============================================================================

Write-Header -Message "Step 1 of 13: Connect to Azure"

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

Write-Header -Message "Step 2 of 13: Select Tenant"

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

# ============================================================================
# Step 3: Select Subscriptions
# ============================================================================

Write-Header -Message "Step 3 of 13: Select Subscriptions"

$subscriptions = Get-AzSubscription -TenantId $script:tenantId
Write-Host "Found $($subscriptions.Count) subscription(s) in your tenant:`n"

if ($subscriptions.Count -eq 0) {
    Write-Error-Custom "No subscriptions were found for tenant $script:tenantId."
    exit 1
}

for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host ("  [{0,2}] {1} ({2})" -f ($i + 1), $subscriptions[$i].Name, $subscriptions[$i].Id)
}

Write-Host ""
Write-SectionLabel "Onboarding scope"
Write-OptionRow -Key "1" -Label "All subscriptions" -Description "Assign Reader once at tenant root scope (/)."
Write-OptionRow -Key "2" -Label "Specific subscriptions" -Description "Choose one or more subscriptions by number."

$selectedSubscriptions = @()
$scopeSelected = $false

while (-not $scopeSelected) {
    $selection = Read-Host "`nSelect onboarding scope (1/2)"
    $normalizedSelection = $selection.Trim().ToLowerInvariant()

    if ($normalizedSelection -in @("1", "a", "all")) {
        $selectedSubscriptions = $subscriptions
        $script:useTenantRootReader = $true
        $scopeSelected = $true
        Write-Success "Selected all $($selectedSubscriptions.Count) subscriptions"
        Write-Info "Reader access will be assigned once at tenant root scope (/)."
    } elseif ($normalizedSelection -in @("2", "s", "specific")) {
        $script:useTenantRootReader = $false

        while ($selectedSubscriptions.Count -eq 0) {
            $subscriptionSelection = Read-Host "Enter subscription numbers (comma-separated, e.g., 1,3,5)"
            $invalidSelections = @()
            $selectedSubscriptions = @()
            $seenSubscriptionIds = @{}

            foreach ($entry in ($subscriptionSelection -split ",")) {
                $subscriptionNumber = 0
                $trimmedEntry = $entry.Trim()

                if (-not [int]::TryParse($trimmedEntry, [ref]$subscriptionNumber) -or $subscriptionNumber -lt 1 -or $subscriptionNumber -gt $subscriptions.Count) {
                    $invalidSelections += $trimmedEntry
                    continue
                }

                $subscription = $subscriptions[$subscriptionNumber - 1]
                if (-not $seenSubscriptionIds.ContainsKey($subscription.Id)) {
                    $selectedSubscriptions += $subscription
                    $seenSubscriptionIds[$subscription.Id] = $true
                }
            }

            if ($invalidSelections.Count -gt 0 -or $selectedSubscriptions.Count -eq 0) {
                Write-Error-Custom "Invalid subscription selection. Enter numbers between 1 and $($subscriptions.Count)."
                $selectedSubscriptions = @()
            }
        }

        $scopeSelected = $true
        Write-Success "Selected $($selectedSubscriptions.Count) subscription(s)"
    } else {
        Write-Error-Custom "Invalid option. Enter 1 for all subscriptions or 2 to choose specific subscriptions."
    }
}

# ============================================================================
# Step 4: Create Service Principal
# ============================================================================

Write-Header -Message "Step 4 of 13: Create Service Principal"

try {
    # Check if app already exists
    $existingApp = Get-AzADApplication -DisplayName $APP_NAME
    
    if ($existingApp) {
        Write-Info "Service principal '$APP_NAME' already exists."
        $app = $existingApp
        $sp = Get-AzADServicePrincipal -ApplicationId $app.AppId
        Write-Success "Using existing application"
    } else {
        # Create new application
        $app = New-AzADApplication -DisplayName $APP_NAME
        Write-Success "Created new application: $APP_NAME"
        
        # Create service principal
        $sp = New-AzADServicePrincipal -ApplicationId $app.AppId
        Write-Success "Created service principal"
        
        # Wait for service principal to propagate
        Write-Info "Waiting for service principal to propagate (30 seconds)..."
        Start-Sleep -Seconds 30
    }
    
    $script:clientId = $app.AppId
    Write-Success "Application (Client) ID: $script:clientId"
    Write-Info "Object ID: $($sp.Id)"
    
} catch {
    Write-Error-Custom "Failed to create service principal: $_"
    exit 1
}

# ============================================================================
# Step 5: Create Client Secret
# ============================================================================

Write-Header -Message "Step 5 of 13: Create Client Secret"

try {
    # Check for existing secrets
    $existingCredentials = Get-AzADAppCredential -ApplicationId $app.AppId
    $validCredentials = @($existingCredentials | Where-Object { $_.EndDateTime -gt (Get-Date) })
    
    if ($validCredentials.Count -gt 0) {
        Write-Info "Found $($validCredentials.Count) existing valid credential(s)."
        Write-Host "Expiry dates:"
        foreach ($cred in $validCredentials) {
            Write-Host "  - $($cred.EndDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC'))"
        }
        
        $createNew = Read-Host "`nDo you want to create a new secret? (yes/no, default no)"
        
        if ($createNew -ne "yes") {
            Write-Info "Using existing credentials. You'll need to provide the secret value manually."
            $script:clientSecret = "<USE_EXISTING_SECRET>"
            
            # Use the latest expiring secret for the expiry date
            $latestCred = $validCredentials | Sort-Object EndDateTime -Descending | Select-Object -First 1
            $script:secretExpiry = $latestCred.EndDateTime.ToString("yyyy-MM-dd")
            $script:isNewSecret = $false
        } else {
            $createNew = "yes"
        }
    } else {
        $createNew = "yes"
    }
    
    if ($createNew -eq "yes") {
        $secretEndDate = (Get-Date).AddMonths(12)
        
        # Create credential
        $credential = New-AzADAppCredential -ApplicationId $app.AppId -EndDate $secretEndDate
        
        $script:clientSecret = $credential.SecretText
        $script:secretExpiry = $secretEndDate.ToString("yyyy-MM-dd")
        $script:isNewSecret = $true
        
        Write-Success "Created new client secret"
        Write-Info "Secret expires on: $script:secretExpiry"
    }
    
} catch {
    Write-Error-Custom "Failed to create client secret: $_"
    exit 1
}

# ============================================================================
# Step 6: Assign Reader Access
# ============================================================================

Write-Header -Message "Step 6 of 13: Assign Reader Access"

if ($script:useTenantRootReader) {
    Write-Info "All subscriptions were selected, so Reader will be assigned at tenant root scope (/)."
    $script:rootReaderAssignmentStatus = Ensure-TenantRootReaderAssignment -PrincipalId $sp.Id
} else {
    Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Reader" -RoleLabel "Reader role"
}

# ============================================================================
# Step 7: Optional Recommended Monitoring Roles
# ============================================================================

Write-Header -Message "Step 7 of 13: Recommended Monitoring Roles"

Write-SectionLabel "Recommended read permissions"
Write-DetailRow -Label "Monitoring Reader" -Value "Application Insights query access on selected subscriptions."
Write-DetailRow -Label "Log Analytics Reader" -Value "Workspace log access for current and future analysis scenarios."
Write-DetailRow -Label "All subscriptions" -Value "Log Analytics Reader is assigned once at the root management group."
Write-DetailRow -Label "Specific subscriptions" -Value "Log Analytics Reader is assigned on each selected subscription."
Write-Host ""
Write-Info "Press Enter to accept the default answer of yes."

$grantMonitoringReadPerms = Read-Host "Do you want to grant these optional recommended monitoring roles? (yes/no, default yes)"

if ([string]::IsNullOrWhiteSpace($grantMonitoringReadPerms) -or $grantMonitoringReadPerms -match "^(?i:yes)$") {
    Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Monitoring Reader" -RoleLabel "Monitoring Reader role"

    if ($script:useTenantRootReader) {
        $script:logAnalyticsReaderStatus = Ensure-RootManagementGroupRoleAssignment -PrincipalId $sp.Id -RoleDefinitionName "Log Analytics Reader" -RoleLabel "Log Analytics Reader role"
    } else {
        Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Log Analytics Reader" -RoleLabel "Log Analytics Reader role"
        $script:logAnalyticsReaderStatus = "processed"
    }
} elseif ($grantMonitoringReadPerms -match "^(?i:no)$") {
    Write-Info "Skipping optional recommended monitoring roles"
    $script:logAnalyticsReaderStatus = "skipped"
} else {
    Write-Info "Unrecognized response. Defaulting to no for the optional recommended monitoring roles."
    $script:logAnalyticsReaderStatus = "skipped"
}

# ============================================================================
# Step 8: Assign Root Management Group Governance Reader Roles
# ============================================================================

Write-Header -Message "Step 8 of 13: Assign Governance Reader Roles"

try {
    $script:rootManagementGroupReaderStatus = Ensure-RootManagementGroupRoleAssignment -PrincipalId $sp.Id -RoleDefinitionName "Reader" -RoleLabel "Reader role (root management group)"
    $script:managementGroupReaderStatus = Ensure-RootManagementGroupRoleAssignment -PrincipalId $sp.Id -RoleDefinitionName "Management Group Reader" -RoleLabel "Management Group Reader role"
} catch {
    $script:rootManagementGroupReaderStatus = "failed"
    $script:managementGroupReaderStatus = "failed"
    Write-Error-Custom "Failed to assign root management group governance reader roles: $_"
}

# ============================================================================
# Step 9: Assign Reservations Reader
# ============================================================================

Write-Header -Message "Step 9 of 13: Assign Reservations Reader"

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
    Write-Info "You may need elevated permissions to assign this role at /providers/Microsoft.Capacity"
}

# ============================================================================
# Step 10: Assign Savings plan Reader
# ============================================================================

Write-Header -Message "Step 10 of 13: Assign Savings Plan Reader"

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
    Write-Info "You may need elevated permissions to assign this role at /providers/Microsoft.BillingBenefits"
}

# ============================================================================
# Step 11: Grant Microsoft Graph Application.Read.All
# ============================================================================

Write-Header -Message "Step 11 of 13: Grant Microsoft Graph Application.Read.All"

Write-SectionLabel "Microsoft Graph governance permission"
Write-DetailRow -Label "Permission" -Value "Application.Read.All application permission with admin consent."
Write-DetailRow -Label "Purpose" -Value "Read applications and service principals for governance and credential posture."
Write-DetailRow -Label "Requires" -Value "Tenant admin consent and Microsoft Graph authentication."
Write-DetailRow -Label "Admin sign-in scopes" -Value "Application.ReadWrite.All and AppRoleAssignment.ReadWrite.All."
Write-Host ""
Write-Info "Press Enter to accept the default answer of yes."

$grantGraphPermission = Read-Host "Do you want to connect to Microsoft Graph and grant Application.Read.All? (yes/no, default yes)"

if (Test-YesResponse -Value $grantGraphPermission) {
    if (Ensure-PowerShellModules -Modules $graphRequiredModules -ModuleSetName "Microsoft Graph" -ManualInstallCommands @(
        "Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force"
    ) -Required $false) {
        $graphConnected = $false

        try {
            Write-Info "Connecting to Microsoft Graph to grant Application.Read.All with admin consent..."
            Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -TenantId $script:tenantId -NoWelcome
            $graphConnected = $true

            # Get Microsoft Graph service principal
            $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

            # Get Application.Read.All application permission
            $appReadAllPermission = $graphSp.AppRoles | Where-Object { $_.Value -eq "Application.Read.All" }

            if ($null -eq $appReadAllPermission) {
                $script:graphPermissionStatus = "failed"
                Write-Error-Custom "Could not find Application.Read.All permission"
            } else {
                # Check if permission already granted
                $existingPermission = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
                    Where-Object { $_.AppRoleId -eq $appReadAllPermission.Id }

                if ($existingPermission) {
                    Write-Info "Application.Read.All already granted for governance and credential posture"
                    $script:graphPermissionStatus = "existing"
                } else {
                    # Grant the permission
                    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graphSp.Id -AppRoleId $appReadAllPermission.Id | Out-Null
                    Write-Success "Granted Application.Read.All with admin consent for governance and credential posture"
                    $script:graphPermissionStatus = "created"
                }
            }

        } catch {
            $script:graphPermissionStatus = "failed"
            Write-Error-Custom "Failed to grant Microsoft Graph Application.Read.All: $_"
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
        Write-Info "Skipping Microsoft Graph Application.Read.All because the Microsoft Graph modules are unavailable."
    }
} else {
    $script:graphPermissionStatus = "skipped"
    Write-Info "Skipping Microsoft Graph Application.Read.All. You can grant it later in Azure Portal or rerun this script."
}

# ============================================================================
# Step 12: Highly Recommended Cost Management Billing Exports
# ============================================================================

Write-Header -Message "Step 12 of 13: Cost Management Billing Exports"

Write-SectionLabel "Highly recommended billing export setup"
Write-NumberedStep -Number 1 -Message "Detect existing daily actual and amortized Cost Management exports."
Write-NumberedStep -Number 2 -Message "Grant the Spotto service principal Storage Blob Data Reader on export containers."
Write-NumberedStep -Number 3 -Message "Create missing daily exports and queue one-time exports for the previous 13 closed months."
Write-Host ""
Write-Info "Exports are written to customer-owned Azure Storage. Spotto cloud-engine reads them later."
Write-Info "This is highly recommended because it reduces Cost Management API calls and Azure rate limiting."
Write-Info "The script keeps the storage public endpoint enabled, anonymous access disabled, and containers private."
Write-Info "New daily recurring exports are run immediately when Azure accepts the run request."
Write-Info "Historical backfill exports are queued once and marked so reruns can recover interrupted backfills without repeated queueing."
Write-Host ""

$configureBillingExports = Read-Host "Set up highly recommended Cost Management exports for Spotto? (yes/no, default yes)"

if (Test-YesResponse -Value $configureBillingExports) {
    $script:billingExportSetupStatus = "processed"
    $existingRecurringExports = @{}
    $detectedExistingExports = @()
    $billingExportSubscriptions = @()

    Write-Info "Checking Cost Management export availability on selected subscriptions..."
    foreach ($sub in $selectedSubscriptions) {
        if (Test-CostExportScopeAvailable -Subscription $sub) {
            $billingExportSubscriptions += $sub
        }
    }

    if ($billingExportSubscriptions.Count -eq 0) {
        $script:billingExportSetupStatus = "unavailable"
        Write-Warning-Custom "Cost Management billing exports are not available for any selected subscription. Skipping storage setup and continuing onboarding."
    }

    if ($script:billingExportSetupStatus -ne "unavailable") {
        Write-Info "Checking for existing daily Cost Management exports on available subscriptions..."
        foreach ($sub in $billingExportSubscriptions) {
            foreach ($datasetType in @("ActualCost", "AmortizedCost")) {
                $matches = @(Find-ExistingRecurringBillingExports -Subscription $sub -DatasetType $datasetType)
                if ($matches.Count -gt 0) {
                    $export = $matches | Select-Object -First 1
                    $destination = Get-ExportDestinationInfo -Export $export
                    $detectedExistingExports += [pscustomobject]@{
                        Subscription = $sub
                        DatasetType = $datasetType
                        Export = $export
                        Destination = $destination
                    }
                }
            }
        }

        if ($detectedExistingExports.Count -gt 0) {
            Write-Host ""
            Write-SectionLabel "Detected compatible recurring exports"
            foreach ($detected in $detectedExistingExports) {
                Write-DetailRow -Label "Subscription" -Value $detected.Subscription.Name
                Write-DetailRow -Label "Dataset" -Value $detected.DatasetType
                Write-DetailRow -Label "Export" -Value $detected.Export.name
                Write-DetailRow -Label "Container" -Value $detected.Destination.Container
                Write-Host ""
            }

            Write-Info "If accepted, storage accounts for existing exports may be updated to keep the public endpoint enabled with anonymous blob access disabled."
            $useExistingExports = Read-Host "Use compatible existing recurring exports where found? (yes/no, default yes)"
            if (Test-YesResponse -Value $useExistingExports) {
                foreach ($detected in $detectedExistingExports) {
                    try {
                        $storageAccountId = $detected.Destination.StorageAccountId
                        $containerName = $detected.Destination.Container
                        Ensure-BillingExportStorageSettings -StorageAccountId $storageAccountId
                        $containerScope = Ensure-BillingExportContainer -StorageAccountId $storageAccountId -ContainerName $containerName
                        $storageReaderStatus = Ensure-StorageBlobDataReaderAssignment -PrincipalId $sp.Id -Scope $containerScope
                        if ($storageReaderStatus -eq "failed") {
                            throw "Storage Blob Data Reader could not be assigned on export container '$containerName'."
                        }

                        $key = "$($detected.Subscription.Id)|$($detected.DatasetType)"
                        $existingRecurringExports[$key] = $detected.Export
                    } catch {
                        Write-Error-Custom "Existing export '$($detected.Export.name)' could not be prepared for Spotto: $_"
                    }
                }
            }
        } else {
            Write-Info "No compatible recurring exports were found on the selected subscriptions."
        }

        $storageDestination = $null
        $billingExportContainerName = $BILLING_EXPORT_CONTAINER_NAME

        if ($existingRecurringExports.Count -gt 0) {
            $firstExistingExport = $existingRecurringExports.Values | Select-Object -First 1
            $firstDestination = Get-ExportDestinationInfo -Export $firstExistingExport
            $useExistingStorageForNewExports = Read-Host "Use the first existing export storage account for backfill and missing exports? (yes/no, default yes)"

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

        if (-not $storageDestination) {
            try {
                $storageDestination = Select-BillingExportStorageAccount -Subscriptions $billingExportSubscriptions
                $billingExportContainerName = Get-DefaultedInput -Prompt "Blob container for Spotto billing exports" -DefaultValue $BILLING_EXPORT_CONTAINER_NAME
            } catch {
                $script:billingExportSetupStatus = "failed"
                Write-Error-Custom "Failed to select or create billing export storage: $($_.Exception.Message)"
                Write-Info "Continuing with the remaining onboarding steps. You can rerun the script after fixing the storage/export prerequisite."
            }
        }

        if ($script:billingExportSetupStatus -ne "failed") {
            try {
                Ensure-ResourceProviderRegistered -SubscriptionId $storageDestination.SubscriptionId -ProviderNamespace "Microsoft.CostManagementExports" -MaxAttempts 60 -PollSeconds 5 | Out-Null
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

        if ($script:billingExportSetupStatus -ne "failed") {
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
} else {
    $script:billingExportSetupStatus = "skipped"
    Write-Info "Skipping highly recommended Cost Management billing export setup"
}

# ============================================================================
# Step 13: Optional Custom Roles
# ============================================================================

Write-Header -Message "Step 13 of 13: Optional Write Permissions"

Write-SectionLabel "Optional write capabilities"
Write-NumberedStep -Number 1 -Message "Dismiss Azure Advisor recommendations."
Write-NumberedStep -Number 2 -Message "Enable Storage Inventory reports."
Write-Host ""

$grantWritePerms = Read-Host "Do you want to grant these optional write permissions? (yes/no, default no)"

if ($grantWritePerms -eq "yes") {
    
    $customRoleSuccessCount = 0
    $customRoleSkipCount = 0
    
    foreach ($sub in $selectedSubscriptions) {
        try {
            Set-AzContext -SubscriptionId $sub.Id | Out-Null
            
            # Check if custom role exists by name (globally in tenant)
            $role = Get-AzRoleDefinition -Name $CUSTOM_ROLE_NAME -ErrorAction SilentlyContinue

            if (-not $role) {
                # Role doesn't exist - Create it
                $roleDefinition = @{
                    Name = $CUSTOM_ROLE_NAME
                    Description = "Custom role for Spotto to manage Azure Advisor recommendations and Storage inventory"
                    Actions = @(
                        "Microsoft.Advisor/recommendations/write",
                        "Microsoft.Advisor/recommendations/suppressions/write",
                        "Microsoft.Advisor/recommendations/suppressions/delete",
                        "Microsoft.Storage/storageAccounts/inventoryPolicies/write",
                        "Microsoft.Storage/storageAccounts/inventoryPolicies/read"
                    )
                    AssignableScopes = @("/subscriptions/$($sub.Id)")
                }
                
                try {
                    $role = New-AzRoleDefinition -Role $roleDefinition
                    Write-Success "Created custom role '$CUSTOM_ROLE_NAME' on: $($sub.Name)"
                } catch {
                    if ($_.Exception.Message -match "Conflict") {
                        Write-Info "Custom role '$CUSTOM_ROLE_NAME' already exists. Loading existing role."
                        $role = Get-AzRoleDefinition -Name $CUSTOM_ROLE_NAME -ErrorAction SilentlyContinue
                    } else {
                        throw
                    }
                }
                
                # Wait for role to propagate
                Start-Sleep -Seconds 10
            } else {
                # Role exists - Check scope
                if ($role.AssignableScopes -notcontains "/subscriptions/$($sub.Id)") {
                    # Update role to include this subscription
                    $updatedScopes = $role.AssignableScopes + "/subscriptions/$($sub.Id)"
                    $role.AssignableScopes = $updatedScopes
                    Set-AzRoleDefinition -Role $role | Out-Null
                    Write-Success "Updated custom role '$CUSTOM_ROLE_NAME' to include: $($sub.Name)"
                    
                    # Wait for update to propagate
                    Start-Sleep -Seconds 5
                } else {
                    Write-Info "Custom role '$CUSTOM_ROLE_NAME' already covers: $($sub.Name)"
                }
            }
            
            # Assign the custom role
            $existingCustomAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $CUSTOM_ROLE_NAME -Scope "/subscriptions/$($sub.Id)" -ErrorAction SilentlyContinue
            
            if ($existingCustomAssignment) {
                Write-Info "Custom role already assigned on: $($sub.Name)"
                $customRoleSkipCount++
            } else {
                New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $CUSTOM_ROLE_NAME -Scope "/subscriptions/$($sub.Id)" | Out-Null
                Write-Success "Assigned custom role on: $($sub.Name)"
                $customRoleSuccessCount++
            }
            
        } catch {
            Write-Error-Custom "Failed to create/assign custom role on $($sub.Name): $_"
            if ($_.Exception.Message -match "Forbidden") {
                Write-Info "Requires Owner or User Access Administrator on the subscription."
            }
        }
    }
    
    Write-Info "Summary: $customRoleSuccessCount new assignments, $customRoleSkipCount already existed"
    
} else {
    Write-Info "Skipping optional write permissions"
}

# ============================================================================
# SUMMARY & CREDENTIALS
# ============================================================================

Write-Header -Message "Setup Complete" -Subtitle "Review the results, then copy the credentials into Spotto"

Write-Success "Service Principal: $APP_NAME ($script:clientId)"
if ($script:useTenantRootReader) {
    switch ($script:rootReaderAssignmentStatus) {
        "created" { Write-Success "Reader role assigned at tenant root scope (/), covering all subscriptions" }
        "existing" { Write-Success "Reader role already existed at tenant root scope (/), covering all subscriptions" }
        "failed" { Write-Error-Custom "Reader role was not assigned at tenant root scope (/)" }
        default { Write-Skipped "Reader role at tenant root scope (/) was not processed" }
    }
} else {
    Write-Success "Reader role processed on $($selectedSubscriptions.Count) selected subscription(s)"
}
if ([string]::IsNullOrWhiteSpace($grantMonitoringReadPerms) -or $grantMonitoringReadPerms -match "^(?i:yes)$") {
    Write-Success "Monitoring Reader processed on selected subscription(s)"
} else {
    Write-Skipped "Monitoring Reader skipped (optional)"
}
switch ($script:logAnalyticsReaderStatus) {
    "created" { Write-Success "Log Analytics Reader assigned at the root management group" }
    "existing" { Write-Success "Log Analytics Reader already existed at the root management group" }
    "processed" { Write-Success "Log Analytics Reader processed on selected subscription(s)" }
    "failed" { Write-Error-Custom "Log Analytics Reader was not assigned" }
    "skipped" { Write-Skipped "Log Analytics Reader skipped (optional)" }
    default { Write-Skipped "Log Analytics Reader was not processed" }
}
switch ($script:rootManagementGroupReaderStatus) {
    "created" { Write-Success "Reader assigned at the root management group for tenant governance hierarchy access" }
    "existing" { Write-Success "Reader already existed at the root management group for tenant governance hierarchy access" }
    "failed" { Write-Error-Custom "Reader was not assigned at the root management group" }
    default { Write-Skipped "Reader at the root management group was not processed" }
}
switch ($script:managementGroupReaderStatus) {
    "created" { Write-Success "Management Group Reader assigned at the root management group" }
    "existing" { Write-Success "Management Group Reader already existed at the root management group" }
    "failed" { Write-Error-Custom "Management Group Reader was not assigned at the root management group" }
    default { Write-Skipped "Management Group Reader was not processed" }
}
switch ($script:reservationReaderStatus) {
    "created" { Write-Success "Reservations Reader assigned at /providers/Microsoft.Capacity" }
    "existing" { Write-Success "Reservations Reader already existed at /providers/Microsoft.Capacity" }
    "failed" { Write-Error-Custom "Reservations Reader was not assigned at /providers/Microsoft.Capacity" }
    default { Write-Skipped "Reservations Reader was not processed" }
}
switch ($script:savingsPlanReaderStatus) {
    "created" { Write-Success "Savings plan Reader assigned at /providers/Microsoft.BillingBenefits" }
    "existing" { Write-Success "Savings plan Reader already existed at /providers/Microsoft.BillingBenefits" }
    "failed" { Write-Error-Custom "Savings plan Reader was not assigned at /providers/Microsoft.BillingBenefits" }
    default { Write-Skipped "Savings plan Reader was not processed" }
}
switch ($script:graphPermissionStatus) {
    "created" { Write-Success "Microsoft Graph Application.Read.All granted for governance and credential posture" }
    "existing" { Write-Success "Microsoft Graph Application.Read.All already existed for governance and credential posture" }
    "failed" { Write-Error-Custom "Microsoft Graph Application.Read.All was not granted" }
    "skipped" { Write-Skipped "Microsoft Graph Application.Read.All skipped" }
    default { Write-Skipped "Microsoft Graph Application.Read.All was not processed" }
}
switch ($script:billingExportSetupStatus) {
    "processed" { Write-Success "Cost Management billing exports processed" }
    "failed" { Write-Error-Custom "Cost Management billing export setup failed before export creation completed" }
    "unavailable" { Write-Warning-Custom "Cost Management billing exports were not available for the selected subscription(s)" }
    "skipped" { Write-Skipped "Cost Management billing export setup skipped (highly recommended)" }
    default { Write-Skipped "Cost Management billing export setup was not processed" }
}
if ($script:billingExportResults.Count -gt 0) {
    $failedBillingExports = @($script:billingExportResults | Where-Object { $_.Status -eq "failed" })
    $unavailableBillingExports = @($script:billingExportResults | Where-Object { $_.Status -eq "unavailable" })
    $processedBillingExports = @($script:billingExportResults | Where-Object { $_.Status -notin @("failed", "unavailable") })
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
        Write-Warning-Custom "Some optional export datasets are not available for this Azure agreement/scope."
    }
    if ($failedBillingExports.Count -gt 0) {
        Write-Info "Some exports failed and may need manual review."
        foreach ($failedExport in ($failedBillingExports | Select-Object -First 5)) {
            Write-Error-Custom "$($failedExport.SubscriptionName) $($failedExport.DatasetType) $($failedExport.ExportKind): $($failedExport.Message)"
        }
    }
}
if ($grantWritePerms -eq "yes") {
    Write-Success "Custom role with write permissions created and assigned"
}
Write-Host ""
Write-Host "Propagation note:" -ForegroundColor Yellow
if ($script:graphPermissionStatus -in @("created", "existing")) {
    Write-Host "  Azure RBAC changes and Microsoft Graph admin consent can take 5-15 minutes to apply." -ForegroundColor Yellow
    Write-Host "  During that time, Spotto may validate the account or list subscriptions while tenant governance data still shows access denied." -ForegroundColor Yellow
    Write-Host "  If that happens, wait a few minutes and rerun validation or retry the tenant sync." -ForegroundColor Yellow
} else {
    Write-Host "  Azure RBAC changes can take 5-15 minutes to apply." -ForegroundColor Yellow
    Write-Host "  Microsoft Graph Application.Read.All was not granted, so application and service principal posture may show access denied." -ForegroundColor Yellow
    Write-Host "  You can grant Graph consent manually or rerun this script and choose yes for Step 11." -ForegroundColor Yellow
}

# Display credentials for copy/paste
Show-Credentials

Show-NextSteps

if ($script:isNewSecret) {
    Write-Host "⚠ REMINDER: The client secret shown above will NOT be displayed again!" -ForegroundColor Red
    Write-Host "              Make sure you've saved it before closing this window.`n" -ForegroundColor Red
}

Write-Host "For support, visit: https://docs.spotto.ai`n"

# Keep credentials visible
Read-Host "Press Enter to exit"

Stop-Transcript
