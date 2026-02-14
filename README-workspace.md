# Workspace Helper Script

This template includes `/app/scripts/workspace-files.sh` for safe workspace file operations.

## Root and Limits

- Workspace root: `${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}`
- Max editable file size: `${WORKSPACE_MAX_BYTES:-1048576}` bytes
- All paths are relative to workspace root

## Operations

The script always returns JSON to stdout.

### `tree <path>`

Lists direct children for a directory.

Example response:

```json
{"success":true,"parentPath":"notes","entries":[{"path":"notes/todo.md","name":"todo.md","kind":"file","size":42,"modifiedAt":"2026-02-14T12:00:00Z"}]}
```

### `read <path>`

Reads a UTF-8 text file.

Example response:

```json
{"success":true,"path":"notes/todo.md","content":"hello","encoding":"utf-8","version":"1700000000000:5"}
```

### `write <path> [expectedVersion]`

Writes file content from stdin. If `expectedVersion` is provided and does not match current file version, returns `VERSION_CONFLICT`.

Example response:

```json
{"success":true,"path":"notes/todo.md","version":"1700000001000:6"}
```

### `mkdir <path>`

Creates a directory.

### `delete <path> [recursive]`

Deletes a file or directory. For non-empty directories, pass `recursive=true`.

## Error Shape

All errors use:

```json
{"success":false,"code":"PATH_INVALID","error":"PATH_INVALID","message":"Path traversal is not allowed"}
```

Common codes: `NOT_FOUND`, `PATH_INVALID`, `VERSION_CONFLICT`, `SIZE_EXCEEDED`, `EXECUTION_ERROR`.
