# maclm-agent

`maclm-agent` is a native, fully local AI assistant for macOS. The project is
designed to work with locally hosted language models and to control the machine
through an explicit, human-approved tool layer without relying on cloud services.

Version v0.4.10.1 completes the desktop-pet subphase, including validated custom
pet import, selection, replacement, removal, and fallback. See [pet format and
installation](docs/pets.md). The built-in Scout (Скаут) art ships in v0.4.10.1. It is an original character
produced with an AI image generator and assembled into a sprite sheet.
The next phase is v0.5 Skills. Clipboard Actions are part of the
local-first MVP. It supports
native tool calling through LM Studio and Ollama. The app
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

Clipboard Actions apply one of six built-in prompts to copied text through the
selected local provider, replace the clipboard with the result, and optionally
paste it back into the application that had focus. Press `⌘⇧Space` to open the
floating quick picker on the display under the pointer. Search, arrow-key
navigation, `Return`, `Esc`, and number keys `1`–`9` work without a mouse. The
shortcut is configurable in Settings and does not require Accessibility access;
only automatic paste requires that permission.

The Settings editor can create custom actions, edit or delete any action,
enable or disable actions, reorder them with drag-and-drop, validate prompt
templates and SF Symbols, and restore the six built-in actions without changing
custom actions.

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
make release VERSION=0.2.4
```

You can also open `maclm-agent.xcodeproj` in Xcode, select the `maclm-agent`
scheme, and press Run. App Sandbox is intentionally disabled for this direct
distribution project.

`make release VERSION=0.2.4` builds the Release configuration, applies an
ad-hoc signature, verifies it, and creates `dist/maclm-agent-0.2.4.dmg`. The
DMG contains the application and an `/Applications` symlink for
drag-to-install.

## Установка

1. Скачайте `maclm-agent-0.2.4.dmg` со страницы
   [GitHub Releases](https://github.com/antohal2/maclm_agent/releases/tag/v0.2.4).
2. Откройте DMG и перетащите `maclm-agent.app` в `/Applications`.
3. Приложение подписано ad-hoc и не проходит нотаризацию Apple. Поэтому при
   первом запуске macOS покажет предупреждение Gatekeeper и заблокирует обычный
   запуск. Разрешить первый запуск можно одним из двух способов:

   - **Finder:** щёлкните правой кнопкой по `maclm-agent.app`, выберите
     «Открыть», затем ещё раз подтвердите «Открыть» в системном диалоге.
   - **Terminal:** удалите карантинные атрибуты приложения командой:
     `xattr -cr /Applications/maclm-agent.app`

Причина такого способа распространения: у проекта нет платного Apple Developer
ID, поэтому приложение распространяется напрямую без Developer ID-подписи и
нотаризации. Полностью отключать Gatekeeper не требуется.

Для автоматической вставки результата приложению нужен доступ Accessibility.
Выдайте его в System Settings → Privacy & Security → Accessibility, включив
`maclm-agent` в списке приложений.
