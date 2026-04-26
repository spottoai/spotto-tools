<#
.SYNOPSIS
    Sets up Azure service principal with appropriate permissions for Spotto AI.

.DESCRIPTION
    This script creates a service principal, assigns the governance and billing permissions Spotto
    uses to analyze your Azure environment, and optionally grants recommended monitoring roles and
    specific write permissions.
    
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
    - Application.Read.All in Microsoft Graph with admin consent
      (read applications and service principals for governance and credential posture)
    - Optional: Custom role for dismissing Azure Advisor recommendations
    - Optional: Custom role for enabling Storage Inventory Reports
    
    This script is idempotent - it can be run multiple times safely.

.NOTES
    Prerequisites:
    - PowerShell 5.1 or PowerShell 7+
    - Azure PowerShell module (will be installed if missing)
    - Microsoft Graph PowerShell module (will be installed if missing)
    - Global Administrator, Application Administrator, or appropriate permissions to create service principals
    - Owner or User Access Administrator on subscriptions, or at tenant root scope (/)
    - Tenant admin consent for Microsoft Graph Application.Read.All
    - Management Group Contributor or Owner role for management group access
    - If assigning Reader at tenant root scope (/), Global Administrators typically need
      to enable Microsoft Entra ID > Properties > Access management for Azure resources
      and then sign out and sign back in before running this script
    
.EXAMPLE
    .\Setup-SpottoAzure.ps1
#>

# Script configuration
$ErrorActionPreference = "Stop"

# Start logging
$logPath = "SpottoSetup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append

# ============================================================================
# CHECK AND INSTALL REQUIRED MODULES
# ============================================================================

Write-Host "Checking required PowerShell modules..." -ForegroundColor Cyan

$requiredModules = @(
    @{ Name = "Az.Accounts"; MinVersion = "2.0.0" },
    @{ Name = "Az.Resources"; MinVersion = "6.0.0" },
    @{ Name = "Microsoft.Graph.Authentication"; MinVersion = "2.0.0" },
    @{ Name = "Microsoft.Graph.Applications"; MinVersion = "2.0.0" }
)

$missingModules = @()

foreach ($module in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $module.Name | Where-Object { $_.Version -ge $module.MinVersion }
    
    if (-not $installed) {
        $missingModules += $module.Name
        Write-Host "✗ Missing: $($module.Name)" -ForegroundColor Red
    } else {
        Write-Host "✓ Found: $($module.Name)" -ForegroundColor Green
    }
}

if ($missingModules.Count -gt 0) {
    Write-Host "`nThe following modules need to be installed:" -ForegroundColor Yellow
    foreach ($module in $missingModules) {
        Write-Host "  - $module" -ForegroundColor Yellow
    }
    
    $install = Read-Host "`nWould you like to install missing modules now? (yes/no)"
    
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
                Write-Host "Install-Module -Name $module -Scope CurrentUser -Force" -ForegroundColor White
                exit 1
            }
        }
        
        Write-Host "`n✓ All modules installed successfully!`n" -ForegroundColor Green
    } else {
        Write-Host "`nPlease install the missing modules manually:" -ForegroundColor Yellow
        Write-Host "Install-Module -Name Az -Scope CurrentUser -Force" -ForegroundColor White
        Write-Host "Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force" -ForegroundColor White
        exit 1
    }
}

