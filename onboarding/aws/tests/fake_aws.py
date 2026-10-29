#!/usr/bin/env python3
"""Offline stand-in for the AWS CLI v2, used by connect.test.sh and connect.test.ps1.

Responses are the already --query'd text output the scripts ask for. Settings (env):
  FAKE_AWS_SCENARIO     standalone | management | member | existing | role-exists |
                        members-fail | registration-fail
  FAKE_AWS_STATE        folder holding stacks (<name>.json) and the role (role)
  FAKE_AWS_LOG          every call is appended here, plus a normalised PARAMS line
  FAKE_LATEST_VERSION   version of the unversioned (latest) templates; "" or "none" = no version
  FAKE_DRIFTED          comma-separated stacks that report drift
  FAKE_INSTANCES        StackSet instances, "account,STATUS,DETAILED;..."
  FAKE_DENY             comma-separated operations to deny, e.g. list-stack-instances or
                        describe-stacks:SpottoBillingAccess (operation:stack)
  FAKE_BILLING_REPAIR_TOKEN  "1" makes the billing-access template declare RepairToken
  FAKE_EXPORT_GRANULARITY / FAKE_EXPORT_RESOURCES  the existing export's TIME_GRANULARITY / INCLUDE_RESOURCES
                        (default DAILY / TRUE)
  FAKE_EXPORT_QUERY     the existing export's QueryStatement (default selects line_item_resource_id)
  FAKE_BUCKET_KEY       the billing bucket's KMSMasterKeyID: a key ID (default), key ARN, alias name or alias ARN;
                        "none" = SSE-S3; aliases ending in "missing" don't exist
  FAKE_MANAGED_POLICIES managed policy ARNs attached to the role, comma-separated; "none" = none
                        (default: ViewOnlyAccess and SecurityAudit)
`aws fake-seed <stack> <version> Key=Value...` writes a deployed stack for a test.
"""
import json
import os
import re
import sys

ACCOUNT = "111122223333"
SCENARIO = os.environ.get("FAKE_AWS_SCENARIO", "standalone")
STATE = os.environ["FAKE_AWS_STATE"]
LATEST = os.environ.get("FAKE_LATEST_VERSION", "2026-10-30.1")
if LATEST == "none":  # PowerShell can't set an empty environment variable
    LATEST = ""
TEMPLATE_PARAMS = {
    "spotto-aws-connect.template.json": ["ExternalId", "TrustedPrincipalArn", "Deployment", "RegistrationTopicArn", "BillingExportName", "CostData", "RetainedBillingStorage", "RoleName", "RepairToken"],
    "spotto-aws-billing-export.template.json": ["Deployment", "BucketRegion"],
    "spotto-aws-billing-access.template.json": ["RoleName", "ExportName", "BucketName", "BasePrefix", "KmsKeyArn"],
    "spotto-aws-members.template.json": ["ExternalId", "TrustedPrincipalArn", "OrganizationalUnitIds", "RoleName", "RepairToken"],
}
if os.environ.get("FAKE_BILLING_REPAIR_TOKEN") == "1":
    TEMPLATE_PARAMS["spotto-aws-billing-access.template.json"].append("RepairToken")
MANAGED_POLICY_ARNS = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess", "arn:aws:iam::aws:policy/SecurityAudit"]
REQUIRED = {"SpottoBillingExport": ["Deployment", "BucketRegion"], "SpottoConnect": ["ExternalId", "TrustedPrincipalArn", "Deployment", "RegistrationTopicArn", "BillingExportName", "RoleName"], "SpottoBillingAccess": ["ExportName", "BucketName"],
            "SpottoMemberAccounts": ["ExternalId", "TrustedPrincipalArn", "OrganizationalUnitIds"]}


def base_stack(stack):
    return re.sub(r"-(dev-au|prod-au|prod-us|prod-eu)$", "", stack)


def fail(code, op, message, rc=254):
    sys.stderr.write(f"\nAn error occurred ({code}) when calling the {op} operation: {message}\n")
    sys.exit(rc)


def arg(args, name, default=""):
    return args[args.index(name) + 1] if name in args else default


def path(name):
    return os.path.join(STATE, name)


