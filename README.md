# Spotto Tools

Use the Azure onboarding wizard to connect your Azure environment to Spotto. It can assess prerequisites without changing Azure by default, or create and repair the Spotto service principal and permissions through a guided PowerShell workflow. Recommended and Custom setup both offer optional billing exports.

The wizard is safe to rerun. If setup is interrupted or Spotto reports a missing permission later, run it again and it will reuse existing resources where possible.

## Run on your machine

Open PowerShell and run:

```powershell
git clone https://github.com/spottoai/spotto-tools.git
Set-Location ./spotto-tools
pwsh -ExecutionPolicy Bypass -File ./onboarding/azure/Setup-SpottoAzure.ps1
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

## Choose a setup mode

- **Recommended read-only access** is the default. Press **Enter** and the wizard selects all subscriptions and configures the reader permissions Spotto needs. If Azure does not allow a tenant-root Reader assignment, the wizard automatically tries each subscription instead. It also grants the read-only management-group roles at the exact tenant root when available, or across the management groups visible to the signed-in operator. Key Vault Reader is assigned at the tenant-root management group when possible, with automatic selected-subscription fallback, so Spotto can inspect secret, key, and certificate expiry metadata without reading secret values or private key material. It reuses a credential with at least three months remaining. The wizard then separately offers recommended billing exports, defaulting to yes; decline to leave exports and storage unchanged. Optional Advisor, Storage Inventory, Reservations Contributor, and Policy write permissions remain excluded.
- **Custom setup** lets you choose subscriptions and individual capabilities. Billing exports are optional and default to yes in both setup modes because export files reduce Cost Management API dependence. After showing the exact broad scopes and requesting separate approval, the wizard first tries a tenant-root management-group export, then topmost visible child groups when root export access is unavailable. Azure supports management-group exports only for EA Usage, so subscription Actual/Amortized exports remain enabled for complete coverage. When storage is needed, choose an existing account from the selected subscriptions or create/reuse a dedicated account in a subscription you select. Its preferred name is `billingexports` plus the final ten normalized tenant-ID characters.
- **Check prerequisites** performs a read-only assessment across subscriptions, visible management groups, Reservations, Savings Plans, and eligible Azure resource PIM roles. If Cost Management export-write access is missing but the operator can assign roles at the exact affected scope, it offers a separate, explicit default-no Cost Management Contributor assignment to the signed-in principal. Declining makes no Azure change.

You will still choose the Azure tenant to connect. The wizard explains anything else it needs as it goes.

After setup, the wizard writes a versioned `SpottoAzureOnboarding-<tenant-suffix>-<timestamp>.json` file for the portal importer. While adding a new manual Azure cloud account, open the file and paste its complete contents into **Import PowerShell Setup Details**. Existing accounts do not show the importer; retain the saved secret and copy any required billing-source fields from the JSON manually. The file always includes the tenant/client values and includes a client secret only when the current run created one. It records accepted recurring billing, management-group, and subscription exports in `billingExports.sources[]`, bounded to the portal's 50-source and 24-KiB limits. Non-conventional locators are retained before conventional sources that cloud-engine can rediscover; the script warns if anything is still omitted for manual review. The file is created without overwriting an existing path and is restricted to the current OS user. Treat a file containing a client secret as sensitive and delete it after use.

## More information

- [Azure onboarding quick guide](./onboarding/azure/README.md)
- [Detailed Azure PowerShell setup and permissions](https://docs.spotto.ai/portal/cloud-account-azure/powershell)
- [Azure onboarding troubleshooting](https://docs.spotto.ai/portal/cloud-account-azure/troubleshooting)

## Support

- [Spotto documentation](https://docs.spotto.ai)
- [Spotto support](https://support.spotto.ai)

## License

MIT License - see [LICENSE](./LICENSE).