Write-Host "✓ All required modules are available`n" -ForegroundColor Green
$APP_NAME = "Spotto AI"
$CUSTOM_ROLE_NAME = "Spotto Access"

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

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Show-Credentials {
    Write-Host "`n" + ("=" * 80) -ForegroundColor Yellow
    Write-Host " SPOTTO CREDENTIALS - Copy these into the Spotto Portal " -ForegroundColor Yellow
    Write-Host ("=" * 80) -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Application (Client) ID:  " -NoNewline
    Write-Host $script:clientId -ForegroundColor Green
    Write-Host "  Directory (Tenant) ID:    " -NoNewline
    Write-Host $script:tenantId -ForegroundColor Green
    Write-Host "  Client Secret:            " -NoNewline
    Write-Host $script:clientSecret -ForegroundColor Green
    Write-Host "  Secret Expiry Date:       " -NoNewline
    Write-Host $script:secretExpiry -ForegroundColor Green
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Yellow
    if ($script:isNewSecret) {
        Write-Host "⚠ IMPORTANT: This secret will not be shown again! Save it now." -ForegroundColor Red
    }
    Write-Host ("=" * 80) -ForegroundColor Yellow
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

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Header "Spotto AI - Azure Setup Script"

Write-Host "This script will:"
Write-Host "1. Create a service principal named '$APP_NAME' (or use existing)"
Write-Host "2. Generate a client secret (valid for 12 months)"
Write-Host "3. Assign Reader access"
Write-Host "   - All subscriptions: one Reader role at tenant root scope (/)"
Write-Host "   - Specific subscriptions: Reader role on each selected subscription"
Write-Host "4. (Optional, recommended) Assign Monitoring Reader and Log Analytics Reader"
Write-Host "   - Monitoring Reader: selected subscriptions"
Write-Host "   - Log Analytics Reader: root management group for all subscriptions, otherwise selected subscriptions"
Write-Host "5. Assign Reader and Management Group Reader at the root management group for tenant governance hierarchy, policy, and RBAC metadata"
Write-Host "6. Assign Reservations Reader at /providers/Microsoft.Capacity"
Write-Host "7. Assign Savings plan Reader at /providers/Microsoft.BillingBenefits"
Write-Host "8. Grant Microsoft Graph Application.Read.All with admin consent for governance and credential posture"
Write-Host "9. (Optional) Create and assign custom roles for write permissions"
Write-Host "`nThis script is idempotent and safe to run multiple times.`n"
Write-Host "Important for 'All subscriptions':" -ForegroundColor Yellow
Write-Host "  - The script will assign Reader at tenant root scope (/)." -ForegroundColor Yellow
Write-Host "  - This needs Owner or User Access Administrator at root scope." -ForegroundColor Yellow
Write-Host "  - Global Administrators usually need to enable Microsoft Entra ID > Properties > Access management for Azure resources first," -ForegroundColor Yellow
Write-Host "    then sign out and sign back in before running the script." -ForegroundColor Yellow
Write-Host "  - Microsoft Graph Application.Read.All also requires tenant admin consent." -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Do you want to continue? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Info "Setup cancelled by user."
    exit
}

# ============================================================================
# Step 1: Connect to Azure
# ============================================================================

Write-Header "Step 1: Connecting to Azure"

try {
    $currentContext = Get-AzContext
    if ($null -eq $currentContext) {
        Write-Info "Not logged in. Initiating login..."
        Connect-AzAccount
    } else {
        Write-Info "Already logged in as: $($currentContext.Account.Id)"
        $reconnect = Read-Host "Do you want to use a different account? (yes/no)"
        if ($reconnect -eq "yes") {
            Connect-AzAccount
        }
    }
    Write-Success "Connected to Azure"
} catch {
    Write-Error-Custom "Failed to connect to Azure: $_"
    exit 1
}

# ============================================================================
# Step 1b: Select Tenant
# ============================================================================

Write-Header "Step 1b: Select Tenant"

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
            Write-Host "  [$($i + 1)] $tenantName"
            Write-Host "      Tenant ID: $($tenant.Id)"
            Write-Host "      Domains: $($tenant.Domains -join ', ')`n"
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
# Step 2: Select Subscriptions
# ============================================================================

Write-Header "Step 2: Select Subscriptions"

$subscriptions = Get-AzSubscription -TenantId $script:tenantId
Write-Host "Found $($subscriptions.Count) subscription(s) in your tenant:`n"

for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host "  [$($i + 1)] $($subscriptions[$i].Name) ($($subscriptions[$i].Id))"
}

Write-Host "`nOptions:"
Write-Host "  [A] All subscriptions"
Write-Host "  [S] Specific subscriptions (comma-separated numbers, e.g., 1,3,5)"

$selection = Read-Host "`nSelect option"

$selectedSubscriptions = @()
if ($selection -eq "A" -or $selection -eq "a") {
    $selectedSubscriptions = $subscriptions
    $script:useTenantRootReader = $true
    Write-Success "Selected all $($selectedSubscriptions.Count) subscriptions"
    Write-Info "Reader access will be assigned once at tenant root scope (/)."
} else {
    $indices = $selection -split ',' | ForEach-Object { [int]$_.Trim() - 1 }
    $selectedSubscriptions = $indices | ForEach-Object { $subscriptions[$_] }
    $script:useTenantRootReader = $false
    Write-Success "Selected $($selectedSubscriptions.Count) subscription(s)"
}

# ============================================================================
# Step 3: Create Service Principal
# ============================================================================

Write-Header "Step 3: Creating Service Principal"

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
# Step 4: Create Client Secret
# ============================================================================

Write-Header "Step 4: Creating Client Secret"

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
        
        $createNew = Read-Host "`nDo you want to create a new secret? (yes/no)"
        
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
# Step 5: Assign Reader Access
# ============================================================================

