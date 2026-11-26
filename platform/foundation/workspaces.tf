# One Kong workspace per team, from teams.yaml.
resource "kong-gateway_workspace" "team" {
  for_each = local.teams
  name     = each.value.workspace
  comment  = "Owned by team ${each.key}. Managed by platform/foundation."
}
