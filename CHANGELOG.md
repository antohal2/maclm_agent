# Changelog

## [v0.4.10.1] - 2026-10-06

- Ship original AI-generated Scout (Скаут) sprite art through the existing bundle folder resource and production validator.
- Default to scout, migrate the legacy built-in selection, and log validation failures before using Canvas.
- Cover bundled art, selection migration, and valid/corrupt fallback paths; v0.4.x is fully closed.

All notable changes to `maclm-agent` are documented in this file.

## [v0.4.10] - 2026-10-06

### Added

- Custom pet folders: bounded descriptor-based reads without following symlinks,
  shared JSON/PNG validation, reserved and case-insensitive identifier checks,
  a 50-pet limit, and atomic install/replacement after disk revalidation.
- Pet selection, thumbnails, confirmed deletion, refresh with broken-entry reasons,
  and automatic built-in fallback for missing or invalid active pets.
- Russian/English messages, adversarial storage tests, and `docs/pets.md`.

### Status

- v0.4.x is complete. Live multi-monitor/fullscreen checks,
  and GitHub Release publication remain deferred. Next phase: v0.5 Skills.

## [v0.4.2] - 2026-10-05

### Added

- Projects with optional working folders and instructions, grouped session
  sidebar, pinning, archive, move, rename, and confirmed deletion.
- Independent local-model conversation titles with cleanup, cancellation,
  a 20-second timeout, and a word-boundary fallback.
- Additive SwiftData migration verified on a copy of the previous real store
  and a synthetic v0.4.1 fixture. Audit entries survive conversation deletion.

## [v0.3.3] - 2026-10-05

### Added

- Local SwiftData audit entries for every AgentLoop tool call, including policy
  blocks, user rejections, automatic approvals, failures and cancellation.
- Paged audit viewer with date/tool/risk/decision filters, argument search,
  details, and filtered streaming JSONL export.
- Configurable audit retention (90 days by default) and confirmed journal clearing.
- Bounded argument/result storage; read_file contents excluded from audit results.

## [v0.2.4] - 2026-08-22

### Added

- Full Clipboard Actions editor for creating, editing, deleting, enabling, and
  reordering built-in and custom actions.
- Live validation for action names, prompt templates, and SF Symbols, including
  cursor-aware insertion of `{{input}}`.
- Confirmed reset of all six built-in actions without modifying custom actions.

### Changed

- Clipboard Action persistence is centralized in `ClipboardActionStore`, with
  stable built-in identifiers and migration from v0.2.0–v0.2.3 records.
- Settings now use a master-detail layout sized for the action editor.

## [v0.2.3] - 2026-08-22

### Added

- Global `⌘⇧Space` shortcut for Clipboard Actions, configurable in Settings
  with conflict detection and immediate re-registration.
- Compact floating quick picker with clipboard preview, action search,
  wraparound arrow navigation, `Return`, `Esc`, and `1`–`9` shortcuts.
- Multi-display and full-screen panel placement, focus restoration, and toggle
  behavior without requiring Accessibility access for the hotkey itself.

### Changed

- Carbon hotkey registration now routes multiple independent application
  shortcuts through one event handler.

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
[v0.2.3]: https://github.com/antohal2/maclm_agent/releases/tag/v0.2.3
[v0.2.4]: https://github.com/antohal2/maclm_agent/releases/tag/v0.2.4
