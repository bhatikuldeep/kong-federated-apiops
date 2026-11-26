#!/usr/bin/env bash
# Scheduled drift check for one team in one environment, with the team's own token.
#
#   pipelines/drift.sh <team>        (KONG_ADDR, KONG_TOKEN as for team.sh)
#
# 1. Managed drift: what the team's repo says vs what Kong has, for entities with the team tag.
# 2. Unmanaged entities: anything in the workspace with neither the team tag nor "platform".
#    A select-tag diff can't see these (it ignores entities without the tag), so it is a
#    separate check.
# Exits 2 on drift, 1 on error, 0 when clean.
set -euo pipefail
team=${1:?usage: drift.sh <team>}
root=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(yq -e ".teams[] | select(.name == \"$team\") | .workspace" "$root/teams.yaml")
tag="team-$team"
: "${KONG_ADDR:?set KONG_ADDR}" "${KONG_TOKEN:?set KONG_TOKEN}"
export DECK_KONG_ADDR="$KONG_ADDR" DECK_HEADERS="Kong-Admin-Token:$KONG_TOKEN"

"$root/pipelines/team.sh" "$team" build >/dev/null
drift=0

set +e
deck gateway diff "$root/build/$team/kong.yaml" --workspace "$workspace" --select-tag "$tag" \
  --skip-workspace-crud --non-zero-exit-code > "$root/build/$team/drift.txt" 2>&1
rc=$?
set -e
case $rc in
  0) echo "$team: managed config matches the repo" ;;
  2) grep -E '^(creating|updating|deleting)' "$root/build/$team/drift.txt" || cat "$root/build/$team/drift.txt"
     echo "$team: DRIFT in managed config" >&2; drift=1 ;;
  *) cat "$root/build/$team/drift.txt" >&2; exit 1 ;;
esac

deck gateway dump --workspace "$workspace" --skip-workspace-crud --with-id -o "$root/build/$team/live.yaml" --yes >/dev/null
unmanaged=$(yq -o=tsv '
  [.. | select(kind == "map") | select(has("name") or has("username")) | select(has("id"))
      | select(((.tags // []) | contains(["'"$tag"'"]) | not) and ((.tags // []) | contains(["platform"]) | not))
      | (.name // .username)] | .[]' "$root/build/$team/live.yaml")
if [[ -n $unmanaged ]]; then
  echo "$team: UNMANAGED entities (no $tag or platform tag):" >&2
  sed 's/^/  - /' <<<"$unmanaged" >&2
  drift=1
else
  echo "$team: no unmanaged entities"
fi

[[ $drift == 0 ]] || exit 2
