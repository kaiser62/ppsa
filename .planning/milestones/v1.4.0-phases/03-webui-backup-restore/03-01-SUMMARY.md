# Phase 03: WebUI Save-File Backup & Restore — Implementation Summary

## Plan 01: Backend (main.py + compose)

### Tasks Completed

1. **compose/docker-compose.yml** — Changed `../backups:/backups:ro` → `../backups:/backups:rw` so the webui container can write save-file archives and read uploaded files.

2. **main.py `_run_docker`** — Added `stop` (`.stop(timeout=30)`) and `start` (`.start()`) subcommands alongside existing restart branch, enabling the backup endpoints to safely pause/restart the palworld container during restore.

3. **Constants & helpers** — Added `SAVEGAMES_DIR = PALWORLD_DATA / "Pal/Saved/SaveGames"`, `SAVE_RESTORE_PARENT = SAVEGAMES_DIR.parent`, and `_validate_save_archive(path)` using stdlib tarfile. The validator checks for a `SaveGames/` directory, `.sav` files, and rejects path traversal (T-03-01, T-03-02).

4. **POST /api/backup/save-file** — Creates a timestamped `.tar.gz` archive of the live SaveGames directory without stopping palworld (D-01). Saves to `/backups/`.

5. **`_do_restore` helper** — Validates archive → stops palworld → extracts tar.gz to `SaveGames` parent → restarts palworld. Defense-in-depth traversal check on extract (T-03-01 recheck).

6. **POST /api/backup/restore** — Restores by filename from `/backups/`. Filename sanitized via `Path(name).name` (T-03-02).

7. **POST /api/backup/restore-upload** — Accepts `UploadFile` (.tar.gz only), writes to temp, delegates to `_do_restore`, cleans up temp in `finally` (T-03-05). Validates extension server-side (T-03-FE-03 defense).

### Threat Model Status

| ID | Threat | Severity | Mitigation | Status |
|----|--------|----------|------------|--------|
| T-03-01 | Tar path traversal | Critical | `_validate_save_archive` + extract-time recheck | SECURED |
| T-03-02 | Filename traversal | High | `Path(filename).name` strip | SECURED |
| T-03-03 | Destructive replace without validation | Critical | Validate before stop | SECURED |
| T-03-05 | Temp file leak | Low | `finally: unlink` | SECURED |

## Plan 02: Frontend (index.html)

### Tasks Completed

1. **Save-File Backup button** — Added to backup tab button group alongside existing "Backup Now".
2. **Actions column** — Added `<th>Actions</th>` to archives table header.
3. **Restore buttons** — Each archive row now has a "Restore" button (danger style).
4. **Upload card** — Card below archives table with `<input type="file" accept=".tar.gz">` and "Restore from Upload" button.
5. **`saveFileBackup()`** — POSTs to `/api/backup/save-file`, shows result alert, refreshes table.
6. **`restoreBackup(filename)`** — confirmAction modal → POST to `/api/backup/restore` → result alert.
7. **`restoreUploadBackup()`** — FormData POST to `/api/backup/restore-upload` with Bearer token from localStorage. Validates file selected and `.tar.gz` extension client-side before upload.

### Security

- Restore always requires confirmAction modal (T-03-FE-01).
- `accept=".tar.gz"` is client-side hint only; server re-validates (T-03-FE-03).
