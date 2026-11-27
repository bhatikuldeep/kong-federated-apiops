#!/usr/bin/env bash
# Runs the whole model on 127.0.0.1 with the repository's own GitHub workflows, executed by act:
# two environments (dev, prod) of Kong Gateway Enterprise in Docker, the one-time bootstrap, the
# platform workflow, then the teams workflow for every team. Called by make.
#
#   lab/lab.sh up | sso | down | clean | act <workflow> [act args] | token <env> <team|platform>
#
# act copies the repository into each job container (never --bind): a job can't change the
# files here. Terraform state lives in the lab's Postgres (pg backend), not in the repository.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
lic=${KONG_LICENSE_FILE:-$HOME/.kong-license-data/license.json}
runner=catthehacker/ubuntu@sha256:ebfc2752875ebb29fbfa360db9dcd2f76bc160147ec6bd1b035bba0ef8b38fbe
mkdir -p .lab

secrets() {
  if [[ ! -f .env ]]; then
    umask 077
    { echo "PG_PASSWORD=$(openssl rand -hex 16)"
      echo "KONG_ADMIN_TOKEN=$(openssl rand -hex 24)"
      echo "PLATFORM_TOKEN=$(openssl rand -hex 24)"
      echo "PAYMENTS_WEB_KEY=$(openssl rand -hex 16)"
      echo "ORDERS_WEB_KEY=$(openssl rand -hex 16)"; } > .env
  fi
  if ! grep -q '^KC_ADMIN_PASSWORD=' .env; then
    { echo "KC_ADMIN_PASSWORD=$(openssl rand -hex 16)"
      echo "KC_CLIENT_SECRET=$(openssl rand -hex 24)"
      echo "SSO_USER_PASSWORD=$(openssl rand -hex 12)"; } >> .env
  fi
  set -a; . ./.env; set +a
}

compose() {
  [[ -f $lic ]] || { echo "no Kong Enterprise license at $lic (set KONG_LICENSE_FILE)" >&2; exit 1; }
  local files=(-f lab/compose.yaml)
  [[ -f .lab/sso ]] && files+=(-f lab/compose.sso.yaml)   # after make sso
  KONG_LICENSE_DATA=$(cat "$lic") docker compose "${files[@]}" "$@"
}

