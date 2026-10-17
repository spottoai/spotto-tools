#!/usr/bin/env python3
"""Offline AWS CLI process fixture. Never imports AWS SDKs or contacts a network."""
import json
import os
import sys
from pathlib import Path

arguments = sys.argv[1:]
if arguments == ['--version']:
    print('aws-cli/2.0.0 Python/3 offline-test')
    sys.exit(0)
service, action = arguments[:2]


def option(name, default=None):
    return arguments[arguments.index(name) + 1] if name in arguments else default


profile = option('--profile', '')
account = profile.removeprefix('account-') if profile.startswith('account-') else os.environ['SPOTTO_TEST_ACCOUNT']
account = os.environ.get('SPOTTO_TEST_WRONG_ACCOUNT') or account
state_path = Path(os.environ['SPOTTO_TEST_STATE'])
state = json.loads(state_path.read_text())
state.setdefault('calls', []).append({'account': account, 'action': action,
                                     'errorFormat': os.environ.get('AWS_CLI_ERROR_FORMAT'),
                                     'retryMode': os.environ.get('AWS_RETRY_MODE'),
                                     'maxAttempts': os.environ.get('AWS_MAX_ATTEMPTS')})
state_path.write_text(json.dumps(state))

# Optional race fixtures apply exactly when the wizard rechecks an approved role.
replacement = os.environ.get('SPOTTO_TEST_RECHECK_STATE')
if replacement and action == 'get-role' and sum(call['action'] == action for call in state['calls']) == 2:
    state['roles'] = json.loads(Path(replacement).read_text())['roles']
    state_path.write_text(json.dumps(state))
if os.environ.get('SPOTTO_TEST_RECHECK_ACCOUNT') and action == 'get-caller-identity' and sum(call['action'] == action for call in state['calls']) == 2:
    account = os.environ['SPOTTO_TEST_RECHECK_ACCOUNT']


def error(code, message):
    prefix = os.environ.get('SPOTTO_TEST_ERROR_PREFIX')
    if prefix:
        print(prefix, file=sys.stderr)
    code = os.environ.get('SPOTTO_TEST_ERROR_CODE') or code
    if os.environ.get('AWS_CLI_ERROR_FORMAT') == 'json':
        print(json.dumps({'Code': code, 'Message': message}), file=sys.stderr)
    else:
        print(f'An error occurred ({code}): {message}', file=sys.stderr)
    sys.exit(1)


if action == os.environ.get('SPOTTO_TEST_TRANSIENT_ACTION') and state.get('missingCount', 0) < 2:
    state['missingCount'] = state.get('missingCount', 0) + 1
    state_path.write_text(json.dumps(state))
    error('NoSuchEntity', 'IAM changes propagate')
if action == os.environ.get('SPOTTO_TEST_FAIL_ACTION') and (
    not os.environ.get('SPOTTO_TEST_FAIL_ACCOUNT') or account == os.environ['SPOTTO_TEST_FAIL_ACCOUNT']
):
    error('AccessDenied', 'sensitive-diagnostic-sentinel')
if service == 'sts' and action == 'get-caller-identity':
    print(json.dumps({'Account': account, 'Arn': f'arn:aws:iam::{account}:role/Administrator'}))
    sys.exit(0)
roles = state.setdefault('roles', {})
role = roles.get(account)
if action == 'get-role':
    if not role:
        error('NoSuchEntity', 'Role does not exist')
    result = {'Role': role}
elif action == 'list-attached-role-policies':
    result = {'AttachedPolicies': [{'PolicyArn': arn} for arn in role.get('managed', [])]}
elif action == 'list-role-policies':
    result = {'PolicyNames': list(role.get('inline', {}))}
elif action == 'get-role-policy':
    result = {'PolicyDocument': role['inline'][option('--policy-name')]}
elif action in ('create-role', 'update-assume-role-policy', 'tag-role', 'put-role-policy', 'attach-role-policy', 'delete-role-policy'):
    if action == 'create-role':
        role = {'Arn': f'arn:aws:iam::{account}:role/SpottoReadOnlyRole', 'RoleId': f'AROA{account}', 'managed': [], 'inline': {}, 'Tags': []}
        roles[account] = role
    if action in ('create-role', 'update-assume-role-policy'):
        argument = option('--assume-role-policy-document') if action == 'create-role' else option('--policy-document')
        role['AssumeRolePolicyDocument'] = json.loads(Path(argument.removeprefix('file://')).read_text())
    if action in ('create-role', 'tag-role'):
        tags = {tag['Key']: tag['Value'] for tag in role.get('Tags', [])}
        for argument in arguments[arguments.index('--tags') + 1:]:
            if argument.startswith('--'):
                break
            key, value = argument.removeprefix('Key=').split(',Value=')
            tags[key] = value
        role['Tags'] = [{'Key': key, 'Value': value} for key, value in tags.items()]
    if action == 'put-role-policy':
        role['inline'][option('--policy-name')] = json.loads(Path(option('--policy-document').removeprefix('file://')).read_text())
    if action == 'attach-role-policy':
        arn = option('--policy-arn')
        if arn not in role['managed']:
            role['managed'].append(arn)
    if action == 'delete-role-policy':
        del role['inline'][option('--policy-name')]
    state_path.write_text(json.dumps(state))
    result = {}
else:
    raise RuntimeError(f'Unexpected offline AWS action: {service} {action}')
print(json.dumps(result))
