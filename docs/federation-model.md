# The federation model

## Who owns what

| | Platform team | API team |
|---|---|---|
| Workspaces, roles, pipeline users | owns (Terraform) | none |
| Mandatory plugins (global in each workspace) | owns (Terraform), can change | can read, can't change or delete |
| Lint rules, allowed plugins, path prefixes | owns | follows |
| Services, routes, team plugins, consumers | reviews the rules, not each change | owns (decK, from its OpenAPI spec) |
| Production deploy | sets the reviewers on the `prod` environment | merges; prod waits for the reviewers |

## Workspace per team, or one shared workspace with tags?

| | Workspace per team (this repository) | One workspace, a tag per team |
|---|---|---|
| Isolation | RBAC enforces it on the Admin API | only the pipeline (decK `--select-tag`) keeps teams apart; any token can write anywhere |
| Mandatory plugins | one copy per workspace (a global plugin applies only to its own workspace) | one copy |
| Shared consumers or upstreams | duplicated per workspace | shared |
| Route clashes between teams | rejected by Kong across workspaces, and by the path-prefix rule | path-prefix rule only |
| Good fit | several teams, regulated estates, separate on-call | one team or a few that trust each other |

## One repository, or one per team?

| | One repository (`teams/<team>/`) | One repository per team (`examples/team-repo`) |
|---|---|---|
| Who can merge | CODEOWNERS per folder; the platform owns the rest | the team owns its repository; the platform owns the pipeline version it calls |
| Rule changes reach teams | at once | when the team moves to the new `platform-ref` |
| Visibility | everything in one place | each team sees only its own |
| Good fit | up to a dozen teams, one organisation | many teams, separate GitHub organisations, or teams that want their own release rhythm |

Both use the same reusable workflow and the same scripts, so a team can start in the shared
repository and move to its own without changing its files.

## One repository per environment?

Not needed: the same files go to every environment, and what differs (Admin API address, tokens,
secrets) lives in the GitHub environment. Promotion is a merge to `main` followed by the `prod`
environment's approval. Entity IDs come from the spec (`--uuid-base`), so an API has the same IDs
in dev and prod.
