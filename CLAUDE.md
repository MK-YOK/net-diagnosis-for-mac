# Mac network diagnosis

Standalone playbook for diagnosing local network connectivity problems on a
Mac. Not a Claude Code skill on purpose — this is a personal single-machine
tool, invoked directly by working in this folder, not something that should
appear in every session's skill catalog.

**Scope: local network path only.** This tool diagnoses the path from this
Mac to its router/gateway and out to the wider internet — interface state,
gateway reachability, DNS resolution, external reachability, Wi-Fi signal.
It does not diagnose or fix ISP/WAN-side outages beyond the gateway handoff,
the same way [disk-maintenance-for-mac](https://github.com/MK-YOK/disk-maintenance-for-mac)
deliberately excludes cloud storage quota from its scope — different problem,
different owner, resolved differently (a router restart won't fix an ISP
outage, just like disk cleanup won't fix a full cloud storage plan).

## Run the diagnostic pass

```bash
./scripts/run.sh
```

This runs three read-only checks, in order:

1. **Interface check** — which network service is active, whether its link
   is up, and whether it has a valid IP.
2. **Connectivity check** — pings the default gateway, checks configured DNS
   resolvers and resolves a couple of known-good hostnames, then pings an
   external IP and hostname. Layered so a failure can be pinned to a specific
   hop (gateway vs. DNS vs. external).
3. **Wi-Fi check** — signal strength, noise, and channel, if the active
   interface is Wi-Fi (harmless no-op on Ethernet).

Nothing here is destructive or even mutating, aside from appending one row
of results to `logs/history.csv` (gitignored, local only) — see below.

## Checking trends over time

Each `run.sh` pass logs a row (timestamp, gateway/external latency and
packet loss, DNS status, Wi-Fi RSSI/noise/channel) to `logs/history.csv`.
History only accumulates from runs the user actually triggers — there's no
background collection, so early on there may be too little data for a
trend.

When the user asks something like "has this gotten slower lately" or "is
this new" rather than just "why is it broken right now", run
`./scripts/net-history-report.sh` and use it alongside the current pass:

- If latency/loss in the report is flagged notably higher than the prior
  average *and* the current pass shows a live problem, treat this as an
  ongoing degradation, not a one-off — worth surfacing in the summary even
  if the current pass alone would look borderline.
- If the report shows no notable change from history, don't manufacture a
  trend narrative — just say current numbers are in line with the recent
  baseline.
- If there's fewer than ~3-5 rows of history, say so rather than drawing a
  conclusion from noise.

## Interpreting the output

**Gateway unreachable, or high packet loss pinging the gateway, while the
interface itself shows a valid IP** — this is a local network path problem
(router or access point), not a DNS or ISP problem. **A router restart is
the first thing to try** — confirmed to resolve exactly this failure mode on
this machine before. Since a restart is a physical action on hardware
outside this Mac, always ask the user before treating it as done — the tool
can only recommend it, not perform it.

**Gateway reachable, but DNS resolution fails (no records returned, or
`scutil --dns` shows no working resolvers)** — DNS-layer issue. Could be the
router's DNS relay, or a misconfigured/unreachable resolver. Distinguish
this from a full outage: the network path to the router is fine, only name
resolution is broken. Try pinging the external IP check (1.1.1.1) — if that
works but the hostname ping doesn't, it confirms DNS as the specific layer
at fault.

**Gateway and DNS both fine, but the external IP/hostname pings fail or show
heavy loss** — likely an ISP/WAN-side issue beyond the router. Out of this
tool's scope to fix (see Scope above) — report it as such rather than
suggesting further local changes.

**Wi-Fi signal is weak (low RSSI, high noise) but gateway/DNS/external all
otherwise pass with high latency or intermittent loss** — a signal-quality
problem distinct from a router/gateway failure. Suggest moving closer to the
access point or checking for interference sources, not a router restart.

## VPN on the default route

`net-vpn-check.sh` reports whether a VPN tunnel owns the default route
(`vpn` / `direct` / `unknown`), and `run.sh` runs it right after the
interface check. A VPN has been the first suspect before and turned out
innocent, so treat it as a **starting point for elimination, not a
culprit**: when things are slow, recommend the user manually disconnect the
VPN and compare before/after. Never disconnect it yourself — that's a user
action, like a router restart.

**Physical gateway.** The GW figure everywhere (snapshot and monitor) is the
**physical LAN router** via `physical_gateway`, not the default-route gateway.
This matters because when a VPN holds the default route, `route -n get
default` has no gateway line at all (previously the GW ping was silently
skipped). So "GW is fine but external is bad" vs "GW itself is bad" stays a
valid router-vs-ISP split regardless of whether a VPN is connected.

## Catching intermittent faults (continuous monitoring)

A single `run.sh` snapshot can't catch a fault that comes and goes. When the
symptom is intermittent — "it was bad, now it's fine, now it's bad again" —
use `./scripts/net-monitor.sh [duration]`. It pings the physical gateway and
an external host every few seconds and prints a timestamped line only when a
threshold is crossed, tagging each with the route class (`vpn`/`direct`/…) so
you can see whether a VPN was in the path when the spike happened. Thresholds
live in `scripts/net-monitor.conf` (override per-run with env vars, e.g.
`GW_SPIKE_MS=30 ./scripts/net-monitor.sh 30m`). Anomalies also append to
`logs/monitor-YYYYMMDD.log`. Keep the non-committal tone: report which layer
(GW / external) degraded and whether it correlates with the VPN — don't
over-conclude from one spike.

## Reporting

Summarize which layer(s) failed (interface / gateway / DNS / external /
Wi-Fi signal) and the recommended next step. If a router restart is
recommended, ask before assuming it's been done — this tool can't perform it
itself.
