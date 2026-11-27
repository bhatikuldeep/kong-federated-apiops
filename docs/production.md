# Running it in production

- **`enforce_rbac = both`.** Endpoint rules alone can't protect a plugin: every plugin write goes to
  `/plugins`.
- **Bootstrap first.** Run [platform/bootstrap](../platform/bootstrap/README.md) once per environment
  while `enforce_rbac = on`, then switch to `both`.
- **Pipelines run as their own RBAC users**, never as the bootstrap super admin (`kong_admin`).
  Teams use theirs; the platform uses `ci-platform`, which has Kong's built-in `super-admin` role.
- **Rotating a team token replaces its RBAC user** (provider 1.4.1). The team role's wildcard entity
  permission keeps its access.
- **Terraform state** in a remote backend with locking. It holds the team tokens: restrict reads.
- **Runners** that can reach the Admin API; never expose the Admin API to the internet.
- **Secrets** reach decK as `DECK_*` variables from `TEAM_SECRETS_<TEAM>`; prefer Kong Vaults for
  upstream credentials.
- **Routes are HTTPS only** by default since Kong Gateway 3.14; the central rulesets keep it so.
- **Kong Manager sign-in through your IdP** (`make sso` shows it with Keycloak). Send roles as
  `<workspace>:<role>` in the claim, so people get `workspace-read-only` from their group and
  nobody assigns roles in Kong. Keep the super admin's RBAC token for the Admin API as break-glass,
  put TLS on the Admin API and Kong Manager with `session_cookie_secure: true`, trust the IdP's
  certificate with `lua_ssl_trusted_certificate`, set `session_secret`, and turn off the password
  grant on the IdP client (only the lab's test uses it).
- **Use `PUT`, not `PATCH`, for plugins and consumers in scripts.** With entity-level RBAC on 3.14
  and 3.16, `PATCH` by ID on them returned `403`. decK and Terraform use `PUT`.
