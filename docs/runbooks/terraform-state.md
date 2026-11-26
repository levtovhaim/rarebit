# Runbook: Terraform state locked, unreadable or lost

- **Alert(s):** none; these show up as errors from `terragrunt plan` or `apply`, locally or in CI.
- **Service:** the infrastructure code: `infra/live` and the state bucket from `infra/live/_global/bootstrap` (ADRs 0032–0035)
- **Severity:** ticket (players aren't affected; infrastructure changes are blocked until it's fixed)
- **Last fired on purpose:** 2026-11-26, "Bootstrap from nothing" for real: the first apply on local state, `terragrunt run -- init -migrate-state` into the new bucket, then `plan` with `No changes`. The stuck-lock and restore drills come with the CI plan workflow.

## What it means

| Error | What's wrong |
|---|---|
| `Error acquiring the state lock` | Another plan or apply holds the unit's lock, or a crashed one left it behind. Plans take the lock too. The lock is the object `<unit path>/terraform.tfstate.tflock` in the state bucket. |
| `AWS account ID not allowed` | The active credentials belong to another account than `RAREBIT_AWS_ACCOUNT_ID`. The provider stopped before doing anything. |
| `Error in function call` on `get_env` or `regex` with `RAREBIT_AWS_ACCOUNT_ID` | The variable is unset, empty or not 12 digits ([infra/README.md](../../infra/README.md) → Setup). |
| `Early exit in terragrunt unit … due to exclude block with no_run = true`, exit 0 | Expected for `destroy` in a `_global` unit: Terragrunt's destroy command skips the account's foundation (ADR 0037). Nothing was destroyed. |
| `Backend configuration changed` | The backend in the generated config differs from the one the working copy was initialized with. Expected once, during the bootstrap migration. Otherwise `RAREBIT_BOOTSTRAP_LOCAL_STATE` is set by mistake: unset it. |
| `AccessDenied` or `NoSuchBucket` from the backend | Expired credentials, a missing permission, or the bucket isn't there |
| `Failed to persist state` / `Failed to save state` at the end of an apply | The apply changed AWS, but writing the new state to S3 failed (expired credentials, network). Terraform wrote `errored.tfstate` instead: see the fix below. |
| `permission denied` replacing `provider.generated.tf` or `backend_override.tf` | Terragrunt's working copy is on a Windows drive mounted into WSL, because `TG_DOWNLOAD_DIR` isn't set: you're outside the mise environment (`echo $TG_DOWNLOAD_DIR`). |
| A plan that wants to create everything for a unit that exists | The unit was moved or renamed, so it's reading an empty state at its new key. Don't apply: see "Move or rename a unit". |
| A plan that wants to recreate resources that exist | The state is wrong: a bad write, a wrong `import`, or state restored from the wrong version |

## Impact on players

None directly. Until it's fixed, nobody can change the infrastructure, through CI or by hand.

## Diagnose (first 5 minutes)

Run these in WSL from the unit's directory (`infra/live/...`). Set `K` to the unit's path under `infra/live`:

```bash
aws sts get-caller-identity --profile rarebit                 # the account matches RAREBIT_AWS_ACCOUNT_ID?
B="rarebit-tfstate-${RAREBIT_AWS_ACCOUNT_ID}-eu-central-1"
K="_global/bootstrap"                                         # this unit's path under infra/live
aws s3api head-bucket --profile rarebit --bucket "$B"         # the bucket exists and you can reach it
aws s3 cp --profile rarebit "s3://$B/$K/terraform.tfstate.tflock" - 2>/dev/null   # a held lock: ID, Who, Operation, Created
aws s3api list-object-versions --profile rarebit --bucket "$B" --prefix "$K/terraform.tfstate" \
  --query "Versions[?Key=='$K/terraform.tfstate'].[VersionId,LastModified,Size,IsLatest]" --output table   # the state's history
terragrunt render --format json                               # the effective backend and provider config
terragrunt run -- state list                                  # what the state says exists
```

All of them are read-only. The last one still shows a permission prompt in agent sessions, because it matches the rule for `state` commands.

## Fix

Each state-changing command below is marked, and a human runs it or approves the exact command (CLAUDE.md → Rules, rule 2).

### A stuck lock

1. Read the lock (Diagnose). `Who` and `Created` say who took it and when.
2. Make sure its holder is gone: no CI run of that unit in progress, and the person in `Who` isn't running anything. **Never remove the lock of an apply that's still running:** two writers corrupt the state.
3. **State-changing:** `terragrunt run -- force-unlock <ID>` with the `ID` from the lock.
4. `terragrunt plan` again. If the crashed run was an apply, the plan shows what it didn't finish.

### Wrong account, or the variable is missing or invalid

Sign in again (`aws login --profile rarebit`) and check `aws sts get-caller-identity --profile rarebit` against `RAREBIT_AWS_ACCOUNT_ID` in `.mise.local.toml`. Never "fix" this by changing the variable to whatever account the credentials point at.

### Restore an earlier state version

1. Find the last good version (Diagnose: the state's history), and download it into a temporary directory, not the unit's (Terragrunt would copy it into its working copy):

   ```bash
   d="$(mktemp -d)"
   aws s3api get-object --profile rarebit --bucket "$B" --key "$K/terraform.tfstate" --version-id <id> "$d/good.tfstate"
   ```

2. **Check that it's this unit's state.** Its lineage must match the current state's:

   ```bash
   jq -r .lineage "$d/good.tfstate"
   terragrunt run -- state pull | jq -r .lineage
   ```

   If they differ, stop: it's another unit's state, or one from before a rebuild.
3. Read it, and check that it holds the resources you expect: `jq -r '.resources[] | "\(.type).\(.name)"' "$d/good.tfstate"`.
4. **State-changing:** `terragrunt run -- state push -force "$d/good.tfstate"`.
   - `-force` skips both of Terraform's checks, the serial (the old version's is lower) and the lineage; that's why step 2 exists.
   - The path must be absolute, because Terragrunt runs Terraform in its working copy, not in this directory.
   - The push takes the unit's lock.
