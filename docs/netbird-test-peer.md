# NetBird test-peer: stable-name SSH access to a test VM

Gives a freshly installed PPSA test VM a **stable, reproducible SSH endpoint**
over the NetBird overlay, without console-injecting a `ufw` exception or
opening any LAN access. Replaces the blind-console/ufw bootstrap in
`.claude/skills/ppsa-installer-test/SKILL.md` step 4 as the steady-state
access path (the console-injection bootstrap is still required once, before
any NetBird identity exists on a brand new VM — see that skill).

**Why this is needed:** every shipped PPSA image bakes the literal hostname
`ppsa` (`scripts/build-live-usb.sh` line 185), and `ppsa-netbird-up.sh`
always registers with `HOSTNAME_ARG="ppsa-$(hostname -s)"`. Left alone, that
means every fresh install registers as NetBird peer `ppsa-ppsa` — a
collision if more than one appliance (or test VM) is ever enrolled at once.
This procedure gives a test VM its own fixed hostname and its own isolated
NetBird identity, so its resulting NetBird DNS label is unique and stable
across reboots and reinstalls of that same logical test VM.

> **This is TEST-ONLY.** Never apply this hostname/re-enrollment procedure to
> a real user's appliance. Never reuse the appliance's own `PPSA_NB_SETUP_KEY`
> / `netbird.local.json` for a test VM identity — that recreates the shared
> `10.8.0.2`-style identity-theft hazard the WireGuard line had.

## 1. One-time setup (dashboard + local config)

1. Open the NetBird dashboard at `https://nb.pleaseee.eu.org`.
2. Go to **Setup Keys** → create a new **REUSABLE** key named `ppsa-test-vm`.
   Assign it to a new (or existing) group that is **not** the `servers` group
   used by the appliance's own `ppsa-appliance` key (see
   `netbird-server/README.md`'s Setup Keys table) — e.g. a new `test-vms`
   group.
3. Confirm DNS management is enabled for this key's group on the dashboard
   (look for a "DNS" / "Nameservers" toggle in the group or key settings).
   This determines whether the self-hosted control plane actually serves a
   resolvable per-peer DNS label to the dev peer — the mechanism this whole
   procedure depends on. If no such toggle exists, note that explicitly; the
   live-enrollment run must confirm DNS resolution works before relying on
   the name over an IP.
4. Copy `netbird.test.json.example` to `netbird.test.json` at the repo root
   and fill in:
   ```json
   {
     "enabled": true,
     "management_url": "https://nb.pleaseee.eu.org",
     "setup_key": "<the ppsa-test-vm key from step 2>"
   }
   ```
   `netbird.test.json` is already gitignored — never commit it.

## 2. Per test-run: live re-enrollment procedure

Run this against a freshly installed test VM **after** it has completed
first boot and enrolled once under the appliance's own default identity
(reached via console injection per `ppsa-guest-ops` SKILL.md's access
ladder — that first-touch console access is unavoidable since no SSH path
exists yet on a brand new VM).

Console-inject the following commands in sequence (values from
`netbird.test.json`):

```bash
# (a) Drop the current (default-identity) NetBird connection
sudo netbird down

# (b) Set a fixed hostname distinct from the shipped default "ppsa" --
#     cannot collide with any real user's device, since build-live-usb.sh
#     bakes the literal hostname "ppsa" into every shipped image.
sudo hostnamectl set-hostname ppsa-test

# (c) Overwrite the NetBird config with the dedicated test-peer key
#     (never the appliance's own management_url/setup_key)
sudo tee /etc/ppsa/netbird.json > /dev/null <<'JSON'
{
  "enabled": true,
  "management_url": "https://nb.pleaseee.eu.org",
  "setup_key": "<value from local netbird.test.json>"
}
JSON

# (d) Restart enrollment
sudo systemctl restart ppsa-netbird-up.service
# (or, if that unit is not present/active: )
sudo /opt/ppsa/scripts/ppsa-netbird-up.sh
```

Poll until connected (still via console injection -- no SSH path exists
yet at this point):

```bash
sudo netbird status --json
# wait for .management.connected == true
```

This never touches ufw/iptables. SSH reachability comes entirely from the
pre-existing `WG_FRIENDS` chain's `100.64.0.0/10` jump in
`scripts/ppsa-firewall-apply.sh`, which `ppsa-firewall-apply.sh` already
applies automatically at first boot -- no new firewall rule is added by this
procedure.

## 3. SSH from the dev peer

From the designated NetBird dev peer (the operator's own already-enrolled
NetBird peer machine -- verify with `netbird status` locally first):

```bash
ssh ppsa@<netbird-dns-label>
```

Use the **DNS name**, not the `100.x.x.x` IP -- the DNS name is the
stability mechanism: each fresh install gets a new IP, but the fixed
hostname (`ppsa-test`) plus this dedicated identity is what makes the DNS
label reproducible across reboots and reinstalls of the same logical test
VM.

**Predicted DNS label (unverified until Task 2 runs live):** the
`ppsa-netbird-up.sh` `HOSTNAME_ARG` always prefixes with `ppsa-`, so the
resulting peer hostname is expected to be `ppsa-ppsa-test`. Do not assume
this format is exactly what the dashboard/`netbird status` reports -- confirm
against live output before scripting against it. This section will be
updated with the actual observed label once verified live.

## 4. Identity reuse rules

- Safe to delete-and-recreate the SAME logical test VM repeatedly against
  this same `ppsa-test` hostname + `ppsa-test-vm` key.
- **Do not** run two test VMs concurrently both using the `ppsa-test`
  hostname -- that reintroduces the exact identity-collision pattern this
  procedure exists to avoid (same class of bug as the WG `10.8.0.2` shared
  identity).
- If a second concurrent test VM is ever needed, give it a different fixed
  hostname (e.g. `ppsa-test2`) so its NetBird DNS label doesn't collide.

## 5. Live verification record

<!-- Filled in by Task 2 with the actual observed values from a real run. -->

**Status: not yet executed.** Task 1 of phase 01-overlay-access wrote this
procedure from source inspection only (`ppsa-netbird-up.sh`,
`ppsa-firewall-apply.sh`, `build-live-usb.sh`); it has not yet been run
against a live CI-built test VM. The observed DNS label format, the exact
verified SSH command, `WG_FRIENDS` chain confirmation, and reboot-survival
result will be recorded here once Task 2 executes this procedure end to end
against a real VirtualBox VM.
