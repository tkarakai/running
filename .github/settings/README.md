# Repository settings as code

Settings that can't be expressed in workflow files. Apply them with `gh`.

## Branch ruleset (not active yet)

[`main-ruleset.json`](main-ruleset.json) protects `main`: no deletion or force-push, linear
history, changes only through squash-merged pull requests, and the `CI` check must pass.
Private-repository rulesets need GitHub Pro (or the repository moving to a paid
organization), so it is **not applied** today — the PR-only workflow is a convention (see
`AGENTS.md`). Once available:

```sh
gh api -X POST repos/tkarakai/running/rulesets --input .github/settings/main-ruleset.json
```

## Applied settings

```sh
R=repos/tkarakai/running
gh api -X PATCH $R -F has_wiki=false -F has_projects=false -F has_discussions=false \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true -F allow_update_branch=true
gh api -X PUT $R/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT $R/actions/permissions -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
gh api -X PUT $R/actions/permissions/selected-actions --input - <<'JSON'
{"github_owned_allowed": true, "verified_allowed": false,
 "patterns_allowed": ["oven-sh/setup-bun@*", "zizmorcore/zizmor-action@*"]}
JSON
gh api -X PUT $R/vulnerability-alerts
gh api -X PUT $R/automated-security-fixes
```
