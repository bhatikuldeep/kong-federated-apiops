#!/usr/bin/env bash
# Entity-level rules for every team workspace, after platform.sh apply. Safe to re-run.
#
#   pipelines/protect.sh <env>      (TF_VAR_admin_url, TF_VAR_admin_token as for platform.sh)
#
# For each team:
#   deployer role: every entity (the role's endpoint rules keep it inside its workspace) (so ownership never depends on which RBAC user
#                  created it), except update and delete on each mandatory plugin
#   viewer role:   read every entity
# Kong evaluates an explicit deny on an entity ahead of a workspace-wide allow.
set -euo pipefail
env=${1:?usage: protect.sh <env>}
root=$(cd "$(dirname "$0")/.." && pwd)
: "${TF_VAR_admin_url:?}" "${TF_VAR_admin_token:?}"
input=$(cd "$root/platform/foundation" && terraform workspace select "$env" >/dev/null && terraform output -json protect)

grant() { # role_id entity_id entity_type actions negative
  local ws=$1 role=$2 body code
  body=$(printf '{"entity_id":"%s","entity_type":"%s","actions":"%s","negative":%s,"comment":"managed by pipelines/protect.sh"}' "$3" "$4" "$5" "$6")
  code=$(curl -sS -o /tmp/protect-$$.json -w '%{http_code}' -X POST -H "Kong-Admin-Token: $TF_VAR_admin_token" \
    -H 'Content-Type: application/json' "$TF_VAR_admin_url/$ws/rbac/roles/$role/entities" -d "$body")
  case $code in
    201) echo "  + $4 $3 ($5$([[ $6 == true ]] && echo ', deny'))" ;;
    400) grep -q '"primary key violation"' /tmp/protect-$$.json || { cat /tmp/protect-$$.json >&2; return 1; } ;;  # already there
    *) echo "  ! $4 $3: HTTP $code" >&2; return 1 ;;
  esac
}

for team in $(yq -p json 'keys | .[]' <<<"$input"); do
  t=$(yq -p json ".$team" <<<"$input")
  ws=$(yq '.workspace' <<<"$t")
  dep=$(yq '.deployer_id' <<<"$t"); view=$(yq '.viewer_id' <<<"$t")
  echo "$team ($env):"
  # "*" and not the workspace ID: decK creates entities with PUT /<entity>/<new id>, and Kong
  # can't place an ID that doesn't exist yet in a workspace, so a workspace-wide grant denies it.
  grant "$ws" "$dep" "*" wildcard read,create,update,delete false
  grant "$ws" "$view" "*" wildcard read false
  for id in $(yq '.mandatory[]' <<<"$t"); do grant "$ws" "$dep" "$id" plugins update,delete true; done
done
