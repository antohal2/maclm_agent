# Changelog

All notable changes to `maclm-agent` are documented in this file.

## [v0.1.0] - 2026-07-30

First local-first MVP release for macOS 15+ on Apple Silicon.

### Added

- Streaming chat with LM Studio through a provider-agnostic Swift interface.
- SwiftData persistence for conversations, messages, tool calls, and decisions.
- Shared chat state across the main window and compact menu bar interface.
- Automatic discovery of LM Studio and Ollama servers, with manual provider,
  URL, and model overrides.
- Safe read-only tools for reading files, listing directories, and searching
  filenames.
- Dangerous tools for writing, moving, and trashing files or running shell
  commands, protected by an explicit human-in-the-loop confirmation layer.
- Settings for provider selection, appearance, and a configurable global
  hotkey.
- Direct-distribution DMG packaging with an ad-hoc signed application.

### Distribution note

This release is not notarized and does not use an Apple Developer ID
certificate. Developer ID signing and Apple notarization with `notarytool` and
`stapler` will be added after enrollment in the Apple Developer Program.

[v0.1.0]: https://github.com/antohal2/maclm_agent/releases/tag/v0.1.0
