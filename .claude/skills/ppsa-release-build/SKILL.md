---
name: ppsa-release-build
description: Trigger, monitor, and download PPSA CI builds (release image + installer ISO) from GitHub Actions. Use when asked to build, tag, release, pre-release, or fetch a PPSA build artifact. Never build locally.
---

# PPSA release / build operations

## Hard rules

- **GitHub Actions ONLY.** Never run `scripts/build-live-usb.sh` locally, never use `Dockerfile.build`/`build-usb.bat`. Local testing happens only on CI-produced artifacts in VirtualBox (see ppsa-installer-test skill).
- Repo: `kaiser62/ppsa` (remote of this working tree).
- Downloads always `aria2c -x16` (never `gh run download` or plain curl), destination `H:\dev\palimage\<ver>\` — D: drive is repo-only.
- **The installer ISO is the final product.** The raw img / VDI are byproducts; test the ISO.

## Trigger builds

```bash
# Release build (usb image + vbox VDI) — publishes a GitHub release ONLY on tag push
git tag vX.Y.Z && git push origin vX.Y.Z          # build-release.yml

# Plain master push = validation build, no release published
# Manual: gh workflow run build-release.yml

# Installer ISO — ALWAYS manual, tagging does NOT build it:
gh workflow run build-installer.yml -f version=vX.Y.Z
```

WG identity/config bake: build reads repo-local `wireguard.local.json` (gitignored) and CI secrets. Policy (user-mandated): **only `public_endpoint` (118.179.74.23:51830) is baked — never a LAN endpoint** (`PPSA_WG_LAN_ENDPOINT` secret was deliberately deleted 2026-07-11; do not re-add). `PPSA_WG_FALLBACK_CONF_B64` bakes the failsafe conf.

## Monitor

```bash
gh run list --workflow=build-installer.yml --limit 3
gh run watch <run-id> --exit-status      # or poll gh run view <run-id>
```
Typical installer build ~30-45 min.

## Download artifacts

Release assets (preferred, after release publishes):
```bash
aria2c -x16 -d "H:/dev/palimage/test<ver>" "https://github.com/kaiser62/ppsa/releases/download/vX.Y.Z/ppsa-installer-vX.Y.Z.iso.zst"
zstd -d -f "H:/dev/palimage/test<ver>/ppsa-installer-vX.Y.Z.iso.zst"
```
For workflow artifacts (unreleased runs): get the artifact zip URL via `gh api repos/kaiser62/ppsa/actions/runs/<id>/artifacts`, then aria2c with an Authorization header (`-H "Authorization: token $(gh auth token)"`).

## After download

Hand off to the ppsa-installer-test skill for VM install + verification.
