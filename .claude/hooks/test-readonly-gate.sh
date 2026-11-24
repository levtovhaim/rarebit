#!/usr/bin/env bash
# Table tests for readonly-gate.sh. Run: bash .claude/hooks/test-readonly-gate.sh
# Each row: expected decision (allow | ask | none), then the command the agent would run.
# shellcheck disable=SC2016 # rows are literal command text; nothing in them should expand
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/readonly-gate.sh"
pass=0
fail=0
# The AWS_PROFILE the gate sees; set per section. Empty means unset (the CLI's default profile).
profile=rarebit

check() { # check <allow|ask|none> <command> [tool]
  local want="$1" cmd="$2" tool="${3:-Bash}" out got rc
  out="$(jq -cn --arg c "$cmd" --arg t "$tool" '{tool_name: $t, tool_input: {command: $c}}' |
    tr -d '\r' | AWS_PROFILE="$profile" AWS_DEFAULT_PROFILE='' bash "$gate")"
  rc=$?
  if ((rc != 0)); then
    got="exit $rc"
  elif [[ -z "$out" ]]; then
    got=none
  else
    got="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" | tr -d '\r')"
  fi
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL want=%s got=%s  %s: %s\n' "$want" "$got" "$tool" "$cmd"
  fi
}

# --- not about aws or gh api: no decision -------------------------------------------
check none 'git status'
check none 'ls ~/.aws'
check none 'grep -n aws-cli .mise.toml'
check none 'echo https://docs.aws.amazon.com/cli/'
check none 'gh pr view 5'
check none 'Get-ChildItem $env:USERPROFILE\.aws' PowerShell

# --- mentions aws or gh api but is not a plain call: ask ----------------------------
check ask 'grep -rn "aws " docs'
check ask 'bash -c '\''aws sts get-caller-identity'\'''
check ask 'aws sts get-caller-identity && echo ok'
check ask 'aws sts get-caller-identity; rm -rf build'
check ask 'aws sts get-caller-identity || true'
check ask 'aws sts get-caller-identity > id.json'
check ask 'aws sts get-caller-identity | tee id.json'
check ask 'aws ec2 describe-instances --query "$(whoami)"'
check ask 'aws ec2 describe-instances --query `whoami`'
check ask $'aws sts get-caller-identity\naws ec2 terminate-instances --instance-ids i-1'
check ask "aws ec2 describe-instances --query 'unbalanced"
check ask 'MSYS_NO_PATHCONV=1 aws s3 ls'
check ask '/usr/local/bin/aws sts get-caller-identity'
check ask '& aws sts get-caller-identity' PowerShell
check ask 'Start-Process aws -ArgumentList "ec2 terminate-instances"' PowerShell
check ask 'aws @args' PowerShell
check ask 'gh api repos/o/r && gh pr merge 1'

# --- aws: plain calls the parser rejects before the policy: ask ---------------------
check ask 'aws'
check ask 'aws sts'
check ask 'aws --unknown-flag sts get-caller-identity'
check ask 'aws --profile'
check ask 'aws --endpoint-url http://localhost:4566 s3 ls'
check ask 'aws ec2 describe-regions --endpoint-url=http://localhost:4566'
check ask 'aws ec2 describe-regions --no-verify-ssl'

# --- aws read-only policy (aws_read_only) -------------------------------------------
check allow 'aws --version'
check allow 'aws sts get-caller-identity'
check allow 'aws --profile rarebit --region eu-central-1 sts get-caller-identity --query Account --output text'
check allow 'aws sts get-caller-identity | jq -r .Account'
check allow "aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output text"
check allow 'aws service-quotas list-requested-service-quota-change-history --service-code ec2'
check allow 'aws budgets describe-budgets --account-id 123456789012'
check allow 'aws ssm get-parameter --name /rarebit/dev/x'
check allow 'aws s3 ls'
check allow 'aws iam get-account-password-policy'
check allow 'aws sts get-caller-identity' PowerShell
check ask 'aws ec2 terminate-instances --instance-ids i-1'
check ask 'AWS.EXE ec2 run-instances --image-id ami-1' PowerShell
check ask 'aws eks update-kubeconfig --name rarebit'
check ask 'aws sts assume-role --role-arn arn:aws:iam::1:role/x --role-session-name y'
check ask 'aws kms decrypt --ciphertext-blob fileb://blob'
check ask 'aws s3 cp s3://bucket/key .'
check ask 'aws s3api get-object --bucket b --key k out.bin'
check ask 'aws secretsmanager get-secret-value --secret-id x'
check ask 'aws secretsmanager get-random-password'
check ask 'aws ssm get-parameter --name x --with-decryption'
check ask 'aws ssm get-parameters-by-path --path /x --with-decryption'
check ask 'aws ecr get-login-password --region eu-central-1'
check ask 'aws ecr get-authorization-token'
check ask 'aws sts get-session-token'
check ask 'aws ec2 get-password-data --instance-id i-1'
check ask 'aws eks get-token --cluster-name rarebit'
check ask 'aws sso get-role-credentials --role-name r --account-id 1 --access-token t'
check ask 'aws lightsail get-instance-access-details --instance-name x'
check ask 'aws configure get aws_secret_access_key'
check ask 'aws configure export-credentials'
check ask 'aws configure list'
check ask 'aws ce get-cost-and-usage --granularity DAILY --metrics UnblendedCost'
check ask 'aws ec2 wait instance-running'

# --- aws profile pin: a read against another profile asks ---------------------------
check ask 'aws --profile other sts get-caller-identity'
check ask 'aws sts get-caller-identity --profile other'
check ask 'aws --profile=other s3 ls'
profile=''
check ask 'aws sts get-caller-identity'
check allow 'aws --profile rarebit sts get-caller-identity'
check allow 'aws sts get-caller-identity --profile=rarebit'
profile=other
check ask 'aws ec2 describe-regions'
profile=rarebit

# --- gh api -------------------------------------------------------------------------
check allow 'gh api repos/levtovhaim/rarebit'
check allow 'gh api repos/o/r --jq .name'
check allow "gh api repos/o/r/rulesets --jq '.[] | .name'"
check allow "gh api --paginate repos/o/r/pulls | jq '.[].number' | head -5"
check allow "gh api 'repos/{owner}/{repo}/branches'"
check allow 'GH API repos/o/r' PowerShell
check ask 'gh api -X GET repos/o/r'
check ask 'gh api -XDELETE repos/o/r'
check ask 'gh api --method=PATCH repos/o/r'
check ask 'gh api repos/o/r -f name=x'
check ask 'gh api repos/o/r -F private=true'
check ask 'gh api repos/o/r --raw-field name=x'
check ask 'gh api repos/o/r --input body.json'
check ask "gh api repos/o/r -H 'X-HTTP-Method-Override: DELETE'"
check ask 'gh api graphql -F query=@q.graphql'
check ask 'gh api repos/o/r --jq'
check ask 'gh api repos/o/r | sh'

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