def load(stack):
    try:
        with open(path(stack + ".json"), encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def save(stack, data):
    with open(path(stack + ".json"), "w", encoding="utf-8") as f:
        json.dump(data, f)
    if base_stack(stack) == "SpottoConnect":
        open(path("role"), "w").close()


def parse_url(url):
    m = re.match(r"^https://spotto-aws-onboarding\.s3\.amazonaws\.com/cloudformation/(?:v([^/]+)/)?([^/]+)$", url)
    if not m or m.group(2) not in TEMPLATE_PARAMS:
        fail("ValidationError", "GetTemplateSummary", f"Template URL not found: {url}")
    return m.group(1) if m.group(1) else LATEST, m.group(2)


def read_params(argv):
    raw = arg(argv, "--parameters")
    if raw.startswith("file://"):
        raw = open(raw[len("file://"):], encoding="utf-8-sig").read()
    return json.loads(raw) if raw else []


def resolve(stack, given, previous, file):
    params = {}
    for p in given:
        key = p["ParameterKey"]
        if key not in TEMPLATE_PARAMS[file]:
            fail("ValidationError", "UpdateStack", f"Parameters: [{key}] do not exist in the template")
        if p.get("UsePreviousValue"):
            if previous is None or key not in previous:
                fail("ValidationError", "UpdateStack", f"Cannot specify UsePreviousValue for {key}: not in the previous stack")
            params[key] = previous[key]
        else:
            params[key] = p["ParameterValue"]
    missing = [k for k in REQUIRED[base_stack(stack)] if k not in params]
    if missing:
        fail("ValidationError", "CreateStack", f"Parameters: {missing} must have values")
    return params


def main():
    argv = sys.argv[1:]
    log = open(os.environ["FAKE_AWS_LOG"], "a", encoding="utf-8")
    log.write(" ".join(argv) + "\n")
    if argv == ["--version"]:
        print("aws-cli/2.17.0 Python/3.11.9 Linux/6.1 exe/x86_64")
        return
    request_region = arg(argv, "--region")
    args = list(argv)
    for flag in ("--profile", "--region"):
        while flag in args:
            i = args.index(flag)
            del args[i:i + 2]
    if args[0] == "fake-seed":
        stack, version = args[1], args[2]
        file = {"SpottoConnect": "spotto-aws-connect.template.json", "SpottoBillingAccess": "spotto-aws-billing-access.template.json",
                "SpottoMemberAccounts": "spotto-aws-members.template.json", "SpottoBillingExport": "spotto-aws-billing-export.template.json"}[base_stack(stack)]
        save(stack, {"status": "CREATE_COMPLETE", "version": version, "file": file,
                     "params": dict(kv.split("=", 1) for kv in args[3:])})
        return
    cmd = " ".join(args[:2])
    query = arg(args, "--query")
    stack = arg(args, "--stack-name")
    if not stack and cmd == "cloudformation describe-stack-drift-detection-status":
        stack = arg(args, "--stack-drift-detection-id").removeprefix("drift-")
    current = load(stack) if stack else None
    if cmd.startswith("cloudformation ") and stack:
        boundary = re.search(r"(dev-au|prod-au|prod-us|prod-eu)$", stack)
        if boundary:
            region = {"dev-au": "ap-southeast-2", "prod-au": "ap-southeast-2", "prod-us": "us-east-1", "prod-eu": "eu-north-1"}[boundary.group(1)]
            if base_stack(stack) == "SpottoBillingExport":
                region = "us-east-1"
            if request_region != region:
                fail("WrongRegion", cmd, f"Expected {region}, got {request_region}")
    if "--parameters" in args:
        pairs = [f"{p['ParameterKey']}=" + ("(previous)" if p.get("UsePreviousValue") else p["ParameterValue"]) for p in read_params(args)]
        log.write(f"PARAMS {stack} " + ";".join(pairs) + "\n")
    log.close()

    deny = os.environ.get("FAKE_DENY", "").split(",")
    if len(args) > 1 and (args[1] in deny or f"{args[1]}:{stack}" in deny):
        fail("AccessDenied", args[1], f"User: arn:aws:iam::{ACCOUNT}:user/admin is not authorized to perform: {args[0]}:{args[1]}")
    if cmd == "sts get-caller-identity":
        print(f"{ACCOUNT}\tarn:aws:iam::{ACCOUNT}:user/admin")
    elif cmd == "organizations describe-organization":
        if SCENARIO in ("standalone", "existing", "role-exists", "registration-fail"):
            fail("AWSOrganizationsNotInUseException", "DescribeOrganization", "Your account is not a member of an organization.")
        print(f"o-abc1234567\t{'999988887777' if SCENARIO == 'member' else ACCOUNT}")
    elif cmd == "organizations list-roots":
        print("r-ab12")
    elif cmd == "cloudformation describe-organizations-access":
        print("ENABLED")
    elif cmd == "cloudformation activate-organizations-access":
        pass
    elif cmd == "iam get-role":
        if SCENARIO == "role-exists" or os.path.exists(path("role")):
            print(f"arn:aws:iam::{ACCOUNT}:role/{arg(args, '--role-name')}")
        else:
            fail("NoSuchEntity", "GetRole", "The role cannot be found.")
    elif cmd == "iam list-attached-role-policies":
        if not (SCENARIO == "role-exists" or os.path.exists(path("role"))):
            fail("NoSuchEntity", "ListAttachedRolePolicies", "The role cannot be found.")
        attached = os.environ.get("FAKE_MANAGED_POLICIES", ",".join(MANAGED_POLICY_ARNS))
        print("\t".join(a for a in attached.split(",") if a and a != "none"))
    elif cmd == "bcm-data-exports list-exports":
        if SCENARIO == "existing":
            print(f"contoso-cur2\tarn:aws:bcm-data-exports:us-east-1:{ACCOUNT}:export/contoso-cur2-abcd")
    elif cmd == "bcm-data-exports get-export":
        if query == "Export.DataQuery.QueryStatement":
            print(os.environ.get("FAKE_EXPORT_QUERY", "SELECT identity_line_item_id,\n  line_item_resource_id,\n  line_item_unblended_cost\nFROM COST_AND_USAGE_REPORT"))
        else:
            print("contoso-cur2\tcontoso-billing\treports\tus-east-1\tPARQUET\t"
                  + os.environ.get("FAKE_EXPORT_GRANULARITY", "DAILY") + "\t" + os.environ.get("FAKE_EXPORT_RESOURCES", "TRUE"))
    elif cmd == "s3api head-bucket":
        if os.environ.get("FAKE_RETAINED_BUCKET") == "missing":
            fail("404", "HeadBucket", "Not Found")
        if os.environ.get("FAKE_RETAINED_BUCKET") == "foreign":
            fail("403", "HeadBucket", "Forbidden")
    elif cmd == "s3api get-bucket-location":
        bucket = arg(args, "--bucket")
        region = "eu-north-1" if bucket.endswith("-prod-eu") else "ap-southeast-2" if bucket.endswith(("-dev-au", "-prod-au")) else "us-east-1"
        print("us-west-2" if os.environ.get("FAKE_RETAINED_BUCKET") == "wrong-region" else region)
    elif cmd == "s3api get-bucket-policy":
        if os.environ.get("FAKE_RETAINED_BUCKET") == "no-policy":
            fail("NoSuchBucketPolicy", "GetBucketPolicy", "Missing policy")
        print('{"Policy":"existing managed delivery policy"}')
    elif cmd == "s3api get-bucket-encryption":
        key = os.environ.get("FAKE_BUCKET_KEY", "1234abcd-12ab-34cd-56ef-1234567890ab")
        print("AES256\tNone" if key == "none" else f"aws:kms\t{key}")
    elif cmd == "kms describe-key":
        key = arg(args, "--key-id")
        if key.endswith("missing"):
            fail("NotFoundException", "DescribeKey", f"Alias {key} is not found.")
        key_id = key.rsplit("/", 1)[-1] if ":key/" in key or re.match(r"^[0-9a-f-]{36}$", key) else "5678efgh-56ef-78gh-90ij-567890abcdef"
        print(f"arn:aws:kms:us-east-1:{ACCOUNT}:key/{key_id}")
    elif cmd == "cloudformation get-template-summary":
        if "--template-url" in args:
            version, file = parse_url(arg(args, "--template-url"))
        elif current:
            version, file = current["version"], current["file"]
        else:
            fail("ValidationError", "GetTemplateSummary", f"Stack with id {stack} does not exist")
        if query == "Metadata":
            print(json.dumps({"GeneratedBy": "fake", **({"TemplateVersion": version} if version else {})}, indent=2))
        else:
            print("\t".join(TEMPLATE_PARAMS[file]))
    elif cmd == "cloudformation describe-stacks":
        if not current:
            fail("ValidationError", "DescribeStacks", f"Stack with id {stack} does not exist")
        if "Outputs" in query:
            key = query.split("'")[1]
            print({"RoleArn": f"arn:aws:iam::{ACCOUNT}:role/{current['params'].get('RoleName', 'SpottoReadOnlyRole')}",
                   "BillingBucketName": f"spotto-billing-{ACCOUNT}-{current['params'].get('Deployment', 'prod-us')}"}.get(key, "None"))
        elif "Parameters" in query:
            for k, v in current["params"].items():
                print(f"{k}\t{v}")
        else:
            print(current["status"])
    elif cmd in ("cloudformation create-stack", "cloudformation update-stack"):
        version, file = parse_url(arg(args, "--template-url"))
        if cmd.endswith("create-stack") and base_stack(stack) == os.environ.get("FAKE_FAIL_CREATE_STACK"):
            fail("ValidationError", "CreateStack", "Simulated interrupted billing provisioning")
        if cmd.endswith("create-stack"):
            if current:
                fail("AlreadyExistsException", "CreateStack", f"Stack [{stack}] already exists")
            save(stack, {"status": "CREATE_COMPLETE", "version": version, "file": file, "params": resolve(stack, read_params(args), None, file)})
        else:
            params = resolve(stack, read_params(args), current["params"], file)
            if params == current["params"] and version == current["version"]:
                fail("ValidationError", "UpdateStack", "No updates are to be performed.")
            save(stack, {"status": "UPDATE_COMPLETE", "version": version, "file": file, "params": params})
        print(f"arn:aws:cloudformation:{request_region}:{ACCOUNT}:stack/{stack}/1")
    elif cmd == "cloudformation delete-stack":
        if current:
            os.remove(path(stack + ".json"))
            if base_stack(stack) == "SpottoConnect" and os.path.exists(path("role")):
                os.remove(path("role"))
    elif cmd == "cloudformation wait":
        if (SCENARIO == "members-fail" and base_stack(stack) == "SpottoMemberAccounts") or (SCENARIO == "registration-fail" and base_stack(stack) == "SpottoConnect"):
            sys.stderr.write("Waiter StackCreateComplete failed: Waiter encountered a terminal failure state\n")
            sys.exit(255)
    elif cmd == "cloudformation describe-stack-events":
        if base_stack(stack) == "SpottoConnect":
            print("SpottoConnect\tThe following resource(s) failed to create: [SpottoRegistration].")
            print("SpottoRegistration\tCloudFormation did not receive a response from your Custom Resource.")
        else:
            print("SpottoMemberAccounts\tThe following resource(s) failed to create: [MemberRoleStackSet].")
            print("MemberRoleStackSet\tYou must enable organizations access to operate a service managed stack set")
    elif cmd == "cloudformation detect-stack-drift":
        print(f"drift-{stack}")
    elif cmd == "cloudformation describe-stack-drift-detection-status":
        drifted = arg(args, "--stack-drift-detection-id")[len("drift-"):] in os.environ.get("FAKE_DRIFTED", "").split(",")
        print(f"DETECTION_COMPLETE\t{'DRIFTED' if drifted else 'IN_SYNC'}")
    elif cmd == "cloudformation describe-stack-resource-drifts":
        if stack in os.environ.get("FAKE_DRIFTED", "").split(","):
            print("Role\tMODIFIED")
    elif cmd == "cloudformation list-stack-instances":
        for item in filter(None, os.environ.get("FAKE_INSTANCES", "").split(";")):
            print("\t".join(item.split(",")))
    else:
        fail("FakeNotImplemented", cmd, "not handled by fake_aws.py", rc=2)


main()
