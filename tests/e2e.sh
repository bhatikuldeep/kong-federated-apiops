#!/usr/bin/env bash
# Proves each rule of the federation model against the running lab (make up first), through the
# repository's own workflows (run by act) and direct Admin API calls for the attempts a team's
# token must not be able to make. Every rule has a check that must pass and, where it applies, an
# attempt that must fail.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); cd "$root" || exit 1
set -a; . ./.env; set +a
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
J='Content-Type: application/json'
DEV=http://127.0.0.1:18001 PROD=http://127.0.0.1:19001
code() { # token method url [body]
  curl -s -o .lab/e2e-body -w '%{http_code}' -X "$2" -H "Kong-Admin-Token: $1" -H "$J" ${4:+-d "$4"} "$3"
}
expect_code() { # desc expected token method url [body]
  local c; c=$(code "$3" "$4" "$5" "${6:-}")
  [[ $c == "$2" ]] && ok "$1 -> $c" || bad "$1" "got $c, want $2"
}
workflow() { # desc expected(pass|fail) workflow [act args]
  local d=$1 want=$2 wf=$3; shift 3
  lab/lab.sh act "$wf" "$@" > .lab/e2e-act.log 2>&1; local rc=$?
  if [[ $want == pass && $rc == 0 ]] || [[ $want == fail && $rc != 0 ]]; then ok "$d (workflow $wf: ${want}ed)"
  else bad "$d" "workflow $wf exit $rc, want $want"; grep -E "❌|Error:" .lab/e2e-act.log | head -5 | sed 's/^/      /'; fi
}
failed_step() { # keeps the run's act log when the expected message isn't in it
  if grep -q -- "$2" .lab/e2e-act.log; then ok "  $1"
  else local f; f=".lab/e2e-miss-$(date +%s).log"; cp .lab/e2e-act.log "$f"; bad "  $1" "no '$2' in the run, see $f"; fi
}
put_body() { yq -p json -o json -I0 '{"name": .name, "config": .config, "tags": .tags, "service": .service, "route": .route, "consumer": .consumer, "enabled": '"$1"'}'; }
platform_plugin() { # url ws name -> json
  curl -s -H "Kong-Admin-Token: $PLATFORM_TOKEN" "$1/$2/plugins?tags=platform" | yq -p json -o json -I0 ".data[] | select(.name == \"$3\")"
}
mkdir -p .lab
PAY_DEV=$(lab/lab.sh token dev payments)

echo "== 1. Rulesets (the ci workflow: central and team rulesets, a rogue team rejected)"
# ci runs on push and pull_request; act runs it as a push:
act push -W .github/workflows/ci.yaml --pull=false \
  -P "ubuntu-latest=catthehacker/ubuntu@sha256:ebfc2752875ebb29fbfa360db9dcd2f76bc160147ec6bd1b035bba0ef8b38fbe" \
  > .lab/e2e-act.log 2>&1 && ok "ci workflow: both teams pass, the rogue spec and plugins are rejected" \
  || { bad "ci workflow"; grep -E "❌|Error:" .lab/e2e-act.log | head -5; }

echo "== 2. Workspace isolation (dev, the payments pipeline token)"
expect_code "payments reads its own workspace" 200 "$PAY_DEV" GET $DEV/payments/services
expect_code "payments reads orders" 403 "$PAY_DEV" GET $DEV/orders/services
expect_code "payments creates a service in orders" 403 "$PAY_DEV" POST $DEV/orders/services '{"name":"x","url":"https://x.example"}'
expect_code "payments creates an RBAC user" 403 "$PAY_DEV" POST $DEV/payments/rbac/users '{"name":"intruder"}'
expect_code "payments creates an RBAC role" 403 "$PAY_DEV" POST $DEV/payments/rbac/roles '{"name":"intruder"}'
expect_code "payments creates a workspace" 403 "$PAY_DEV" POST $DEV/workspaces '{"name":"intruder"}'
expect_code "payments creates a vault" 403 "$PAY_DEV" POST $DEV/payments/vaults '{"name":"env","prefix":"intruder"}'
expect_code "payments creates a Kong Manager admin" 403 "$PAY_DEV" POST $DEV/payments/admins '{"username":"intruder","email":"intruder@example.com"}'
expect_code "payments creates a group" 403 "$PAY_DEV" POST $DEV/payments/groups '{"name":"intruder"}'
expect_code "payments reads the license" 403 "$PAY_DEV" GET $DEV/payments/licenses
expect_code "payments creates an event hook" 403 "$PAY_DEV" POST $DEV/payments/event-hooks '{"source":"crud","event":"services","handler":"webhook","config":{"url":"https://x.example"}}'
expect_code "payments generates a keyring key" 403 "$PAY_DEV" POST $DEV/payments/keyring/generate '{}'

