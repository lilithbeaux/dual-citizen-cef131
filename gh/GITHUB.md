# Dual Citizen — GitHub preparation

Prepared 2026-10-28. This is the clean, portable copy of the project for GitHub.

## What is in this tree

| Path | Purpose |
|------|---------|
| `README.md` | Project overview, architecture, launch, build |
| `docs/ARCHITECTURE.md` | Process model, V8 plugin, IPC, extensions, CDP |
| `docs/DUAL-CITIZEN-TECH-SPEC.md` | Full technical specification |
| `docs/reddit-facebook-README.md` | Reddit/Facebook automation docs |
| `docs/ASSET-SYSTEM-DOCS.md` | Asset embedding system |
| `src/` | Portable Pascal sources (env-var paths, no `/home/lilareyon` hardcoding) |
| `scripts/` | `build.sh`, `run.sh`, asset embed/verify |
| `extensions/` | 13 Chrome extensions (12 auto-loaded + `lilith-mcp-listener`) |

## Build

```bash
./scripts/build.sh
```

Requires `lazbuild` (Lazarus 4.4 / FPC 3.2.2), CEF 131 runtime at `$CEFRUNTIME`,
CEF4Delphi source at `$CEF4DELPHI` — all external, not in this repo.

## Run

```bash
./scripts/run.sh dual_citizen_v2 about:blank
```

## Known issue

`src/umessagebridge.pas` is **dead code**: `ucontrollerbrowser.pas` never references
it, and it implements the deprecated `ICefMessageRouterBrowserSide*` interfaces.
It compiles cleanly, so it does not break the build — but it is unused and should
be removed or wired in. See `docs/ARCHITECTURE.md` §Extensions.

## Verification

`dual_citizen_v2` built from this tree: 38,135,032 bytes, zero compile errors,
byte-identical to the prior build. Live test under Xvfb `:99`:

```
list_tabs   -> ok, tab_id 1, profile_1
version     -> ok (window.__dc_plugin v1.0.0)
sendToPascal -> ok (IPC delivered)
get_eval    -> ok (poll 2)
```