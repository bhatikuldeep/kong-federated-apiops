# The federation model

## Who owns what

| | Platform | API team |
|---|---|---|
| Workspaces, roles, pipeline users | owns | none |
| Mandatory plugins | owns | read only (`403` on change) |
| Central rulesets | owns | passes them |
| Services, routes, own plugins, own rulesets | reviews the rules | owns |
| Production | sets reviewers | merges; prod waits |

## Workspace per team or one shared workspace?

| | Workspace per team (this repo) | Shared workspace, tag per team |
|---|---|---|
| Isolation | RBAC on the Admin API | the pipeline only |
| Mandatory plugins | one copy per workspace | one copy |
| Good fit | two or more teams | one team |

## One repository or one per team?

In a federated model each team owns its repository: its spec, its plugins, its rules, its merges.
This repository keeps everything in one place so a single clone runs the whole model; treat
`teams/<team>/` as what each team's repository would hold.

| | One repo (`teams/<team>/`) | Repo per team (`examples/team-repo`) |
|---|---|---|
| Who merges | CODEOWNERS per folder | the team |
| Central rule changes | reach teams at once | when the team bumps `platform-ref` |
| Drift check | the platform's drift workflow | the team's scheduled run |
| Good fit | a pilot, or a few teams | federation at scale |

Both use the same reusable workflow, so a team moves without changing its files.

## Split a team into its own repository

1. **Platform repository:** keep `platform/`, `teams.yaml`, `.github/` and the central rulesets.
   Tag a release (`v1.0.0`). If it's private, set its Actions **Access** policy to allow the team
   repositories ([GitHub: access to reusable workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)).
2. **`teams.yaml`:** add `repository: <org>/<repo>` to the team. Terraform still creates its
   workspace and pipeline token; CI and drift here skip it.
3. **Team repository:** move `teams/<team>/*` to its root and copy
   `examples/team-repo/.github/workflows/deploy.yaml`. Set `team`, `platform-repository` and
   `platform-ref` to the release tag.
4. **Secrets and environments** in the team repository: `KONG_TOKEN_DEV`, `KONG_TOKEN_PROD`
   (`terraform output ci_tokens`), `TEAM_SECRETS`, `SMOKE_KEY`, and the `KONG_ADDR_*` /
   `PROXY_URL_*` variables. Give the `prod` environment the platform team as required reviewers.
   If the platform repository is private, add `REPO_READ_TOKEN`: a fine-grained token with access
   to the platform repository only and **Contents: read-only**. The built-in token is
   ["limited to the repository that contains your workflow"](https://docs.github.com/en/actions/concepts/security/github_token),
   so it reads the team repository but not the platform's.
5. **Remove** `teams/<team>/` here. The team's workflow now runs plan on pull requests, deploy on
   merge and drift every weekday.

The platform keeps control through the pinned workflow and rulesets: a team changes its files, not
the pipeline. The platform's own CI uses the `payments` example as a test fixture
(`tests/fixtures/`, `ci.yaml`); keep a copy there if you move `payments` out.

## One repository per environment?

No. The same files go to dev and prod; addresses and tokens live in GitHub environments, and
`environments/<env>.yaml` holds the few values that differ.
