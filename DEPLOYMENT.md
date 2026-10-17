Status: living
Last updated: 2026-10-16
Owner: Platform

# Setup & Usage

## AWS

See [AWS onboarding](onboarding/aws/README.md). Use AWS CLI v2 with customer-authorized
sessions and either PowerShell 7.4+, or Bash 3.2+ with jq 1.6+ and GNU timeout
(`gtimeout` from Homebrew coreutils on macOS). Both scripts are standalone files
and consume the portal's versioned company package. Read-only checks and dry runs
are available; final effective access is validated by Spotto's existing Create/Update
flow. Neither script requires Terraform.

Authenticate before running the Bash script: use `aws sts get-caller-identity --profile
<profile>` to complete and cache an MFA assume-role session, or `aws sso login --profile
<profile>` for IAM Identity Center. Repeat for each profile. Supervised CLI jobs cannot
complete terminal prompts. Both scripts warn about unrequested legacy broad managed
policies; they preserve those attachments until the owning tool removes them after
replacement access has been validated.

For publication, publish the complete `spotto-tools` change (including the Bash script
and fixtures) first, then the Terraform compatibility/release-note change, then the
documentation, then the UI links. Validate the public script/guide URLs after publication.

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
