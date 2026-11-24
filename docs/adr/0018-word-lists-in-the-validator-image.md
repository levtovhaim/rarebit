# 0018. Ship the word lists in the validator image

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

`validator migrate` loads `data/categories/*.json` into Postgres (ADR 0014). In Kubernetes it runs as a Job, so the files have to reach that Job somehow. ADR 0014 left the packaging open, to be decided with the Dockerfile and the chart. The files are small (1,249 words, about 30 KB) and change only by pull request.

## Decision

The word lists are copied into the validator image at build time, at `/data/categories` (the default `VALIDATOR_DATA_DIR`), read-only, with fixed permissions (directories 0555, files 0444). A content change is a new image, built and promoted like a code change, and the migrate Job of that release loads exactly the lists that were reviewed with it.

## Alternatives considered

| Option | Why not |
|---|---|
| A ConfigMap mounted into the Job | Content and code would be versioned and rolled out separately. ConfigMaps are capped at 1 MiB, which the lists will outgrow once open data is added. |
| A separate data image, as an init container | A second image to build, tag and promote, for files this small. Revisit if content changes become much more frequent than code changes. |
| The Job clones the repository or downloads a release artifact | Network access and credentials at runtime, and the content loaded is no longer tied to an image digest. |

## Consequences

- **Good:**
  - one artifact per release: the image digest identifies both the code and the content;
  - a rollback that goes through a normal sync (a reverted image tag, which runs the migrate Job first) restores the previous lists with the previous code;
  - no runtime network access or extra mounts for the Job.
- **Bad / risks:**
  - a content-only change rebuilds and redeploys the image (the data layers come last, so only they change);
  - the `serve` pods carry files only `migrate` reads (about 30 KB);
  - a rollback that skips the migrate Job (`kubectl rollout undo`) leaves the old pods on lists keyed by the newer normalizer: only `validator_content_normalizer_mismatch` shows it ([issue 23](https://github.com/levtovhaim/rarebit/issues/23) adds the alert);
  - a rollback's migrate Job fails if a later migration broke the old binary's content load, so migrations must stay expand/contract (ADR 0016);
  - two image versions against one database overwrite each other's lists on every run, so every environment, previews included, needs its own database.
- **Follow-ups:**
  - CI must build the validator image when `data/categories/**` changes, not only `apps/validator/**` and `native/**` (and the Dockerfile and its ignore files), or a content-only PR merges without reaching the database;
  - data CI and previews for content PRs run the same image build;
  - a CI check that runs the previous image's `migrate` against the new schema.

## How we'll know it was right

Content PRs go through the same pipeline as code without extra steps, and the image stays well under its size limit as the lists grow. If content changes far outpace code changes, revisit the separate data image.
