---
status: resolved
trigger: "PPSA WebUI dashboard stuck showing 'loading' in various places even though the Palworld game server itself is confirmed up and running"
created: 2026-07-21
updated: 2026-07-21
---

## Resolution

root_cause: |
  Palworld dedicated server's REST API (thijsvanloef/palworld-server-docker image,
  port 8212) binds to 127.0.0.1 ONLY inside its own container network namespace —
  confirmed via byte-level decode of /proc/net/tcp inside ppsa-palworld
  (local_address 0100007F:2014 = 127.0.0.1:8212). This is a hardcoded behavior of
  the underlying Palworld game server binary (no PalWorldSettings.ini key or env
  var controls the bind address; confirmed via web research of the image's
  entrypoint.sh and official Palworld REST API docs). The ppsa-webui container
  (a separate container on the same `compose_default` bridge network) can NEVER
  reach palworld:8212 — confirmed via raw TCP socket.connect() timing out both
  by container name and by raw bridge IP (172.18.0.5), while a curl from INSIDE
  the palworld container to its own localhost:8212 succeeds. webui's
  palworld_get()/dashboard() correctly targets http://palworld:8212 per its own
  config — the connectivity gap is entirely on the upstream image's listener
  scope, not a PPSA app or compose misconfiguration. This has likely been broken
  since the initial commit (git log shows no prior compose networking or
  main.py connectivity-related change ever touched this). main.py's graceful
  degradation (the recent v1.4.0 hardening) is exactly why this manifested as
  an indefinite "Starting up..."/"Waiting for server..." state rather than a
  loud error — masking the connectivity gap instead of surfacing it.
