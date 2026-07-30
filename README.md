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
make release
```

You can also open `maclm-agent.xcodeproj` in Xcode, select the `maclm-agent`
scheme, and press Run. App Sandbox is intentionally disabled for this direct
distribution project.

`make release` creates a Release archive without requesting an Apple signing
identity, copies the application from the archive, applies an ad-hoc signature,
verifies it, and builds `dist/maclm-agent-0.1.0.dmg`. The DMG contains the
application and an `/Applications` symlink for drag-to-install.

## Установка

1. Скачайте `maclm-agent-0.1.0.dmg` со страницы
   [GitHub Releases](https://github.com/antohal2/maclm_agent/releases/tag/v0.1.0).
2. Откройте DMG и перетащите `maclm-agent.app` в `/Applications`.
3. Приложение подписано ad-hoc подписью, без Apple Developer ID, поэтому при
   первом запуске macOS Gatekeeper может показать предупреждение «нельзя
   проверить разработчика» или «приложение повреждено и не может быть открыто».
   Это ожидаемо и не означает, что файл действительно повреждён. Разрешить
   первый запуск можно одним из способов:

   - **Finder:** щёлкните правой кнопкой по `maclm-agent.app` → «Открыть» →
     подтвердите «Открыть». Это требуется только один раз.
   - **Terminal:** снимите карантинный атрибут перед первым запуском:
     `xattr -cr /Applications/maclm-agent.app`
   - **System Settings:** после первой попытки запуска откройте
     System Settings → Privacy & Security и нажмите «Открыть в любом случае»
     внизу страницы.

Developer ID signing and Apple notarization will be added after enrollment in
the Apple Developer Program. The release script can then replace
`codesign --sign -` with `codesign --sign "$DEVELOPER_ID_APPLICATION"` and add
`notarytool` plus `stapler`.
