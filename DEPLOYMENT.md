Status: living
Last updated: 2026-02-15
Owner: Platform

# Setup & Usage

## AWS

See [AWS onboarding](onboarding/aws/README.md). Use PowerShell 7.4+ and AWS CLI v2
with customer-authorized sessions. Setup consumes the portal's versioned company
package. Read-only checks and WhatIf are available; final effective access is
validated by Spotto's existing Create/Update flow.

## Prerequisites
- PowerShell 5.1 or PowerShell 7+
- Azure account with required permissions (see `README.md`)
- For detailed onboarding permission scopes, including optional `Log Analytics Reader`, see `onboarding/azure/README.md`

## Run onboarding script
```powershell
# Clone and enter the repo
# Run the setup script from onboarding folder
.\onboarding\azure\Setup-SpottoAzure.ps1
```

Follow the prompts to select tenant/subscriptions and capture generated credentials.
