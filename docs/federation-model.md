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

| | One repo (`teams/<team>/`) | Repo per team (`examples/team-repo`) |
|---|---|---|
| Who merges | CODEOWNERS per folder | the team |
| Central rule changes | reach teams at once | when the team bumps `platform-ref` |
| Good fit | up to a dozen teams | many teams or organisations |

Both use the same reusable workflow, so a team can move later without changing its files.

## One repository per environment?

No. The same files go to dev and prod; addresses and tokens live in GitHub environments, and
`environments/<env>.yaml` holds the few values that differ.
