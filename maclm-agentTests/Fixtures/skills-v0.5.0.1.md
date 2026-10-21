# Skills migration fixture

`skills-v0.5.0.1.store` is synthetic SQLite data generated on 2026-10-21 from
tag `v0.5.0.1` (`e8401c9`), with Xcode 27.1 and Swift 6. No user data is included.

The standalone Swift executable used all nine original `@Model` declarations:
Conversation, Project, Message, ToolCall, ClipboardAction, SecurityRule,
AuditEntry, Checkpoint, SkillRecord. The persisted supporting enums and Codable
types were taken from that same tag. Unused non-model helpers were omitted;
ConversationTitle.fallback was stubbed without changing any model declaration.
The executable was compiled with `-module-name maclm_agent -swift-version 6`.
Python sqlite3's backup API consolidated the resulting WAL into this file.

Contents: one project, one conversation with provider context metadata, two
messages, one completed read_file call, one audit entry linked to the conversation,
one checkpoint and one enabled SkillRecord with hash `enabled-before-upgrade`.
It contains neither v0.5.1 session skill fields nor SkillRecord.lastUsedAt.
Migration tests copy the fixture to a temporary directory before opening it.
