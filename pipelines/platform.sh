#!/usr/bin/env bash
# The platform pipeline: workspaces, access and mandatory plugins, with Terraform.
#
#   pipelines/platform.sh <env> <plan|apply|drift>
#
# Needs TF_VAR_admin_url and TF_VAR_admin_token (the platform team's token) for <env>.
# drift exits 2 when Kong no longer matches the code (someone changed it by hand).
set -euo pipefail
env=${1:?usage: platform.sh <env> <plan|apply|drift>}
action=${2:?usage: platform.sh <env> <plan|apply|drift>}
cd "$(dirname "$0")/../platform/foundation"
terraform init -input=false >/dev/null
terraform workspace select -or-create "$env" >/dev/null
case "$action" in
  plan)  terraform plan -input=false ;;
  apply) terraform apply -input=false -auto-approve ;;
  drift)
    set +e; terraform plan -input=false -detailed-exitcode -no-color > "/tmp/platform-drift-$env.txt"; rc=$?; set -e
    case $rc in
      0) echo "platform $env: no drift" ;;
      2) grep -E '^\s+# .* (will|must)' "/tmp/platform-drift-$env.txt" || true
         echo "platform $env: DRIFT, Kong differs from platform/foundation" >&2; exit 2 ;;
      *) cat "/tmp/platform-drift-$env.txt" >&2; exit 1 ;;
    esac ;;
  *) echo "unknown action: $action" >&2; exit 2 ;;
esac
