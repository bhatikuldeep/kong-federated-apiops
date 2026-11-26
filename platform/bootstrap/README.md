# Bootstrap (once per environment)

Entity permissions must exist before entity-level RBAC is enforced. Once per environment:

1. Start Kong with `enforce_rbac = on`.
2. Run the script with the super admin token:

   ```bash
   KONG_ADDR=https://kong-admin.dev.example.com \
   SUPER_ADMIN_TOKEN=<super admin token> \
   PLATFORM_TOKEN=<new random token> \
     platform/bootstrap/bootstrap.sh
   ```

   It creates the `ci-platform` user and its `platform-admin` role (every endpoint, every entity, all
   workspaces), and gives the super admin a wildcard entity permission.
3. Restart Kong with `enforce_rbac = both`.
4. Save the token as the environment's `PLATFORM_TOKEN_<ENV>` secret.

Safe to re-run while `enforce_rbac = on`. Not Terraform because provider 1.4.1 can't grant an
endpoint permission in workspace `*`.
