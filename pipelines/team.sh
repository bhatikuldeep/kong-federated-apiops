#!/usr/bin/env bash
# The team pipeline. Every stage runs the same way on a laptop and in CI.
#
#   pipelines/team.sh <team> <stage>
#
# Stages, in order: lint-api, build, lint-kong, validate, diff, sync, smoke.
# Offline stages (lint-api, build, lint-kong) need no Kong. Online stages need:
#   KONG_ADDR    the environment's Admin API, e.g. https://kong-admin.dev.example.com
#   KONG_TOKEN   the team pipeline's own RBAC token (never a person's, never the platform's)
#   PROXY_URL    the environment's proxy (https), for smoke; SMOKE_KEY a consumer key
set -euo pipefail

team=${1:?usage: team.sh <team> <stage>}
stage=${2:?usage: team.sh <team> <stage>}
root=$(cd "$(dirname "$0")/.." && pwd)
src="${TEAM_DIR:-$root/teams/$team}"     # a team's own repository can point this at its root
out="$root/build/$team"
mkdir -p "$out"

entry=$(yq -e ".teams[] | select(.name == \"$team\")" "$root/teams.yaml") \
  || { echo "team '$team' is not in teams.yaml" >&2; exit 1; }
workspace=$(yq '.workspace' <<<"$entry")
prefix=$(yq '.path_prefix' <<<"$entry")
tag="team-$team"

online() {
  : "${KONG_ADDR:?set KONG_ADDR}" "${KONG_TOKEN:?set KONG_TOKEN}"
  export DECK_KONG_ADDR="$KONG_ADDR" DECK_HEADERS="Kong-Admin-Token:$KONG_TOKEN"
}
gw() { deck gateway "$@" --workspace "$workspace" --select-tag "$tag" --skip-workspace-crud; }

case "$stage" in
  lint-api)
    deck file lint -s "$src/openapi.yaml" "$root/platform/governance/api-rules.yaml"
    ;;
  build)
    deck file openapi2kong -s "$src/openapi.yaml" --select-tag "$tag" --uuid-base "$tag" -o "$out/1-oas.yaml"
    deck file add-plugins -s "$out/1-oas.yaml" -o "$out/2-plugins.yaml" "$src/plugins.yaml"
    deck file merge -o "$out/3-merged.yaml" "$out/2-plugins.yaml" "$src/consumers.yaml"
    deck file add-tags -s "$out/3-merged.yaml" -o "$out/kong.yaml" "$tag"
    yq -i "._workspace = \"$workspace\"" "$out/kong.yaml"
    echo "built $out/kong.yaml"
    ;;
  lint-kong)
    # The platform's rules, plus one generated for this team: its routes stay under its prefix.
    cat > "$out/team-rules.yaml" <<RULES
rules:
  route-prefix:
    description: Routes stay under the team's path prefix from teams.yaml.
    given: \$..routes[*].paths[*]
    severity: error
    message: "routes of team $team must start with $prefix"
    then:
      function: pattern
      functionOptions: {match: "^~?$prefix([/\$]|\$)"}
RULES
    rc=0
    deck file lint -s "$out/kong.yaml" --display-only-failures "$root/platform/governance/kong-rules.yaml" || rc=1
    deck file lint -s "$out/kong.yaml" --display-only-failures "$out/team-rules.yaml" || rc=1
    exit $rc
    ;;
  validate) online; deck gateway validate "$out/kong.yaml" --workspace "$workspace" --skip-workspace-crud ;;
  diff)     online; gw diff "$out/kong.yaml" ;;
  sync)     online; gw sync "$out/kong.yaml" ;;
  smoke)
    : "${PROXY_URL:?set PROXY_URL}" "${SMOKE_KEY:?set SMOKE_KEY (a consumer key for this team)}"
    # SMOKE_INSECURE=1 only for a proxy with Kong's default self-signed certificate (the lab).
    tls=(); [[ ${SMOKE_INSECURE:-} == 1 ]] && tls=(--insecure)
    # Kong picks up new routes within db_update_frequency (5 s by default): retry briefly.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      headers=$(curl -sS "${tls[@]}" -o /dev/null -D - -H "apikey: $SMOKE_KEY" "$PROXY_URL$prefix")
      [[ $(head -1 <<<"$headers" | awk '{print $2}') == 200 ]] && break
      sleep 1
    done
    code=$(head -1 <<<"$headers" | awk '{print $2}')
    echo "GET $prefix -> $code"
    [[ $code == 200 ]] || { echo "smoke failed: expected 200" >&2; exit 1; }
    grep -qi '^kong-request-id:' <<<"$headers" || { echo "mandatory correlation-id did not run" >&2; exit 1; }
    grep -qi '^x-ratelimit-limit-minute:' <<<"$headers" || { echo "mandatory rate-limiting did not run" >&2; exit 1; }
    echo "mandatory platform plugins ran on $team's route"
    ;;
  *) echo "unknown stage: $stage" >&2; exit 2 ;;
esac
