# Running it in production

- **`enforce_rbac = both`.** Endpoint rules alone can't protect individual plugins: every plugin
  write goes to `/plugins`, wherever the plugin applies.
- **Bootstrap before you enforce.** Entity permissions have to exist before entity-level RBAC is
  switched on. Run `platform/bootstrap` once per environment while `enforce_rbac = on`: it creates
  the platform pipeline's RBAC user (`ci-platform`, a role with every endpoint in every workspace
  and every entity) and gives the built-in super admin a wildcard entity permission. Without that,
  the super admin sees only what it created itself.
- **The platform pipeline runs as `ci-platform`, never as the super admin.** An identity without a
  wildcard entity permission gets `403` (not `404`) for an entity it can't see, including a deleted
  one, so it can't tell "gone" from "not mine".
- **Team tokens rotate by replacing the RBAC user** (kong-gateway provider 1.4.1 marks `user_token`
  as "Requires replacement"). The team role's wildcard entity permission keeps the team's access to
  everything it deployed; without it, entities stay owned by the deleted user.
- **Terraform state** in a remote backend with locking, one state per environment (the lab uses
  the `pg` backend with Terraform workspaces `dev` and `prod`). The state holds the team tokens:
  restrict who can read it.
- **Runners** that can reach the Admin API, which should never be exposed to the internet.
  Workflows serialise runs per environment and team with `concurrency`.
- **Routes default to HTTPS only** (since Kong Gateway 3.14); the central ruleset keeps it that way.
- **Secrets:** consumer keys and other values reach decK as `DECK_*` environment variables from the
  `TEAM_SECRETS_<TEAM>` secret; for upstream credentials prefer Kong Vaults (`{vault://...}`
  references pass through decK unchanged).
- **PATCH vs PUT:** on 3.14 and 3.16 with entity-level RBAC, `PATCH` by ID on a plugin or a consumer
  returned `403` for every identity tried; `PUT` works. decK and the Terraform provider use `PUT`.
