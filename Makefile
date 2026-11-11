.PHONY: help vendor shell site-config site-config-check elm-dev elm-build elm-test elm-check elm-format elm-tailwind-gen pb-hook-test pb-migration-check photo-pipeline-test crop-gesture-test statics-build statics statics-test dist build test check clean

help: ## List available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "%-22s %s\n", $$1, $$2}'

vendor: ## Ensure the shared master-builder checkout exists
	@if [ ! -e vendor/master-builder/AGENTS.md ]; then mkdir -p vendor && git clone https://github.com/Suomen-Palikkaharrastajat-ry/master-builder.git vendor/master-builder; fi

shell: ## Enter devenv shell
	devenv shell

SITE_CONFIG_I18N := elm-app/src elm-app/main.js
-include vendor/master-builder/mk/site-config.mk

.PHONY: elm-dev
elm-dev: vendor ## Start the Elm/Vite development server
	cd elm-app && vite --host 0.0.0.0 --configLoader runner

.PHONY: elm-build
elm-build: site-config-check elm-tailwind-gen ## Build the SPA and copy static assets into dist/
	cd elm-app && vite build --configLoader runner
	cp -r assets/. dist/

.PHONY: elm-test
elm-test: elm-tailwind-gen ## Run Elm unit tests
	cd elm-app && elm-test

.PHONY: pb-hook-test
pb-hook-test: ## Syntax-check and run no-network PocketBase hook tests
	node --check fixtures/pb_hooks/set_lookup.pb.js
	node --test fixtures/pb_hooks/set_lookup.test.mjs

.PHONY: pb-migration-check
pb-migration-check: ## Syntax-check the list photo migration
	node --check fixtures/pb_migrations/1794377044_table_catalogs_photo.js

.PHONY: photo-pipeline-test
photo-pipeline-test: ## Test thumbnail sizing and metadata stripping
	node --test elm-app/photo-pipeline.test.mjs

.PHONY: crop-gesture-test
crop-gesture-test: ## Test cover crop pointer, touch, and wheel gesture handling
	node --test elm-app/crop-gestures.test.mjs

.PHONY: elm-tailwind-gen
elm-tailwind-gen: elm-app/.elm-tailwind/.stamp ## Generate typed Tailwind Elm modules for shared UI components

ELM_APP_SOURCES := $(shell find elm-app/src -name '*.elm')
ELM_PACKAGE_SOURCES := $(shell find vendor/master-builder/packages -name '*.elm' -o -name '*.css' 2>/dev/null)

elm-app/.elm-tailwind/.stamp: elm-app/elm.json elm-app/vite.config.mjs elm-app/main.css $(ELM_APP_SOURCES) $(ELM_PACKAGE_SOURCES)
	cd elm-app && elm-tailwind-classes gen
	mkdir -p elm-app/.elm-tailwind
	touch $@

.PHONY: elm-check
elm-check: site-config-check elm-tailwind-gen ## Validate Elm formatting
	cd elm-app && elm-format --validate src/ tests/

.PHONY: elm-format
elm-format: ## Format Elm sources
	cd elm-app && elm-format --yes src/ tests/

.PHONY: statics-build
statics-build: ## Build the explicit no-op Haskell statics executable
	cabal build statics
	cp $$(cabal list-bin statics) statics/statics

.PHONY: statics
statics: statics-build ## Run the explicit no-op static generator
	./statics/statics

.PHONY: statics-test
statics-test: ## This intentionally small static generator has no separate tests
	@echo "No statics tests: generator is an explicit no-op."

.PHONY: dist build
dist build: elm-build statics ## Build SPA assets and run the no-op statics target

.PHONY: test
test: elm-test pb-hook-test pb-migration-check photo-pipeline-test crop-gesture-test statics-test ## Run application tests

.PHONY: check
check: elm-check ## Run formatting and site configuration checks

.PHONY: clean
clean: ## Remove generated outputs
	rm -rf dist elm-app/elm-stuff elm-app/.elm-tailwind elm-app/.vite dist-newstyle statics/statics
