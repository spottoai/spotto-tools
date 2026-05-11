# Spotto Tools

Official tools and scripts for Spotto AI - your cloud cost optimization platform.

## What's This?

A collection of automation scripts and tools to help you get up and running with Spotto quickly. Whether you're an individual customer connecting your first Azure subscription or an MSP onboarding multiple customers, we've got you covered.

## What's Inside

### 🚀 Azure Onboarding Script
Automated PowerShell script to connect your Azure environment to Spotto:
- Creates an Azure service principal with the permissions Spotto needs
- Assigns Reader access across your subscriptions, or inherits it via tenant root scope when onboarding all subscriptions
- Optionally assigns recommended Monitoring Reader and Log Analytics Reader roles
- Configures management-group governance visibility, tenant-wide or per-subscription Log Analytics Reader access, plus Reservations Reader and Savings plan Reader access
- Grants Microsoft Graph `Application.Read.All` with admin consent for governance and credential posture
- Highly recommended: Detects or creates Azure Cost Management exports to customer-owned storage, with daily CSV/GZIP exports, immediate first runs when supported, and one-time 13-month backfill where supported
- New billing export resource groups and storage accounts default to Azure location `australiaeast`
- Optional: Sets up write permissions for Advisor recommendations and Storage inventory

The script is **idempotent** - safe to run multiple times.

### 📚 Documentation
- Step-by-step setup guide
- Permissions explained
- Troubleshooting tips

## Quick Start

### Prerequisites
- PowerShell 5.1 or PowerShell 7+
- Azure PowerShell modules including `Az.Accounts`, `Az.Resources`, and `Az.Storage` (the script can install missing modules)
- Azure account with appropriate permissions:
  - Global Administrator or Application Administrator to create the service principal
  - Owner or User Access Administrator on subscriptions, and at tenant root scope (`/`) if onboarding all subscriptions
  - Management Group Contributor or Owner at the root management group
  - Tenant admin consent for Microsoft Graph `Application.Read.All`
  - Highly recommended billing export setup: permission to manage Cost Management exports, storage accounts, containers, and `Storage Blob Data Reader` role assignments

### Setup
```powershell
# Clone the repo
git clone https://github.com/spotto/spotto-tools.git
cd spotto-tools

# Run the setup script
.\onboarding\azure\Setup-SpottoAzure.ps1
```

The script will:
1. Check and install required PowerShell modules
2. Guide you through selecting your tenant and subscriptions
3. Create a service principal named "Spotto AI"
4. Assign the required governance, billing, and optional monitoring permissions
5. Configure the highly recommended Azure Cost Management exports for Spotto cloud-engine to read later
6. Display credentials to copy into the Spotto portal

You can safely rerun the script. It checks for existing Spotto resources, role assignments, storage containers, and export definitions, then reuses or updates them where possible.

### Next Steps

1. Copy the credentials displayed at the end of the script
2. Go to [Spotto Portal](https://portal.spotto.ai)
3. Navigate to: **Connectors** > **Cloud Accounts**
4. Add a cloud account, paste your credentials, click **Validate Credentials**, then click **Create**

## Coming Soon

- ☁️ **AWS Support** - Onboarding scripts for AWS accounts
- 🔧 **Additional Utilities** - Cost reporting, recommendation exports, and more

## Support

- 📖 [Full Documentation](https://docs.spotto.ai)
- 💬 [Support Portal](https://support.spotto.ai)
- 🌐 [Spotto Website](https://spotto.ai)

## Contributing

Found a bug? Have a suggestion? Open an issue or submit a pull request!

## License

MIT License - see [LICENSE](LICENSE) for details
