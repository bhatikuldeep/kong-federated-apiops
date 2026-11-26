#!/usr/bin/env bash
# Proves each rule of the federation model against the running lab (make up first).
# Every rule has a check that must pass and, where it applies, an attempt that must fail.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); cd "$root" || exit 1
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
expect_code() { # desc expected method path [body]   (uses KONG_ADDR/KONG_TOKEN)
  local c; c=$(curl -s -o /tmp/e2e-body -w '%{http_code}' -X "$3" -H "Kong-Admin-Token: $KONG_TOKEN" \
    -H 'Content-Type: application/json' ${5:+-d "$5"} "$KONG_ADDR$4")
  [[ $c == "$2" ]] && ok "$1 -> $c" || bad "$1" "got $c, want $2"
}
expect_exit() { # desc expected-exit command...
  local d=$1 want=$2; shift 2
  "$@" > /tmp/e2e-out 2>&1; local rc=$?
  [[ $rc == "$want" ]] && ok "$d (exit $rc)" || { bad "$d" "exit $rc, want $want"; sed 's/^/      /' /tmp/e2e-out | tail -8; }
}
expect_out() { grep -q -- "$2" /tmp/e2e-out && ok "$1" || bad "$1" "output lacks: $2"; }
admin() { curl -s -H "Kong-Admin-Token: $KONG_ADMIN_TOKEN" -H 'Content-Type: application/json' "$@"; }
set -a; . ./.env; set +a
diff_zero() { pipelines/team.sh payments diff > /tmp/e2e-out 2>&1 && grep -q 'Created: 0' /tmp/e2e-out && grep -q 'Updated: 0' /tmp/e2e-out && grep -q 'Deleted: 0' /tmp/e2e-out; }

echo "== 1. API design and platform rules (offline, no Kong)"
for t in payments orders; do expect_exit "$t spec passes API rules" 0 pipelines/team.sh $t lint-api; done
export TEAM_DIR=tests/fixtures/rogue
expect_exit "spec without security or contact is rejected" 1 pipelines/team.sh payments lint-api
expect_out  "  reason: security" "a top-level security requirement is required"
expect_out  "  reason: contact" "info.contact is required"
expect_out  "  reason: operationId" "operationId is required"
pipelines/team.sh payments build >/dev/null 2>&1
expect_exit "rogue plugins are rejected" 1 pipelines/team.sh payments lint-kong
expect_out  "  reason: mandatory plugin reused" "plugin is not on the platform's allowed list"
expect_out  "  reason: global plugin" "global) plugins are reserved"
expect_out  "  reason: ordering" "ordering field is reserved"
expect_out  "  reason: route outside the team prefix" "routes of team payments must start with /payments"
unset TEAM_DIR; pipelines/team.sh payments build >/dev/null

echo "== 2. Workspace isolation (dev, payments pipeline token)"
eval "$(lab/lab.sh env dev payments)"
expect_code "payments reads its own workspace" 200 GET /payments/services
expect_code "payments reads orders" 403 GET /orders/services
expect_code "payments creates a service in orders" 403 POST /orders/services '{"name":"x","url":"http://x.example"}'
expect_code "payments creates an RBAC user" 403 POST /payments/rbac/users '{"name":"intruder"}'
expect_code "payments creates an RBAC role" 403 POST /payments/rbac/roles '{"name":"intruder"}'
expect_code "payments creates a workspace" 403 POST /workspaces '{"name":"intruder"}'
expect_exit "decK sync into orders with the payments token fails" 1 \
  deck gateway sync build/payments/kong.yaml --workspace orders --select-tag team-payments --skip-workspace-crud \
  --kong-addr "$KONG_ADDR" --headers "Kong-Admin-Token:$KONG_TOKEN"

