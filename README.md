# maclm-agent

`maclm-agent` is a native, fully local AI assistant for macOS. The project is
designed to work with locally hosted language models and to control the machine
through an explicit, human-approved tool layer without relying on cloud services.

Version v0.1.5 supports native tool calling through LM Studio and Ollama. The app
discovers local servers at `http://localhost:1234` and
`http://localhost:11434`, lists their models, and keeps the selected provider,
model, and optional custom URL between launches. Conversations and messages are stored with
SwiftData and remain available after relaunch. The main window includes a
sidebar for creating, switching, renaming, and deleting conversations. A
compact menu bar chat shares the active conversation and streaming state with
the main window. Safe read-only tools can read UTF-8 files, list directories,
and recursively search filenames using a case-insensitive substring match.
Tool arguments and results are saved with each conversation and shown inline.

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
