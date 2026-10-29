# AWS Launch Stack Templates

These templates are **generated**. Don't edit them by hand: change the policy builders in the `api` repo and run

```bash
cd api
npm run aws:connect-templates         # regenerate
npm run aws:connect-templates:check   # fail when these files are out of date
```

The generator is `api/scripts/aws/generate-connect-templates.ts`. It uses the same builders as the manual IAM bundle. Run the check before publishing to verify that these generated files still match the API policies. Customers and the public publisher do not need access to the API repository.

The files are published unchanged to `AWS_CONNECT_TEMPLATE_BASE_URL`, `https://spotto-aws-onboarding.s3.amazonaws.com/cloudformation/`, with the same file names. Deploy access templates in the API-supplied region; only the separate billing-definition template uses us-east-1.

The publishing workflow runs on `main` and uses GitHub OIDC to upload the templates.
It checks versioned files for content conflicts and checks every existing latest
template before uploading anything. A release cannot replace a latest template
with an older date or build number, including when an older workflow is rerun.
Same-version retries and newer releases are allowed. Unreadable templates or
missing/invalid version metadata stop publishing. Latest aliases are updated only
after the versioned upload succeeds. Versioned content is protected by the publisher's
checks; S3 write-once enforcement is not configured.

Run the offline publisher checks with:

```bash
bash .github/scripts/publish-versioned-templates.test.sh
```

## Template responsibilities

| Template | Region | Resources |
| --- | --- | --- |
| `spotto-aws-connect.template.json` | API-supplied regional boundary | Access role, optional regional private billing bucket/policy, regional registration |
| `spotto-aws-billing-export.template.json` | `us-east-1` (AWS-global definition) | Native CUR 2.0 export definition only; regional delivery |
| `spotto-aws-billing-access.template.json` | Access stack region | Read access to an existing export's exact S3 prefix/KMS key |
| `spotto-aws-members.template.json` | Access stack region | Service-managed member-role StackSet |
| `spotto-aws-member-role.template.json` | StackSet's regional target | Member-account access role |

The access stack requires the paired `Deployment`, `RegistrationTopicArn` and
`BillingExportName` from the API, plus `ExternalId`, `TrustedPrincipalArn` and
`RoleName`. Its rules validate deployment/region/topic/export together. `CreateExport`
prepares regional storage/read access; it does not create a global export resource.
`None` is used when granting access to an existing export. There is no US default
for registration. `RepairToken` reapplies the role's policies without a new identity.

The billing-export template accepts only `Deployment` and `BucketRegion`. Bucket
and export names are derived from that deployment and the current AWS account;
`S3BucketOwner` is explicit and a rule rejects a destination region that does not
match the deployment. This stack has no External ID, SNS callback, role or Lambda.
Create it only after the regional access stack completes. It outputs `ExportArn`.

AU uses Sydney `ap-southeast-2`, US N. Virginia `us-east-1`, EU Stockholm
`eu-north-1`. Dev AU and prod AU are separate boundaries. Access, billing-access,
member and export stack names end in `-<deployment>`; the default role is
`SpottoReadOnlyRole` in every deployment. New billing bucket:
`spotto-billing-<account-id>-<deployment>`. New export:
`spotto-cur2-<deployment>` with daily Parquet/resource IDs at prefix `cur2`.

Billing bucket, policy and export are retained. Removing access does not erase
billing files. Existing-source setup validates its real owner/region/prefix and
never silently changes its destination. For usage see [the client guide](../README.md).

Template-level metadata alone cannot update a CloudFormation stack. Each release
also stamps inline-policy Sids and the export description, so version-only changes
are noninterrupting resource updates with stable names and unchanged permissions.

`RetainedBillingStorage` defaults to `false`. The clients set it to `true` only for
verified retained-storage recovery, with `CostData=None`; a rule rejects other
combinations. This persists the need for the separate billing-export and billing-access
stacks, allowing interrupted recovery to resume and checks to detect missing components.