echo "== 3. Mandatory plugins (dev)"
# PUT is how decK, Terraform and the provider update a plugin. (On 3.16 with enforce_rbac=both a
# PATCH of a plugin is refused for every identity, so PATCH proves nothing here.)
put_body() { yq -p json -o json -I0 '{"name": .name, "config": .config, "tags": .tags, "service": .service, "route": .route, "consumer": .consumer, "enabled": '"$1"'}'; }
for p in $(curl -s -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/plugins?tags=platform" | yq -p json '.data[].id'); do
  cur=$(curl -s -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/plugins/$p"); name=$(yq -p json .name <<<"$cur")
  expect_code "payments switches off mandatory $name" 403 PUT "/payments/plugins/$p" "$(put_body false <<<"$cur")"
  expect_code "payments deletes mandatory $name" 403 DELETE "/payments/plugins/$p"
done
[[ $(curl -s -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/plugins?tags=platform" | yq -p json '[.data[] | select(.enabled)] | length') == 3 ]] \
  && ok "all 3 mandatory plugins still enabled" || bad "mandatory plugins still enabled"
own=$(curl -s -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/plugins?tags=team-payments" | yq -p json -o json '.data[] | select(.name == "key-auth")')
expect_code "control: payments updates its own plugin" 200 PUT "/payments/plugins/$(yq -p json .id <<<"$own")" "$(put_body true <<<"$own")"
rl=$(curl -s -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/plugins?tags=platform" | yq -p json -o json '.data[] | select(.name == "rate-limiting")')
c=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Kong-Admin-Token: $KONG_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  "$KONG_ADDR/payments/plugins/$(yq -p json .id <<<"$rl")" -d "$(put_body true <<<"$rl")")
[[ $c == 200 ]] && ok "control: the platform updates the same mandatory plugin -> 200" || bad "control: platform update" "got $c"
expect_exit "mandatory plugins run on the team's route" 0 pipelines/team.sh payments smoke

echo "== 4. Drift (dev)"
expect_exit "no drift after deploy" 0 pipelines/drift.sh payments
diff_zero && ok "re-deploy changes nothing" || bad "re-deploy changes nothing"
curl -s -o /dev/null -X PATCH -H "Kong-Admin-Token: $KONG_TOKEN" -H 'Content-Type: application/json' \
  "$KONG_ADDR/payments/services/team-payments" -d '{"retries":9}'   # someone edits by hand
expect_exit "hand edit of a managed service is drift" 2 pipelines/drift.sh payments
pipelines/team.sh payments sync >/dev/null 2>&1
expect_exit "re-sync repairs it" 0 pipelines/drift.sh payments
curl -s -o /dev/null -X POST -H "Kong-Admin-Token: $KONG_TOKEN" -H 'Content-Type: application/json' \
  "$KONG_ADDR/payments/services/team-payments/plugins" -d '{"name":"rate-limiting","config":{"minute":100000,"policy":"local"}}'
expect_exit "a plugin added outside the pipeline is caught" 2 pipelines/drift.sh payments
expect_out  "  reason: unmanaged" "UNMANAGED"
rogue=$(curl -s -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/plugins" | yq -p json '.data[] | select(.name == "rate-limiting" and .service != null) | .id')
curl -s -o /dev/null -X DELETE -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/plugins/$rogue"
expect_exit "clean again once removed" 0 pipelines/drift.sh payments
eval "$(lab/lab.sh env dev platform)"; : "${TF_VAR_admin_url:?}"
p=$(admin "$TF_VAR_admin_url/payments/plugins?tags=platform" | yq -p json '.data[] | select(.name == "rate-limiting") | .id')
admin -o /dev/null -X PUT "$TF_VAR_admin_url/payments/plugins/$p" -d "$(admin "$TF_VAR_admin_url/payments/plugins/$p" | put_body false)"
expect_exit "platform drift: a disabled mandatory plugin is caught" 2 pipelines/platform.sh dev drift
pipelines/platform.sh dev apply >/dev/null
expect_exit "platform apply restores it" 0 pipelines/platform.sh dev drift

echo "== 5. Token rotation keeps the team's access (dev)"
( cd platform/foundation && terraform workspace select dev >/dev/null && \
  terraform apply -input=false -auto-approve -replace='random_password.ci_token["payments"]' >/dev/null ) && pipelines/protect.sh dev >/dev/null
eval "$(lab/lab.sh env dev payments)"
expect_code "new token reads the team's service" 200 GET /payments/services/team-payments
diff_zero && ok "new token: re-deploy changes nothing" || bad "new token: re-deploy changes nothing"

echo "== 6. Promotion and one-repo or many"
eval "$(lab/lab.sh env prod payments)"
expect_exit "prod smoke" 0 pipelines/team.sh payments smoke
dev_id=$(yq '.services[0].id' build/payments/kong.yaml)
[[ $(curl -s -H "Kong-Admin-Token: $KONG_TOKEN" "$KONG_ADDR/payments/services/team-payments" | yq -p json .id) == "$dev_id" ]] \
  && ok "same service ID in dev and prod (built from the same spec)" || bad "same service ID in dev and prod"
split=$(mktemp -d); cp teams/payments/* "$split/"
TEAM_DIR=$split pipelines/team.sh payments build >/dev/null 2>&1
TEAM_DIR=$split pipelines/team.sh payments diff > /tmp/e2e-out 2>&1
grep -q 'Created: 0' /tmp/e2e-out && grep -q 'Updated: 0' /tmp/e2e-out && grep -q 'Deleted: 0' /tmp/e2e-out \
  && ok "the team folder works from its own repository" || bad "team folder from its own repository"
rm -rf "$split"; pipelines/team.sh payments build >/dev/null

echo; echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