Write-Header "Step 5: Assigning Reader Access"

if ($script:useTenantRootReader) {
    Write-Info "All subscriptions were selected, so Reader will be assigned at tenant root scope (/)."
    $script:rootReaderAssignmentStatus = Ensure-TenantRootReaderAssignment -PrincipalId $sp.Id
} else {
    Ensure-SubscriptionRoleAssignments -PrincipalId $sp.Id -Subscriptions $selectedSubscriptions -RoleDefinitionName "Reader" -RoleLabel "Reader role"
}

# ============================================================================
# Step 6: Optional Recommended Monitoring Roles
# ============================================================================

Write-Header "Step 6: Optional Recommended Monitoring Roles"

Write-Host "Spotto can optionally request these recommended read permissions:"
Write-Host "  1. Monitoring Reader"
Write-Host "     - Includes Application Insights query access via Microsoft.Insights/Components/Query/Read"
Write-Host "     - Assigned on the selected subscriptions"
Write-Host "  2. Log Analytics Reader"
Write-Host "     - All subscriptions: assigned once at the root management group for tenant-wide workspace log access"
Write-Host "     - Specific subscriptions: assigned on each selected subscription"
Write-Host "     - Broader than Log Analytics Data Reader and suited for future workspace log analysis`n"
Write-Info "Press Enter to accept the default answer of yes."

$grantMonitoringReadPerms = Read-Host "Do you want to grant these optional recommended monitoring roles? (yes/no)"

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
# Step 7: Assign Root Management Group Governance Reader Roles
# ============================================================================

Write-Header "Step 7: Assigning Root Management Group Governance Reader Roles"

try {
    $script:rootManagementGroupReaderStatus = Ensure-RootManagementGroupRoleAssignment -PrincipalId $sp.Id -RoleDefinitionName "Reader" -RoleLabel "Reader role (root management group)"
    $script:managementGroupReaderStatus = Ensure-RootManagementGroupRoleAssignment -PrincipalId $sp.Id -RoleDefinitionName "Management Group Reader" -RoleLabel "Management Group Reader role"
} catch {
    $script:rootManagementGroupReaderStatus = "failed"
    $script:managementGroupReaderStatus = "failed"
    Write-Error-Custom "Failed to assign root management group governance reader roles: $_"
}

# ============================================================================
# Step 8: Assign Reservations Reader
# ============================================================================

Write-Header "Step 8: Assigning Reservations Reader"

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
# Step 9: Assign Savings plan Reader
# ============================================================================

Write-Header "Step 9: Assigning Savings plan Reader"

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
# Step 10: Grant Microsoft Graph Application.Read.All
# ============================================================================

Write-Header "Step 10: Granting Microsoft Graph Application.Read.All"

