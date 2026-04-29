# Changelog

All notable changes to the sso-rules plugin land here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [SemVer](https://semver.org/) — bumps reflect compatibility of the report shape and the canonical rule set, not the underlying devstack.

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
