# Azure Onboarding Wizard

`Setup-SpottoAzure.ps1` is the interactive wizard for connecting Azure to Spotto. Run this one script; it guides you through sign-in, tenant selection, prerequisite checks, Spotto access, and optional billing exports.

It is safe to rerun. Use it again to repair interrupted setup, add missing permissions, or update an existing Spotto connection. Applications created by the wizard carry tenant-specific ownership tags. A matching tagged application is reused automatically, a missing service principal is repaired, and an untagged legacy `Spotto` or `Spotto AI` application is reused only after you enter its exact client ID.

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

For offline verification of application identity, secret recovery, backfill idempotency, deterministic storage naming, safe reuse, option routing, and JSON generation:

```powershell
pwsh -ExecutionPolicy Bypass -File ./onboarding/azure/tests/Setup-SpottoAzure.Offline.ps1
```

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

Press **Enter** to use the default. The wizard automatically selects all subscriptions and configures the Azure and Microsoft Graph reader permissions Spotto needs. It first tries one inherited tenant-root Reader assignment; if Azure rejects that scope, it automatically falls back to idempotent Reader assignments on each selected subscription.

This includes Monitoring Reader, Log Analytics Reader, Security Reader, Key Vault Reader, and the exact Microsoft Graph governance permission set, including `Policy.Read.All` and `LicenseAssignment.Read.All`. Monitoring Reader, Security Reader, and Log Analytics Reader are checked on every selected subscription. Key Vault Reader allows Spotto to inspect secret, key, and certificate expiry metadata without reading secret values or private key material. The wizard assigns it at the exact tenant-root management group when available and automatically falls back to every selected subscription when that assignment cannot be confirmed. This inherited role applies to vaults using Azure RBAC; legacy access-policy vaults still require a per-vault list policy.

The wizard also assigns Reader, Management Group Reader, Monitoring Reader, and Log Analytics Reader at the exact tenant root management group when available, or on each management group visible to the signed-in operator. A child group is never treated as tenant root just because its parent is hidden.

If the existing credential with the latest expiry has at least three months remaining, it is reused. Otherwise the wizard plans a replacement but creates it only after all required setup steps succeed and transcript logging has stopped.

After the read-only permissions, the wizard separately offers recommended Cost Management billing exports and defaults the answer to yes. Declining leaves exports and storage unchanged. Accepting authorizes the signed-in operator to make the required export, storage, and RBAC changes; the Spotto service principal remains read-only and receives `Storage Blob Data Reader` on the private export container. Broad management-group scopes retain a separate consent prompt. When storage is required, select an existing account from the selected subscriptions or create/reuse a dedicated account in a subscription you choose. The preferred dedicated name is `billingexports` plus the final ten normalized tenant-ID characters. Optional Advisor, Storage Inventory, Reservations Contributor, and Policy write permissions remain excluded from Recommended mode.

### Custom setup

Choose Custom setup when you want specific subscriptions, individual permission choices, or supported write capabilities. Billing exports remain optional and default to yes, as they do in Recommended mode. The wizard shows every possible broad scope and requires separate approval before using it; when only some subscriptions were selected, that approval defaults to no. If approved, the wizard prefers one broad export at the exact tenant-root management group. If export access cannot be confirmed there, it tries only the topmost visible child management groups, avoiding overlapping nested exports. Subscriptions added later under an approved management-group branch are automatically included by that broad export.

Management-group exports are not a complete replacement: Azure supports them only for Enterprise Agreement scopes and uncompressed CSV Usage charges, excluding purchases, reservations, savings plans, Amortized Cost, and multiple currencies. The wizard therefore retains subscription Actual/Amortized recurring exports and 13-month backfills by default; an operator can explicitly skip that fallback after confirming an accepted billing-scope export covers every selected subscription and dataset. The wizard does not label a subscription Usage-only export as complete Actual Cost. A backfill is marked pending before its run is requested and queued only after Azure accepts the run. If a run or marker update is interrupted, a rerun reports the pending state as ambiguous and does not blindly queue a duplicate; inspect Azure export run history before retrying it manually. Existing compatible billing-account/profile exports are also reusable. If export storage is needed, creating a dedicated account is the recommended default. Its stable name starts with `billingexports` and uses the final ten tenant-ID characters; reruns find and reuse that exact account in the selected host subscription. A deterministic collision suffix is used when the preferred name cannot be safely created or reused, including when an untagged account with that name is declined. Selecting a restricted existing account requires separate approval before the script enables its public endpoint and changes its default firewall action to Allow.

At the end, after required Azure work succeeds and transcript logging stops, the wizard creates any planned secret and immediately writes `SpottoAzureOnboarding-<tenant-suffix>-<timestamp>.json` in the current directory. If the protected file cannot be written, the wizard removes that exact new Azure credential by key ID; if exact rollback also fails, it displays the still-active value as an emergency recovery path. While adding a new manual Azure cloud account, open the file and paste its complete contents into **Import PowerShell Setup Details**. Existing accounts do not show the importer; retain the saved secret and copy any required billing-source fields from the JSON manually. The file always contains the tenant and client IDs and contains the client secret only when this run created one. Accepted recurring billing, management-group, and subscription exports are included in `billingExports.sources[]` up to the portal's 50-source and 24-KiB configuration limits. Non-conventional locators are retained before conventional scopes and names that cloud-engine can rediscover, and the script warns when anything is still omitted for manual review. Each included source carries its exact Azure scope, dataset, export name, and storage destination when known. One-time backfill definitions are not emitted as recurring sources. The file uses exclusive-create semantics and owner-only filesystem permissions. A JSON file containing a client secret is sensitive. The wizard keeps it by default and deletes it only when you explicitly confirm that the portal import and save succeeded.

### Check prerequisites

Choose **Check prerequisites** to assess the signed-in operator before setup. The wizard separately checks subscription RBAC assignment, Cost Management export-write, storage-account write, blob-container write, management-group export/RBAC authority, tenant/provider-scope authority, current reservation inventory visibility, and Azure resource-role PIM eligibility. It expands only the scopes that need action, PIM activation, or manual review.

Eligible PIM access is reported separately from active access. Activate the suggested role, reconnect the Azure session, and rerun the check before using Recommended setup. Assessment is read-only by default. When Cost Management export-write access is missing and the same session has confirmed role-assignment authority at that exact scope, the wizard offers to assign **Cost Management Contributor** to the signed-in principal. The prompt lists every scope and defaults to no; declining changes nothing, while acceptance creates or reuses only those exact role assignments and requires reconnecting and rerunning the check. No applications, secrets, exports, storage, policies, or provider registrations are changed. The wizard can install missing PowerShell modules locally.

Microsoft Entra app-management roles, Graph admin-consent roles, and Entra directory-role PIM are left as an explicit manual check because inspecting them safely would require the diagnostic mode to request extra Microsoft Graph permissions.

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