fix: |
  Option B (sidecar relay), chosen by user over network_mode:service:palworld
  on webui (Option A, larger blast radius on webui's ports/firewall model) and
  over changing the dashboard's data-source contract away from REST entirely
  (Option C, would regress the v1.4.0 live player/FPS/uptime metrics feature).

  Added a new `palworld-rest-proxy` service (image alpine/socat:latest,
  container_name ppsa-palworld-rest-proxy) in compose/docker-compose.yml,
  using `network_mode: "service:palworld"` so it shares palworld's network
  namespace and can see its loopback-bound REST listener. It runs
  `socat TCP-LISTEN:18212,fork,reuseaddr TCP:127.0.0.1:8212`, relaying a NEW
  port (18212, chosen to avoid any bind-address ambiguity with palworld's own
  127.0.0.1:8212 listener) out to the bridge network under the same `palworld`
  DNS name/IP (shared netns = shared identity, so no new DNS alias or
  discovery is needed). Added a healthcheck using busybox netstat (the
  alpine/socat image has no ss/curl) verifying the relay port is listening.

  webui's `PALWORLD_API_URL` env var changed from `http://palworld:8212` to
  `http://palworld:18212` — the only change to the webui service. Also added
  `palworld-rest-proxy: condition: service_started` to webui's `depends_on`
  (proxy starts near-instantly, no Steam-download wait like palworld itself,
  so this costs nothing and avoids an unnecessary first-poll connection
  failure). webui's own `ports:`, `cap_add`, volumes, and the host-level UFW /
  DOCKER-USER firewall rules were NOT touched — port 18212 is never published
  to the host (confirmed via `ss -tlnp` before/after showing only 8080), so it
  carries the exact same host-exposure profile that palworld's un-relayed 8212
  always had (never host-published, internal-bridge-only).

  No changes to docker/webui/app/main.py were needed — PALWORLD_API_URL was
  already a plain env var with no hardcoded port assumption.
verification: |
  Deployed to the live E2E VM (ppsa-e2e-test, 192.168.1.156) via the
  ppsa-guest-ops skill's console-injection + LAN-SSH-enable path (host cannot
  reach the VM's bridged IP directly). Backed up the existing compose file,
  deployed the new one, validated with `docker compose config --quiet`
  (passed), then `docker compose up -d`.

  Result: ppsa-palworld was NOT recreated/restarted (stayed at its prior 11h
  uptime, zero player disruption) — only the new palworld-rest-proxy sidecar
  was created and ppsa-webui was recreated to pick up the new env var. Both
  came up and reported `healthy` within ~40s.

  Before fix: GET /api/dashboard -> {"server_state":"starting",
  "players_known":false,"metrics":{},"players":{}}
  After fix:  GET /api/dashboard -> {"server_state":"running",
  "players_known":true,"metrics":{"currentplayernum":0,"serverfps":58,
  "serverfpsaverage":51.05,"serverframetime":17.11,"days":27,
  "maxplayernum":16,"basecampnum":0,"uptime":35135},
  "players":{"players":[]},"server":{"version":"v1.0.1.100619",
  "servername":"PPSA Server","description":"Managed by PPSA",
  "worldguid":"92B0945989D04904AB087C2C93475298"}}

  Also confirmed directly from inside the webui container:
  `curl http://palworld:18212/v1/api/info` -> HTTP 200 in 12ms (was a 5s
  ConnectTimeout against :8212 before the fix).

  Confirmed no change to host-exposed attack surface: `ss -tlnp` on the VM
  host shows only 0.0.0.0:8080/[::]:8080 listening before and after — port
  18212 is bridge-internal only, same exposure profile palworld's REST port
  always had (never host-published).

  webui logs post-fix show continuous "GET /api/dashboard HTTP/1.1" 200 OK
  from the NetBird-overlay client (100.70.51.219) with no new errors.
files_changed:
  - compose/docker-compose.yml (added palworld-rest-proxy service; changed
    webui's PALWORLD_API_URL env var and depends_on)

## Symptoms

- **Expected behavior:** Dashboard tab shows live server status/stats (player count, FPS, uptime, version) once the Palworld container is up.
- **Actual behavior:** Whole dashboard page never resolves — server status/stats cards and the rest of the page stay stuck on "loading". No browser console errors or red error banners reported by the user (not yet confirmed via devtools — needs checking).
- **Error messages:** None reported yet — needs direct check of `/api/dashboard` and `/api/system` responses, container logs (`docker logs ppsa-webui`), and browser console.
- **Timeline:** First observed on this fresh install (VM `ppsa-e2e-test`, v1.5.0 build, just completed first boot). No prior "working" baseline on this exact VM — this is the first time the dashboard was loaded on it.
- **Reproduction:** Load the WebUI dashboard tab at `http://192.168.1.156:8080` (admin/admin) on the freshly-installed VM.

## Environment

- VirtualBox VM `ppsa-e2e-test`, still registered/running from the v1.5.0 installer E2E test.
- Banner: Web UI `http://192.168.1.156:8080` (admin/admin), SSH `ppsa@192.168.1.156` (password `ppsa`), NetBird overlay `100.70.201.76`.
- **Access constraint:** this host cannot reach `192.168.1.156` directly (`curl` times out, exit 28) — likely a bridged-adapter subnet mismatch (same symptom hit an SSH timeout to the same address in the prior e2e report). Investigation will likely need console injection via VirtualBox (VBoxManage screenshotpng + exec_command console injection, `ppsa` auto-logs-in on tty1 with passwordless sudo) or SSH over the NetBird overlay (`100.70.201.76`) if reachable from this host's own NetBird peer.
- Relevant code: `docker/webui/app/main.py` (FastAPI, single file, `/api/*` + static frontend), `docker/webui/app/static/index.html` (plain JS, no framework). `dashboard()`/`palworld_get()` handlers, `palworld_get()` has a `default=` param for graceful degradation, `/api/system` is documented to never bare-500.
- Note: this appliance is fresh off the v1.4.0 WebUI Professional Overhaul milestone which specifically hardened dashboard loading states (durable game-version detection, honest fresh-boot server states, graceful `/api/system` degradation) — a regression here would be notable given how recently that was verified.

## Current Focus

- hypothesis: soft lockups (`watchdog: BUG: soft lockup - CPU#0 stuck for Ns!`) visible on console are causing WebUI/API requests to stall or timeout at the kernel/scheduler level, rather than an application-level bug in dashboard()/palworld_get()
- test: enable LAN SSH via console injection, then curl /api/dashboard and /api/system directly from inside the VM, check docker container status/logs, check dmesg for lockup frequency/duration
- expecting: if lockups are frequent/ongoing, API calls will be slow-but-eventually-succeed or container health checks will be flapping; if API calls return promptly and correctly, the bug is likely frontend JS not application backend
- next_action: RESOLVED. Option B (palworld-rest-proxy sidecar) implemented in compose/docker-compose.yml, deployed to ppsa-e2e-test, and verified live — /api/dashboard now returns server_state:"running", players_known:true, and real metrics. See Resolution section above for full fix/verification detail.

## Evidence

- timestamp: 2026-07-21T00:00:00Z
  checked: VBoxManage screenshotpng of ppsa-e2e-test console (tty1)
  found: Console shows repeated kernel soft lockup warnings — `[ 486.535997] watchdog: BUG: soft lockup - CPU#0 stuck for 25s! [swapper/0:0]` and `[ 889.114178] watchdog: BUG: soft lockup - CPU#0 stuck for 139s! [swapper/0:0]`. Banner with Web UI/SSH credentials is displayed correctly (first-boot completed). `wsl --list --running` on host shows no WSL distros currently running, so this is not live WSL2/Hyper-V contention at time of screenshot (though it may have occurred earlier during first boot).
  implication: The VM itself is host-resource-starved or was starved during boot severely enough to trigger kernel watchdog soft lockups (CPU stuck 139 seconds). This is a strong candidate root cause for "everything looks stuck/loading" — if this affected the palworld container's startup or the webui container's event loop, it would present as generic hangs rather than an app-level bug. Per project knowledge (ppsa-vbox-hyperv-contention memory), this exact signature (soft lockups on VBox) is caused by WSL2/Hyper-V starving the VM, historically resolved by `wsl --shutdown` + VM reset. Need to confirm whether app-level API calls are actually hanging/erroring, or whether this is a red herring and the real bug is elsewhere.

- timestamp: 2026-07-21T00:10:00Z
  checked: SSH'd into VM (LAN SSH enabled via console-injected ufw rule), `docker ps -a`, then curl'd /api/login, /api/dashboard, /api/system directly on localhost:8080 from inside the VM
  found: All 5 containers report `Up ... (healthy)`. `/api/login` returns 200 with valid JWT in 0.4s. `/api/dashboard` returns 200 in ~5s with body `{"server":{"error":""},"metrics":{},"players":{},"player_count":0,"players_known":false,"server_state":"starting","version":"v1.0.1.100619"}`. `/api/system` returns 200 in 0.04s with full CPU/memory/disk/container list, `"degraded":false`.
  implication: Backend APIs are NOT hanging or erroring — they return valid, well-formed JSON promptly (well under any reasonable frontend timeout). `server_state:"starting"` is expected/correct given Palworld is only 25min into first-boot Steam download. This STRONGLY suggests the soft-lockup hypothesis is a red herring (or at least not currently manifesting as an API hang) and the "stuck on loading" symptom is a FRONTEND rendering bug — the frontend JS likely isn't handling the `"starting"` state / empty `metrics`/`players` objects correctly and is stuck showing a loading spinner instead of rendering the "starting" state.

- timestamp: 2026-07-21T00:20:00Z
  checked: Read `docker/webui/app/static/index.html` refreshDashboard() (lines 726-782) — this correctly renders 'Starting...'/'—'/'Waiting for server...' for the "starting"/players_known=false case, not literal stuck-"Loading...". Then curl'd /api/players, /api/logs, /api/backup/status, /api/backup/config, /api/mods, /api/firewall/config, /api/firewall/status directly — all returned fast valid 200 JSON. /api/logs output proved Palworld's REST API has been up and serving `/v1/api/players OK` repeatedly since 22:14:57 (many minutes before this check, uptime 1672s).
  implication: Frontend dashboard-rendering code is correct and not the bug. But there's a contradiction: /api/logs (read via `docker logs`) proves Palworld's REST endpoint IS being hit successfully and returning OK — yet /api/dashboard reported `players_known:false` and `server_state:"starting"`. Something is preventing the WEBUI CONTAINER specifically from reaching that REST endpoint, even though the endpoint itself is clearly alive and answering to someone.

- timestamp: 2026-07-21T00:25:00Z
  checked: `docker exec ppsa-webui env | grep -i palworld` -> PALWORLD_API_URL=http://palworld:8212, PALWORLD_ADMIN_PASSWORD=changeme. Ran a Python httpx GET from inside ppsa-webui container to http://palworld:8212/v1/api/info with correct creds.
  found: `ConnectTimeout('')` — confirmed with the exact URL/credentials the app itself uses.
  implication: This is not a credentials or app-logic bug — the webui container genuinely cannot open a TCP connection to palworld:8212, using the app's own real configured values.

- timestamp: 2026-07-21T00:30:00Z
  checked: `docker inspect` network settings for both containers (both on `compose_default` bridge, palworld IP 172.18.0.5, webui IP 172.18.0.6, DNS aliases correct including 'palworld'). Raw Python socket.connect() from webui container to ("palworld", 8212) and to ("172.18.0.5", 8212) directly (bypassing DNS).
  found: Both raw TCP connects time out — confirms this is not an HTTP/httpx-specific issue or DNS issue, it's TCP-level: the palworld container's port 8212 is unreachable from ANY other container on the same bridge network, by IP or by name.
  implication: Rules out DNS misconfiguration, rules out httpx client bugs, rules out compose network misattachment. The problem is entirely on the palworld container's listening-socket side.

- timestamp: 2026-07-21T00:35:00Z
  checked: `docker exec ppsa-palworld env | grep -iE "REST|API|PORT"` (RESTAPI_ENABLED=true, RESTAPI_PORT=8212 confirmed set correctly). `docker exec ppsa-palworld curl -s -m5 http://localhost:8212/v1/api/info -u admin:changeme` from INSIDE the palworld container itself. `docker exec ppsa-palworld cat /proc/net/tcp` to list actual listening sockets.
  found: curl from inside the palworld container to its own localhost:8212 succeeds (HTTP 200). `/proc/net/tcp` shows a LISTEN entry `local_address 0100007F:2014` — `0100007F` is little-endian hex for `127.0.0.1`, `2014` hex = `8212` decimal. This is the ONLY socket for port 8212, and it is bound to `127.0.0.1`, not `0.0.0.0`.
  implication: The Palworld dedicated server's REST API is bound to loopback (127.0.0.1) ONLY, inside its own container network namespace. It is reachable from a process running inside that same container's netns (which is why the container's periodic self-poll/healthcheck-adjacent activity in the logs — "/v1/api/players OK" — succeeds; that traffic originates from inside the palworld container itself, not from webui). It is NOT reachable via the bridge network by any other container — not by container name, not by container IP. This is the actual root cause: webui's palworld_get() correctly targets http://palworld:8212 per its own config, but that address is architecturally unreachable given how the upstream Palworld server binbinds its REST listener.

- timestamp: 2026-07-21T00:40:00Z
  checked: web research — thijsvanloef/palworld-server-docker README/docs, official Palworld REST API docs, entrypoint.sh behavior (writes RESTAPIPort/RCONPort into PalWorldSettings.ini only, no bind-address override, no socat/proxy rebind step)
  found: Confirmed community/official guidance: Palworld's dedicated-server REST API (and RCON) are designed for local/trusted access and the upstream image's own README advises against forwarding the REST API port externally. No PalWorldSettings.ini key exists to change the bind address — this is a hardcoded loopback bind in the game server binary itself, not a compose/env misconfiguration on PPSA's side.
  implication: This is a genuine, non-configurable upstream limitation of the community Palworld Docker image + game binary: the REST API can only ever be reached from a process sharing the palworld container's network namespace. `compose/docker-compose.yml` has never (since initial commit) configured webui to share that namespace — `git log` confirms neither `docker-compose.yml`'s palworld service networking nor `main.py`'s palworld_get()/dashboard() logic have ever addressed this; the only prior touches to main.py were response-shape/graceful-degradation hardening (04-01, DASH-01..05), which is exactly why the symptom degrades "gracefully" into permanent starting/loading instead of a loud error — masking the real connectivity gap.

## Reasoning Checkpoint

```yaml
reasoning_checkpoint:
  hypothesis: "The webui container can never reach the Palworld REST API at http://palworld:8212 because Palworld's dedicated-server binary hardcodes its REST API listener to bind 127.0.0.1 (loopback) inside its own container network namespace — this is a fixed upstream behavior of thijsvanloef/palworld-server-docker's underlying game binary, not a PPSA compose/app misconfiguration. As a result /api/dashboard's rest_ok is permanently False, server_state is stuck at 'starting' and players_known stuck at false forever, which the frontend correctly renders as an indefinite 'Starting up...'/'Waiting for server...' state that the user perceives as 'stuck loading'."
  confirming_evidence:
    - "Direct httpx GET AND raw socket.connect() from inside ppsa-webui to palworld:8212 (both by DNS name and by raw IP 172.18.0.5) time out at the TCP layer -- ruling out DNS, app credentials, and httpx-specific bugs."
    - "curl from INSIDE ppsa-palworld to its own localhost:8212 succeeds (HTTP 200), and /proc/net/tcp inside that container shows the ONLY socket for port 8212 bound to local_address 0100007F:2014 (127.0.0.1:8212), not 0.0.0.0:8212 -- proving the listener itself is loopback-scoped."
    - "docker logs ppsa-palworld shows '/v1/api/players OK' being served repeatedly -- proving the REST endpoint is genuinely alive and functioning, which is what makes this a connectivity/binding gap rather than a crashed or misconfigured REST API."
  falsification_test: "If the REST API were actually bound to 0.0.0.0, a raw socket.connect() from ppsa-webui to the palworld container's actual bridge IP (172.18.0.5:8212) would succeed. It did not -- it timed out identically to the by-name attempt. This directly falsifies any DNS-only or docker-compose-network-misconfiguration hypothesis, and directly confirms the loopback-bind hypothesis (a non-loopback-bound service reachable-by-IP-but-not-by-name would point to DNS; unreachable by both name AND raw IP, while working over its own loopback, points specifically to bind-address scope)."
  fix_rationale: "The fix must let the webui process reach 127.0.0.1:8212 as seen from the SAME network namespace as the palworld container, since the game binary's listener cannot be reconfigured to bind 0.0.0.0. The standard Docker Compose mechanism for this is `network_mode: \"service:palworld\"` (or `container:ppsa-palworld`) on the webui service, so webui's own 'localhost'/127.0.0.1 IS the palworld container's loopback, making palworld:8212 resolve as intended. This addresses the root cause (namespace isolation preventing loopback-bound service access) rather than papering over the symptom (e.g. suppressing the 'starting' banner or fudging players_known to true)."
  blind_spots: "(1) Sharing network namespace with palworld means webui's OWN port 8080 would then be published via the palworld container's network config instead of its own -- compose port mappings on a service using network_mode: service:X are ignored/must be moved to the target service, so compose/docker-compose.yml's `ports: - 8080:8080` under webui needs to move under palworld's service block (or an explicit palworld ports entry added) -- MUST verify this in compose file before/while applying the fix, and re-verify the WG_FRIENDS iptables assumptions on port 8080 (docs/CLAUDE.md notes 8080/tcp is WG_FRIENDS-gated) still hold under the new network topology. (2) Not yet verified whether wgdashboard health checks or watchtower depend on webui's current separate IP/hostname in a way that would break under shared-namespace. (3) Have not yet tested the fix live -- only formed the hypothesis and traced the mechanism; verification against original symptom (dashboard eventually shows real player count / FPS / uptime once applied) is still pending."
```

## Eliminated

- hypothesis: soft lockups causing WebUI/API requests to stall or timeout at the kernel/scheduler level
  evidence: Direct curl of /api/login (0.4s), /api/dashboard (5s), /api/system (0.04s) from inside the VM all returned fast, valid 200 responses with correct JSON. No hangs, no errors, no timeouts. Backend is fully responsive despite the earlier soft-lockup console messages (which may have been transient during boot / host WSL contention that has since cleared).
  timestamp: 2026-07-21T00:10:00Z

- hypothesis: frontend JS (refreshDashboard) fails to handle the 'starting'/players_known=false state correctly and gets stuck on a literal 'Loading...' placeholder
  evidence: Read index.html lines 726-782 in full — the code explicitly handles state==='starting' (renders 'Starting...'/'—') and !players_known (renders 'Waiting for server...') as intentional, correctly-implemented UI states, not bugs. The user-visible "stuck on loading" is these honest waiting-states persisting FOREVER because the underlying condition (palworld REST unreachable) never resolves — not a frontend rendering defect.
  timestamp: 2026-07-21T00:20:00Z
