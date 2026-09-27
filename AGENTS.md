# Claudex agent guide

`AGENTS.md` is the sole project instruction file for every coding agent.
Read `.ai/memory/MEMORY.md` only when prior context is relevant.
`scripts/check-docs.mjs` checks all Markdown for long dashes and hyphenated prose.

## CI, cost and documentation

- Use **Blacksmith** runners for supported GitHub Actions CI. Check the current
  [runner documentation](https://docs.blacksmith.sh/blacksmith-runners/overview)
  and repository access before selecting labels. Preserve required checks and
  native platform coverage; retain an existing gate until its replacement proves
  equivalent coverage for the same source. Record any provider exception.
- Minimize total cost across CI, hosting, storage, network, APIs, AI and tooling.
  Choose the least costly option that meets the task's quality, security,
  reliability and performance requirements. Preserve mandated models and gates;
  never trade away correctness, coverage, accessibility or data safety for price.
- Use the fewest hosted CI runs that still cover changed paths, scheduled
  checks and required gates. Iterate locally, route jobs by scope, reuse valid
  caches, avoid duplicate runs and bound retries/concurrency. Cancel superseded
  verification when safe; review releases and migrations before cancellation.
  Preserve checks for the exact commit and native platforms. Measure usage, expire disposable
  artifacts and retire only verified idle resources within task authority.
- Keep Markdown focused: one canonical home per topic, short sections and useful
  links. Keep commands and safeguards near their use; move detailed history to
  dated evidence. Update stale guidance against code, preserve release records,
  and avoid duplicating this policy in every document.

## What this is

Claudex is an open source compatibility layer that lets Codex GPT models and
native Claude models run through the Claude Code terminal interface. Managed
GPT sessions reuse an existing local Codex login, run a pinned, verified
CLIProxyAPI binary bound to `127.0.0.1`, and launch an isolated Claude Code
profile pointed at that proxy. Native Claude model routes use the caller owned
Claude profile in a separate process after managed routing is removed.
Fableplan uses a native read only Fable planner and an isolated managed Terra
implementer, transferring only bounded plan text through a private temporary
file. Claudex does not fork or patch the signed Claude Code executable: it is a
launcher/wrapper, distributed as Bash + PowerShell scripts.

Production code is intentionally dependency light: Bash, PowerShell, a small Node preload module, and JSON. There is no application build step or bundler.

## Commands

```bash
./test.sh                    # full Unix suite (targeted regressions, then test.zsh in an isolated fake home)
./test.ps1                   # full Windows suite (run from PowerShell)
npm test                     # docs, preload, skill bridge/contract/security, package bootstrap and setup lock checks
npm run test:all             # same as ./test.sh
./scripts/build-release.sh   # build release archives (tarball + Windows zip) into dist/
```

Focused checks (fast, no fake home setup) before opening a PR:

```bash
node scripts/check-docs.mjs        # community files, Markdown prose lint (dashes/hyphens), links, CHANGELOG, workflow pinning
node scripts/check-preload.mjs     # preload.cjs integrity
node --check preload.cjs           # Node syntax check
node --check skill-bridge.cjs      # shared skill bridge syntax check
node tests/skill-bridge.test.cjs   # discovery/materialization behavior
node tests/skill-contract.test.cjs # Claude/Codex compatibility contract
node tests/skill-security.test.cjs # hostile filesystem/plugin inputs
bash -n claudex codex-session install.sh statusline usage-limit
zsh -n test.zsh
git diff --check
```

There is no single test runner: `test.zsh`/`test.ps1` are one large suite of isolated regressions using fake homes and fake provider commands (Codex, Claude Code, curl, CLIProxyAPI) so tests never touch a real session. To narrow scope while iterating, grep the suite file for the relevant test function name and read it directly; there's no `--filter` flag.

CI (`.github/workflows/test.yml`) runs on every push to `main` and every PR: the Unix suite on macOS + Ubuntu, the PowerShell suite on Windows, plus three Ubuntu jobs: `package-artifacts` (`npm test` + `scripts/check-release-artifacts.sh`), `node-18-shared-runtime` (`npm test` on the minimum supported Node), and `legacy-linux-node` (managed Node fallback in an Ubuntu 20.04 container).

## Architecture

### Request flow

```
user -> claudex launcher (Bash or PowerShell)
           |-- managed GPT -> isolated Claude profile -> loopback proxy -> Codex
           |-- native Claude -> scrub managed state -> caller owned Claude profile
           `-- Fableplan -> native Fable plan file -> managed Terra
```

Native Claude and managed GPT processes may run concurrently, but each process
receives one provider environment only. Provider credentials, profiles,
sessions, and billing contexts never cross that boundary.

### Components (Unix / Windows implementations kept behaviorally in sync)

| Component | Unix | Windows | Responsibility |
| --- | --- | --- | --- |
| Launcher | `claudex` | `claudex.ps1`, `claudex.cmd` | Parse Claudex flags, negotiate Claude Code capabilities, configure the session, launch Claude Code |
| Installer | `install.sh` | `install.ps1` | Install dependencies, private config, launchers, verified compatibility binary |
| Auth bridge | `codex-session` | `codex-session.ps1` | Validate Codex login, atomically sync the minimum credential fields |
| Usage helper | `usage-limit` | `usage-limit.ps1` | Fetch, sanitize, cache, and display Codex usage limits |
| Status line | `statusline` | `statusline.ps1` | Render model, effort, stable context %, cached usage status |
| Self update | `self-update` | `self-update.ps1` | Check GitHub releases and refresh the installed Claudex, lock guarded |
| Terminal preload | `preload.cjs` | shared | Translate Solplan input and replace only the positioned interactive welcome billing field before restoring native stdout |
| Skill bridge | `skill-bridge.cjs` | shared | Snapshot and adapt existing Claude/Codex skills and plugin skills without activating source plugin code |
| Settings template | `settings.json` | shared | Isolated default Claude Code settings written into the managed config |

Every shared behavior change must touch both the Bash and PowerShell implementation (`claudex`/`claudex.ps1`, `codex-session`/`codex-session.ps1`, etc.): platform drift is treated as a bug unless the underlying OS genuinely lacks the feature, in which case the boundary must be documented, not silently emulated.

### Authentication lifecycle

Codex owns the actual login/logout UX. Claudex only verifies `codex login status`, reads the file backed ChatGPT session from the standard Codex location, and atomically writes the minimum fields CLIProxyAPI needs into Claudex's private credential directory (restrictive permissions). A background watcher fingerprints the standard Codex credential file for the life of a proxied session and re syncs on account changes, clearing any cached usage snapshot/account selection so stale account data can't leak into the footer. Logout always tears down the bridge even if the upstream logout call fails.

### Usage limit flow

The status line never blocks on network I/O: it reads a sanitized cached summary and triggers a bounded background refresh when stale. Detailed usage comes from the authenticated web endpoint, falling back to the Codex app server `account/rateLimits/read` interface (fallback disabled while a specific bridge account is explicitly selected, since app server may represent a different account). Identity/credential fields are stripped before any snapshot is written to disk.

### Context stabilization

Claude Code can emit zero/missing context data transiently during startup and compaction. The status line stores the last trustworthy context percentage per session and reuses only that session's own last known value: never a false zero, and sub-1% usage renders as `<1%`.

### Update and compatibility strategy

At every launch, `claudex` reads `claude --help` and only injects flags Claude Code actually supports; unrecognized arguments are passed through unchanged. The installer does a best effort Claude Code update; the launcher re checks on a configurable interval without blocking startup, recovers stale lock directories, and avoids racing an explicit update command. Claudex also updates itself: `claudex self-update` runs the installed helper directly, and unless `CLAUDEX_AUTO_UPDATE` is off the launcher spawns that helper as a background check. The CLIProxyAPI dependency is pinned by version and SHA-256 per OS/arch pair and verified at install time: never vendored into the repo.

### Trust boundaries

- Trusted: repo managed scripts, installed private config, standard Codex credentials, supported CLI flags.
- Loopback boundary: CLIProxyAPI binds `127.0.0.1` only, guarded by a generated local key.
- Provider process boundary: native Claude and managed GPT routing and
  credentials remain in separate processes.
- Fableplan boundary: only bounded validated plan text crosses from the native
  planner to the managed implementer through a private temporary file.
- Third party boundary: Codex, Claude Code, provider APIs, browser extensions, and CLIProxyAPI are separately maintained.
- Public repo boundary: no generated config, auth, prompts, history, sessions, or usage caches are ever committed. `~/.config/claudex` is fully separate from normal Claude Code state.

## Design rules (from docs/development.md: treat as binding)

1. Never modify the signed Claude Code binary.
2. Keep normal Claude Code state separate from `~/.config/claudex`.
3. Let Codex own login and logout.
4. Keep secrets out of arguments, logs, caches, tests, and Git.
5. Bind the compatibility service to loopback only; verify every downloaded asset's SHA-256.
6. Preserve unknown Claude Code arguments exactly (pass through, don't drop or reinterpret).
7. Keep Bash and PowerShell behavior aligned.
8. Fail clearly when an essential upstream interface is unavailable: no silent degradation.
9. Add a regression test before considering a bug fixed.

Updating the CLIProxyAPI pin is security sensitive: collect every macOS/Linux/Windows x64/ARM64 asset from the official upstream release, compute each digest independently, update both installers together, and run the full platform test matrix. Never replace a digest just to make a failed download pass.

## Repository layout

| Path | Purpose |
| --- | --- |
| `claudex`, `claudex.ps1`, `claudex.cmd` | Cross platform launchers |
| `install.sh`, `install.ps1`, `install.zsh` | Install and compatibility entry points |
| `bootstrap.sh`, `bootstrap.ps1` | One command installers: fetch and verify the latest release, then run the platform installer |
| `codex-session*` | Authentication bridge |
| `usage-limit*` | Detailed and cached quota reporting |
| `statusline*` | Stable compact footer |
| `self-update`, `self-update.ps1` | Claudex self update helpers (GitHub release check, lock guarded refresh) |
| `preload.cjs` | Byte preserving Solplan input alias and one shot interactive ChatGPT plan label |
| `skill-bridge.cjs`, `skills/` | Existing skill compatibility, isolated plugin adapters, and platform specific bundled skills |
| `settings.json`, `env.example` | Reproducible configuration templates |
| `test.zsh`, `test.ps1`, `test.sh`, `tests/` | Isolated cross platform regression suites plus targeted helper suites and Node tests |
| `scripts/` | `build-release.sh`, `check-docs.mjs`, `check-preload.mjs`, `check-release-artifacts.sh`, `create-release-archives.mjs` |
| `bin/`, `claudex-package.cmd` | Package manager bootstrap entrypoint (Homebrew / Scoop / WinGet) plus the package setup lock helper |
| `docs/` | User/maintainer docs: architecture, Claude Code compatibility, configuration, development, installation, package managers, skills, troubleshooting, usage |

## Configuration model

The installer writes private runtime config to `~/.config/claudex/env`; `env.example` documents supported overrides (model aliases, permission mode, concurrency/retry limits, context window/compaction thresholds, usage display cadence, proxy URL/token/binary path, auto update behavior). See `docs/configuration.md` for the full variable table: don't hardcode defaults elsewhere without checking there first, since values like the default model ID or context window change between releases.

## Releasing

Maintainers release from a clean `main` after CI passes: bump `CHANGELOG.md` (Unreleased -> SemVer version, kept in sync with `package.json`), tag `vMAJOR.MINOR.PATCH`, push the tag, publish a GitHub Release, then update the Homebrew tap / Scoop bucket / WinGet manifest with the exact release asset hashes.

<!-- BEGIN BEAMO STORAGE HYGIENE -->
## Local storage hygiene

- Run `/Users/HP/dev/storage-maintenance --report` before and after work likely
  to generate more than 1 GiB. Follow `/Users/HP/dev/STORAGE_HYGIENE.md`.
- Keep disposable staging under `$TMPDIR` or `/private/tmp`; remove it normally,
  or register verified staging outside Git after verifying uploaded or released bytes:
  `storage-maintenance --register PATH --ttl-days 3`. Keep hashes, URLs,
  versions and receipts instead of duplicate binaries.
- Remove clean, merged worktrees through Git. Preserve dirty/unmerged work and
  history; under pressure remove only reproducible dependencies from such work.
- Never delete others' work, browser profiles, application databases, Docker
  volumes, cloud drive or personal data. Chrome/Google and Zoom are protected.
  Do not add cleanup daemons or install from the orphaned home `package.json`.
<!-- END BEAMO STORAGE HYGIENE -->
