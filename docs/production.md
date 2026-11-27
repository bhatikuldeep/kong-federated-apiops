# Running it in production

- **`enforce_rbac = both`.** Endpoint rules alone can't protect a plugin: every plugin write goes to
  `/plugins`.
- **Bootstrap first.** Run [platform/bootstrap](../platform/bootstrap/README.md) once per environment
  while `enforce_rbac = on`, then switch to `both`.
- **Pipelines run as their own RBAC users**, never as the bootstrap super admin (`kong_admin`).
  Teams use theirs; the platform uses `ci-platform`, which has Kong's built-in `super-admin` role.
- **Runners** that can reach the Admin API; never expose the Admin API to the internet.
- **Secrets** reach decK as `DECK_*` variables from `TEAM_SECRETS_<TEAM>_<ENV>`; prefer Kong Vaults
  for upstream credentials.
- **Routes are HTTPS only** by default since Kong Gateway 3.14; the central rulesets keep it so.
- **Kong Manager sign-in through your IdP** (`make sso` shows it with Keycloak). Send roles as
  `<workspace>:<role>` in the claim, so people get `workspace-read-only` from their group and
  nobody assigns roles in Kong. Keep the super admin's RBAC token for the Admin API as break-glass,
  put TLS on the Admin API and Kong Manager with `session_cookie_secure: true`, trust the IdP's
  certificate with `lua_ssl_trusted_certificate`, set `session_secret`, and turn off the password
  grant on the IdP client (only the lab's test uses it).
- **Use `PUT`, not `PATCH`, for plugins and consumers in scripts.** With entity-level RBAC on 3.14
  and 3.16, `PATCH` by ID on them returned `403`. decK and Terraform use `PUT`.

## The pipelines

![The team pipeline: lint and build, then plan or deploy per environment](team-pipeline.svg)

![Bootstrap, the platform workflow and the weekday drift check](drift.svg)

Kong Manager sign-in with an identity provider (`make sso`):

![Sign-in through Keycloak, roles from the kong_roles claim](sso-sequence.svg)

## GitHub settings

Kong tokens live in GitHub **environments**, never at repository level: a repository secret is
readable by a workflow on any branch, so anyone who can push a branch could read it.

| Environment | Rules | Used by |
|---|---|---|
| `dev` | none | pull request plans, dev deploys and applies, dev drift |
| `prod` | deployment branches: `main` only; required reviewers: the platform team | prod deploys and applies |
| `prod-drift` | deployment branches: `main` only; no reviewers | the weekday drift check of prod |

Pull requests only ever plan against dev. Expect dev's secrets to be reachable from a branch, so
keep dev free of production data.

`<ENV>` is `DEV` or `PROD`, `<TEAM>` the team name in upper case. Set each environment's own values
(`prod-drift` takes the same values as `prod`):

| Name | Kind | Where | Value |
|---|---|---|---|
| `KONG_ADDR_<ENV>` | variable | environment | the Admin API URL |
| `PROXY_URL_<ENV>` | variable | environment | the proxy URL, for the smoke test (optional) |
| `PLATFORM_TOKEN_<ENV>` | secret | environment | `ci-platform`'s token (bootstrap) |
| `SUPER_ADMIN_TOKEN_<ENV>` | secret | environment | `kong_admin`'s token, for the bootstrap only; remove it afterwards |
| `TF_STATE_PG_CONN_<ENV>` | secret | environment | `postgres://user:pass@host:5432/db?sslmode=verify-full`, reaching only this environment's state |
| `KONG_TOKEN_<TEAM>_<ENV>` | secret | environment | the team's pipeline token (`terraform output -json ci_tokens`) |
| `TEAM_SECRETS_<TEAM>_<ENV>` | secret | environment | JSON of the team's `DECK_` variables, e.g. `{"DECK_PAYMENTS_WEB_KEY":"..."}` |
| `SMOKE_KEY_<TEAM>_<ENV>` | secret | environment | an API key the smoke test sends to `GET <proxy>/<team>` |
| `KONG_ENABLED` | variable | repository | `true`; without it nothing calls Kong (lint still runs) |
| `KONG_RUNNER` | variable | repository | a runner label that can reach the Admin API (default `ubuntu-latest`) |
| `REPO_READ_TOKEN` | secret | team repository | only for a team with its own repository and a private platform repository |

A public copy of this repository runs its checks but never calls Kong, because `KONG_ENABLED` isn't
set. Don't give a public repository a self-hosted runner that can reach your Admin API.

## Terraform state

`platform/foundation/versions.tf` uses the `pg` backend (`PG_CONN_STR`); swap it for your
organisation's backend if it has one. State holds every pipeline token, so each environment's
connection reaches only its own state and reads are restricted. To read a team's token:

```bash
cd platform/foundation && export PG_CONN_STR=...   # that environment's state
terraform init && terraform workspace select prod
terraform output -json ci_tokens                    # {"payments": "...", "orders": "..."}
```

## Add a team

1. `teams.yaml`: add the name (lower-case letters and digits; it becomes the workspace and part of
   secret names).
2. `platform/governance/teams/<team>.yaml`: copy `payments.yaml` and replace `payments` everywhere.
3. `.github/CODEOWNERS`: add `/teams/<team>/` with the team's GitHub team.
4. Merge. The platform workflow creates the workspace, roles, pipeline user and mandatory plugins.
5. Set the team's secrets in `dev`, `prod` and `prod-drift` (table above), from `ci_tokens`.
6. The team adds `teams/<team>/` with `openapi.yaml`, `plugins.yaml` and `consumers.yaml` (all three
   required), and optionally `rules/` and `environments/<env>.yaml` (a `deck file patch` file).
   For the smoke test, `GET /<team>` answers with the `SMOKE_KEY`.

A team with its own repository: [split a team out](federation-model.md#split-a-team-into-its-own-repository).

## Change the guardrails

- **Mandatory plugins:** `platform/foundation/mandatory-plugins.tf` (the plugin and its entry in
  `mandatory_plugin_ids`, which the deny rules use). Keep the name off the allowed list, and update
  the name pattern in `no-mandatory-override` and `global-plugins-are-mandatory` in every
  `platform/governance/teams/<team>.yaml`.
- **Allowed plugins:** `allowed-plugins` in `platform/governance/kong-rules.yaml`.
- **Central rules:** `platform/governance/api-rules.yaml` (the spec) and `kong-rules.yaml` (the decK
  file). `error` fails a pipeline, `warn` only reports. CI checks a change against every team in
  this repository before it merges.

## Roll back and rotate

- **Roll back a deploy:** revert the pull request; the pipeline deploys the previous files. If Git
  and Kong disagree, restore the backup artifact of that run (kept 30 days):
  `deck gateway sync --workspace <team> --skip-consumers backup-<team>-<env>.yaml`.
  Without `--skip-consumers` the sync deletes the team's consumers, which the backup leaves out.
- **Rotate a team token:** `terraform apply -replace='random_password.ci_token["<team>"]'` in each
  environment's workspace, then update `KONG_TOKEN_<TEAM>_<ENV>`. The new RBAC user keeps the team's
  access through the role's wildcard entity permission.
