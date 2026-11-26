#!/usr/bin/env bash
# See README.md. One-time, per environment, run by a person while enforce_rbac = on.
set -euo pipefail
: "${KONG_ADDR:?}" "${SUPER_ADMIN_TOKEN:?}" "${PLATFORM_TOKEN:?}"
api() { curl -sS -o /tmp/bootstrap.json -w '%{http_code}' -H "Kong-Admin-Token: $SUPER_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' "$@"; }
step() { # description, accepted codes, curl args...
  local d=$1 ok=$2; shift 2; local c; c=$(api "$@")
  if [[ " $ok " == *" $c "* ]]; then echo "  $d ($c)"; else echo "  $d: HTTP $c" >&2; cat /tmp/bootstrap.json >&2; exit 1; fi
}
# 400 and 409 mean "already there" on a re-run.
echo "bootstrap $KONG_ADDR"
step "role platform-admin" "201 409" -X POST "$KONG_ADDR/rbac/roles" \
  -d '{"name":"platform-admin","comment":"The platform pipeline."}'
step "  every endpoint in every workspace" "201 400 409" -X POST "$KONG_ADDR/rbac/roles/platform-admin/endpoints" \
  -d '{"endpoint":"*","workspace":"*","actions":"read,create,update,delete"}'
step "  every entity" "201 400" -X POST "$KONG_ADDR/rbac/roles/platform-admin/entities" \
  -d '{"entity_id":"*","entity_type":"wildcard","actions":"read,create,update,delete"}'
step "super-admin: every entity" "201 400" -X POST "$KONG_ADDR/rbac/roles/super-admin/entities" \
  -d '{"entity_id":"*","entity_type":"wildcard","actions":"read,create,update,delete"}'
if [[ $(api "$KONG_ADDR/rbac/users/ci-platform") == 404 ]]; then
  step "user ci-platform" "201" -X POST "$KONG_ADDR/rbac/users" \
    -d "{\"name\":\"ci-platform\",\"user_token\":\"$PLATFORM_TOKEN\",\"comment\":\"The platform pipeline.\"}"
fi
step "  has role platform-admin" "201 400 409" -X POST "$KONG_ADDR/rbac/users/ci-platform/roles" \
  -d '{"roles":"platform-admin"}'
