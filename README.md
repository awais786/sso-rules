# sso-rules-plugin

Claude Code skill that enforces SSO + bypass + build-pattern + cookie-security invariants on every app behind oauth2-proxy + Traefik ForwardAuth in a `foss-server-bundle-devstack`.

Targets the five-app stack — **Plane**, **Outline**, **Penpot**, **SurfSense**, **Twenty** — and any new app added behind ForwardAuth.

## What it does

When you edit `docker-compose.yml`, `traefik/`, or any fork repo, run `/sso-rules:app-rules` (or invoke the skill from the Skill tool) and it produces a strict 16-row audit table covering every universal invariant. Every row is `✅`, `❌`, or `n/a` with file:line evidence — no narrative PASS/FAIL prose.

The 16 rows map onto six explicit threats (`RULES.md` §4):

| # | Threat | Closed by rows |
|---|--------|----------------|
| 1 | External attacker forges identity headers | 1 (strip-auth + mpass), 2 (ports unexposed), 3 (bypass discipline) |
| 2 | Sibling-container compromise | Acknowledged not closed; defense-in-depth options listed |
| 3 | Backend acts on `X-Auth-Request-*` without ForwardAuth verifying | 4 (`AUTH_TYPE=SSO` env), 5 (frontend mirror), 6 (server-side gate) |
| 4 | Cookie misconfiguration | 12 (`secure` from `SERVER_URL`, `sameSite`, `httpOnly` per role) |
| 5 | Identity-managed UI lets the user lock themselves out | 15 (signin / password / email / 2FA gates) |
| 6 | Logout regression to `/oauth2/sign_out` | 14 (logout shape + portal-host regex) |

## Sample output

For a passing audit on a clean Twenty integration:

```
| #  | Invariant                                                | Status | Notes                                                                                                              |
|----|----------------------------------------------------------|--------|--------------------------------------------------------------------------------------------------------------------|
| 1  | strip-auth-headers + mpass-auth on -secure (in that order) | ✅     | twenty-secure (docker-compose.yml:1097) — strip-auth-headers@docker,mpass-auth@docker in correct order             |
| 2  | backend ports unexposed                                  | ✅     | no `ports:` block on twenty/twenty-worker (docker-compose.yml:1048-1119)                                           |
| 3  | bypass router priority + path discipline                 | ✅     | twenty-static priority=20, paths /static/, /assets/, Path(/favicon.ico) (docker-compose.yml:1080)                  |
| 4  | AUTH_TYPE=SSO env (backend)                              | ✅     | x-twenty-env line 87                                                                                               |
| 5  | AUTH_TYPE mirror on split frontends                      | ✅     | generateFrontConfig writes window._env_.AUTH_TYPE (utils/generate-front-config.ts:15)                              |
...
**All invariants hold.**
```

For a failing audit, the table replaces ✅ with ❌ and the Notes column carries the file:line + concrete fix.

## Install

```
/plugin marketplace add https://github.com/awais786/sso-rules
/plugin install sso-rules
```

(Local-clone install also works: `/plugin marketplace add /path/to/sso-rules`.)

After install:

```
/sso-rules:app-rules
```

## Running the audit (no LLM, free, deterministic)

`scripts/audit-sso.sh` does a pure-bash version of 11 of the 16 invariants — same threat-to-row mapping as `SKILL.md` §5. Runs in <30s, no API key, exits 1 on security-critical violations (rows 1-7 + 12), prints the same 16-row table. The 5 fork-side semantic rows report `?` when forks aren't on disk; the LLM-backed `/sso-rules:audit-all-apps` covers those.

**Local, against a compose repo:**
```
bash <(curl -sSfL https://raw.githubusercontent.com/awais786/sso-rules/v0.5.0/scripts/audit-sso.sh)
```
or, if cloned:
```
COMPOSE=docker-compose.yml \
  bash /path/to/sso-rules/scripts/audit-sso.sh
```

**GitHub Actions — reusable workflow (recommended).** Drop a 5-line caller in `.github/workflows/sso-audit.yml` of any compose repo:

```yaml
name: SSO audit
on:
  pull_request:
    paths: [docker-compose.yml, traefik/**, Makefile, options.mk, .env.example]
  push:
    branches: [main]
  schedule:
    - cron: '0 9 * * 1'
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  sso-audit:
    uses: awais786/sso-rules/.github/workflows/audit.yml@v0.5.0
```

The reusable workflow handles checkout (caller + 5 forks), yq install, audit run, PR comment, and CI gating. Pin to a tag (`@v0.5.0`); bump deliberately when rules evolve. To skip fork checkout (rows 14-15 will report `?`), pass `with: { skip-fork-checkout: true }`. For a non-default compose path, pass `with: { compose-path: path/to/docker-compose.yml }`.

