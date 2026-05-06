# Changelog

All notable changes to the sso-rules plugin land here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [SemVer](https://semver.org/) — bumps reflect compatibility of the report shape and the canonical rule set, not the underlying devstack.

## [0.7.0] — 2026-05-05

### Changed
- **`RULES.md` §1 Session TTL** — canonical contract rolled back to the **three-env shape** that matches what's deployed: `SESSION_COOKIE_MAX_AGE_SECONDS`, `SESSION_COOKIE_REFRESH_SECONDS`, `SESSION_REFRESH_TOKEN_MAX_AGE_SECONDS`. Defaults restored to `604800 / 3600 / 1209600`.
- Dropped the `_DURATION` siblings entirely. Apps that need a duration-string format (Twenty NestJS `ms()`, oauth2-proxy / Penpot Go `time.Duration`) consume `${VAR}s` — compose appends the `s` suffix; both parsers accept it. One source var per horizon, no dual format.
- **`scripts/audit-sso.sh`** rows 9-10 grep patterns updated to the old names. Row 11 (sliding refresh, `SESSION_COOKIE_REFRESH_SECONDS`) unchanged.
- **`apps-overview.md`** §"Session TTL wiring" — table updated. Outline row clarified: consumer env name stays `SESSION_TTL_SECONDS` because the fork patch reads `env.SESSION_TTL_SECONDS` literally; only the interpolation source changes.
- **`SKILL.md`** rows 9-10 + section "session access TTL" / "Refresh TTL" — updated to old names.
- **`README.md`** issue-table rows 9 + 11 — updated to old names.

### Why
The four-env (`SESSION_TTL_SECONDS` + `SESSION_TTL_DURATION` ×2) shape introduced in v0.3.0 never aligned with the operator-side `.env` files actually deployed in production foss-server-bundle, which still used the original `SESSION_COOKIE_MAX_AGE_SECONDS` names. The rename PR ([foss-server-bundle-devstack#33](https://github.com/Pressingly/foss-server-bundle-devstack/pull/33)) was reverted because pushing the new names would have required a `.env` migration on every deploy. Easier to roll the contract back to the names already in use, and use `${VAR}s` for the duration-format consumers.

Pairs with [foss-server-bundle-devstack#XX](https://github.com/Pressingly/foss-server-bundle-devstack) (add 2 missing wirings only) and [foss-server-bundle#XX](https://github.com/Pressingly/foss-server-bundle) (counter-rename + 2 wirings).

## [0.6.0] — 2026-05-04

### Added
- **Row 17: global HTTP→HTTPS redirect at Traefik entrypoint** — security-critical row. Fails CI when the Traefik `command:` block doesn't carry `--entrypoints.web.http.redirections.entryPoint.to=websecure`. Crucially, also fails when the env-var form (`TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_TO`) is used — Traefik 3.x silently ignores it, so deployers can have it set in compose and still serve plaintext on :80.
- `RULES.md` §1 **No plaintext HTTP routes** subsection — codifies the entrypoint-redirect requirement, the env-var-form footgun, and the ACME HTTP-01 exception (Traefik auto-routes the challenge with higher priority than the redirect).

### Why
Verified live on prod 2026-05-04: every per-app HTTP route (foss-pm, foss-docs, foss-design, foss-research, foss landing) returned 200 over plaintext with no redirect. The deploy had `HTTPS_REDIRECT_TARGET=websecure` set in `.env` and threaded into Traefik via env vars, but Traefik 3.6.12 silently ignored the env-var path (verified by inspecting the static-config dump in `docker logs traefik` — the `web` entrypoint had no `redirections` key at all).

This is the same shape as the 2026-04-30 Electric `/v1/shape` exfil — HTTPS sibling gated by `mpass-auth`, HTTP twin lacking middlewares — but generalized to every per-app HTTP router. Anyone hitting port 80 without HSTS state (curl, mobile WebView, first-time visitor, bot) sees the SPA in plaintext, posts login forms over plaintext, and transmits non-`Secure` cookies unencrypted.

Row 17 catches both missing-redirect and broken-env-var-redirect deployments deterministically. Pairs with the fix in [foss-server-bundle-devstack#38](https://github.com/Pressingly/foss-server-bundle-devstack/pull/38) and [foss-server-bundle#18](https://github.com/Pressingly/foss-server-bundle/pull/18).

## [0.5.0] — 2026-04-30

### Added
- `.github/workflows/audit.yml` — reusable workflow (`workflow_call`). Compose repos add a 5-line caller workflow that pins to a tag of this plugin; the reusable workflow does checkout + fork checkout + yq install + audit run + PR comment + security-critical fail-on-violation. Single source of truth for the workflow logic; bump the consumer's `@v0.x.y` ref to roll out rule changes.
- `apps-overview.md` — per-app SSO integration + tech stack quick reference. Architecture-only, no vuln disclosure. Useful for team onboarding.

### Why
Previously each compose repo would have to maintain its own copy of the workflow YAML (option A in the design). With reusable workflows, consumers write 5 lines and inherit the full chain. Adding a 6th compose repo is now a paste of 5 lines; updating the workflow logic is one PR in this plugin + a tag bump in each consumer.

### Consumer pattern

```yaml
# .github/workflows/sso-audit.yml in any compose repo
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

## [0.4.0] — 2026-04-30

### Added
- `scripts/audit-sso.sh` — pure-bash deterministic audit of the 16 invariants in `SKILL.md` §5. No LLM, no API key. Runs in <30s against any compose repo with `bash audit-sso.sh` (compose path, traefik dir, etc. configurable via env vars). Exits 1 on security-critical (rows 1-7, 12) violations so it can gate CI. 11 of 16 rows are fully deterministic; the 5 fork-side semantic rows (3 path discipline, 6 backend AUTH_TYPE gate, 12 cookie flags, 14 logout regex form, 15 identity-managed UI) report `?` when forks aren't checked out alongside the compose repo.
- README "Running the audit" section — three patterns: local invocation, GitHub Actions step that curls a pinned tag, fetching forks alongside for full coverage of rows 14-15.

### Why
Previously the audit could only be run via the `/sso-rules:audit-all-apps` skill (LLM-backed, requires API budget, slower, non-deterministic). The bash script catches the same regressions in CI for free, while the LLM path stays available for the harder semantic checks.

## [0.3.0] — 2026-04-29

### Added
- `RULES.md` §4 **Threat model & security verification** — six named threats with the invariants that close each. External header forging, sibling-container compromise, backend trust-gate bypass, cookie misconfiguration, identity-managed UI lock-out, logout regression.
- `RULES.md` §2 — Twenty as the 5th app. Matrix column populated; "App-specific notes" subsection covers single-tenant SSO scoping, the workspace bootstrap dance, init-db external-postgres detection, cookie maxAge=refresh, the documented header trust chain, and the catalog of SSO-gated UI surfaces.
- `RULES.md` §1 Session TTL — the canonical four-env shape (`SESSION_TTL_SECONDS` + `SESSION_TTL_DURATION` for the access cookie, `SESSION_REFRESH_TTL_SECONDS` + `SESSION_REFRESH_TTL_DURATION` for the refresh token, `SESSION_COOKIE_REFRESH_SECONDS` for sliding refresh).
- `SKILL.md` §5 — strict 16-row report table. Each Status cell is exactly one of `✅`, `❌`, or `n/a`. The Notes cell carries a file:line citation on `✅` or a file:line + fix on `❌`. New rows: AUTH_TYPE mirror on split frontends, backend refuses identity headers when AUTH_TYPE≠SSO, cookie security flags. Existing logout row now explicitly checks for `/oauth2/sign_out` re-introduction.

### Changed
- `RULES.md` §1 Session TTL — replaced the original two-env `SESSION_TTL_*` shape with the four-env access/refresh + sliding-refresh shape that matches the actual codebase.
- `SKILL.md` §5 report table — replaced the `✅/❌` literal placeholder with a single `<status>` placeholder; the menu definition now lives in the prose above the table.

### Fixed
- Per-app verified-ground-truth map in `RULES.md` §1 Session TTL — corrected env names to match `docker-compose.yml` reality (`SESSION_COOKIE_AGE`, `ACCESS_TOKEN_LIFETIME_SECONDS`, `PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE`, `OAUTH2_PROXY_COOKIE_EXPIRE`, `ACCESS_TOKEN_EXPIRES_IN`).

## [0.2.0] — 2026-04-28

### Added
- Full DEFAULT_EMAIL_DOMAIN propagation across all four prior forks (Plane, Outline, Penpot, SurfSense) with verified file:line ground truth in `RULES.md` §2 App matrix.
- `RULES.md` §3 "Adding a new app" — 10-item checklist for any new app intake.
- `RULES.md` §1 — universal invariants for SSO chain, bypass discipline, build pattern, logout, identity-managed UI, compose hygiene, valkey cascade.

### Changed
- Logout shape canonicalized as 1-layer with portal-host regex, post the 2026-04-17 simplification that dropped the oauth2-proxy `/sign_out` hop.

## [0.1.0] — 2026-04-21

### Added
- Initial plugin scaffold: `marketplace.json`, `commands/app-rules.md`, `skills/app-rules/SKILL.md`, `skills/app-rules/RULES.md`.
- First version of the universal invariants and the four-app matrix (Plane, Outline, Penpot, SurfSense).