echo "== 2b. The team's people: read-only (role workspace-read-only; make sso assigns it from Keycloak)"
VT=$(openssl rand -hex 20)
code "$PLATFORM_TOKEN" POST $DEV/payments/rbac/users "{\"name\":\"probe-viewer\",\"user_token\":\"$VT\"}" >/dev/null
expect_code "a person gets workspace-read-only in payments" 201 "$PLATFORM_TOKEN" POST $DEV/payments/rbac/users/probe-viewer/roles '{"roles":"workspace-read-only"}'
expect_code "they can read the payments workspace" 200 "$VT" GET $DEV/payments/services
expect_code "they can't create a service" 403 "$VT" POST $DEV/payments/services '{"name":"x","url":"https://x.example"}'
expect_code "they can't change the team's service" 403 "$VT" PUT $DEV/payments/services/team-payments '{"name":"team-payments","url":"https://x.example"}'
expect_code "they can't read orders" 403 "$VT" GET $DEV/orders/services
expect_code "they can't read the license" 403 "$VT" GET $DEV/payments/licenses
code "$PLATFORM_TOKEN" DELETE $DEV/payments/rbac/users/probe-viewer >/dev/null

echo "== 3. Mandatory plugins (dev). PUT is how decK and Terraform update a plugin."
for name in correlation-id request-size-limiting rate-limiting; do
  p=$(platform_plugin $DEV payments $name); id=$(yq -p json .id <<<"$p")
  expect_code "payments switches off mandatory $name" 403 "$PAY_DEV" PUT "$DEV/payments/plugins/$id" "$(put_body false <<<"$p")"
  expect_code "payments deletes mandatory $name" 403 "$PAY_DEV" DELETE "$DEV/payments/plugins/$id"
done
n=$(curl -s -H "Kong-Admin-Token: $PLATFORM_TOKEN" "$DEV/payments/plugins?tags=platform" | yq -p json '[.data[] | select(.enabled)] | length')
[[ $n == 3 ]] && ok "all 3 mandatory plugins still enabled" || bad "mandatory plugins still enabled" "$n enabled"
own=$(curl -s -H "Kong-Admin-Token: $PAY_DEV" "$DEV/payments/plugins?tags=team-payments" | yq -p json -o json -I0 '.data[] | select(.name == "key-auth")')
expect_code "control: payments updates its own plugin" 200 "$PAY_DEV" PUT "$DEV/payments/plugins/$(yq -p json .id <<<"$own")" "$(put_body true <<<"$own")"
rl=$(platform_plugin $DEV payments rate-limiting)
expect_code "control: the platform updates the same mandatory plugin" 200 "$PLATFORM_TOKEN" PUT "$DEV/payments/plugins/$(yq -p json .id <<<"$rl")" "$(put_body true <<<"$rl")"

