[中文](forgejo-agit-pull-request-secrets.md) | [English](forgejo-agit-pull-request-secrets_en.md)

# Forgejo AGit pull requests and Actions secrets

## Rule

A `pull_request` workflow that needs repository Actions secrets must be triggered by a regular pull request from a branch in the same repository. Do not use AGit flow for such changes.

In Forgejo 14.0.3, Forgejo runs an AGit pull request as a fork pull request even when a repository member created it against the same repository. Repository Actions secrets are not provided to fork pull requests.

## Symptoms

Typical symptoms are:

- Jobs that need only public inputs or cached outputs can succeed.
- A job that uses a repository secret such as `INFRA_SSH_KEY` or `REPO_TOKEN` fails quickly.
- Rerunning the same workflow does not help because the event remains a fork pull request.
- An aggregate or required job fails after its dependency fails.

Check the pull request type before rotating credentials.

## Diagnosis

Inspect the pull request:

```sh
tea api repos/OWNER/REPO/pulls/NUMBER \
  | jq '{flow, head: .head.ref, head_repo: .head.repo.full_name, base_repo: .base.repo.full_name}'
```

`flow: 1` means AGit flow. A regular branch pull request has `flow: 0`.

Inspect the Actions run:

```sh
tea api 'repos/OWNER/REPO/actions/runs?limit=20' \
  | jq '.workflow_runs[] | {id, event, status, is_fork_pull_request, html_url}'
```

Apply the recovery below when the failed run has both `event: "pull_request"` and `is_fork_pull_request: true`, and the failed step needs a repository secret.

## Recovery

1. Keep the existing commit and push it to a regular branch in the target repository.
2. Close the AGit pull request.
3. Create a regular same-repository pull request from that branch without `--agit`:

   ```sh
   git push origin HEAD:refs/heads/fix/example
   tea pr create --head fix/example --base main \
     --title 'fix: example'
   ```

4. Verify that the new pull request has `flow: 0` and that the head and base `repo.full_name` values match.
5. Verify that the new Actions run has `is_fork_pull_request: false`, then observe the job that needs secrets.
6. Approval must name the exact head SHA of the new pull request. Approval on the old pull request does not carry over.

## Cause

The Forgejo 14.0.3 pull request model marks AGit flow as fork flow. When Actions prepares secrets for a `pull_request` event, it filters repository secrets from fork pull requests. The decision happens before the workflow starts, so environment declarations in the workflow cannot repair it.

Relevant implementation:

- [Forgejo 14.0.3 pull request flow](https://codeberg.org/forgejo/forgejo/src/tag/v14.0.3/models/issues/pull.go)
- [Forgejo 14.0.3 Actions secret filtering](https://codeberg.org/forgejo/forgejo/src/tag/v14.0.3/models/secret/secret.go)

## Incident record

On 2026-09-27, a private infrastructure pull request was created with AGit flow. The ARM job succeeded after hitting its cache, while the x86 job failed when it used an SSH secret to verify a dependency repository. After the AGit pull request was closed and the same commit was submitted through a regular same-repository pull request, the new run was classified as non-fork, the secret check and ARM job succeeded, and the x86 job entered its normal build stage.
