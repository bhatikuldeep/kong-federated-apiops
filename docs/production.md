# Running it in production

- **`enforce_rbac = both`.** Endpoint rules alone can't protect a plugin: every plugin write goes to
  `/plugins`.
- **Bootstrap first.** Run [platform/bootstrap](../platform/bootstrap/README.md) once per environment
  while `enforce_rbac = on`, then switch to `both`.
- **Pipelines run as their own RBAC users**, never as the super admin. Teams use theirs; the
  platform uses `ci-platform`.
- **Rotating a team token replaces its RBAC user** (provider 1.4.1). The team role's wildcard entity
  permission keeps its access.
- **Terraform state** in a remote backend with locking. It holds the team tokens: restrict reads.
- **Runners** that can reach the Admin API; never expose the Admin API to the internet.
- **Secrets** reach decK as `DECK_*` variables from `TEAM_SECRETS_<TEAM>`; prefer Kong Vaults for
  upstream credentials.
- **Routes are HTTPS only** by default since Kong Gateway 3.14; the central rulesets keep it so.
- **Use `PUT`, not `PATCH`, for plugins and consumers in scripts.** With entity-level RBAC on 3.14
  and 3.16, `PATCH` by ID on them returned `403`. decK and Terraform use `PUT`.