try {
    Write-Info "Connecting to Microsoft Graph to grant Application.Read.All with admin consent..."
    Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -TenantId $script:tenantId -NoWelcome
    
    # Get Microsoft Graph service principal
    $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
    
    # Get Application.Read.All application permission
    $appReadAllPermission = $graphSp.AppRoles | Where-Object { $_.Value -eq "Application.Read.All" }
    
    if ($null -eq $appReadAllPermission) {
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
    
    try {
        Disconnect-MgGraph | Out-Null
    } catch {
        # Silently ignore if already disconnected
    }
    
} catch {
    $script:graphPermissionStatus = "failed"
    Write-Error-Custom "Failed to grant Microsoft Graph Application.Read.All: $_"
    Write-Info "You may need a tenant admin to grant admin consent."
    Write-Info "You can also grant this manually through Azure Portal > App Registrations > API Permissions"
}

# ============================================================================
# Step 11: Optional Custom Roles
# ============================================================================

Write-Header "Step 11: Optional Custom Roles (Write Permissions)"

Write-Host "Spotto can optionally perform these actions if you grant write permissions:"
Write-Host "  1. Dismiss Azure Advisor Recommendations"
Write-Host "  2. Enable Storage Inventory Reports`n"

$grantWritePerms = Read-Host "Do you want to grant these optional write permissions? (yes/no)"

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

Write-Header "Setup Complete!"

Write-Host "✓ Service Principal: $APP_NAME ($script:clientId)"
if ($script:useTenantRootReader) {
    switch ($script:rootReaderAssignmentStatus) {
        "created" { Write-Host "✓ Reader role assigned at tenant root scope (/), covering all subscriptions" }
        "existing" { Write-Host "✓ Reader role already existed at tenant root scope (/), covering all subscriptions" }
        "failed" { Write-Host "✗ Reader role was not assigned at tenant root scope (/)" }
        default { Write-Host "• Reader role at tenant root scope (/) was not processed" }
    }
} else {
    Write-Host "✓ Reader role processed on $($selectedSubscriptions.Count) selected subscription(s)"
}
if ([string]::IsNullOrWhiteSpace($grantMonitoringReadPerms) -or $grantMonitoringReadPerms -match "^(?i:yes)$") {
    Write-Host "✓ Monitoring Reader processed on selected subscription(s)"
} else {
    Write-Host "• Monitoring Reader skipped (optional)"
}
switch ($script:logAnalyticsReaderStatus) {
    "created" { Write-Host "✓ Log Analytics Reader assigned at the root management group" }
    "existing" { Write-Host "✓ Log Analytics Reader already existed at the root management group" }
    "processed" { Write-Host "✓ Log Analytics Reader processed on selected subscription(s)" }
    "failed" { Write-Host "✗ Log Analytics Reader was not assigned" }
    "skipped" { Write-Host "• Log Analytics Reader skipped (optional)" }
    default { Write-Host "• Log Analytics Reader was not processed" }
}
switch ($script:rootManagementGroupReaderStatus) {
    "created" { Write-Host "✓ Reader assigned at the root management group for tenant governance hierarchy access" }
    "existing" { Write-Host "✓ Reader already existed at the root management group for tenant governance hierarchy access" }
    "failed" { Write-Host "✗ Reader was not assigned at the root management group" }
    default { Write-Host "• Reader at the root management group was not processed" }
}
switch ($script:managementGroupReaderStatus) {
    "created" { Write-Host "✓ Management Group Reader assigned at the root management group" }
    "existing" { Write-Host "✓ Management Group Reader already existed at the root management group" }
    "failed" { Write-Host "✗ Management Group Reader was not assigned at the root management group" }
    default { Write-Host "• Management Group Reader was not processed" }
}
switch ($script:reservationReaderStatus) {
    "created" { Write-Host "✓ Reservations Reader assigned at /providers/Microsoft.Capacity" }
    "existing" { Write-Host "✓ Reservations Reader already existed at /providers/Microsoft.Capacity" }
    "failed" { Write-Host "✗ Reservations Reader was not assigned at /providers/Microsoft.Capacity" }
    default { Write-Host "• Reservations Reader was not processed" }
}
switch ($script:savingsPlanReaderStatus) {
    "created" { Write-Host "✓ Savings plan Reader assigned at /providers/Microsoft.BillingBenefits" }
    "existing" { Write-Host "✓ Savings plan Reader already existed at /providers/Microsoft.BillingBenefits" }
    "failed" { Write-Host "✗ Savings plan Reader was not assigned at /providers/Microsoft.BillingBenefits" }
    default { Write-Host "• Savings plan Reader was not processed" }
}
switch ($script:graphPermissionStatus) {
    "created" { Write-Host "✓ Microsoft Graph Application.Read.All granted for governance and credential posture" }
    "existing" { Write-Host "✓ Microsoft Graph Application.Read.All already existed for governance and credential posture" }
    "failed" { Write-Host "✗ Microsoft Graph Application.Read.All was not granted" }
    default { Write-Host "• Microsoft Graph Application.Read.All was not processed" }
}
if ($grantWritePerms -eq "yes") {
    Write-Host "✓ Custom role with write permissions created and assigned"
}
Write-Host ""
Write-Host "Propagation note:" -ForegroundColor Yellow
Write-Host "  Azure RBAC changes and Microsoft Graph admin consent can take 5-15 minutes to apply." -ForegroundColor Yellow
Write-Host "  During that time, Spotto may validate the account or list subscriptions while tenant governance data still shows access denied." -ForegroundColor Yellow
Write-Host "  If that happens, wait a few minutes and rerun validation or retry the tenant sync." -ForegroundColor Yellow

# Display credentials for copy/paste
Show-Credentials

Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host " NEXT STEPS " -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Copy the credentials shown above"
Write-Host "2. Go to the Spotto Portal: https://portal.spotto.ai"
Write-Host "3. Navigate to: Cloud Accounts > Add Cloud Account"
Write-Host "4. Paste the credentials into the form"
Write-Host "5. Click 'Validate Credentials' and then 'Create'"
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

if ($script:isNewSecret) {
    Write-Host "⚠ REMINDER: The client secret shown above will NOT be displayed again!" -ForegroundColor Red
    Write-Host "              Make sure you've saved it before closing this window.`n" -ForegroundColor Red
}

Write-Host "For support, visit: https://docs.spotto.ai`n"

# Keep credentials visible
Read-Host "Press Enter to exit"

Stop-Transcript
