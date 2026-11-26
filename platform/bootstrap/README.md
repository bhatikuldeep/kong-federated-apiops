# Bootstrap (once per environment)

Entity permissions must exist before entity-level RBAC is enforced. Once per environment:

1. Start Kong with `enforce_rbac = on`.
2. Run the **bootstrap** workflow (Actions, Run workflow, pick the environment). It needs
   `KONG_ADDR_<ENV>`, `SUPER_ADMIN_TOKEN_<ENV>` and a new random `PLATFORM_TOKEN_<ENV>`.
3. Restart Kong with `enforce_rbac = both`.

It creates the `ci-platform` user the platform workflows run as. Run it once: a second run fails
on the existing role.
