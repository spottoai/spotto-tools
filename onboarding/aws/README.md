# Connect AWS from the Command Line

`connect.sh` (Bash 3.2+) and `Connect-SpottoAws.ps1` (PowerShell 7+) deploy the same
CloudFormation templates as the Portal, using your own AWS CLI v2 session. The
Portal supplies the deployment, registration topic, company External ID and trusted
principal together. Copy them as one command; do not choose a different geography.

## Regional setup

| Spotto geography | Access/registration stack and new CUR bucket |
| --- | --- |
| AU | Sydney (`ap-southeast-2`) |
| US | N. Virginia (`us-east-1`) |
| EU | Stockholm (`eu-north-1`) |

Development AU and production AU have different topics and resource names even
though both use Sydney. Each topic delivers only to its owning API. Public generic
templates share central S3 hosting; private CUR files are stored separately.

For a new export, the scripts wait for the regional access stack (role, private
bucket and delivery policy), then create `SpottoBillingExport-<deployment>` in
`us-east-1`. AWS only provides the Data Exports definition control plane there.
Files are delivered directly to the regional bucket; the billing-only stack has no
External ID, registration topic or customer compute runtime. The plan asks for
approval before either stack is changed.

## Run the command

Copy the command from **Connect AWS → Use CloudShell**. An AU development example:

```bash
curl -fsSL https://raw.githubusercontent.com/spottoai/spotto-tools/main/onboarding/aws/connect.sh | bash -s -- \
  --deployment dev-au \
  --registration-topic-arn arn:aws:sns:ap-southeast-2:715809501612:spotto-aws-connect-dev-au \
  --external-id spotto-<from-the-portal> \
  --trusted-principal-arn <from-the-portal>
```

For a local checkout, use your own signed-in profile:

```bash
bash onboarding/aws/connect.sh --profile <name> --deployment dev-au --external-id <id> --trusted-principal-arn <arn>
```

```powershell
pwsh ./onboarding/aws/Connect-SpottoAws.ps1 -AwsProfile <name> -Deployment dev-au -ExternalId <id> -TrustedPrincipalArn <arn>
```

## Options

| Bash | PowerShell | Meaning |
| --- | --- | --- |
| `--deployment` | `-Deployment` | Required: `dev-au`, `prod-au`, `prod-us` or `prod-eu`, from the Portal |
| `--registration-topic-arn` | `-RegistrationTopicArn` | Topic from the same API setup; a mismatched topic is rejected before AWS calls |
| `--external-id` | `-ExternalId` | Company External ID, required for first connection |
| `--trusted-principal-arn` | `-TrustedPrincipalArn` | Runtime principal shown in Portal, required for first connection |
| `--profile` | `-AwsProfile` | AWS CLI profile; otherwise the current credential chain |
| `--cost-data create\|existing` | `-CostData` | Create regional storage and a global export definition, or select an existing export |
| `--export-arn` | `-ExportArn` | An existing CUR 2.0 export; otherwise choose from discovery |
| `--connect-members yes\|no` | `-ConnectMembers` | Deploy member roles with a service-managed StackSet |
| `--organizational-unit-ids` | `-OrganizationalUnitIds` | Selected root/OU IDs for member accounts |
| `--role-name` | `-RoleName` | Default `SpottoReadOnlyRole` in every deployment; renaming an existing stack's role is refused |
| `--check` | `-Check` | Report version, drift and member status; a required missing export stack is unhealthy |
| `--repair` | `-Repair` | Reapply role policies; recreate a deleted role while retaining billing resources |
| `--yes` | `-Yes` | Accept the displayed/default operations without interactive questions |
| `--help` | `-Help` | Show usage |

A new connection must create an export or select a supported existing one. An
existing export must be Parquet, daily/hourly and include resource IDs; the scripts
read its destination and resolve its KMS key rather than inventing a location.
Keep existing source geography explicit and check your company's data-location
requirements before using a source elsewhere. No source is silently moved.

## Update, check and repair

Use the same deployment every time. Stack names are suffixed with it:
`SpottoConnect-<deployment>`, `SpottoBillingAccess-<deployment>`,
`SpottoMemberAccounts-<deployment>` and `SpottoBillingExport-<deployment>`.
The default new bucket is `spotto-billing-<account-id>-<deployment>` and the export
is `spotto-cur2-<deployment>` under `cur2`. This avoids dev/prod name collisions.

```bash
bash onboarding/aws/connect.sh --deployment dev-au --check
bash onboarding/aws/connect.sh --deployment dev-au --repair
```

```powershell
pwsh ./onboarding/aws/Connect-SpottoAws.ps1 -Deployment dev-au -Check
pwsh ./onboarding/aws/Connect-SpottoAws.ps1 -Deployment dev-au -Repair
```

Reruns use versioned templates and preserve unchanged stack parameters. The US
export stack is checked in its own region, independently of the regional access
stack. Repair never changes deployment or moves billing files. Billing bucket,
delivery policy and export definitions are retained when access stacks are removed.
The owning Spotto registration endpoint must remain available for stack deletion.

## Troubleshooting

- **Deployment or topic mismatch:** copy the full command from the owning Portal.
- **Registration timed out:** check the company External ID, the exact regional SNS
  topic in the plan, SCP restrictions on SNS Publish and the owning API availability.
- **An existing role/export conflicts:** use the intended deployment or a supported
  existing export; do not delete retained billing data as an incidental repair.
- **Export limit reached:** AWS permits five CUR 2.0 exports per account. Reuse a
  supported regional export or review unused definitions explicitly.
- **First data is absent:** AWS can take up to 24 hours to deliver current-month files.
  Setup can finish once the definition and storage access are validated.

Offline checks (no AWS calls):

```bash
bash onboarding/aws/tests/connect.test.sh
pwsh -NoProfile -File onboarding/aws/tests/connect.test.ps1
bash .github/scripts/publish-versioned-templates.test.sh
```

A failed regional registration can leave a retained bucket before the export
stack exists. The command can recreate access without recreating that bucket,
grant its exact billing prefix and create the missing definition. It checks the
retained bucket's account owner, region and existing delivery policy before deleting
the failed access stack. A failed check stops without deletion; restore the managed
policy or review the retained resources explicitly. It never empties/deletes a bucket.

Recovery intent is saved in the access stack before continuing billing setup. If either
the export or billing-access step fails, rerun the same command; it resumes using the
retained bucket. `--check`/`-Check` reports either missing billing component.