admin() { [[ $1 == dev ]] && echo http://127.0.0.1:18001 || echo http://127.0.0.1:19001; }
upper() { tr '[:lower:]' '[:upper:]' <<<"$1"; }

# A team pipeline's token, as Terraform created it (what you'd store as a CI secret).
token() { # env team|platform
  if [[ $2 == platform ]]; then echo "$PLATFORM_TOKEN"; return; fi
  ( cd platform/foundation
    export PG_CONN_STR="postgres://kong:$PG_PASSWORD@127.0.0.1:15432/tfstate?sslmode=disable"
    terraform init -input=false >/dev/null
    terraform workspace select "$1" >/dev/null
    terraform output -json ci_tokens ) | yq -p json ".$2"
}

# What a GitHub repository would hold as variables and secrets, for act.
act_files() {
  { echo "KONG_ADDR_DEV=http://kong-dev:8001"; echo "KONG_ADDR_PROD=http://kong-prod:8001"
    echo "PROXY_URL_DEV=https://kong-dev:8443"; echo "PROXY_URL_PROD=https://kong-prod:8443"
    echo "PROXY_INSECURE=true"; echo "KONG_ENABLED=true"; } > .lab/vars
  { echo "PLATFORM_TOKEN_DEV=$PLATFORM_TOKEN"; echo "PLATFORM_TOKEN_PROD=$PLATFORM_TOKEN"
    echo "SUPER_ADMIN_TOKEN_DEV=$KONG_ADMIN_TOKEN"; echo "SUPER_ADMIN_TOKEN_PROD=$KONG_ADMIN_TOKEN"
    # One state database in the lab; in production each environment's connection reaches only its own state.
    echo "TF_STATE_PG_CONN_DEV=postgres://kong:$PG_PASSWORD@postgres:5432/tfstate?sslmode=disable"
    echo "TF_STATE_PG_CONN_PROD=postgres://kong:$PG_PASSWORD@postgres:5432/tfstate?sslmode=disable"
    if [[ ${1:-} == teams ]]; then
      for t in $(yq '.teams[].name' teams.yaml); do
        local T key; T=$(upper "$t"); key=$(eval echo "\$${T}_WEB_KEY")
        echo "KONG_TOKEN_${T}_DEV=$(token dev "$t")"; echo "KONG_TOKEN_${T}_PROD=$(token prod "$t")"
        for E in DEV PROD; do
          echo "TEAM_SECRETS_${T}_${E}={\"DECK_${T}_WEB_KEY\":\"$key\"}"; echo "SMOKE_KEY_${T}_${E}=$key"
        done
      done
    fi; } > .lab/secrets
  chmod 600 .lab/secrets
}

run_act() { # workflow file, then act args
  local wf=$1; shift
  # Never mount the working copy into a job: a checkout step would wipe it.
  for a in "$@"; do [[ $a == --bind* ]] && { echo "refusing to run act with --bind" >&2; exit 2; }; done
  # act 0.2.98 can crash ("fatal error: concurrent map ...") when it starts the matrix jobs of a reusable
  # workflow called with `secrets: inherit`. GitHub runs them on separate runners. Every workflow
  # here is safe to run again (drift only reads; deploy and apply converge), so retry the crash.
  local out rc attempt
  for attempt in 1 2 3; do
    out=$(mktemp); rc=0
    act workflow_dispatch -W ".github/workflows/$wf" --network fapi_default --pull=false \
      -P "ubuntu-latest=$runner" --var-file .lab/vars --secret-file .lab/secrets "$@" >"$out" 2>&1 || rc=$?
    cat "$out"
    if grep -q "fatal error: concurrent map" "$out"; then
      rm -f "$out"; echo "act crashed (known act bug), run $attempt of 3; retrying" >&2; continue
    fi
    rm -f "$out"; return $rc
  done
  return 1
}

case "${1:-}" in
  up)
    secrets
    if [[ ! -f .lab/bootstrapped ]]; then
      echo "=== one-time bootstrap (enforce_rbac = on)"
      KONG_ENFORCE_RBAC=on compose up -d --wait
      act_files
      for env in dev prod; do run_act bootstrap.yaml --input environment=$env; done
      touch .lab/bootstrapped
    fi
    echo "=== Kong with enforce_rbac = both"
    compose up -d --wait
    act_files
    echo "=== platform workflow"; run_act platform.yaml
    act_files teams
    for t in $(yq '.teams[].name' teams.yaml); do
      echo "=== teams workflow: $t"; run_act teams.yaml --input team="$t"
    done
    echo; echo "Kong dev:  proxy https://127.0.0.1:18443  Admin API http://127.0.0.1:18001  Kong Manager http://127.0.0.1:18002"
    echo "Kong prod: proxy https://127.0.0.1:19443  Admin API http://127.0.0.1:19001  Kong Manager http://127.0.0.1:19002"
    if [[ -f .lab/sso ]]; then echo "Kong Manager dev: sign in with Keycloak (make sso)"
    else echo "Kong Manager login: kong_admin, password = KONG_ADMIN_TOKEN in .env"; fi
    ;;
  sso)
    secrets
    [[ -f .lab/bootstrapped ]] || { echo "run make up first" >&2; exit 1; }
    touch .lab/sso
    echo "=== Keycloak, and Kong Manager on dev with OpenID Connect"
    compose up -d --wait
    echo; echo "Kong Manager dev: http://127.0.0.1:18002, sign in with Keycloak"
    echo "Users: pay-reader@example.com, ord-reader@example.com, no-group@example.com"
    echo "Password: SSO_USER_PASSWORD in .env. Keycloak admin: http://127.0.0.1:18080 (admin, KC_ADMIN_PASSWORD)"
    ;;
  down) secrets; compose down ;;
  clean)
    secrets
    # act job containers and their volumes (act-toolcache is shared between runs: keep it)
    docker ps -aq --filter "name=^act-" | xargs -r docker rm -f >/dev/null
    docker volume ls -q --filter "name=^act-" | grep -v '^act-toolcache$' | xargs -r docker volume rm >/dev/null || true
    compose down -v --remove-orphans
    for d in build .lab; do [[ -e $d ]] && rm -r "$d"; done
    rm -f .env platform/foundation/.terraform/environment platform/foundation/.terraform/terraform.tfstate
    ;;
  act) secrets; act_files teams; shift; run_act "$@" ;;
  token) secrets; token "${2:?env}" "${3:?team or platform}" ;;
  *) echo "usage: lab/lab.sh up|sso|down|clean|act <workflow> [args]|token <env> <team>" >&2; exit 2 ;;
esac