**GitHub Actions — inline curl (alternative).** If you can't reach the reusable workflow (e.g. action perms locked down), drop the script in directly:
```yaml
- name: Run SSO audit
  run: |
    curl -sSfL https://raw.githubusercontent.com/awais786/sso-rules/v0.5.0/scripts/audit-sso.sh -o audit-sso.sh
    chmod +x audit-sso.sh
    bash audit-sso.sh
```
Pin to the version tag so a rule change can't silently fail your CI; bump deliberately.

**For full coverage** with the inline pattern (rows 14-15 read fork sources), check out the forks alongside your compose repo:
```
- uses: actions/checkout@v4
  with: { repository: Pressingly/plane,    ref: foss-main, path: ../plane }
- uses: actions/checkout@v4
  with: { repository: Pressingly/outline,  ref: foss-main, path: ../outline }
- uses: actions/checkout@v4
  with: { repository: Pressingly/penpot,   ref: implement-sso-v2, path: ../penpot }
- uses: actions/checkout@v4
  with: { repository: Pressingly/SurfSense, ref: foss-main, path: ../SurfSense }
- uses: actions/checkout@v4
  with: { repository: awais786/twenty,     ref: sso-auth, path: ../twenty }
```
The reusable workflow does this automatically.

The script is invariant-by-invariant transparent — every row prints a file:line citation on ✅ and a file:line + the concrete fix on ❌.

## Use cases

- **Editing `docker-compose.yml`** — verify a new env / router / volume mount doesn't break an invariant
- **Editing `traefik/` labels** — verify the ForwardAuth chain is intact
- **Editing a fork repo** (Plane / Outline / Penpot / SurfSense / Twenty) — verify the auth integration shape stays canonical
- **Adding a 6th app** — walk the new-app checklist before merging
- **Reviewing a teammate's PR** — security-focused 16-row scan before approval

## What this skill is NOT

- Not a runtime health check — that's a separate `/review`-style skill
- Not a security scanner — it doesn't read code for SQL injection, XSS, etc.
- Not a substitute for code review — invariants are necessary, not sufficient
- Not a substitute for `RULES.md` — the doc evolves; always re-read

## Files

```
sso-rules/
├── .claude-plugin/plugin.json     # plugin manifest
├── marketplace.json                # marketplace listing
├── commands/
│   ├── app-rules.md               # /sso-rules:app-rules slash command
│   └── audit-all-apps.md          # /sso-rules:audit-all-apps slash command
├── skills/
│   └── app-rules/
│       ├── SKILL.md                # the skill itself (loaded by Claude Code)
│       └── RULES.md                # canonical contract: §1 invariants, §2 app matrix,
│                                   # §3 new-app checklist, §4 threat model,
│                                   # §5 diagnosis quick-ref, §6 references
├── scripts/
│   └── audit-sso.sh               # pure-bash deterministic audit, no LLM,
│                                   # no API key. Same 16-row report as the skill.
│                                   # Runs in <30s; exits 1 on security-critical
│                                   # violations so it can gate CI.
├── .github/workflows/
│   └── audit.yml                  # reusable workflow (workflow_call) — compose
│                                   # repos add a 5-line caller pinned to a tag.
├── apps-overview.md                # per-app SSO + tech stack quick reference
├── CHANGELOG.md                    # release notes
├── LICENSE                         # MIT
└── README.md                       # this file
```

## Provenance

Rules distilled from the foss-server-bundle-devstack `CLAUDE.md` + `docs/mpass-sso*.md` + per-app design docs. The mpass SSO rollout (April 2026) produced these as deployment invariants. Twenty integration (April 2026) added §4 threat-model section + the 16-row strict report shape.

For full narrative + diagnosis tables, see the source devstack's `CLAUDE.md`.

## Common failure modes

The audit produces ❌ when the deployment doesn't match the contract. Each `❌` ships with the file:line + the concrete fix in the Notes column, but here are the gotchas you'll hit most often when adding or modifying an app.

