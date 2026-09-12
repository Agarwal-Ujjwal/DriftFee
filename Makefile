# DriftFee — common tasks. `make help` lists them.

.PHONY: help build test demo attacks fork deep analyze deploy-sim coverage clean

RPC ?= https://ethereum-rpc.publicnode.com
SLITHER := .venv-slither/bin/slither

help: ## List available targets
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Compile
	forge build

test: ## Full suite, excluding the network
	forge test --no-match-path 'test/*.fork.t.sol'

attacks: ## The four attack regressions, with numbers
	@forge test --match-test \
	  "splittingDoesNotDefeat|premovingNoLongerBuys|roundTripCostsMore|crossingEquilibriumIsPriced" -vv

demo: attacks ## Alias for `attacks`

fork: ## Run against the deployed mainnet PoolManager and real USDC/WETH
	forge test --match-path 'test/*.fork.t.sol' -vv

deep: ## 10k fuzz runs, 256 invariant runs
	FOUNDRY_PROFILE=deep forge test --no-match-path 'test/*.fork.t.sol'

coverage: ## Line/branch coverage for the hook
	forge coverage --match-path 'test/DriftFee.t.sol' --no-match-coverage '(test|lib)/'

analyze: ## Static analysis (see README for venv setup)
	$(SLITHER) .

deploy-sim: ## Simulate a mainnet deployment, mining the CREATE2 salt
	OWNER=0x1a9C8182C09F50C8318d769245beA52c32BE35BC \
	  forge script script/Deploy.s.sol:Deploy --rpc-url $(RPC)

clean: ## Remove build artifacts
	forge clean
