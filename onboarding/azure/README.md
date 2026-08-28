# Azure Onboarding Wizard

`Setup-SpottoAzure.ps1` is the interactive wizard for connecting Azure to Spotto. Run this one script; it guides you through sign-in, tenant selection, and Spotto access. Billing exports are available through Custom setup.

It is safe to rerun. Use it again to repair interrupted setup, add missing permissions, or update an existing Spotto connection.

## Run on your machine

From the repository root:

```powershell
pwsh -ExecutionPolicy Bypass -File ./onboarding/azure/Setup-SpottoAzure.ps1
```

Or from this directory:

```powershell
pwsh -ExecutionPolicy Bypass -File ./Setup-SpottoAzure.ps1
```

Using Windows PowerShell 5.1? Replace `pwsh` with `powershell.exe`.

## Run in Azure Cloud Shell

Open **Azure Portal**, start **Cloud Shell**, choose **PowerShell**, and paste:

```powershell
Invoke-WebRequest `
    -Uri "https://raw.githubusercontent.com/spottoai/spotto-tools/main/onboarding/azure/Setup-SpottoAzure.ps1" `
    -OutFile "./Setup-SpottoAzure.ps1"

& ./Setup-SpottoAzure.ps1
```

The downloaded script remains visible in Cloud Shell so your team can review it before running it again.

## Setup modes

### Recommended read-only access

Press **Enter** to use the default. The wizard automatically selects all subscriptions and configures the Azure and Microsoft Graph reader permissions Spotto needs.

This includes Monitoring Reader, Log Analytics Reader, Security Reader, and the exact Microsoft Graph governance permission set, including `Policy.Read.All` and `LicenseAssignment.Read.All`.

If the existing credential with the latest expiry has at least three months remaining, it is reused. Otherwise the wizard creates a replacement secret. Billing exports, export storage, and optional write access are not configured.

### Custom setup

Choose Custom setup when you want specific subscriptions, billing exports, individual permission choices, or supported write capabilities.

## What you need

- PowerShell 5.1 or PowerShell 7+
- An Azure administrator account that can create the Spotto application and assign access at the selected scopes
- Any required PIM roles activated before setup

The wizard can install missing Azure and Microsoft Graph PowerShell modules. You will choose the Azure account and tenant; Custom setup also lets you choose subscription scope and credential behaviour.

## Detailed documentation

- [PowerShell setup, permissions, and billing exports](https://docs.spotto.ai/portal/cloud-account-azure/powershell)
- [Operator permissions and PIM](https://docs.spotto.ai/portal/cloud-account-azure/operator-permissions)
- [Manual permission reference](https://docs.spotto.ai/portal/cloud-account-azure/manual)
- [Troubleshooting](https://docs.spotto.ai/portal/cloud-account-azure/troubleshooting)

When Spotto reports missing access, fix the operator prerequisite if necessary and rerun the wizard. Existing resources and role assignments are reused where possible.
