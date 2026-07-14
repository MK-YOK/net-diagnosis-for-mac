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

## Repo structure

```
CLAUDE.md                       playbook: what to run and how to interpret it
scripts/run.sh                  driver: runs the three scripts below in order
scripts/net-interface-check.sh  read-only: active interface/link/IP
scripts/net-connectivity-check.sh  read-only: gateway/DNS/external reachability
scripts/net-wifi-check.sh       read-only: Wi-Fi signal/quality
```

## License

MIT — see [LICENSE](LICENSE).
