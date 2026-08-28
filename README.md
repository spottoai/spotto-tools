# Spotto Tools

Use the Azure onboarding wizard to connect your Azure environment to Spotto. It can check prerequisites without changing Azure, or create and repair the Spotto service principal and permissions through a guided PowerShell workflow. Billing exports are available through Custom setup.

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

- **Recommended read-only access** is the default. Press **Enter** and the wizard selects all subscriptions and configures the reader permissions Spotto needs. If Azure does not allow a tenant-root Reader assignment, the wizard automatically tries each subscription instead. It also grants the read-only management-group roles at the exact tenant root when available, or across the management groups visible to the signed-in operator. Key Vault Reader is assigned at the tenant-root management group when possible, with automatic selected-subscription fallback, so Spotto can inspect secret, key, and certificate expiry metadata without reading secret values or private key material. It reuses a credential with at least three months remaining and does not configure billing exports, storage, or optional write access.
- **Custom setup** lets you choose subscriptions and individual capabilities. Billing exports and export storage are optional, default to no, and are configured only when you explicitly enable them.
- **Check prerequisites** is a read-only dry run. It checks active access across subscriptions, visible management groups, Reservations, and Savings Plans, then shows eligible Azure resource PIM roles that may need activation. It does not create an app, secret, role assignment, export, or storage resource.

You will still choose the Azure tenant to connect. The wizard explains anything else it needs as it goes.

## More information

- [Azure onboarding quick guide](./onboarding/azure/README.md)
- [Detailed Azure PowerShell setup and permissions](https://docs.spotto.ai/portal/cloud-account-azure/powershell)
- [Azure onboarding troubleshooting](https://docs.spotto.ai/portal/cloud-account-azure/troubleshooting)

## Support

- [Spotto documentation](https://docs.spotto.ai)
- [Spotto support](https://support.spotto.ai)

## License

MIT License - see [LICENSE](./LICENSE).
