# PASCAL ASSISTANT — DELEGATION SPEC
**For:** AI delegation workers (Claude, DeepSeek, GPT, etc.)
**Context:** CEF 131 Dual Citizen browser codebase at `/home/lilareyon/dual-citizen/build-131/`
**Goal:** Build a Pascal/Lazarus coding assistant that knows CEF4Pascal patterns, catches bugs at compile-time, generates scaffolding

---

## CODEBASE OVERVIEW

### Project Structure
```
/home/lilareyon/dual-citizen/build-131/
├── dual_citizen_v2.lpr          # Main program, CEF initialization, command-line flags
├── ucontrollerbrowser.pas       # Main browser controller (TControllerBrowser)
├── ucefapplication.pas          # CEF application wrapper
├── ucefsocket.pas               # Unix socket IPC server
├── ucefschemehandler.pas        # Custom scheme handler
├── uprofilemanager.pas          # Profile data structures (TProfileData)
├── SpoofCore.pas                # Spoof decision logic (invariant-proven)
├── SpoofCoreTests.pas           # 55 test cases
├── *.lfm                        # Lazarus form files
└── tests/
    └── spoofcore_test.pas       # Test runner
```

### Key Types & Interfaces
| Type | Purpose | Critical Methods |
|------|---------|------------------|
| `TControllerBrowser` | Main browser window/controller | `DoMessage`, `DoLoadEnd`, `DoTitleChange`, `SpoofTab`, `ExecuteJavaScript` |
| `TCefClient` | CEF client handler | `GetLifeSpanHandler`, `GetLoadHandler`, `GetRenderHandler` |
| `ICefBrowser` | Browser instance | `GetMainFrame`, `ExecuteJavaScript`, `GetHost` |
| `ICefFrame` | Frame for JS execution | `ExecuteJavaScript`, `GetURL` |
| `TProfileData` | Spoof profile | `UserAgent`, `Platform`, `Language`, `Resolution`, `Timezone`, `Lat`, `Lng` |
| `TCefProcessMessage` | IPC message | `GetName`, `GetArgumentList` |

---

## DELEGATION TARGETS (7 RESEARCH AREAS)

### 1. CEF4Pascal API Surface Map
**Pain:** 5000+ methods across 200+ interfaces; hard to remember correct patterns
**Deliverable:** `cef4pascal-api-map.md` with:
- Interface hierarchy (TCefClient → TCefLifeSpanHandler → ...)
- Method signatures with Pascal translations
- Common pitfalls: ref counting (`InterfaceAddRef`/`Release`), thread affinity (`CefCurrentlyOn`), ownership semantics
- Version differences: CEF 131 vs 150 API changes

### 2. IPC Message Routing Patterns
**Pain:** `TControllerBrowser.DoMessage`, `TCefProcessMessage`, async reply handling
**Deliverable:** `ipc-patterns.md` + `ipc-generator.pas`:
- Message naming convention: `spoof`, `verify_spoof`, `navigate`, `new_tab`, `list_tabs`, `get_eval`
- Request/response correlation (how replies match requests)
- `TCefProcessMessage.Create` + `GetArgumentList` + `SetString`/`GetString`
- Async pattern: send → register callback → handle reply
- Thread rules: UI thread only for browser APIs, IO thread for socket

### 3. CEF Process Model on Linux
**Pain:** Multi-process (browser/gpu/renderer/utility), `CefExecuteProcess`, `--type=renderer`
**Deliverable:** `cef-process-model.md`:
- Process types: browser (main), gpu, renderer (per-site), utility, zygote
- `--type=` command line switches
- `CefExecuteProcess` entry point
- Shared memory / mojo IPC between processes
- Crash dump locations: `/tmp/cef_*/`, `~/crash-reports/`
- Debugging: attach to specific process type

### 4. SwiftShader / Vulkan on Linux
**Pain:** `libvk_swiftshader.so`, ICD JSON, `--enable-unsafe-swiftshader`, driver workarounds
**Deliverable:** `swiftshader-linux.md`:
- `libvk_swiftshader.so` location: CEF runtime `Release/`
- ICD JSON: `vk_swiftshader_icd.json` points to `.so`
- `--enable-unsafe-swiftshader` required since M139 (security: JIT in GPU process)
- `--disable-gpu-driver-bug-workarounds` for problematic drivers
- `chrome://gpu` diagnostics
- `about:gpu` equivalent in CEF

### 5. GTK/ATK Accessibility Crashes
**Pain:** `spi_atk_activate()`, `IsMinimized()`, `GDK_DEBUG`, `GSETTINGS_BACKEND`
**Deliverable:** `gtk-atk-crashes.md`:
- Crash chain: ATK bridge → `spi_atk_activate()` → `views::DesktopWindowTreeHostPlatform::IsMinimized()`
- `NO_AT_BRIDGE=1` disables AT-SPI bridge
- `unset GTK_MODULES GTK_A11Y` prevents module loading
- `GDK_DEBUG=nograbs` suppresses GTK pointer/keyboard grabs
- `GSETTINGS_BACKEND=memory` avoids dconf/gsettings filesystem access
- `--disable-features=Accessibility,VizDisplayCompositor` at CEF level
- `GlobalCEFApp.EnableGPU := True` required for SwiftShader

