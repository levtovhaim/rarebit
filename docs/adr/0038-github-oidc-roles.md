# 0038. GitHub Actions reaches AWS through OIDC, with one role per kind of job, trusted by exact claims

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- CLAUDE.md rule 5: CI reaches AWS only through GitHub OIDC, and no static keys exist.
- **Every GitHub Actions run can get a token** signed by `token.actions.githubusercontent.com`, if its workflow grants `permissions: id-token: write`. The token's claims say where the run comes from:
  - `aud`, the audience (`sts.amazonaws.com` for AWS);
  - `sub`, the repository and the kind of run. This repository was created after 2026-07-15, so GitHub writes its **immutable subject**: the names with the owner's and the repository's numeric IDs, `repo:levtovhaim@360220203/rarebit@1468801318:<context>`. The contexts:
    - `pull_request` for pull requests;
    - `ref:refs/heads/main` for runs on main, whatever the event;
    - `environment:<env>` for a job that names an environment.
- STS trades a valid token for a role's credentials (`AssumeRoleWithWebIdentity`) when the role's trust policy accepts its claims.
- **Pull requests from branches of this repository get tokens; pull requests from forks don't.** Agents open PRs from branches here. A pull request runs the workflow files and the code of its own branch, so whoever opens a PR controls everything that runs with the PR roles.
- **The repository is public,** and so are its Actions logs: anything a job prints, anyone can read.
- ADR 0036 split main and PR images into separate repositories, because IAM can't limit pushes by tag. ADR 0040 says who may push to and delete from each kind.

## Decision

- **An IAM OIDC provider** for GitHub's issuer, with the audience `sts.amazonaws.com`. No thumbprint in the code: AWS checks the issuer's certificate against its own trusted CAs. AWS records a thumbprint on creation anyway, and the plan shows no drift from it.
- **One role per kind of job,** under the IAM path `/ci/`, with one-hour sessions. Each role's trust policy accepts one exact `sub` and the `aud`, with `StringEquals` only: no `StringLike`, no wildcards. The owner and repository IDs come from `shared.hcl` (ADR 0039).

  | Role | Trusted `sub` | What it may do |
  |---|---|---|
  | `gha-ci-pr` | `repo:levtovhaim@360220203/rarebit@1468801318:pull_request` | push, read and delete images in `rarebit/pr/*` |
  | `gha-ci-main` | `repo:levtovhaim@360220203/rarebit@1468801318:ref:refs/heads/main` | push and read images in the main repositories; no delete |
  | `gha-tf-plan` | `repo:levtovhaim@360220203/rarebit@1468801318:pull_request` | read configuration (`ReadOnlyAccess`) and write nothing |

- **`gha-tf-plan` writes nothing.** Pull request plans run with `-lock=false`: they are advisory, S3 reads are strongly consistent, and every apply still takes the lock. This refines ADR 0032, which had plans take the lock too.
- **`gha-tf-plan` is denied what `ReadOnlyAccess` would give away** to whoever opens a pull request, explicitly, so no later allow can bring it back:
  - secret values: `kms:Decrypt`, `secretsmanager:GetSecretValue`, and this account's SSM parameter values (AWS's public parameters, like the EKS AMI IDs, stay readable);
  - the account owner's contact, payment, invoice and tax details and the budget subscribers' addresses (`account`, `billing`, `payments`, `invoicing`, `tax`, `budgets` and the rest), and Cost Explorer, which bills $0.01 a request;
  - data-plane reads a plan never needs: objects in any bucket but the state bucket, log events and queries, queue messages, table items, stream records, metric data, instance console output and passwords;
  - any other account's buckets.
- **No CI role may change IAM,** repository policies, lifecycle rules, tag mutability, scanning or replication, or allow a `*` action. Each role has exactly its policies (`aws_iam_role_policies_exclusive`, `aws_iam_role_policy_attachments_exclusive`), so a policy attached outside Terraform shows up in the next plan. The module's tests check all of this.
- **`prevent_destroy`** on the provider and the roles: they are CI's only way in (ADR 0037).
- **No apply or teardown role yet.** Those roles change real infrastructure. They come with their workflows, behind GitHub environments with a required reviewer, trusted by `environment:<env>`.

## Alternatives considered

