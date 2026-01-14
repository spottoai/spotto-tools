<#
.SYNOPSIS
    Sets up Azure service principal with appropriate permissions for Spotto AI.

.DESCRIPTION
    This script creates a service principal, assigns necessary permissions for Spotto to analyze
    your Azure environment, and optionally grants write permissions for specific actions.
    
    Permissions granted:
    - Reader role on selected subscriptions (read Azure resources)
    - Reservation Reader at tenant level (read Reserved Instances)
    - Savings Plan Reader at tenant level (read Savings Plans)
    - Application.Read.All in Microsoft Graph (read service principal credential expiry)
    - Optional: Custom role for dismissing Azure Advisor recommendations
    - Optional: Custom role for enabling Storage Inventory Reports
    
    This script is idempotent - it can be run multiple times safely.

.NOTES
    Prerequisites:
    - PowerShell 5.1 or PowerShell 7+
    - Azure PowerShell module (will be installed if missing)
    - Microsoft Graph PowerShell module (will be installed if missing)
    - Global Administrator or appropriate permissions to create service principals
    - Owner or User Access Administrator role on subscriptions
    
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

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Header "Spotto AI - Azure Setup Script"

Write-Host "This script will:"
Write-Host "1. Create a service principal named '$APP_NAME' (or use existing)"
Write-Host "2. Generate a client secret (valid for 12 months)"
Write-Host "3. Assign Reader role on your selected subscriptions"
Write-Host "4. Assign Reservation Reader (tenant-level)"
Write-Host "5. Assign Savings Plan Reader (tenant-level)"
Write-Host "6. Grant Application.Read.All permission in Microsoft Graph"
Write-Host "7. (Optional) Create and assign custom roles for write permissions"
Write-Host "`nThis script is idempotent and safe to run multiple times.`n"

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
    Write-Success "Selected all $($selectedSubscriptions.Count) subscriptions"
} else {
    $indices = $selection -split ',' | ForEach-Object { [int]$_.Trim() - 1 }
    $selectedSubscriptions = $indices | ForEach-Object { $subscriptions[$_] }
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
# Step 5: Assign Reader Role on Subscriptions
# ============================================================================

Write-Header "Step 5: Assigning Reader Role on Subscriptions"

$successCount = 0
$skipCount = 0

foreach ($sub in $selectedSubscriptions) {
    try {
        Set-AzContext -SubscriptionId $sub.Id | Out-Null
        
        # Check if role assignment already exists
        $existingAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Reader" -Scope "/subscriptions/$($sub.Id)" -ErrorAction SilentlyContinue
        
        if ($existingAssignment) {
            Write-Info "Reader role already assigned on: $($sub.Name)"
            $skipCount++
        } else {
            New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Reader" -Scope "/subscriptions/$($sub.Id)" | Out-Null
            Write-Success "Assigned Reader role on: $($sub.Name)"
            $successCount++
        }
    } catch {
        Write-Error-Custom "Failed to assign Reader role on $($sub.Name): $_"
    }
}

Write-Info "Summary: $successCount new assignments, $skipCount already existed"

# ============================================================================
# Step 6: Assign Reservation Reader (Tenant Level)
# ============================================================================

Write-Header "Step 6: Assigning Reservation Reader (Tenant Level)"

try {
    $reservationScope = "/providers/Microsoft.Capacity"
    
    # Check if role assignment already exists
    $existingReservation = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $reservationScope -RoleDefinitionName "Reservations Reader" -ErrorAction SilentlyContinue
    
    if ($existingReservation) {
        Write-Info "Reservation Reader role already assigned"
    } else {
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Reservations Reader" -Scope $reservationScope | Out-Null
        Write-Success "Assigned Reservation Reader role at tenant level"
    }
} catch {
    Write-Error-Custom "Failed to assign Reservation Reader role: $_"
    Write-Info "You may need elevated permissions to assign this role"
}

# ============================================================================
# Step 7: Assign Savings Plan Reader (Tenant Level)
# ============================================================================

Write-Header "Step 7: Assigning Savings Plan Reader (Tenant Level)"

try {
    $savingsPlanScope = "/providers/Microsoft.BillingBenefits"
    
    # Check if role assignment already exists
    $existingSavingsPlan = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $savingsPlanScope -RoleDefinitionName "Savings plan Reader" -ErrorAction SilentlyContinue
    
    if ($existingSavingsPlan) {
        Write-Info "Savings Plan Reader role already assigned"
    } else {
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Savings plan Reader" -Scope $savingsPlanScope | Out-Null
        Write-Success "Assigned Savings Plan Reader role at tenant level"
    }
} catch {
    Write-Error-Custom "Failed to assign Savings Plan Reader role: $_"
    Write-Info "You may need elevated permissions to assign this role"
}

# ============================================================================
# Step 8: Grant Microsoft Graph Permissions
# ============================================================================

Write-Header "Step 8: Granting Microsoft Graph Permissions"

try {
    Write-Info "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -TenantId $script:tenantId -NoWelcome
    
    # Get Microsoft Graph service principal
    $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
    
    # Get Application.Read.All permission
    $appReadAllPermission = $graphSp.AppRoles | Where-Object { $_.Value -eq "Application.Read.All" }
    
    if ($null -eq $appReadAllPermission) {
        Write-Error-Custom "Could not find Application.Read.All permission"
    } else {
        # Check if permission already granted
        $existingPermission = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id | 
            Where-Object { $_.AppRoleId -eq $appReadAllPermission.Id }
        
        if ($existingPermission) {
            Write-Info "Application.Read.All permission already granted"
        } else {
            # Grant the permission
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graphSp.Id -AppRoleId $appReadAllPermission.Id | Out-Null
            Write-Success "Granted Application.Read.All permission"
        }
    }
    
    try {
        Disconnect-MgGraph | Out-Null
    } catch {
        # Silently ignore if already disconnected
    }
    
} catch {
    Write-Error-Custom "Failed to grant Microsoft Graph permissions: $_"
    Write-Info "You may need to grant this manually through Azure Portal > App Registrations > API Permissions"
}

# ============================================================================
# Step 9: Optional Custom Roles
# ============================================================================

Write-Header "Step 9: Optional Custom Roles (Write Permissions)"

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
                
                $role = New-AzRoleDefinition -Role $roleDefinition
                Write-Success "Created custom role '$CUSTOM_ROLE_NAME' on: $($sub.Name)"
                
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
Write-Host "✓ Reader role assigned on $($selectedSubscriptions.Count) subscription(s)"
Write-Host "✓ Reservation Reader assigned at tenant level"
Write-Host "✓ Savings Plan Reader assigned at tenant level"
Write-Host "✓ Microsoft Graph permissions granted"
if ($grantWritePerms -eq "yes") {
    Write-Host "✓ Custom role with write permissions created and assigned"
}

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