| Row | What broke it | Symptom | Fix |
|-----|---------------|---------|-----|
| 1 | Reversed middleware order on `-secure` (`mpass-auth` before `strip-auth-headers`) | External clients can supply `X-Auth-Request-Email` and ForwardAuth blesses it | Put `strip-auth-headers@docker` first, always |
| 2 | Added `ports: ['8080:80']` to a backend for "local dev access" | The whole ForwardAuth chain is bypassable from `localhost:8080` | Remove the host port; use a Traefik subdomain instead |
| 3 | Added a bypass router for `/api/v1` "to skip auth on read-only endpoints" | Unauthenticated user data reads | Bypass is for static / health / webhooks only — see RULES.md §1 |
| 4 | Backend container missing `AUTH_TYPE=SSO` env | Header-trust gate disabled; backend accepts forged headers from any caller | Wire `AUTH_TYPE: SSO` in the service's compose env |
| 5 | New Next.js frontend doesn't redirect to SSO | Frontend sees `window._env_.AUTH_TYPE` as empty | Wire `NEXT_PUBLIC_*_AUTH_TYPE: SSO` (split process) or copy Twenty's `generateFrontConfig` pattern (unified image) |
| 6 | Backend SSO middleware acts on headers without checking AUTH_TYPE | Local dev with AUTH_TYPE empty silently trusts spoofed headers | Early-return / 404 when `env.AUTH_TYPE !== 'SSO'` (see Twenty's `sso-proxy-login.controller.ts:57` for the pattern) |
| 7 | Added `tls.certresolver=letsencrypt` to a router | ACME isn't configured; self-signed loads silently or fails | Use `tls=true` only — mkcert wildcard handles all subdomains |
| 8 | Bind-mounted source into a Pattern B compiled image and "changes don't appear" | Compiled bundle was baked at build time; volume mount has no effect | Either rebuild the image or convert to Pattern A (interpreted) |
| 8 | Baked `NEXT_PUBLIC_FOO` with a real value at build time and the SPA falls back to a default | terser dead-code-eliminated the placeholder branch | Pattern B2 — bake `__NEXT_PUBLIC_FOO__` placeholder; substitute at startup |
| 9 | `.env` set `SESSION_TTL_SECONDS=8h` but sessions last 7 days | Compose reads a different env name (drift); `.env` value is dead | Verify the interpolation chain: `.env` → compose `${SESSION_TTL_SECONDS}` → app native env (e.g. `SESSION_COOKIE_AGE`) |
| 10 | Cookie expires at the access TTL, not the refresh TTL (Twenty / SurfSense) | User loses refresh token alongside the access token; forced re-auth | Cookie `maxAge` derives from `REFRESH_TOKEN_EXPIRES_IN`, not access |
| 11 | Active user got bounced to Cognito after `SESSION_TTL_SECONDS` even though they were clicking | `SESSION_COOKIE_REFRESH_SECONDS` not set or `0` — sliding refresh disabled | Set it to a value < `SESSION_TTL_SECONDS` (typically 1h); compose default 3600 |
| 12 | Cookies aren't stored on http://localhost dev | `secure: true` hardcoded on the cookie | Derive: `secure: SERVER_URL.startsWith('https')` |
| 13 | Restarted Valkey and `oauth2-proxy` silently fails session lookups | Service missing `depends_on: valkey: { restart: true }` | Add the cascade declaration; compose v2 doesn't bounce dependents on its own |
| 14 | Logout lands on the wrong domain (e.g. `foss.<domain>` after the deployment moved to `moneta.<domain>`) | Portal-host prefix was hardcoded in the logout file (or `SMB_NAME` env unset / has a per-app default that masked the misconfig) | Source the prefix from the **required** `SMB_NAME` env (no default); expose it per stack (Vite `define` / Outline `@Public` / Twenty `generateFrontConfig` / Penpot `nginx-entrypoint.sh` / SurfSense `docker-entrypoint.js`); document in `.env.example` |
| 15 | A user changed their email in the SPA and got locked out | Email-change UI was visible under SSO; the new email doesn't match what oauth2-proxy injects | Gate the email field on `useIsSsoEnabled` (or the per-fork equivalent) — read-only when SSO is on |
| 16 | Ran `docker compose up` and bind mounts disappeared | Bare invocation drops the dev overlay | Use `COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml docker compose up --no-deps` (or the Makefile target) |

When the audit ❌s, find the matching row above and apply the fix. If your scenario isn't listed, the Notes column on that row in the report will carry the file:line + concrete fix — that's the authoritative answer.

## Maintenance

- **New app added behind ForwardAuth** — append a column to `RULES.md` §2 App matrix and an "App-specific notes" subsection. Update `SKILL.md` step 5 if a new threat surfaces.
- **New threat vector identified** — add to `RULES.md` §4 with the closing invariants. Add a row to `SKILL.md` §5 if the existing rows don't cover it.
- **Env-name change in compose** — update `RULES.md` §1 Session TTL ground-truth wiring map.

## License

MIT
