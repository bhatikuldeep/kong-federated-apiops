# Running it in production

- **`enforce_rbac = both`.** Endpoint rules alone can't protect individual plugins: every plugin
  write goes to `/plugins`, wherever the plugin applies.
- **A platform pipeline identity, not the super admin.** Create an RBAC user (for example
  `ci-platform`) with a role in the `default` workspace that has endpoint `*` in workspace `*` and an
  entity permission with `entity_id: "*"`. Under `enforce_rbac = both` the built-in super admin has
  no entity permissions and its role can't be changed, so it can't see what team pipelines create.
- **Team pipeline tokens rotate by replacing the RBAC user.** With kong-gateway provider 1.4.1,
  changing `user_token` replaces the user. The team role's wildcard entity permission is what keeps
  the team's access to everything it deployed; without it, entities are owned by the old user and
  disappear from the new one.
- **Entity permissions are set by `pipelines/protect.sh`, not Terraform.** On 3.16 they can be
  created through the Admin API but not read back by an identity without a wildcard entity
  permission, so Terraform could create them and then fail on every later plan.
- **Terraform state** in a remote backend with locking, one state per environment (the lab uses
  Terraform workspaces `dev` and `prod`).
- **Runners** that can reach the Admin API, which should never be exposed to the internet. Serialise
  runs per environment (the workflows use `concurrency`).
- **Routes default to HTTPS only** on 3.16: serve the proxy over TLS, or set `protocols` on purpose.
- **Secrets:** consumer keys and other values reach decK as `DECK_*` environment variables from CI
  secrets; for upstream credentials prefer Kong Vaults (`{vault://...}` references pass through
  decK unchanged).
