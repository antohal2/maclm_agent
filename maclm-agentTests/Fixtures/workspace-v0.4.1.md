# Workspace migration fixture

`workspace-v0.4.1.store` is a synthetic SQLite store generated on 2026-10-05
with the unmodified SwiftData model declarations from git tag `v0.4.1`.
It contains one conversation titled `Legacy fixture`, two synthetic messages,
one completed `read_file` ToolCall attached to the assistant message, and one
AuditEntry referencing the conversation ID. No user data is included.

The generator was a standalone Swift executable with those six persistence
models, the original RiskLevel enum, and a minimal ToolExecutionResult type for
compiling the audit helper. SQLite's backup API consolidated the generated WAL
into this single file. No migration schema or new Project declaration was used
to generate it. WorkspaceTests copies this file before opening it with the new
schema; the checked-in fixture is never modified during tests.
