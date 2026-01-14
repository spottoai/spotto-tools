# Spotto Tools

Official tools and scripts for Spotto AI - your cloud cost optimization platform.

## What's This?

A collection of automation scripts and tools to help you get up and running with Spotto quickly. Whether you're an individual customer connecting your first Azure subscription or an MSP onboarding multiple customers, we've got you covered.

## What's Inside

### 🚀 Azure Onboarding Script
Automated PowerShell script to connect your Azure environment to Spotto:
- Creates Azure service principal with appropriate permissions
- Assigns Reader role across your subscriptions
- Configures Reservation and Savings Plan access
- Grants Microsoft Graph permissions
- Optional: Sets up write permissions for Advisor recommendations and Storage inventory

The script is **idempotent** - safe to run multiple times.

### 📚 Documentation
- Step-by-step setup guide
- Permissions explained
- Troubleshooting tips

## Quick Start

### Prerequisites
- PowerShell 5.1 or PowerShell 7+
- Azure account with appropriate permissions:
  - Global Administrator or Application Administrator (to create service principals)
  - Owner or User Access Administrator role on subscriptions

### Setup
```powershell
# Clone the repo
git clone https://github.com/spotto/spotto-tools.git
cd spotto-tools/azure

# Run the setup script
.\Setup-SpottoAzure.ps1
```

The script will:
1. Check and install required PowerShell modules
2. Guide you through selecting your tenant and subscriptions
3. Create a service principal named "Spotto AI"
4. Assign necessary permissions
5. Display credentials to copy into the Spotto portal

### Next Steps

1. Copy the credentials displayed at the end of the script
2. Go to [Spotto Portal](https://portal.spotto.ai)
3. Navigate to: **Cloud Accounts** > **Add Cloud Account**
4. Paste your credentials and click **Validate & Create**

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