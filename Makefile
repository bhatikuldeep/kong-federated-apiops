# Run from the repository root. Tools come from mise.toml (mise install). sso is optional (Part 3).
.PHONY: up test sso down clean
up:    ## Start dev and prod Kong, apply the platform, deploy every team
	mise exec -- lab/lab.sh up
test:  ## Prove each rule of the model, including the failure cases
	mise exec -- tests/e2e.sh
sso:   ## Optional: Kong Manager sign-in with Keycloak, then prove the IdP groups decide access
	mise exec -- lab/lab.sh sso
	mise exec -- tests/sso.sh
down:  ## Stop the containers (state is kept)
	mise exec -- lab/lab.sh down
clean: ## Remove everything this repository created
	mise exec -- lab/lab.sh clean
