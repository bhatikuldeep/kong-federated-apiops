# Bootstrap (once per environment)

Entity permissions must exist before entity-level RBAC is enforced. Once per environment:

1. Start Kong with `enforce_rbac = on`.
2. Run the **bootstrap** workflow (Actions, Run workflow, pick the environment). It reads, from
   that GitHub environment, `KONG_ADDR_<ENV>`, `SUPER_ADMIN_TOKEN_<ENV>` (`kong_admin`'s token: the
   `KONG_PASSWORD` of the first `kong migrations bootstrap`) and a new random `PLATFORM_TOKEN_<ENV>`.
3. Restart Kong with `enforce_rbac = both`.

It creates the `ci-platform` user the platform workflows run as, with Kong's built-in
`super-admin` role. Run it once: a second run fails because what it creates already exists.
