#!/usr/bin/env bash
# Runs the whole model on 127.0.0.1: two environments (dev, prod) of Kong Gateway Enterprise
# in Docker, the platform pipeline, then every team pipeline. Called by make.
#
#   lab/lab.sh up | down | clean | env <dev|prod> <team|platform>
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
lic=${KONG_LICENSE_FILE:-$HOME/.kong-license-data/license.json}

secrets() {
  if [[ ! -f .env ]]; then
    umask 077
    { echo "PG_PASSWORD=$(openssl rand -hex 16)"
      echo "KONG_ADMIN_TOKEN=$(openssl rand -hex 24)"
      echo "DECK_PAYMENTS_WEB_KEY=$(openssl rand -hex 16)"
      echo "DECK_ORDERS_WEB_KEY=$(openssl rand -hex 16)"; } > .env
  fi
  set -a; . ./.env; set +a
}

compose() {
  [[ -f $lic ]] || { echo "no Kong Enterprise license at $lic (set KONG_LICENSE_FILE)" >&2; exit 1; }
  KONG_LICENSE_DATA=$(cat "$lic") docker compose -f lab/compose.yaml "$@"
}

admin() { [[ $1 == dev ]] && echo http://127.0.0.1:18001 || echo http://127.0.0.1:19001; }
proxy() { [[ $1 == dev ]] && echo https://127.0.0.1:18443 || echo https://127.0.0.1:19443; }

# Print the environment a pipeline needs, for: eval "$(lab/lab.sh env dev payments)"
envfor() {
  local env=$1 who=$2
  if [[ $who == platform ]]; then
    printf 'export TF_VAR_admin_url=%q TF_VAR_admin_token=%q\n' "$(admin "$env")" "$KONG_ADMIN_TOKEN"
  else
    local tok
    tok=$(cd platform/foundation && terraform workspace select "$env" >/dev/null && terraform output -json ci_tokens | yq -p json ".$who")
    local key; key=$(eval echo "\$DECK_$(tr '[:lower:]' '[:upper:]' <<<"$who")_WEB_KEY")
    printf 'export KONG_ADDR=%q KONG_TOKEN=%q PROXY_URL=%q SMOKE_KEY=%q SMOKE_INSECURE=1\n' "$(admin "$env")" "$tok" "$(proxy "$env")" "$key"
    printf 'export DECK_%s_WEB_KEY=%q\n' "$(tr '[:lower:]' '[:upper:]' <<<"$who")" "$key"
  fi
}

deploy_team() {
  local env=$1 team=$2
  ( eval "$(envfor "$env" "$team")"
    for s in lint-api build lint-kong validate diff sync smoke; do
      echo "--- $team $env: $s"; pipelines/team.sh "$team" "$s"
    done )
}

case "${1:-}" in
  up)
    secrets
    compose up -d --wait
    for env in dev prod; do
      echo "=== platform $env"
      ( eval "$(envfor "$env" platform)"; pipelines/platform.sh "$env" apply | grep -E 'Apply complete|No changes'; pipelines/protect.sh "$env" )
      for team in $(yq '.teams[].name' teams.yaml); do deploy_team "$env" "$team"; done
    done
    echo; echo "Kong dev:  proxy https://127.0.0.1:18443  admin http://127.0.0.1:18001"
    echo "Kong prod: proxy https://127.0.0.1:19443  admin http://127.0.0.1:19001"
    ;;
  down) secrets; compose down ;;
  clean)
    secrets; compose down -v --remove-orphans
    rm -rf build platform/foundation/terraform.tfstate.d platform/foundation/.terraform/environment .env
    ;;
  env) secrets; envfor "${2:?env}" "${3:?team or platform}" ;;
  *) echo "usage: lab/lab.sh up|down|clean|env <env> <team|platform>" >&2; exit 2 ;;
esac
