# net-diagnosis-for-mac

A small, self-contained playbook for diagnosing local network connectivity
problems on macOS. Combines plain read-only shell scripts with a
[CLAUDE.md](CLAUDE.md) that tells [Claude Code](https://claude.com/claude-code)
how to interpret the output and what to recommend (and what to just ask
about, like a router restart).

**Scope:** the local network path only — this Mac's interface, the gateway
(router), DNS resolution, and reachability out to the wider internet. It
does not diagnose or fix ISP/WAN-side outages beyond the router handoff;
that's a different problem with a different owner, same way
[disk-maintenance-for-mac](https://github.com/MK-YOK/disk-maintenance-for-mac)
excludes cloud storage quota from its scope.

## What it does

- Checks which network service/interface is active and whether it has a
  valid IP and an up link.
- Pings the default gateway, checks configured DNS resolvers, resolves a
  couple of known-good hostnames, then pings an external IP and hostname —
  layered so a failure can be pinned to a specific hop (gateway vs. DNS vs.
  external).
- Reports Wi-Fi signal strength/noise/channel if the active interface is
  Wi-Fi.
- Everything is read-only diagnostics — nothing here changes network
  settings or restarts anything. Physical actions (like restarting a router)
  are left as a recommendation with an explicit confirmation step.
- Logs a row of latency/loss numbers to `logs/history.csv` on every run, so
  repeated runs build up a time series — see
  [Tracking trends over time](#tracking-trends-over-time).

## Requirements

- macOS (uses `ifconfig`, `route`, `scutil`, `dig`, `ping`, `system_profiler`
  or `wdutil`)
- Bash
- Optional: [Claude Code](https://claude.com/claude-code) CLI, to get the
  interpretation/judgment layer on top of the raw diagnostics

## Usage

### With Claude Code (recommended)

```bash
cd net-diagnosis-for-mac
claude "diagnose my network connection per the playbook in this folder's CLAUDE.md"
```

Claude Code reads [CLAUDE.md](CLAUDE.md) automatically, runs
`scripts/run.sh`, and interprets which layer (interface, gateway, DNS,
external, Wi-Fi signal) is at fault.

### Without Claude Code

The scripts are plain bash with no dependency on Claude Code:

```bash
cd net-diagnosis-for-mac
./scripts/run.sh
```

Or run individual checks:

```bash
./scripts/net-interface-check.sh
./scripts/net-connectivity-check.sh
./scripts/net-wifi-check.sh
```

See [CLAUDE.md](CLAUDE.md) for how to read the output (which failure pattern
points to a router problem vs. DNS vs. an ISP-side outage).

## Tracking trends over time

Every `run.sh` pass appends one row (timestamp, gateway/external latency and
packet loss, DNS status, Wi-Fi RSSI/noise/channel if applicable) to
`logs/history.csv`. That file is gitignored — it's local, machine-specific
history, not something to commit. It builds up only from runs you actually
do; there's no background/cron collection.

To see the trend (e.g. "has it actually gotten slower lately, or does it
just feel that way"):

```bash
./scripts/net-history-report.sh        # last 20 runs + latest vs. prior average
./scripts/net-history-report.sh 50     # last 50 runs
```

The report flags the latest run's latency/loss against the average of all
prior runs so a real regression shows up as a number, not a guess.

## Repo structure

```
CLAUDE.md                       playbook: what to run and how to interpret it
scripts/run.sh                  driver: runs the checks below, then logs the result
scripts/net-interface-check.sh  read-only: active interface/link/IP
scripts/net-connectivity-check.sh  read-only: gateway/DNS/external reachability
scripts/net-wifi-check.sh       read-only: Wi-Fi signal/quality
scripts/net-log-run.sh          appends one CSV row per run to logs/history.csv
scripts/net-history-report.sh   summarizes logs/history.csv and flags trends
logs/history.csv                time series of past runs (gitignored)
```

## Disclaimer

This is a personal diagnostic tool, provided as-is with no warranty (see
[LICENSE](LICENSE)). Everything it runs is read-only diagnostics — it never
changes network settings, restarts services, or takes any action on its
own. Any corrective step (like a router restart) is only ever a suggestion
that a human decides on and carries out. Use on a work Mac is subject to
your employer's own IT/security policies; check with them before running
third-party scripts on a managed machine.

## License

MIT — see [LICENSE](LICENSE).
