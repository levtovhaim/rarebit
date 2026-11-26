# Runbook: Terraform state locked, unreadable or lost

- **Alert(s):** none; these show up as errors from `terragrunt plan` or `apply`, locally or in CI.
- **Service:** the infrastructure code: `infra/live` and the state bucket from `infra/live/_global/bootstrap` (ADRs 0032, 0033)
- **Severity:** ticket (players aren't affected; infrastructure changes are blocked until it's fixed)
- **Last fired on purpose:** not yet (the stuck-lock drill comes with the CI plan workflow)

## What it means

| Error | What's wrong |
|---|---|
| `Error acquiring the state lock` | Another plan or apply holds the unit's lock, or a crashed one left it behind. The lock is the object `<unit path>/terraform.tfstate.tflock` in the state bucket. |
| `AWS account ID not allowed` | The active credentials belong to another account than `RAREBIT_AWS_ACCOUNT_ID`. The provider stopped before doing anything. |
| `Error in function call` … `get_env("RAREBIT_AWS_ACCOUNT_ID")` | The variable isn't set ([infra/README.md](../../infra/README.md) → Setup). |
| `Backend configuration changed` | The backend in the generated config differs from the one the working copy was initialized with. Expected once, during the bootstrap migration. Otherwise `RAREBIT_BOOTSTRAP_LOCAL_STATE` is set by mistake. |
| `AccessDenied` or `NoSuchBucket` from the backend | Expired credentials, a missing permission, or the bucket isn't there |
| A plan that wants to recreate resources that exist | The state is wrong: a bad write, a wrong `import`, or state restored from the wrong version |

## Impact on players

None directly. Until it's fixed, nobody can change the infrastructure, through CI or by hand.

## Diagnose (first 5 minutes)

Every command here is read-only. Run them from the unit's directory (`infra/live/...`), with the bucket name in `B`:

```bash
aws sts get-caller-identity                                   # the account matches RAREBIT_AWS_ACCOUNT_ID?
B="rarebit-tfstate-${RAREBIT_AWS_ACCOUNT_ID}-eu-central-1"
aws s3api head-bucket --bucket "$B"                           # the bucket exists and you can reach it
aws s3 cp "s3://$B/_global/bootstrap/terraform.tfstate.tflock" - 2>/dev/null   # the lock: ID, Who, Operation, Created
aws s3api list-object-versions --bucket "$B" --prefix _global/bootstrap/terraform.tfstate \
  --query 'Versions[].[VersionId,LastModified,Size,IsLatest]' --output table   # the state's history
terragrunt render --format json                               # the effective backend and provider config
terragrunt state list                                         # what the state says exists
```

## Fix

Each state-changing command below is marked, and a human runs it or approves the exact command (CLAUDE.md → Rules, rule 2).

### A stuck lock

1. Read the lock (Diagnose). `Who` and `Created` say who took it and when.
2. Make sure its holder is gone: no CI run of that unit in progress, and the person in `Who` isn't running anything. **Never remove the lock of an apply that's still running:** two writers corrupt the state.
3. **State-changing:** `terragrunt run -- force-unlock <ID>` with the `ID` from the lock.
4. `terragrunt plan` again. If the crashed run was an apply, the plan shows what it didn't finish.

### Wrong account, or the variable is missing

Sign in again (`aws login --profile rarebit`) and check `aws sts get-caller-identity` against `RAREBIT_AWS_ACCOUNT_ID` in `.mise.local.toml`. Never "fix" this by changing the variable to whatever account the credentials point at.

### Restore an earlier state version

1. Find the last good version (Diagnose, `list-object-versions`), and download it: `aws s3api get-object --bucket "$B" --key <unit path>/terraform.tfstate --version-id <id> good.tfstate`.
2. Read it, and check that it holds the resources you expect (`jq '.resources[].type' good.tfstate`).
3. **State-changing:** `terragrunt run -- state push -force good.tfstate`. `-force` is needed because the old version has a lower serial than the current one. The push takes the unit's lock.
4. `terragrunt plan`: it shows how reality differs from the restored state. Resolve that with `import` or a normal apply, not by pushing again.

Never delete object versions in the bucket by hand: they are the history this procedure needs.

### Bootstrap from nothing (a new account, or the bucket is gone)

The state bucket stores the state of the unit that creates it, so its first apply has to keep its state locally.

1. Set up as in [infra/README.md](../../infra/README.md) → Setup, then `cd infra/live/_global/bootstrap`.
2. **State-changing:** `RAREBIT_BOOTSTRAP_LOCAL_STATE=true terragrunt apply`. The variable makes Terragrunt write `backend_override.tf`, which points the backend at `bootstrap.tfstate` in this directory (git ignores it). The apply creates the bucket, about 7 resources.
3. **State-changing:** `terragrunt run -- init -migrate-state`. Without the variable, the override is gone and the backend is S3 again. Terraform says the backend changed and asks `Do you want to copy existing state to the new backend?`: answer `yes`.
4. Verify: `terragrunt plan` says `No changes`, and `aws s3 ls "s3://$B/_global/bootstrap/"` lists `terraform.tfstate`.
5. Delete the local copies: `rm bootstrap.tfstate bootstrap.tfstate.backup`. The state is in S3 now, versioned.

If the bucket was lost, so is every other unit's state. Run the bootstrap above, then bring each unit back with `import` blocks for the resources that still exist.

## Verify

- `terragrunt plan` in the unit runs and says `No changes` (or shows only the change you expect).
- The lock is gone after the run: `aws s3api head-object --bucket "$B" --key <unit path>/terraform.tfstate.tflock` returns `Not Found`.

## Roll back or escalate

- The state is versioned: a bad write is undone by restoring the version before it (above).
- If the bucket itself is damaged, or its policy locks everyone out, use the account's root or an administrator in the console. Don't reach for `--backend-bootstrap`: that would let Terragrunt create a bucket with its own settings (ADR 0032).

## Prevention

- `prevent_destroy` on the bucket; versioning with 90 days and 20 versions of history.
- `allowed_account_ids` in every unit's provider (ADR 0033).
- CI plans with a role that can read state but not write it (the GitHub OIDC roles).
