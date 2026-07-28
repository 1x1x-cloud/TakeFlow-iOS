# Script persistence

Module 1 introduces the first versioned SwiftData schema.

- `ScriptSchemaV1` is immutable once released. New fields, constraints, or relationships require a new `VersionedSchema` and an explicit `MigrationStage`.
- SwiftData records stay inside the persistence layer. Other modules exchange `Script` values through `ScriptRepository`.
- The production configuration is local-only and explicitly disables CloudKit.
- Deletion first records `deletedAt`. The library hides tombstones immediately, permits restoration during the undo window, and purges expired tombstones later.
- Unsaved editor snapshots are stored separately under Application Support in `TakeFlow/RecoveryDrafts`. They are JSON files named only by stable Script UUID, use atomic replacement and file protection, and are never stored in UserDefaults or Caches.
- Recovery snapshots contain the formal record version, editor session UUID and monotonic revision. The actor rejects late older writes. A successful SwiftData save removes the matching recovery file and installs an in-process revision barrier so delayed tasks cannot recreate it.
- A recovery snapshot is offered only when its exact formal-record version matches and its draft timestamp is newer. The saved Script remains visible until the user explicitly chooses recovery; stale, corrupt or mismatched snapshots never overwrite it.
- Stable UUIDs are never derived from titles. Content and full local paths must never be written to logs.
- Tests use isolated in-memory or temporary on-disk containers. Production storage is never opened by tests.
