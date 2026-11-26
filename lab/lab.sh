#!/usr/bin/env bash
# Runs the whole model on 127.0.0.1 with the repository's own GitHub workflows, executed by act:
# two environments (dev, prod) of Kong Gateway Enterprise in Docker, the one-time bootstrap, the
# platform workflow, then the teams workflow for every team. Called by make.
#
#   lab/lab.sh up | down | clean | act <workflow> [act args] | token <env> <team|platform>
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
  set -a; . ./.env; set +a
}

compose() {
  [[ -f $lic ]] || { echo "no Kong Enterprise license at $lic (set KONG_LICENSE_FILE)" >&2; exit 1; }
  KONG_LICENSE_DATA=$(cat "$lic") docker compose -f lab/compose.yaml "$@"
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
    echo "PROXY_INSECURE=true"; } > .lab/vars
  { echo "PLATFORM_TOKEN_DEV=$PLATFORM_TOKEN"; echo "PLATFORM_TOKEN_PROD=$PLATFORM_TOKEN"
    echo "TF_STATE_PG_CONN=postgres://kong:$PG_PASSWORD@postgres:5432/tfstate?sslmode=disable"
    if [[ ${1:-} == teams ]]; then
      for t in $(yq '.teams[].name' teams.yaml); do
        local T key; T=$(upper "$t"); key=$(eval echo "\$${T}_WEB_KEY")
        echo "KONG_TOKEN_${T}_DEV=$(token dev "$t")"; echo "KONG_TOKEN_${T}_PROD=$(token prod "$t")"
        echo "TEAM_SECRETS_${T}={\"DECK_${T}_WEB_KEY\":\"$key\"}"; echo "SMOKE_KEY_${T}=$key"
      done
    fi; } > .lab/secrets
  chmod 600 .lab/secrets
}

run_act() { # workflow file, then act args
  local wf=$1; shift
  # Never mount the working copy into a job: a checkout step would wipe it.
  for a in "$@"; do [[ $a == --bind* ]] && { echo "refusing to run act with --bind" >&2; exit 2; }; done
  act workflow_dispatch -W ".github/workflows/$wf" --network fapi_default --pull=false \
    -P "ubuntu-latest=$runner" --var-file .lab/vars --secret-file .lab/secrets "$@"
}

case "${1:-}" in
  up)
    secrets
    if [[ ! -f .lab/bootstrapped ]]; then
      echo "=== one-time bootstrap (enforce_rbac = on)"
      KONG_ENFORCE_RBAC=on compose up -d --wait
      for env in dev prod; do
        KONG_ADDR=$(admin $env) SUPER_ADMIN_TOKEN=$KONG_ADMIN_TOKEN PLATFORM_TOKEN=$PLATFORM_TOKEN \
          platform/bootstrap/bootstrap.sh
      done
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
    echo "Kong Manager login: kong_admin, password = KONG_ADMIN_TOKEN in .env"
    ;;
  down) secrets; compose down ;;
  clean)
    secrets; compose down -v --remove-orphans
    for d in build .lab; do [[ -e $d ]] && rm -r "$d"; done
    rm -f .env platform/foundation/.terraform/environment platform/foundation/.terraform/terraform.tfstate
    ;;
  act) secrets; act_files teams; shift; run_act "$@" ;;
  token) secrets; token "${2:?env}" "${3:?team or platform}" ;;
  *) echo "usage: lab/lab.sh up|down|clean|act <workflow> [args]|token <env> <team>" >&2; exit 2 ;;
esac
