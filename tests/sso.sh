#!/usr/bin/env bash
# Kong Manager with Keycloak: people sign in with their identity provider account, and their
# Keycloak group alone decides what they can see. Each group carries <workspace>:<role>
# (payments:workspace-read-only) in the kong_roles claim. Nobody assigns roles in Kong by hand.
# Signs in the way Kong Manager's own tests do without a browser: Basic credentials on /auth,
# which Kong exchanges at Keycloak (password grant), then the session cookie on every call.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
set -a; . ./.env; set +a
DEV=http://127.0.0.1:18001 KC=http://127.0.0.1:18080
pass=0 fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
jar() { echo ".lab/sso-${1%%@*}.jar"; }

signin() { # user: the status of /auth (the password stays off the command line)
  rm -f "$(jar "$1")"
  curl -s -o /dev/null -w '%{http_code}' -c "$(jar "$1")" -K - "$DEV/auth" <<<"user = \"$1:$SSO_USER_PASSWORD\""
}
as() { # user method path: the status code
  curl -s -o /dev/null -w '%{http_code}' -b "$(jar "$1")" -X "$2" -H 'Content-Type: application/json' \
    ${3:+"$DEV$3"} ${4:+-d "$4"}
}
expect() { # desc want user method path [body]
  local got; got=$(as "${@:3}"); [[ $got == "$2" ]] && ok "$1 -> $got" || bad "$1" "got $got, want $2"
}
kc_token() {
  printf %s "$KC_ADMIN_PASSWORD" | curl -s "$KC/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin --data-urlencode password@- | yq -p json .access_token
}
kc() { curl -s -H "Authorization: Bearer $KCT" "$@"; }
move() { # user from-group to-group, in Keycloak
  local uid from to
  uid=$(kc "$KC/admin/realms/lab/users?exact=true&username=$1" | yq -p json '.[0].id')
  from=$(kc "$KC/admin/realms/lab/groups?exact=true&search=$2" | yq -p json '.[0].id')
  to=$(kc "$KC/admin/realms/lab/groups?exact=true&search=$3" | yq -p json '.[0].id')
  kc -X DELETE "$KC/admin/realms/lab/users/$uid/groups/$from"
  kc -X PUT "$KC/admin/realms/lab/users/$uid/groups/$to"
}
P=pay-reader@example.com O=ord-reader@example.com N=no-group@example.com

echo "== 1. A payments person (Keycloak group payments-read-only)"
c=$(signin $P); [[ $c == 302 ]] && ok "signs in through Keycloak -> $c" || bad "sign in" "got $c, want 302"
u=$(curl -s -b "$(jar $P)" "$DEV/userinfo" | yq -p json .admin.username)
[[ $u == "$P" ]] && ok "Kong knows them as $u" || bad "userinfo" "$u"
n=$(curl -s -H "Kong-Admin-Token: $PLATFORM_TOKEN" "$DEV/admins" | yq -p json "[.data[] | select(.username == \"$P\")] | length")
[[ $n == 1 ]] && ok "Kong created the admin at first sign-in" || bad "admin created" "$n admins named $P"
expect "reads payments" 200 $P GET /payments/services
expect "can't create a service in payments" 403 $P POST /payments/services '{"name":"x","url":"https://x.example"}'
expect "can't read orders" 403 $P GET /orders/services

echo "== 2. An orders person, and someone in no group"
signin $O >/dev/null
expect "orders person reads orders" 200 $O GET /orders/services
expect "orders person can't read payments" 403 $O GET /payments/services
c=$(signin $N); [[ $c == 302 ]] && ok "no-group person signs in -> $c" || bad "no-group sign in" "got $c"
expect "but can't read payments" 403 $N GET /payments/services
expect "or orders" 403 $N GET /orders/services

echo "== 3. The identity provider moves the payments person to orders"
KCT=$(kc_token)
move $P payments-read-only orders-read-only
signin $P >/dev/null
expect "after the next sign-in: no payments" 403 $P GET /payments/services
expect "and orders instead" 200 $P GET /orders/services
move $P orders-read-only payments-read-only
signin $P >/dev/null
expect "moved back: payments again" 200 $P GET /payments/services

rm -f .lab/sso-*.jar
echo; echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
