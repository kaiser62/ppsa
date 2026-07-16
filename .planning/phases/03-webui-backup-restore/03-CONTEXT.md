# Phase 3: WebUI Save-File Backup & Restore — Context

**Phase:** 3 — WebUI Save-File Backup & Restore
**Requirements:** BKP-01, BKP-02, BKP-03, BKP-04, BKP-05
**Source:** Inline decision capture with the user (feature request: "only save file backup in the webui, also restore from webui correctly")

## Domain

Add two capabilities to the PPSA WebUI (FastAPI app, `docker/webui/app/main.py`):
1. A **lightweight save-file backup** — archive ONLY the Palworld SaveGames data, fast,
   without stopping the palworld container or invoking the heavy offen full-volume backup.
2. A **safe restore** — from an on-box archive OR a user-uploaded file — that correctly
   replaces the live save without risking data loss if it goes wrong.

This is distinct from the existing backup surface:
- `/api/backup/trigger` runs the offen container's full-volume backup (stops palworld,
  tars the whole `palworld_data` volume → `/backups`). That STAYS as-is.
- `/api/backup/status` lists archives in `BACKUP_DIR = /backups`. Reuse/extend.
- `/api/server/save` calls Palworld REST `/save` (in-game save). Unrelated; leave alone.
- There is currently **NO restore endpoint and no save-file-only backup** — this phase adds both.

## Locked Decisions

| ID | Decision | Choice | Rationale |
|----|----------|--------|-----------|
| D-01 | Backup scope | **Save-file-only** — archive just the Palworld SaveGames dir, NO palworld stop, NO full offen/volume backup | User wants a fast, small world-save snapshot separate from the heavy nightly backup |
| D-02 | Restore source | **Both** — restore from an on-box archive (chosen from the backup list) OR from a `.tar.gz` uploaded by the user | User picked both |
| D-03 | Restore safety | **Stop → pre-backup → replace → restart, with explicit confirm** — require confirmation; stop palworld; snapshot current SaveGames to a safety archive FIRST; extract chosen archive over SaveGames; restart palworld | Restore is destructive; never lose the current save on a bad restore |
| D-04 | Validation | Restore **validates the archive is a well-formed Palworld save** BEFORE touching the live save; clear success/failure reported | "restore from webui correctly" — no silent partial restore |

## Canonical References

- `docker/webui/app/main.py` — FastAPI app; existing `/api/backup/*`, `/api/server/save`, `_run_docker`, `_host_exec`, `BACKUP_DIR = /backups`, `UploadFile` usage (`install_mod`, `wireguard_upload`) as the file-upload pattern to mirror
- `docker/webui/app/static/index.html` — single-page frontend (plain JS, no framework); Backup tab lives here
- `compose/docker-compose.yml` — palworld + webui + backup services, volumes (`palworld_data`), the `/backups` mount, and how webui reaches host/other containers
- Palworld SaveGames path inside the palworld container: `Pal/Saved/SaveGames/0/<id>/` (the dir the offen hot-tar race hit in the nb.12 bug — see [[ppsa-webui-backup-save-bugs]])
- `.planning/codebase/ARCHITECTURE.md`, `STRUCTURE.md` — WebUI + stack layout
- CLAUDE.md — "only `docker/webui/app/` is live WebUI code"; auth is HTTP Basic → JWT Bearer

## Claude's Discretion (planner to resolve from source)

- **Exact mechanism for the webui container to read/write the palworld SaveGames.** Determine
  from compose whether webui shares the `palworld_data` volume, must `docker exec`/`docker cp`
  into the palworld container, or goes through `_host_exec`. Pick the one that already has a
  precedent in the codebase; do not invent a new privileged mount if an existing path works.
- Archive format + naming for save-file backups (align with the existing `/backups` archive
  naming so `/api/backup/status` lists them; distinguish save-file archives from offen's if needed).
- How "stop/restart palworld" is done from webui (reuse the existing `_run_docker` exec/stop path
  used elsewhere — do NOT add new host privileges).
- Validation depth for "well-formed Palworld save" (e.g. archive opens + contains the expected
  `Pal/Saved/SaveGames/...` structure and a `Level.sav`/GameUserSettings) — pragmatic, not exhaustive.
- Frontend: extend the existing Backup tab in `static/index.html` (plain JS) — new backup button,
  archive list actions (restore), upload control, and a confirm gate for restore.

## Scope Fence

**In scope:** save-file-only backup endpoint + button; restore endpoints (from on-box archive and
from upload); safe-restore sequence (confirm, stop, pre-backup, extract, restart, report);
archive validation; the Backup-tab frontend for all of the above.

**Out of scope:** changing/removing the existing offen full-volume backup (`/api/backup/trigger`)
or its schedule; the in-game `/api/server/save`; a Download-archive button (user chose save-file-only,
not archive+download — do not add download); any change to appliance networking/firewall; cloud/offsite
backup. Restore auth uses the existing WebUI auth — no new auth model.

## Success Criteria (from ROADMAP)

1. A WebUI "save-file backup" action produces a timestamped archive of ONLY the SaveGames data,
   without stopping palworld, and it appears in the WebUI backup list.
2. The user can restore from an on-box archive (from the list) OR a `.tar.gz` they upload.
3. Restore requires explicit confirmation, and before overwriting: stops palworld → snapshots
   current SaveGames to a safety archive → extracts the chosen archive over SaveGames → restarts palworld.
4. Restore validates the archive before touching the live save and reports clear success/failure
   (no silent partial restore).

## Risk Summary

- **Data loss on restore** — the whole point of D-03's pre-backup + validation. A restore that
  wipes SaveGames then fails to extract must be recoverable from the safety snapshot. Mitigation:
  validate first, snapshot second, extract third, and never delete the safety snapshot on failure.
- **Path/permission mismatch** — writing into the palworld save dir from the webui container can
  hit UID/permission issues; the planner must confirm the working access path from compose, not assume.
- **Palworld running during restore** — extracting over a live save corrupts state; restore MUST
  stop palworld first (mirror the nb.12 lesson that hot operations on the live save race and fail —
  see [[ppsa-webui-backup-save-bugs]]).
- **Upload safety** — uploaded archive is untrusted: validate type/structure and guard against path
  traversal (tar entries escaping the target dir) before extracting.
