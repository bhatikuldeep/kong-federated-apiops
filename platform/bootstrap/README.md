# Bootstrap (once per environment, by a person)

Entity-level RBAC needs its permissions in place **before** it is enforced: Kong's docs say entity
permissions "must be bootstrapped before enforcement is enabled". So, once per environment:

1. Start Kong with `enforce_rbac = on` and a super admin token (`KONG_PASSWORD` at
   `kong migrations bootstrap`).
2. Run `bootstrap.sh` with that token. It creates:
   - role `platform-admin` in the `default` workspace: every endpoint in every workspace, and every
     entity;
   - RBAC user `ci-platform` with that role, whose token the platform pipelines use;
   - an entity permission for every entity on the built-in `super-admin` role, so the super admin
     can still see and repair everything after the switch.
3. Restart Kong with `enforce_rbac = both`.
4. Store the `ci-platform` token as the environment's `PLATFORM_TOKEN_<ENV>` secret.

```bash
KONG_ADDR=https://kong-admin.dev.example.com \
SUPER_ADMIN_TOKEN=<super admin token> \
PLATFORM_TOKEN=<new random token> \
  platform/bootstrap/bootstrap.sh
```

It's safe to re-run (with `enforce_rbac = on`). Everything after this is Terraform and decK, run by
the pipelines.

Why not Terraform here: with kong-gateway provider 1.4.1 an endpoint permission's workspace is
also the workspace in the request path, so the provider can't create a permission for workspace
`*`, which the platform role needs.
