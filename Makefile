PROJECT := maclm-agent.xcodeproj
SCHEME := maclm-agent
CONFIGURATION ?= Debug
DERIVED_DATA ?= /tmp/maclm-agent-DerivedData
DESTINATION := platform=macOS,arch=arm64

.PHONY: build test lint format run generate release tools

build:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		build

test:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		test

lint: tools
	swiftformat maclm-agent maclm-agentTests --lint --cache ignore
	swiftlint lint --no-cache --strict --config .swiftlint.yml

format: tools
	swiftformat maclm-agent maclm-agentTests --cache ignore
	swiftlint lint --fix --no-cache --config .swiftlint.yml

run: build
	open "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/maclm-agent.app"

release:
	./scripts/build_release.sh

generate:
	@command -v xcodegen >/dev/null || { \
		echo "error: XcodeGen is required. Install it with: brew install xcodegen"; \
		exit 1; \
	}
	xcodegen generate

tools:
	@command -v swiftformat >/dev/null || { \
		echo "error: SwiftFormat is required. Install it with: brew install swiftformat"; \
		exit 1; \
	}
	@command -v swiftlint >/dev/null || { \
		echo "error: SwiftLint is required. Install it with: brew install swiftlint"; \
		exit 1; \
	}
