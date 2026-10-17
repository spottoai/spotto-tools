"""Run the standalone Bash entrypoint; only AWS is replaced by FakeAwsCli.py.

The package fixture is copied unchanged from terraform-aws-spotto/tests/fixtures/
spotto-aws-setup.json, generated there by the real API bundle builder.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest


TESTS = Path(__file__).resolve().parent
ACCOUNT = "111122223333"
MUTATIONS = {
    "create-role", "update-assume-role-policy", "tag-role", "put-role-policy",
    "attach-role-policy", "delete-role-policy",
}


class BashOnboardingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotto bash tests ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.script = self.root / "setup-spotto-aws.sh"
        source = TESTS.parent / self.script.name
        if source.exists():
            shutil.copyfile(source, self.script)
        fake = self.root / "aws"
        shutil.copyfile(TESTS / "FakeAwsCli.py", fake)
        fake.chmod(0o700)
        self.state_path = self.root / "state.json"
        self.write_state({"roles": {}, "calls": []})
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("SPOTTO_TEST_")}
        self.environment.update(PATH=f"{self.root}{os.pathsep}{os.environ['PATH']}",
                                SPOTTO_TEST_STATE=str(self.state_path),
                                SPOTTO_TEST_ACCOUNT=ACCOUNT)
        self.package = json.loads((TESTS / "fixtures/spotto-aws-setup.json").read_text())
        # Discovery-only standalone account, retaining the API-authored policies.
        self.package["roles"] = [self.package["roles"][2]]
        role = self.package["roles"][0]
        role["accountId"] = ACCOUNT
        role["roleArn"] = f"arn:aws:iam::{ACCOUNT}:role/SpottoReadOnlyRole"
        estate = self.package["configuration"]["estates"][0]
        account = copy.deepcopy(estate["accounts"][0])
        account.update(purposes=["resource-discovery"], roleArn=role["roleArn"])
        estate.update(accounts=[account], billingSources=[], kind="standalone")
        estate.pop("organization")
        self.package_path = self.root / "setup package.json"
        self.output = self.root / "results.json"

    def write_state(self, state):
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def mutations(self):
        return [call["action"] for call in self.state()["calls"] if call["action"] in MUTATIONS]

    def run_script(self, *options, expected=0, answers=None):
        self.package_path.write_text(json.dumps(self.package))
        self.output = self.root / f"results-{len(list(self.root.glob('results*')))}.json"
        arguments = [os.environ.get("SPOTTO_TEST_BASH", "bash"), str(self.script), "--setup-package", str(self.package_path),
                     "--output", str(self.output)]
        if answers is None:
            arguments.append("--non-interactive")
        with subprocess.Popen(arguments + list(options), stdin=subprocess.PIPE, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env=self.environment, start_new_session=True) as process:
            try:
                log, _ = process.communicate(answers or "", timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                self.fail("Bash onboarding exceeded the 60 second test deadline")
            self.assertEqual(process.returncode, expected, log)
        self.assertNotIn("sensitive-diagnostic-sentinel", log)
        report = json.loads(self.output.read_text()) if self.output.exists() else None
        return report, log

    def configure(self, *options, **kwargs):
        return self.run_script("--configure", "--yes", *options, **kwargs)

    def configured_role(self):
        bundle = self.package["roles"][0]["setup"]["onboardingBundle"]
        return {
            "Arn": f"arn:aws:iam::{ACCOUNT}:role/SpottoReadOnlyRole",
            "RoleId": "AROA111122223333", "Tags": [
                {"Key": "SpottoCompanyId", "Value": "company-example"},
                {"Key": "SpottoManagedBy", "Value": "Setup-SpottoAws"}],
            "AssumeRolePolicyDocument": copy.deepcopy(bundle["trustPolicy"]),
            "inline": {"SpottoGuardrails": copy.deepcopy(bundle["guardrailPolicy"])},
            "managed": ["arn:aws:iam::aws:policy/SecurityAudit",
                        "arn:aws:iam::aws:policy/ReadOnlyAccess"],
        }

    def seed(self, role):
        self.write_state({"roles": {ACCOUNT: role}, "calls": []})

    def test_default_is_read_only(self):
        report, _ = self.run_script()
        self.assertEqual(report["results"][0]["status"], "changes-required")
        self.assertEqual(self.mutations(), [])

    def test_interactive_enter_is_read_only_and_declining_writes_is_planned(self):
        report, _ = self.run_script(answers="\n")
        self.assertEqual(report["results"][0]["status"], "changes-required")
        report, _ = self.run_script(answers="2\nn\n")
        self.assertEqual(report["results"][0]["status"], "planned")
        self.assertEqual(self.mutations(), [])

    def test_unattended_configuration_requires_explicit_approval(self):
        report, _ = self.run_script("--configure", expected=1)
        self.assertIsNone(report)
        self.assertEqual(self.state()["calls"], [])

    def test_dry_run_never_writes(self):
        report, _ = self.run_script("--dry-run")
        self.assertEqual(report["results"][0]["status"], "planned")
        self.assertEqual(self.mutations(), [])

    def test_create_and_rerun_are_idempotent_and_handoff_is_portal_compatible(self):
        report, _ = self.configure()
        self.assertEqual(self.mutations(), ["create-role", "put-role-policy",
                                           "attach-role-policy", "attach-role-policy"])
        self.assertEqual(set(report), {"kind", "schemaVersion", "companyId", "configuration", "results"})
        self.assertEqual(report["kind"], "spotto.aws.manual-onboarding")
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["companyId"], "company-example")
        self.assertEqual(report["configuration"], self.package["configuration"])
        self.assertEqual(report["results"], [{"accountId": ACCOUNT,
                         "roleArn": f"arn:aws:iam::{ACCOUNT}:role/SpottoReadOnlyRole", "status": "configured"}])
        self.assertNotIn("externalId", json.dumps(report))
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        state = self.state()
        state["calls"] = []
        self.write_state(state)
        self.configure()
        self.assertEqual(self.mutations(), [])

    def test_matching_role_from_another_tool_is_verified_without_adoption(self):
        for manager in ("Terraform", "CloudFormation", None):
            with self.subTest(manager=manager):
                role = self.configured_role()
                role["Tags"] = [] if manager is None else [
                    {"Key": "SpottoCompanyId", "Value": "company-example"},
                    {"Key": "SpottoManagedBy", "Value": manager}]
                self.seed(role)
                report, _ = self.configure()
                self.assertEqual(report["results"][0]["status"], "configured")
                self.assertEqual(self.mutations(), [])

    def test_foreign_ownership_cannot_be_repaired(self):
        for tags in ([{"Key": "SpottoCompanyId", "Value": "other-company"}],
                     [{"Key": "SpottoManagedBy", "Value": "Terraform"}],
                     [{"Key": "SpottoManagedBy", "Value": "CloudFormation"}],
                     [{"Key": "aws:cloudformation:stack-id", "Value": "stack"}]):
            with self.subTest(tags=tags):
                role = self.configured_role()
                role["Tags"] = tags
                role["inline"] = {}
                self.seed(role)
                report, _ = self.configure("--repair-existing-role", expected=1)
                self.assertEqual(report["results"][0]["status"], "failed")
                self.assertEqual(self.mutations(), [])

    def test_ownership_tag_keys_follow_iam_case_insensitivity(self):
        for tags in ([{"Key": "spottomanagedby", "Value": "Terraform"}],
                     [{"Key": "spottocompanyid", "Value": "other-company"}]):
            with self.subTest(tags=tags):
                role = self.configured_role()
                role["Tags"] = tags
                role["inline"] = {}
                # Legacy trust may lack an External ID; company tags still bind it.
                role["AssumeRolePolicyDocument"]["Statement"][0].pop("Condition")
                self.seed(role)
                self.configure("--repair-existing-role", expected=1)
                self.assertEqual(self.mutations(), [])

    def test_empty_manager_tag_is_verify_only(self):
        role = self.configured_role()
        role["Tags"][1]["Value"] = ""
        self.seed(role)
        report, _ = self.configure("--repair-existing-role")
        self.assertEqual(report["results"][0]["status"], "configured")
        self.assertEqual(self.mutations(), [])
        role["inline"] = {}
        self.seed(role)
        self.configure("--repair-existing-role", expected=1)
        self.assertEqual(self.mutations(), [])

    def test_cloudformation_stack_tags_allow_verification_but_never_repair(self):
        for manager in (None, "Setup-SpottoAws", "CloudFormation"):
            with self.subTest(manager=manager):
                role = self.configured_role()
                role["Tags"] = [{"Key": "aws:cloudformation:stack-id", "Value": "stack-example"}]
                if manager is not None:
                    role["Tags"].append({"Key": "SpottoManagedBy", "Value": manager})
                self.seed(role)
                report, _ = self.run_script("--check-only")
                self.assertEqual(report["results"][0]["status"], "configuration-matches")
                report, _ = self.configure("--repair-existing-role")
                self.assertEqual(report["results"][0]["status"], "configured")
                self.assertEqual(self.mutations(), [])
                role["inline"] = {}
                self.seed(role)
                self.configure("--repair-existing-role", expected=1)
                self.assertEqual(self.mutations(), [])

    def test_current_api_package_needs_no_legacy_managed_policy_attachments(self):
        self.package = json.loads((TESTS / "fixtures/spotto-aws-setup-current.json").read_text())
        profiles = self.root / "profiles.json"
        profiles.write_text(json.dumps({role["accountId"]: f'account-{role["accountId"]}'
                                      for role in self.package["roles"]}))
        report, _ = self.configure("--profile-map", str(profiles))
        self.assertEqual([result["status"] for result in report["results"]], ["configured"] * 3)
        self.assertNotIn("attach-role-policy", self.mutations())
        guardrails = self.state()["roles"][ACCOUNT]["inline"]["SpottoGuardrails"]
        self.assertTrue(any(statement["Effect"] == "Allow" for statement in guardrails["Statement"]))

    def test_cancellation_stops_account_and_cli_children_before_further_writes(self):
        for cancellation_signal, expected, ignore_term in ((signal.SIGTERM, 143, False),
                                                           (signal.SIGINT, 130, False),
                                                           (signal.SIGTERM, 143, True)):
            with self.subTest(signal=cancellation_signal, ignore_term=ignore_term):
                self.write_state({"roles": {}, "calls": []})
                self.package_path.write_text(json.dumps(self.package))
                original = self.root / "original-fake-aws"
                shutil.copyfile(TESTS / "FakeAwsCli.py", original)
                original.chmod(0o700)
                marker = self.root / "create-started"
                marker.unlink(missing_ok=True)
                fake = self.root / "aws"
                ignore_trap = "  trap '' TERM\n" if ignore_term else ""
                fake.write_text('#!/usr/bin/env bash\nif [[ $2 == create-role ]]; then\n' + ignore_trap +
                                '  printf "%s\\n" "$$" > "$SPOTTO_TEST_STARTED"\n  sleep 30\nfi\n'
                                'exec "$SPOTTO_TEST_ORIGINAL" "$@"\n')
                environment = dict(self.environment, SPOTTO_TEST_STARTED=str(marker),
                                   SPOTTO_TEST_ORIGINAL=str(original))
                arguments = [os.environ.get("SPOTTO_TEST_BASH", "bash"), str(self.script),
                             "--setup-package", str(self.package_path), "--output", str(self.output),
                             "--configure", "--yes", "--non-interactive"]
                with subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True, env=environment,
                                      start_new_session=True) as process:
                    cli_group = None
                    try:
                        deadline = time.monotonic() + 10
                        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertTrue(marker.exists(), "Did not reach the delayed create-role")
                        cli_pid = int(marker.read_text())
                        cli_group = os.getpgid(cli_pid)
                        process.send_signal(cancellation_signal)
                        try:
                            log, _ = process.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            self.fail("Cancellation did not stop the account/CLI processes")
                        self.assertEqual(process.returncode, expected, log)
                        self.assertEqual(self.mutations(), [])
                        self.assertFalse(self.output.exists())
                        with self.assertRaises(ProcessLookupError, msg="Cancelled AWS CLI process was not reaped"):
                            os.kill(cli_pid, 0)
                    finally:
                        # Also kills descendants if an assertion or cancellation handling fails.
                        if cli_group is not None:
                            try:
                                os.killpg(cli_group, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.communicate()

    def test_other_company_external_id_is_refused(self):
        role = self.configured_role()
        role["AssumeRolePolicyDocument"]["Statement"][0]["Condition"]["StringEquals"]["sts:ExternalId"] = "spotto-another-company"
        self.seed(role)
        self.configure("--repair-existing-role", expected=1)
        self.assertEqual(self.mutations(), [])

    def test_other_company_external_id_condition_variants_are_refused(self):
        for operator, key, value in (
                ("StringLike", "sts:ExternalId", "spotto-another-company"),
                ("StringEqualsIfExists", "sts:ExternalId", "spotto-another-company"),
                ("ForAnyValue:StringEquals", "sts:ExternalId", ["spotto-another-company"]),
                ("StringEquals", "STS:ExternalID", ["spotto-another-company"])):
            with self.subTest(operator=operator, key=key):
                role = self.configured_role()
                role["Tags"] = []
                role["AssumeRolePolicyDocument"]["Statement"][0]["Condition"] = {operator: {key: value}}
                self.seed(role)
                self.configure("--repair-existing-role", expected=1)
                self.assertEqual(self.mutations(), [])

    def test_single_statement_object_cannot_bypass_company_binding(self):
        role = self.configured_role()
        role["Tags"] = []
        statement = role["AssumeRolePolicyDocument"]["Statement"][0]
        statement["Condition"]["StringEquals"]["sts:ExternalId"] = "spotto-another-company"
        role["AssumeRolePolicyDocument"]["Statement"] = statement
        self.seed(role)
        self.configure("--repair-existing-role", expected=1)
        self.assertEqual(self.mutations(), [])

    def test_selected_capabilities_require_their_generated_policies(self):
        original = json.loads((TESTS / "fixtures/spotto-aws-setup.json").read_text())
        profiles = self.root / "profiles.json"
        profiles.write_text(json.dumps({role["accountId"]: f'account-{role["accountId"]}'
                                      for role in original["roles"]}))
        for field in ("billingAccessPolicy", "commitmentsAccessPolicy"):
            with self.subTest(field=field):
                self.package = copy.deepcopy(original)
                self.package["roles"][0]["setup"]["onboardingBundle"].pop(field)
                report, _ = self.configure("--profile-map", str(profiles), expected=1)
                self.assertIsNone(report)
                self.assertEqual(self.state()["calls"], [])

    def test_unselected_capabilities_cannot_add_permissions(self):
        bundle = self.package["roles"][0]["setup"]["onboardingBundle"]
        bundle["commitmentsAccessPolicyName"] = "SpottoCommitmentsPlanning"
        bundle["commitmentsAccessPolicy"] = {"Statement": [{"Effect": "Allow", "Action": "savingsplans:*", "Resource": "*"}]}
        self.configure(expected=1)
        self.assertEqual(self.state()["calls"], [])

    def test_repair_preserves_customer_policies_and_orders_guardrails_before_trust(self):
        role = self.configured_role()
        role["Tags"] = []
        role["AssumeRolePolicyDocument"]["Statement"].append(
            {"Effect": "Allow", "Principal": {"AWS": "*"}, "Action": "sts:AssumeRole"})
        role["inline"] = {"CustomerPolicy": {"Version": "2012-10-17", "Statement": []},
                          "SpottoCommitmentsPlanning": {"Statement": []}}
        role["managed"].append("arn:aws:iam::111122223333:policy/CustomerPolicy")
        self.seed(role)
        self.configure(expected=1)
        self.assertEqual(self.mutations(), [])
        report, log = self.configure("--repair-existing-role")
        self.assertEqual(report["results"][0]["status"], "configured")
        self.assertIn("removes 1", log)
        self.assertEqual(self.mutations(), ["put-role-policy", "delete-role-policy",
                                           "update-assume-role-policy", "tag-role"])
        current = self.state()["roles"][ACCOUNT]
        self.assertIn("CustomerPolicy", current["inline"])
        self.assertIn("arn:aws:iam::111122223333:policy/CustomerPolicy", current["managed"])
        self.assertNotIn("SpottoCommitmentsPlanning", current["inline"])

    def test_wrong_account_stops_before_any_writes_or_results(self):
        self.environment["SPOTTO_TEST_WRONG_ACCOUNT"] = "000011112222"
        report, _ = self.configure(expected=1)
        self.assertIsNone(report)
        self.assertEqual(self.mutations(), [])

    def test_access_denied_is_not_a_missing_role(self):
        self.environment["SPOTTO_TEST_FAIL_ACTION"] = "get-role"
        report, _ = self.configure(expected=1)
        self.assertEqual(report["results"][0]["status"], "failed")
        self.assertEqual(self.mutations(), [])
        self.assertEqual(sum(call["action"] == "get-role" for call in self.state()["calls"]), 1)

    def test_partial_failure_can_be_repaired_without_rewriting_policies(self):
        self.environment["SPOTTO_TEST_FAIL_ACTION"] = "attach-role-policy"
        report, _ = self.configure(expected=1)
        self.assertEqual(report["results"][0]["status"], "failed")
        del self.environment["SPOTTO_TEST_FAIL_ACTION"]
        state = self.state()
        state["calls"] = []
        self.write_state(state)
        self.configure()
        self.assertEqual(self.mutations(), ["attach-role-policy", "attach-role-policy"])

    def test_propagation_errors_are_retried_but_access_denied_is_not(self):
        self.environment["SPOTTO_TEST_TRANSIENT_ACTION"] = "put-role-policy"
        self.configure()
        self.assertEqual(self.state()["missingCount"], 2)

    def test_operator_error_format_does_not_change_error_handling(self):
        self.environment["AWS_CLI_ERROR_FORMAT"] = "json"
        self.configure()
        self.assertTrue(all(call["errorFormat"] == "legacy" for call in self.state()["calls"]))

    def test_legacy_attachments_are_reported_without_changing_match_or_detaching(self):
        self.package["roles"][0]["setup"]["onboardingBundle"]["managedPolicies"] = []
        for mode, status in (("--check-only", "configuration-matches"),
                             ("--configure", "configured"), ("--dry-run", "configured")):
            with self.subTest(mode=mode):
                role = self.configured_role()
                role["managed"].append(f"arn:aws:iam::{ACCOUNT}:policy/CustomerPolicy")
                self.seed(role)
                options = (mode, "--yes") if mode == "--configure" else (mode,)
                report, log = self.run_script(*options)
                self.assertEqual(report["results"][0]["status"], status)
                self.assertIn("arn:aws:iam::aws:policy/ReadOnlyAccess", log)
                self.assertIn("arn:aws:iam::aws:policy/SecurityAudit", log)
                self.assertIn("validat", log.lower())
                self.assertEqual(self.mutations(), [])
                self.assertEqual(self.state()["roles"][ACCOUNT]["managed"], role["managed"])

    def test_actual_service_error_is_parsed_after_unrelated_parentheses(self):
        self.environment["SPOTTO_TEST_ERROR_PREFIX"] = "Credential helper note (unrelated)"
        self.configure()
        self.assertEqual(self.mutations()[0], "create-role")

    def test_diagnostic_parentheses_cannot_disguise_access_denied_as_missing(self):
        self.environment.update(SPOTTO_TEST_ERROR_PREFIX="Helper note (NoSuchEntity)",
                                SPOTTO_TEST_FAIL_ACTION="get-role")
        report, _ = self.configure(expected=1)
        self.assertEqual(report["results"][0]["status"], "failed")
        self.assertEqual(self.mutations(), [])

    def test_standard_cli_retries_are_enabled_and_bounded(self):
        self.configure()
        self.assertTrue(self.state()["calls"])
        self.assertTrue(all(call["retryMode"] == "standard" and call["maxAttempts"] == "3"
                            for call in self.state()["calls"]))

    def test_incompatible_jq_reports_a_dependency_error_before_aws(self):
        fake_jq = self.root / "jq"
        fake_jq.write_text('#!/bin/sh\nprintf "jq: error: IN/2 is not defined\\n" >&2\nexit 3\n')
        fake_jq.chmod(0o700)
        report, log = self.configure(expected=1)
        self.assertIsNone(report)
        self.assertIn("Install jq 1.6 or later", log)
        self.assertNotIn("setup package", log.lower())
        self.assertEqual(self.state()["calls"], [])

    def test_incompatible_timeout_reports_a_dependency_error_before_aws(self):
        for name in ("timeout", "gtimeout"):
            fake_timeout = self.root / name
            fake_timeout.write_text('#!/bin/sh\nprintf "unrecognized option --kill-after\\n" >&2\nexit 1\n')
            fake_timeout.chmod(0o700)
        report, log = self.configure(expected=1)
        self.assertIsNone(report)
        self.assertIn("Install GNU timeout", log)
        self.assertEqual(self.state()["calls"], [])

    def test_gtimeout_is_used_when_timeout_is_incompatible(self):
        real_timeout = shutil.which("timeout") or shutil.which("gtimeout")
        incompatible = self.root / "timeout"
        incompatible.write_text('#!/bin/sh\nexit 1\n')
        incompatible.chmod(0o700)
        compatible = self.root / "gtimeout"
        compatible.write_text(f'#!/bin/sh\nexec "{real_timeout}" "$@"\n')
        compatible.chmod(0o700)
        report, _ = self.run_script("--check-only")
        self.assertEqual(report["results"][0]["status"], "changes-required")
        self.assertEqual(self.mutations(), [])

    def test_credential_helper_stderr_is_not_used_as_an_error_code(self):
        fake = self.root / "aws"
        fake.write_text('#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo aws-cli/2.0.0; else echo "(sensitive-diagnostic-sentinel)" >&2; exit 1; fi\n')
        self.configure(expected=1)
        self.assertEqual(self.mutations(), [])

    def test_full_api_package_handles_multiple_profiles_and_split_billing(self):
        self.package = json.loads((TESTS / "fixtures/spotto-aws-setup.json").read_text())
        profiles = self.root / "profiles.json"
        profiles.write_text(json.dumps({account: f"account-{account}" for account in
                                      (ACCOUNT, "000011112222", "444455556666")}))
        report, _ = self.configure("--profile-map", str(profiles))
        self.assertEqual([result["accountId"] for result in report["results"]],
                         [ACCOUNT, "000011112222", "444455556666"])
        self.assertEqual([call["action"] for call in self.state()["calls"][:3]],
                         ["get-caller-identity"] * 3)
        roles = self.state()["roles"]
        definition = roles[ACCOUNT]["inline"]["SpottoBillingExportRead"]
        self.assertIn("arn:aws:bcm-data-exports:us-east-1:111122223333:export/example-cur2-0123", json.dumps(definition))
        storage = roles["000011112222"]["inline"]["SpottoBillingExportRead"]
        self.assertIn("arn:aws:s3:::example-cost-exports/cur2/example-cur2/*", json.dumps(storage))
        self.assertNotIn("SpottoCommitmentsPlanning", roles["000011112222"]["inline"])
        self.assertIn("SpottoCommitmentsPlanning", roles[ACCOUNT]["inline"])

    def test_one_failed_account_does_not_hide_other_account_results(self):
        self.package = json.loads((TESTS / "fixtures/spotto-aws-setup.json").read_text())
        profiles = self.root / "profiles.json"
        profiles.write_text(json.dumps({role["accountId"]: f'account-{role["accountId"]}'
                                      for role in self.package["roles"]}))
        self.environment.update(SPOTTO_TEST_FAIL_ACTION="create-role", SPOTTO_TEST_FAIL_ACCOUNT=ACCOUNT)
        report, _ = self.configure("--profile-map", str(profiles), expected=1)
        self.assertEqual([result["status"] for result in report["results"]],
                         ["failed", "configured", "configured"])
        self.assertNotIn(ACCOUNT, self.state()["roles"])

    def test_wrong_last_profile_stops_before_modifying_any_account(self):
        self.package = json.loads((TESTS / "fixtures/spotto-aws-setup.json").read_text())
        profiles = self.root / "profiles.json"
        profiles.write_text(json.dumps({ACCOUNT: f"account-{ACCOUNT}",
                                      "000011112222": "account-000011112222",
                                      "444455556666": "account-999900001111"}))
        report, _ = self.configure("--profile-map", str(profiles), expected=1)
        self.assertIsNone(report)
        self.assertEqual(len(self.state()["calls"]), 3)
        self.assertEqual(self.mutations(), [])

    def test_invalid_packages_are_rejected_before_aws_calls(self):
        original = copy.deepcopy(self.package)
        mutations = {
            "string schema": lambda p: p.update(schemaVersion="1"),
            "boolean schema": lambda p: p["configuration"].update(schemaVersion=True),
            "credential": lambda p: p["configuration"].update(credentials={"secret": "redacted"}),
            "company": lambda p: p["configuration"].update(companyId="other"),
            "duplicate role": lambda p: p["roles"].append(copy.deepcopy(p["roles"][0])),
            "numeric account": lambda p: p["roles"][0].update(accountId=111122223333),
            "role path": lambda p: p["roles"][0].update(roleArn=f"arn:aws:iam::{ACCOUNT}:role/custom/SpottoReadOnlyRole"),
            "wildcard trust": lambda p: p["roles"][0]["setup"]["onboardingBundle"]["trustPolicy"]["Statement"][0].update(Principal={"AWS": "*"}),
            "managed policy": lambda p: p["roles"][0]["setup"]["onboardingBundle"]["managedPolicies"].append({"arn": "arn:aws:iam::aws:policy/AdministratorAccess"}),
            "null managed policies": lambda p: p["roles"][0]["setup"]["onboardingBundle"].update(managedPolicies=None),
            "object managed policies": lambda p: p["roles"][0]["setup"]["onboardingBundle"].update(managedPolicies={}),
            "keyed managed policies": lambda p: p["roles"][0]["setup"]["onboardingBundle"].update(managedPolicies={"policy": {"arn": "arn:aws:iam::aws:policy/SecurityAudit"}}),
            "missing managed policies": lambda p: p["roles"][0]["setup"]["onboardingBundle"].pop("managedPolicies"),
            "missing guardrails": lambda p: p["roles"][0]["setup"]["onboardingBundle"].pop("guardrailPolicy"),
            "missing discovery": lambda p: p["configuration"]["estates"][0]["accounts"][0].update(purposes=[]),
            "wrong provider": lambda p: p["configuration"].update(provider="Azure"),
            "oversize": lambda p: p.update(padding="a" * 1048576),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                self.package = copy.deepcopy(original)
                mutate(self.package)
                report, _ = self.configure(expected=1)
                self.assertIsNone(report)
                self.assertEqual(self.state()["calls"], [])

    def test_invalid_profile_map_is_rejected_before_aws_calls(self):
        profiles = self.root / "profiles.json"
        profiles.write_text(json.dumps({ACCOUNT: {"credentials": "not a profile"}}))
        self.configure("--profile-map", str(profiles), expected=1)
        self.assertEqual(self.state()["calls"], [])

    def test_control_characters_in_profile_map_are_rejected_before_aws(self):
        for name in ("admin\nother", "admin\x00", "admin\x7f"):
            with self.subTest(name=repr(name)):
                profiles = self.root / "profiles.json"
                profiles.write_text(json.dumps({ACCOUNT: name}))
                self.configure("--profile-map", str(profiles), expected=1)
                self.assertEqual(self.state()["calls"], [])

    def test_existing_output_is_never_overwritten(self):
        target = self.root / "existing.json"
        target.write_text("keep me")
        self.configure("--output", str(target), expected=1)
        self.assertEqual(target.read_text(), "keep me")
        self.assertEqual(self.state()["calls"], [])

    def test_output_symlink_is_never_followed(self):
        target = self.root / "customer-file.json"
        target.write_text("keep me")
        link = self.root / "output-link.json"
        link.symlink_to(target)
        self.configure("--output", str(link), expected=1)
        self.assertEqual(target.read_text(), "keep me")
        self.assertEqual(self.state()["calls"], [])

    def test_unknown_and_conflicting_options_fail_before_aws(self):
        for arguments in (("--unknown",), ("--profile",), ("--check-only", "--configure"),
                          ("--region", "us-gov-west-1"), ("--yes",)):
            with self.subTest(arguments=arguments):
                self.run_script(*arguments, expected=1)
                self.assertEqual(self.state()["calls"], [])

    def test_permissions_boundary_is_reported_and_preserved(self):
        role = self.configured_role()
        role["PermissionsBoundary"] = {"PermissionsBoundaryArn": f"arn:aws:iam::{ACCOUNT}:policy/Boundary"}
        self.seed(role)
        report, log = self.configure()
        self.assertIn(f"arn:aws:iam::{ACCOUNT}:policy/Boundary", log)
        self.assertEqual(report["results"][0]["status"], "configured")
        self.assertEqual(self.mutations(), [])

    def test_changed_role_requires_a_new_review_before_writing(self):
        for change in ("foreign-owner", "replaced", "appeared", "disappeared", "policy-drift"):
            with self.subTest(change=change):
                role = self.configured_role()
                role["inline"]["SpottoGuardrails"] = {"Statement": [{"Effect": "Deny", "Action": "s3:GetObject", "Resource": "*"}]}
                self.seed(role)
                replacement = copy.deepcopy(role)
                if change == "foreign-owner":
                    replacement["Tags"] = [{"Key": "SpottoCompanyId", "Value": "other-company"}]
                elif change == "replaced":
                    replacement["RoleId"] = "AROAREPLACED012345"
                elif change == "policy-drift":
                    # The plan still says replace guardrails; the approved current policy changed.
                    replacement["inline"]["SpottoGuardrails"]["Statement"][0]["Action"] = "s3:GetObjectVersion"
                if change == "appeared":
                    self.write_state({"roles": {}, "calls": []})
                changed = self.root / "changed.json"
                changed.write_text(json.dumps({"roles": {} if change == "disappeared" else {ACCOUNT: replacement}}))
                self.environment["SPOTTO_TEST_RECHECK_STATE"] = str(changed)
                report, _ = self.configure(expected=1)
                self.assertEqual(report["results"][0]["status"], "failed")
                self.assertEqual(self.mutations(), [])

    def test_changed_session_after_approval_cannot_write(self):
        self.environment["SPOTTO_TEST_RECHECK_ACCOUNT"] = "000011112222"
        self.configure(expected=1)
        self.assertEqual(self.mutations(), [])

    def test_cli_timeout_is_bounded_and_never_leaks_diagnostics(self):
        # Replace the deadline utility, keeping the Bash -> CLI process boundary real.
        # It delegates version checks and exercises the real GNU timeout on a hung CLI.
        real_timeout = shutil.which("timeout") or shutil.which("gtimeout")
        shim = self.root / "timeout"
        shim.write_text(f'#!/usr/bin/env bash\nexec "{real_timeout}" --kill-after=0.1s 0.2s "${{@:3}}"\n')
        shim.chmod(0o700)
        fake = self.root / "aws"
        fake.write_text('#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo aws-cli/2.0.0; else sleep 30; fi\n')
        report, log = self.configure("--profile", "customer-mfa", expected=1)
        self.assertIsNone(report)
        self.assertIn("(Timeout)", log)
        self.assertIn("aws sts get-caller-identity --profile customer-mfa", log)
        self.assertIn("aws sso login", log)
        self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
