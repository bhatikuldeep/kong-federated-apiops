# Mandatory plugins: global in every team workspace (a global plugin applies only to its own
# workspace), tagged "platform" so a team's decK sync (scoped to the team's tag) never sees them
# as its own. The deployer role below can read them but not change or delete them.
resource "kong-gateway_plugin_correlation_id" "mandatory" {
  for_each  = local.teams
  workspace = kong-gateway_workspace.team[each.key].name
  tags      = ["platform"]
  enabled   = true # set explicitly, or Terraform ignores a plugin switched off by hand
  config = {
    header_name     = "Kong-Request-ID"
    generator       = "uuid#counter"
    echo_downstream = true
  }
}

resource "kong-gateway_plugin_request_size_limiting" "mandatory" {
  for_each  = local.teams
  workspace = kong-gateway_workspace.team[each.key].name
  tags      = ["platform"]
  enabled   = true # set explicitly, or Terraform ignores a plugin switched off by hand
  config = {
    allowed_payload_size = 1
    size_unit            = "megabytes"
  }
}

resource "kong-gateway_plugin_rate_limiting" "mandatory" {
  for_each  = local.teams
  workspace = kong-gateway_workspace.team[each.key].name
  tags      = ["platform"]
  enabled   = true # set explicitly, or Terraform ignores a plugin switched off by hand
  config = {
    minute   = 600
    limit_by = "ip"
    policy   = "local"
  }
}

locals {
  # Every mandatory plugin, per team, for the deny rules in rbac.tf.
  mandatory_plugin_ids = merge([
    for team in keys(local.teams) : {
      "${team}|correlation-id"        = { team = team, id = kong-gateway_plugin_correlation_id.mandatory[team].id }
      "${team}|request-size-limiting" = { team = team, id = kong-gateway_plugin_request_size_limiting.mandatory[team].id }
      "${team}|rate-limiting"         = { team = team, id = kong-gateway_plugin_rate_limiting.mandatory[team].id }
    }
  ]...)
}