5. `terragrunt plan`: it shows how reality differs from the restored state.
   - **If it wants to destroy anything, stop** and find out why before applying: the restored state may be the wrong one.
   - Resolve what's missing with `import` or a normal apply, not by pushing again.
6. Delete the copy: `rm -rf "$d"`.

Nobody can delete old object versions, not even the admin: the bucket policy denies `s3:DeleteObjectVersion` (ADR 0032). They are the history this procedure needs.

### An apply that couldn't save its state

1. Find the file Terraform wrote instead: `find ~/.cache/terragrunt -name errored.tfstate`. It's the only record of what the apply did, so don't delete it.
2. Fix the cause (usually `aws login --profile rarebit` again).
3. **State-changing:** from the unit's directory, `terragrunt run -- state push "<full path>/errored.tfstate"`.
4. `terragrunt plan` should now show only what the apply didn't get to. Then delete `errored.tfstate`.

### `permission denied` from Terragrunt on a Windows drive

Work inside the repo with mise active (`echo $TG_DOWNLOAD_DIR` prints `~/.cache/terragrunt`), so the working copies are on the Linux filesystem (ADR 0033). Then remove the copy Terragrunt left in the checkout: `chmod -R u+w .terragrunt-cache && rm -rf .terragrunt-cache`.

### Move or rename a unit

The state key is the unit's path (`<path>/terraform.tfstate`), so a unit that moves reads an empty state at its new key, and its plan wants to create everything again.

1. Before moving: in the old directory, `terragrunt run -- state pull > "$d/unit.tfstate"` (with `d="$(mktemp -d)"`).
2. Move the directory, in a PR of its own.
3. **State-changing:** in the new directory, `terragrunt run -- state push "$d/unit.tfstate"`. The new key is empty, so the push needs no `-force`.
4. `terragrunt plan` in the new directory says `No changes`. The old key stays in the bucket with its history; leave it.

### Bootstrap from nothing (a new account, or the bucket is gone)

The state bucket stores the state of the unit that creates it, so its first apply has to keep its state locally (ADR 0034).

1. Set up as in [infra/README.md](../../infra/README.md) → Setup, then `cd infra/live/_global/bootstrap`.
2. **State-changing:** `RAREBIT_BOOTSTRAP_LOCAL_STATE=true terragrunt apply`. The variable makes Terragrunt write `backend_override.tf`, which points the backend at `bootstrap.tfstate` in this directory (git ignores it). The apply creates the bucket: 7 resources.
3. **State-changing:** `terragrunt run -- init -migrate-state`. Without the variable, the override is gone and the backend is S3 again. Terraform says the backend changed and asks `Do you want to copy existing state to the new backend?`: answer `yes`.
4. Verify: `terragrunt plan` says `No changes`, and `aws s3 ls --profile rarebit "s3://$B/_global/bootstrap/"` lists `terraform.tfstate`.
5. Delete the local copies: `rm -f bootstrap.tfstate bootstrap.tfstate.backup`. The state is in S3 now, versioned. Terragrunt doesn't copy state files into its working copy (`exclude_from_copy`), so no other copy is left.

If the bucket was lost, so is every other unit's state. Run the bootstrap above, then bring each unit back with `import` blocks for the resources that still exist.

## Verify

- `terragrunt plan` in the unit runs and says `No changes` (or shows only the change you expect).
- The lock is gone after the run: `aws s3api head-object --profile rarebit --bucket "$B" --key "$K/terraform.tfstate.tflock"` returns `Not Found`.

## Roll back or escalate

- The state is versioned: a bad write is undone by restoring the version before it (above).
- Deleting the bucket on purpose takes one reviewed PR and an apply that: lift `prevent_destroy` in the module (bucket, versioning, policy), remove the bucket policy's `DenyDeletingTheBucketOrItsHistory` statement, and change the `exclude` block in `infra/live/root.hcl` (ADR 0037). Until then, `terragrunt destroy` there prints `Early exit … due to exclude block with no_run = true` and exits 0.
- If the bucket itself is damaged, or its policy locks everyone out, use the account's root user, which can always remove a bucket policy. Don't reach for `--backend-bootstrap`: that would let Terragrunt create a bucket with its own settings (ADR 0034).

## Prevention

- `prevent_destroy` on the bucket, its versioning and its policy; a bucket policy that denies everyone deleting the bucket or an old version; versioning with 90 days and the newest 20 versions of history (ADR 0032).
- `allowed_account_ids` in every unit's provider and backend, from an account ID that must be exactly 12 digits (ADRs 0033, 0035).
- Terragrunt's destroy command skips every `_global` unit, also in `run --all` (ADR 0037); `make infra` checks it.
- `make infra` runs with no AWS credentials, so a test can't reach AWS.
- Pull request plans run as `gha-tf-plan` with `-lock=false` (ADR 0038): read-only everywhere, no writes at all, so a pull request can't delete or plant a lock. Applies take the lock and wait for it (`-lock-timeout`, issue #62).
- Reads and writes of state audited with CloudTrail data events (issue #58).
