# Four commands, run from the repository root. Tools come from mise.toml (mise install).
.PHONY: up test down clean
up:    ## Start dev and prod Kong, apply the platform, deploy every team
	mise exec -- lab/lab.sh up
test:  ## Prove each rule of the model, including the failure cases
	mise exec -- tests/e2e.sh
down:  ## Stop the containers (state is kept)
	mise exec -- lab/lab.sh down
clean: ## Remove everything this repository created
	mise exec -- lab/lab.sh clean
