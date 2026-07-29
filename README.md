# maclm-agent

`maclm-agent` is a native, fully local AI assistant for macOS. The project is
designed to work with locally hosted language models and to control the machine
through an explicit, human-approved tool layer without relying on cloud services.

Version v0.1.0 completes the local-first MVP. It supports native tool calling
through LM Studio and Ollama. The app
discovers local servers at `http://localhost:1234` and
`http://localhost:11434`, lists their models, and keeps the selected provider,
model, and optional custom URL between launches. Conversations and messages are stored with
SwiftData and remain available after relaunch. The main window includes a
sidebar for creating, switching, renaming, and deleting conversations. A
compact menu bar chat shares the active conversation and streaming state with
the main window. Safe read-only tools can read UTF-8 files, list directories,
and recursively search filenames using a case-insensitive substring match.
Dangerous tools can write, move, and trash files or run exact zsh commands with
captured output and a timeout. Every dangerous call pauses until the user
explicitly approves or rejects its complete arguments in the chat. Tool
arguments, decisions, and results are saved with each conversation and shown
inline. The Settings window provides live provider status, manual URL/model
override, persistent Light/Dark/Auto appearance, and a configurable global
hotkey (Control-Shift-Space by default) that toggles the menu bar panel from
any application. A tested Keychain service is ready for future secret-backed
providers.

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
