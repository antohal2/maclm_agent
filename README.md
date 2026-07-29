# maclm-agent

`maclm-agent` is a native, fully local AI assistant for macOS. The project is
designed to work with locally hosted language models and to control the machine
through an explicit, human-approved tool layer without relying on cloud services.

This repository currently contains the v0.1.0 application scaffold: a SwiftUI
window, a menu bar extra, the initial layer-based source layout, and a unit-test
target. Networking, model providers, persistence, and agent tools will be added
in later steps.

## Requirements

- macOS 15.0 or later on Apple Silicon
- Xcode with the macOS 15 SDK or later
- SwiftLint and SwiftFormat: `brew install swiftlint swiftformat`
- XcodeGen only when regenerating the project: `brew install xcodegen`

## Build and run

```sh
make build
make test
make lint
make run
```

You can also open `maclm-agent.xcodeproj` in Xcode, select the `maclm-agent`
scheme, and press Run. App Sandbox is intentionally disabled for this direct
distribution project.
