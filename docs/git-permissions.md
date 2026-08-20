# Git Permissions Setup

This repo uses path-based access control to enforce that clerks can only modify
their own `hosts/clerks/<name>/` directory. All shared paths (`modules/`,
`secrets/`, `lib/`, `flake.nix`, etc.) require beacon's approval.

## CODEOWNERS

The `CODEOWNERS` file in the repo root defines path ownership. It is used by
GitHub, Gitea (1.21+), and GitLab (Premium+). GitLab CE users must use the
alternative approach described below.

## Platform Setup

### GitLab CE (no CODEOWNERS support)

GitLab CE lacks CODEOWNERS but can enforce restrictions via Protected Branches
and server-side Push Rules (or a custom pre-receive hook).

#### 1. Protect the `main` branch

Settings → Repository → Protected Branches:
- Branch: `main`
- Allowed to merge: Maintainers
- Allowed to push: No one (force all changes through MRs)

#### 2. Grant clerk accounts Developer role

Each clerk (e.g. `openclaw-default`, `openclaw-technician`) should be a
**Developer** in the project. They can create branches and MRs but cannot push
to `main` directly.

#### 3. Server-side pre-receive hook (recommended)

GitLab CE supports custom server-side hooks. Create a `pre-receive` hook that
checks the committer against allowed paths:

```bash
#!/usr/bin/env bash
# /var/opt/gitlab/git-data/repositories/<namespace>/<project>.git/custom_hooks/pre-receive
#
# Restrict clerk users to their own hosts/clerks/<name>/ directory.
# Beacon (maintainer) is unrestricted.

RESTRICTED_USERS="openclaw-default openclaw-technician"

while read oldrev newrev refname; do
  # Only enforce on main
  [[ "$refname" != "refs/heads/main" ]] && continue

  # Get the pusher's username from GL_USERNAME (set by GitLab)
  pusher="${GL_USERNAME}"

  # Skip unrestricted users
  is_restricted=false
  for u in $RESTRICTED_USERS; do
    [[ "$pusher" == "$u" ]] && is_restricted=true && break
  done
  $is_restricted || continue

  # Determine allowed path prefix for this clerk
  # Convention: username "openclaw-<name>" → allowed path "hosts/clerks/<name>/"
  clerk_name="${pusher#openclaw-}"
  allowed_prefix="hosts/clerks/${clerk_name}/"

  # Check all changed files
  changed_files=$(git diff --name-only "$oldrev" "$newrev")
  while IFS= read -r file; do
    if [[ "$file" != ${allowed_prefix}* ]]; then
      echo "GL-HOOK-ERR: User '$pusher' is not allowed to modify '$file'"
      echo "GL-HOOK-ERR: Clerks may only modify their own hosts/clerks/<name>/ directory."
      exit 1
    fi
  done <<< "$changed_files"
done

exit 0
```

#### 4. Auto-merge clerk MRs (optional)

Use a CI job or webhook to auto-merge MRs from clerks when:
- All changed files are within the clerk's allowed directory
- CI pipeline passes

Example `.gitlab-ci.yml` snippet:

```yaml
auto-merge-clerk:
  stage: deploy
  rules:
    - if: '$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME && $GITLAB_USER_LOGIN =~ /^openclaw-/'
  script:
    - |
      CLERK_NAME="${GITLAB_USER_LOGIN#openclaw-}"
      ALLOWED="hosts/clerks/${CLERK_NAME}/"
      # Check all changed files are within allowed path
      CHANGED=$(git diff --name-only origin/main...HEAD)
      for f in $CHANGED; do
        if [[ "$f" != ${ALLOWED}* ]]; then
          echo "Change to '$f' requires beacon review. Skipping auto-merge."
          exit 0
        fi
      done
      echo "All changes within ${ALLOWED} — auto-merging."
      glab mr merge "$CI_MERGE_REQUEST_IID" --yes --auto
```

---

### GitHub

#### 1. Enable branch protection on `main`

Settings → Branches → Add rule for `main`:
- [x] Require a pull request before merging
- [x] Require review from Code Owners
- [x] Require approvals (1)

#### 2. CODEOWNERS is automatically recognized

The `CODEOWNERS` file in the repo root is read by GitHub. Ensure the usernames
(`@beacon`, `@openclaw-default`, etc.) match actual GitHub accounts.

#### 3. Auto-merge clerk PRs

Option A: GitHub Actions workflow that auto-approves and merges PRs from clerk
accounts when only their allowed paths are modified.

Option B: Use the "auto-merge" feature — clerks enable auto-merge on their PR,
and it merges once CODEOWNERS requirements are satisfied (i.e. they are the
owner of all changed files).

---

### Gitea (1.21+)

#### 1. Enable branch protection on `main`

Settings → Branches → `main`:
- [x] Enable branch protection
- [x] Require pull request
- [x] Required approvals: 1
- [x] Require approval from code owners

#### 2. CODEOWNERS is automatically recognized

Gitea reads `CODEOWNERS` from the repo root (or `.gitea/CODEOWNERS`).

#### 3. Auto-merge

Gitea 1.22+ supports auto-merge. Configure similarly to GitHub.

---

## Adding a New Clerk

When adding a new clerk:

1. Create `hosts/clerks/<name>/` directory
2. Add a CODEOWNERS entry: `/hosts/clerks/<name>/ @openclaw-<name>`
3. If using GitLab CE pre-receive hook, add `openclaw-<name>` to `RESTRICTED_USERS`
4. Create the clerk's git account on the hosting platform with Developer role