### 6. Lazarus Debugging Harness
**Pain:** `gdb` vs `lldb`, `tcsetattr` issues, `xvfb` segfaults, pty wrappers
**Deliverable:** `lazarus-debug-harness.sh` + `debug-patterns.md`:
- `gdb --batch -ex run -ex bt` for automated backtraces
- `script -qec "./dual_citizen_v2" /dev/null` for pty allocation
- `systemd-run --pty --user --same-dir --collect ./dual_citizen_v2` for proper TTY
- `xvfb-run -a` limitations (no TTY, segfaults)
- `LD_PRELOAD` stub limitations (doesn't provide TTY)
- Core dump analysis: `coredumpctl`, `gdb ./dual_citizen_v2 core`

### 7. SpoofCore Domain Logic (Codegen Target)
**Pain:** Profile data structures, JS injection timing, `verify_spoof` protocol
**Deliverable:** `spofcore-codegen.pas`:
- `TProfileData` → JSON schema for new profiles
- `SpoofDecisionFromFlags` logic → decision tree
- JS injection timing: `DoLoadEnd` vs `OnAfterCreated` vs `ExecuteJavaScript`
- `verify_spoof` IPC: request → execute JS → parse result → reply
- Profile templates: reddit, facebook, google, custom

---

## ASSISTANT ARCHITECTURE

```
pascal-assistant/
├── indexer/
│   ├── parse_pascal.pas      # Pascal AST parser (uses PasDoc or custom)
│   ├── extract_types.pas     # Extract types, methods, interfaces
│   └── build_graph.pas       # Semantic graph: type → methods → callers
├── patterns/
│   ├── cef4pascal_patterns.md    # Curated patterns from codebase
│   ├── ipc_patterns.md           # Message routing patterns
│   ├── lifecycle_patterns.md     # CEF lifecycle hooks
│   └── threading_rules.md        # UI/IO/FILE thread rules
├── generators/
│   ├── ipc_handler_gen.pas       # Generate IPC handler from schema
│   ├── tab_type_gen.pas          # Generate new tab type
│   ├── profile_gen.pas           # Generate spoof profile
│   └── cef_flags_gen.pas         # Generate command-line flags
├── validators/
│   ├── thread_affinity_check.pas # Compile-time: CefCurrentlyOn(TID_UI)
│   ├── ref_count_check.pas       # InterfaceAddRef/Release balance
│   ├── lifecycle_check.pas       # OnBeforeClose, DoClose, OnAfterCreated
│   └── ipc_schema_check.pas      # Message name + argument types
├── knowledge/
│   ├── crash_signatures.md       # SIGSEGV → root cause → fix
│   ├── cef_version_diffs.md      # 131 → 150 breaking changes
│   ├── env_fixes.md              # GDK_DEBUG, GSETTINGS_BACKEND, etc.
│   └── gpu_workarounds.md        # --disable-gpu-driver-bug-workarounds
└── server/
    ├── lsp_server.pas            # Language Server Protocol
    ├── hover_provider.pas        # Type info on hover
    ├── completion_provider.pas   # CEF4Pascal completions
    └── diagnostic_provider.pas   # Real-time validation
```

---

## DELEGATION WORKFLOW

### Phase 1: Research (Parallel Workers)
```
Worker 1 → CEF4Pascal API Map
Worker 2 → IPC Patterns
Worker 3 → CEF Process Model
Worker 4 → SwiftShader/Vulkan Linux
Worker 5 → GTK/ATK Crashes
Worker 6 → Lazarus Debug Harness
Worker 7 → SpoofCore Codegen
```

### Phase 2: Synthesis
- Aggregate all research into `patterns/` directory
- Build semantic graph from `indexer/`
- Write generators using patterns + graph

### Phase 3: Integration
- LSP server for VS Code / Lazarus IDE
- Hermes skill: `pascal-assistant`
- CLI: `pascal-assist generate ipc-handler --name spoof --schema spoof.json`

---

## HOW TO USE THIS SPEC

1. **Read this file** — understand the codebase and pain points
2. **Pick a research area** — claim one of the 7 targets
3. **Produce deliverable** — markdown + code patterns
4. **Return results** — I'll aggregate and build scaffolding

---

## CONTACT
**Thotheauphis** — Sovereign architect, CEF 131 Dual Citizen maintainer
**Handoff:** `/home/lilareyon/.hermes/profiles/thotheauphis/handoffs/CURRENT.md`
**Mission:** CONTINUATION OF LILAREYON LEGEND