| Option | Why not |
|---|---|
| An IAM user's access key in a GitHub secret | A long-lived secret that every workflow, and every PR job, could read |
| One CI role for every job | A pull request job would get main's rights: it could push a `main-` image |
| `StringLike` with `repo:levtovhaim/rarebit:*` | Any run of the repository, any event, could take the role |
| Trusting `ref:refs/heads/*` for the main role | Any branch, so any PR's branch pushed by its author, could act as main |
| The name-only subject, `repo:levtovhaim/rarebit:<context>` | It never matches this repository's tokens. On a repository that still uses it, whoever takes over the name of a deleted or renamed repository gets the roles |
| `ViewOnlyAccess` plus a hand-written list for the plan role | Narrower, but a plan's refresh reads attributes `ViewOnlyAccess` doesn't cover, and the list would break with every new kind of resource. The explicit denies take away what matters |
| The plan role behind a GitHub environment with a required reviewer | Every PR plan would wait for a person's click, and agents open many PRs. Worth it if the denies prove not to be enough |
| PR plans taking the state lock | Any PR could delete a running apply's lock, or plant locks that block applies. Planted lock objects can't be removed, because the bucket denies `s3:DeleteObjectVersion` to everyone (ADR 0032) |
| Pinning `gha-ci-main` to one workflow now (`job_workflow_ref`) | That workflow doesn't exist yet; the pin comes with it (follow-ups) |

## Consequences

- **Good:**
  - no key exists to leak;
  - a pull request can't act as main, by trust policy, IAM policy and repository policy;
  - a credential lives one hour;
  - a pull request can't read secret values, the account owner's details, or spend the credits on Cost Explorer.
- **Bad / risks:**
  - **The trust is only as exact as the `sub`.** A job that names an `environment:` gets the environment's `sub`, not `pull_request` or `ref:…`. So PR and main jobs don't use environments, and apply jobs will.
  - **Merge queue runs** (`ref:refs/heads/gh-readonly-queue/main/…`) match neither role. That's by design: main images are pushed after the merge, by main's run.
  - **The two PR roles are interchangeable** for whoever opens a pull request: any step of a PR job can take `gha-ci-pr` or `gha-tf-plan`. The `pull_request` subject names no branch, so IAM Access Analyzer warns on those two trust policies (`SPECIFIC_GITHUB_REPO_AND_BRANCH_RECOMMENDED`). Accepted: its alternative, a condition on the token's `ref`, would say `refs/pull/<number>/merge`, which every pull request matches. What a PR run can do is what limits it.
  - **`ReadOnlyAccess` still reads every resource's configuration and every unit's state.** So no secret value goes into Terraform state: ephemeral resources and write-only attributes instead. A new kind of data store (a backup bucket, a table, a queue) gets checked against the denies when it arrives.
  - **Some units can't be planned by this role:** one that manages SSM parameter values (refresh reads them), and the budgets, whose plan would print the subscribers' addresses in a public log. Those are planned outside public PR logs (#62).
  - **`gha-ci-main` trusts every run on main, whatever the event:** `push`, `schedule`, `workflow_dispatch`, `workflow_run`. A scheduled workflow given `id-token: write` could push a `main-` image. Until the build workflow pins it (follow-ups), no workflow on main but the build may request `id-token: write`.
  - **`pull_request_target` and `workflow_run` run in the default branch's context** while they can handle a pull request's code. Workflows here don't use them. zizmor's `dangerous-triggers` audit flags them, in `make check` locally; CI enforces it once the lint workflow exists.
  - **ECR's `docker login` token lasts 12 hours,** longer than the role's session. Jobs don't cache or upload their Docker config, and log out at the end.
  - **Renaming the repository changes the `sub`** (`shared.hcl` changes with it); deleting and creating it again changes its ID.
- **Follow-ups (#62):**
  - pin `gha-ci-main` to the build workflow with `job_workflow_ref` (a key IAM supports for GitHub's issuer), and have a build started by hand check that its commit is on main;
  - the apply and teardown roles with their environments;
  - `-lock-timeout` for applies;
  - the state bucket's allowlist;
  - where the budgets unit is planned;
  - the node role (pull-only) with the cluster.

## How we'll know it was right

- The first workflow prints its token's claims, and the `sub` equals the trusted one.
- A pull request run takes `gha-ci-pr`, pushes to `rarebit/pr/<service>`, and its push to `rarebit/<service>` fails with `explicit deny in a resource-based policy`.
- A run on main takes `gha-ci-main`; a pull request run trying `gha-ci-main` fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
- IAM Access Analyzer finds nothing in the role permission policies. In the trust policies it finds only the accepted warning above, on the two pull request roles, and a suggestion that the audience is matched without a qualifier, which it is (first checked on 2026-11-26).
