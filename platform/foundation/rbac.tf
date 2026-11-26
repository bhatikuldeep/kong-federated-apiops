# Access per team workspace. Kong runs with enforce_rbac = both, so a request must pass the
# endpoint rules and the entity rules.
locals {
  # The deployer may do anything in its workspace, except access control and the workspace itself.
  deployer_deny = ["/rbac", "/rbac/*", "/rbac/*/*", "/rbac/*/*/*", "/rbac/*/*/*/*", "/workspaces", "/workspaces/*", "/vaults", "/vaults/*"]
}

resource "kong-gateway_rbac_role" "deployer" {
  for_each  = local.teams
  name      = "apiops-deployer"
  comment   = "Used by the ${each.key} pipeline only."
  workspace = kong-gateway_workspace.team[each.key].name
}

resource "kong-gateway_rbac_role_endpoint" "deployer_allow" {
  for_each  = local.teams
  role_id   = kong-gateway_rbac_role.deployer[each.key].id
  workspace = kong-gateway_workspace.team[each.key].name
  endpoint  = "*"
  actions   = ["read", "create", "update", "delete"]
  negative  = false
}

resource "kong-gateway_rbac_role_endpoint" "deployer_deny" {
  for_each  = { for p in setproduct(keys(local.teams), local.deployer_deny) : "${p[0]}|${p[1]}" => { team = p[0], endpoint = p[1] } }
  role_id   = kong-gateway_rbac_role.deployer[each.value.team].id
  workspace = kong-gateway_workspace.team[each.value.team].name
  endpoint  = each.value.endpoint
  actions   = ["create", "update", "delete"]
  negative  = true
}

# Entity rules. Allow every entity, so the team's access never depends on which RBAC user created
# an entity (a rotated pipeline token keeps everything), then deny update and delete on each
# mandatory plugin: Kong checks the explicit deny first.
resource "kong-gateway_rbac_role_entity" "deployer_all" {
  for_each    = local.teams
  role_id     = kong-gateway_rbac_role.deployer[each.key].id
  workspace   = kong-gateway_workspace.team[each.key].name
  entity_id   = "*"
  entity_type = "wildcard"
  actions     = ["read", "create", "update", "delete"]
}

resource "kong-gateway_rbac_role_entity" "deployer_protect" {
  for_each    = local.mandatory_plugin_ids
  role_id     = kong-gateway_rbac_role.deployer[each.value.team].id
  workspace   = kong-gateway_workspace.team[each.value.team].name
  entity_id   = each.value.id
  entity_type = "plugins"
  actions     = ["update", "delete"]
  negative    = true
}

# Read-only access for the team's people (Kong Manager), mapped to an identity provider group
# in production.
resource "kong-gateway_rbac_role" "viewer" {
  for_each  = local.teams
  name      = "apiops-viewer"
  comment   = "Read-only, for the ${each.key} team's people."
  workspace = kong-gateway_workspace.team[each.key].name
}

resource "kong-gateway_rbac_role_endpoint" "viewer" {
  for_each  = local.teams
  role_id   = kong-gateway_rbac_role.viewer[each.key].id
  workspace = kong-gateway_workspace.team[each.key].name
  endpoint  = "*"
  actions   = ["read"]
  negative  = false
}

resource "kong-gateway_rbac_role_entity" "viewer" {
  for_each    = local.teams
  role_id     = kong-gateway_rbac_role.viewer[each.key].id
  workspace   = kong-gateway_workspace.team[each.key].name
  entity_id   = "*"
  entity_type = "wildcard"
  actions     = ["read"]
}

# The pipeline's own identity. No person uses this token.
resource "random_password" "ci_token" {
  for_each = local.teams
  length   = 40
  special  = false
}

resource "kong-gateway_rbac_user" "ci" {
  for_each   = local.teams
  name       = "ci-${each.key}"
  comment    = "The ${each.key} pipeline."
  user_token = random_password.ci_token[each.key].result
  enabled    = true
  workspace  = kong-gateway_workspace.team[each.key].name
}

resource "kong-gateway_rbac_user_role" "ci" {
  for_each  = local.teams
  user_id   = kong-gateway_rbac_user.ci[each.key].id
  role      = kong-gateway_rbac_role.deployer[each.key].name
  workspace = kong-gateway_workspace.team[each.key].name
}

output "ci_tokens" {
  description = "Each team pipeline's Admin API token. Store it as that team's CI secret."
  value       = { for k, v in random_password.ci_token : k => v.result }
  sensitive   = true
}
