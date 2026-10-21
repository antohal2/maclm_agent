# v0.5.2 migration fixture

Synthetic SQLite database generated before the step 5.3 model edits on 2026-10-21,
from v0.5.2 (7dcd90b), using all nine original models in the maclm_agent test host.
A temporary XCTest wrote it with the original model declarations; Python sqlite3
backup consolidated the WAL. No user data is included.

One project with instructions, one conversation and user message, one enabled
SkillRecord (hash v052-enabled and lastUsedAt), one linked skill.attached audit,
and persisted attached/declined skill references. It has no pin, manifest,
explicit-detach or stable-catalog fields. Migration tests always open a copy.