echo "== 4. Drift (the drift workflow) and repair (the platform and teams workflows)"
workflow "no drift after deploy" pass drift.yaml
expect_code "someone edits a managed service by hand" 200 "$PAY_DEV" PATCH $DEV/payments/services/team-payments '{"retries":9}'
workflow "a hand edit is drift" fail drift.yaml
failed_step "found by the managed-config diff" "Failure - Main Drift: managed config differs"
workflow "the teams workflow repairs it" pass teams.yaml --input team=payments
expect_code "someone adds a plugin outside the pipelines" 201 "$PAY_DEV" POST $DEV/payments/services/team-payments/plugins '{"name":"rate-limiting","config":{"minute":100000,"policy":"local"}}'
rogue=$(yq -p json -o yaml .id .lab/e2e-body)
workflow "a plugin added by hand is drift" fail drift.yaml
failed_step "found by the ownership rule" "created outside the pipelines"
expect_code "it is removed" 204 "$PAY_DEV" DELETE "$DEV/payments/plugins/$rogue"
expect_code "a team creates its own rate-limiting tagged platform" 201 "$PAY_DEV" POST $DEV/payments/services/team-payments/plugins '{"name":"rate-limiting","config":{"minute":100000,"policy":"local"},"tags":["platform"]}'
fake=$(yq -p json -o yaml .id .lab/e2e-body)
lim=""; for _ in 1 2 3 4 5 6 7 8 9 10; do
  lim=$(curl -sk -o /dev/null -D - -H "apikey: $PAYMENTS_WEB_KEY" https://127.0.0.1:18443/payments | tr -d '\r' | awk -F': ' 'tolower($1)=="ratelimit-limit"{print $2}')
  [[ $lim == 100000 ]] && break; sleep 1; done
[[ $lim == 100000 ]] && ok "it replaces the platform's limit on live traffic (RateLimit-Limit: $lim)" || bad "override on live traffic" "RateLimit-Limit: $lim"
workflow "the override is drift" fail drift.yaml
failed_step "found by the no-mandatory-override rule" "overrides a mandatory plugin"
failed_step "and by the platform-tag rule" "only global plugins may carry the platform tag"
expect_code "it is removed" 204 "$PAY_DEV" DELETE "$DEV/payments/plugins/$fake"
rl=$(platform_plugin $DEV payments rate-limiting); rlid=$(yq -p json .id <<<"$rl")
expect_code "the platform's mandatory rate limit is switched off by hand" 200 "$PLATFORM_TOKEN" PUT "$DEV/payments/plugins/$rlid" "$(put_body false <<<"$rl")"
workflow "a switched-off mandatory plugin is drift" fail drift.yaml
failed_step "found by the platform job" "Failure - Main Drift: Kong differs from platform/foundation"
workflow "the platform workflow restores it" pass platform.yaml
expect_code "the mandatory rate limit is deleted outside the pipelines" 204 "$PLATFORM_TOKEN" DELETE "$DEV/payments/plugins/$rlid"
workflow "a deleted mandatory plugin is drift" fail drift.yaml
workflow "the platform workflow recreates it" pass platform.yaml
new=$(yq -p json .id <<<"$(platform_plugin $DEV payments rate-limiting)")
[[ -n $new && $new != "$rlid" ]] && ok "recreated with a new ID" || bad "recreated with a new ID"
expect_code "payments deletes the recreated plugin" 403 "$PAY_DEV" DELETE "$DEV/payments/plugins/$new"
workflow "no drift once repaired" pass drift.yaml

echo "== 5. Rollback from the pre-sync backup"
deck gateway dump --workspace payments --select-tag team-payments --skip-consumers -o .lab/backup.yaml --yes \
  --kong-addr $DEV --headers "Kong-Admin-Token:$PAY_DEV" >/dev/null 2>&1
expect_code "a bad change lands" 200 "$PAY_DEV" PATCH $DEV/payments/services/team-payments '{"retries":0}'
deck gateway sync --workspace payments --select-tag team-payments --skip-consumers .lab/backup.yaml \
  --kong-addr $DEV --headers "Kong-Admin-Token:$PAY_DEV" >/dev/null 2>&1 && ok "deck gateway sync of the backup (--skip-consumers)" || bad "rollback sync"
r=$(curl -s -H "Kong-Admin-Token: $PAY_DEV" $DEV/payments/services/team-payments | yq -p json .retries)
[[ $r == 5 ]] && ok "the service is back as it was (retries $r)" || bad "rollback restored the service" "retries $r"
expect_code "the team's consumer is still there" 200 "$PAY_DEV" GET $DEV/payments/consumers/payments-web

echo "== 6. Token rotation keeps the team's access"
( cd platform/foundation && export PG_CONN_STR="postgres://kong:$PG_PASSWORD@127.0.0.1:15432/tfstate?sslmode=disable" \
    TF_VAR_admin_url=$DEV TF_VAR_admin_token=$PLATFORM_TOKEN && terraform workspace select dev >/dev/null && \
  terraform apply -input=false -auto-approve -replace='random_password.ci_token["payments"]' >/dev/null ) \
  && ok "the payments token is rotated (Terraform replaces its RBAC user)" || bad "token rotation"
NEW=$(lab/lab.sh token dev payments)
[[ $NEW != "$PAY_DEV" ]] && ok "it is a new token" || bad "it is a new token"
expect_code "the old token is refused" 401 "$PAY_DEV" GET $DEV/payments/services
expect_code "the new token reads the team's service" 200 "$NEW" GET $DEV/payments/services/team-payments
workflow "the teams workflow deploys with the new token" pass teams.yaml --input team=payments
grep -q "Updated: 0" .lab/e2e-act.log && grep -q "Created: 0" .lab/e2e-act.log && ok "  and has nothing to change" || bad "  and has nothing to change"

echo "== 7. Promotion"
d=$(curl -s -H "Kong-Admin-Token: $PLATFORM_TOKEN" $DEV/payments/services/team-payments | yq -p json .id)
p=$(curl -s -H "Kong-Admin-Token: $PLATFORM_TOKEN" $PROD/payments/services/team-payments | yq -p json .id)
[[ -n $d && $d == "$p" ]] && ok "same service ID in dev and prod (built from the same spec)" || bad "same service ID in dev and prod"
dp=$(curl -s -H "Kong-Admin-Token: $PLATFORM_TOKEN" $DEV/payments/services/team-payments | yq -p json .path)
pp=$(curl -s -H "Kong-Admin-Token: $PLATFORM_TOKEN" $PROD/payments/services/team-payments | yq -p json .path)
[[ $dp == /anything/payments && $pp == /anything/payments-prod ]] && ok "prod gets its environment patch (backend $pp), dev doesn't ($dp)" \
  || bad "environment patch" "dev $dp, prod $pp"

echo; echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
