# 2026-09-26 — Local `gbu` EXTRA source for Grok Bot weekly

**Why:** Owner wants Glance to rank `gbu --json` beside the existing Cursor
DashboardService `GrokBotQuotaReader`, without replacing it.

**What landed**

- `Sources/QuotaCore/GbuQuotaReader.swift` — shells `gbu --json`, emits windows
  with `source: "gbu"`, `via: "gbu"`, id `local-mac:grok-bot:gbu-weekly`.
- `Sources/CodeCaps/MonitorModel.swift` — `readLocalSources()` also awaits
  `GbuQuotaReader().read()`.
- `Sources/QuotaCore/BoundedQuotaProcess.swift` — PATH includes `~/.gbu/bin`.
- Issues use key `gbu` (not `grok-bot`) so a failed EXTRA cannot blank the
  Cursor reader.  Missing `gbu` binary is silent (optional EXTRA).

**Verify**

```bash
swift test --filter GbuQuotaReaderTests
swift test --filter GrokBotQuotaReaderTests
```
