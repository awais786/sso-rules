---
name: app-rules
description: Use when editing docker-compose.yml, traefik/, or any fork repo (plane, outline, penpot, surfsense) in a foss-server-bundle-devstack — enforces SSO chain, bypass router, build pattern, logout, session TTL, and compose hygiene invariants for every app behind oauth2-proxy + Traefik ForwardAuth. Also use when adding a new app behind ForwardAuth.
---

# app-rules — devstack invariants check

Canonical rules every app in a foss-server-bundle-devstack must follow. Applies to existing apps (Plane, Outline, Penpot, SurfSense) and any future app added behind oauth2-proxy + Traefik ForwardAuth.

When editing `docker-compose.yml`, `traefik/`, or a fork repo, **read this skill's companion doc** at `skills/app-rules/RULES.md` (the canonical contract). Then verify the change against the invariants below.

## Steps

### 1. Load the canonical rules
Read [`RULES.md`](./RULES.md) — bundled with this skill, contains:
- §1 Universal invariants (every app, current + future)
- §2 App matrix (Plane / Outline / Penpot / SurfSense × shape columns)
- §3 "Adding a new app" 10-item checklist
- §4 Diagnosis quick-ref

### 2. Check the change against universal invariants

For every diff in scope (compose, Traefik labels, fork code), verify:

- **`-secure` routers** carry `strip-auth-headers@docker, mpass-auth@docker` in that order
- **Bypass routers** are `priority=20+`, only static / health / webhooks / admin-bootstrap / out-of-band-sync — never user data or mutations
- **Backend ports** are NOT published on host (no `ports:` block on app backends)
- **`AUTH_TYPE=SSO`** env is set on every app container (header-trust gate)
- **TLS** uses `tls=true` only — never `tls.certresolver=letsencrypt`
- **Build pattern** is consistent: Pattern A (interpreted) gets volume mounts; Pattern B (compiled) gets placeholder tokens (`__NEXT_PUBLIC_FOO__`), not real values, baked into the image
- **Session access TTL** wires `SESSION_TTL_SECONDS` or `SESSION_TTL_DURATION` into the app's native config (Django `SESSION_COOKIE_AGE`, Penpot `:auth-token-cookie-max-age`, oauth2-proxy `OAUTH2_PROXY_COOKIE_EXPIRE`, FastAPI `ACCESS_TOKEN_LIFETIME_SECONDS`, Twenty `ACCESS_TOKEN_EXPIRES_IN`, Outline JWT cookie via fork patch)
- **Refresh TTL** wires `SESSION_REFRESH_TTL_SECONDS` / `SESSION_REFRESH_TTL_DURATION` for apps that mint refresh tokens (SurfSense, Twenty, Outline OAuth-provider role)
- **Sliding-refresh** wires `SESSION_COOKIE_REFRESH_SECONDS` for oauth2-proxy + Penpot so active sessions never hit the access ceiling
- **Valkey consumers** declare `depends_on: valkey: { restart: true }` (sessions cascade on Valkey recreate)
- **Logout** clears app session + uses the *narrowed* portal-host regex (`hostname.replace(/^foss-[^.]+\./, "foss.")`) with an `origin` fallback. The looser `^[^.]*\.` form misfires on `localhost` / non-`foss-*` deployments
- **Identity-managed UI** hidden under SSO: signin/signup, password change/reset, email change, 2FA enforcement toggle, 2FA TOTP setup page (redirect, not just hide)
- **Compose commands** in scripts/Makefile use `COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml ... --no-deps` — never bare `docker compose`

### 3. If adding a new app
Walk the "Adding a new app" 10-item checklist in `RULES.md` §3. Each item is required unless deferred with a written tradeoff documented in your repo's `docs/known-issues.md`.

### 4. If changing identity / cookies / session shape
Cross-check against the matrix in `RULES.md` §2. Confirm:
- The change applies consistently across all apps (SSO chain rules are uniform; per-app integration shape is the only variation)
- The "App-specific notes" subsection for the affected app stays accurate (update it if not)

### 5. Report

Print **only** the table below — no PASS/FAIL prose sections, no preamble. Each Status cell is exactly one of `✅`, `❌`, or `n/a`. The Notes cell carries a concrete file:line citation when ✅ and a file:line + the specific fix when ❌. If the change touches no SSO/ForwardAuth surface, skip the table and write a one-sentence "no in-scope changes" line instead.

| Invariant | Status | Notes |
|-----------|--------|-------|
| strip-auth-headers + mpass-auth on -secure (in that order) | ✅ \| ❌ | router(s) checked + file:line; on ❌ name the missing/misordered middleware |
| bypass router priority + path discipline | ✅ \| ❌ | router(s) checked at priority=20+; on ❌ flag the user-data / mutation path that was bypassed |
| backend ports unexposed | ✅ \| ❌ | on ❌ list every service with a `ports:` block |
| AUTH_TYPE=SSO env | ✅ \| ❌ | service(s) checked; on ❌ name the apps missing the env (header-trust gate disabled) |
| TLS = mkcert (no certresolver) | ✅ \| ❌ | on ❌ flag any `tls.certresolver=letsencrypt` |
| build pattern correctness | ✅ \| ❌ | A vs B (and B1 vs B2) called out; on ❌ flag real values baked into a B image or source volume-mounted into a compiled container |
| session TTL wired (`SESSION_TTL_SECONDS`/`SESSION_TTL_DURATION`) | ✅ \| ❌ | service(s) checked; on ❌ list apps not consuming the canonical envs |
| refresh TTL wired (`SESSION_REFRESH_TTL_*`) | ✅ \| ❌ \| n/a | only refresh-token apps (SurfSense, Twenty, Outline OAuth provider). `n/a` for apps that don't mint refresh tokens |
| sliding-refresh (`SESSION_COOKIE_REFRESH_SECONDS`) wired | ✅ \| ❌ \| n/a | oauth2-proxy + Penpot only. `n/a` for everything else |
| valkey cascade declared | ✅ \| ❌ | on ❌ list services missing `depends_on: valkey: { restart: true }` |
| logout shape (1-layer + narrowed regex) | ✅ \| ❌ | logout file checked; on ❌ name the wrong target (e.g. `/oauth2/sign_out`) or the loose `^[^.]*\.` regex |
| identity-managed UI hidden under SSO | ✅ \| ❌ | gates checked: signin/signup, password change, email change, password reset, 2FA enforce + TOTP setup |
| compose hygiene (no bare `docker compose`) | ✅ \| ❌ | on ❌ flag scripts/Makefile invoking compose without `COMPOSE_FILE` + `--no-deps` |

End the table with one of:
- `**All invariants hold.**` — every row is ✅ or `n/a`
- `**N violations.**` followed by a single sentence calling out the most load-bearing fix first (the one that re-exposes auth bypass, leaks user data, or breaks the next deploy).

## What this skill is NOT
- Not a runtime health check — that's a separate `/review`-style skill.
- Not a design tool — for new app intake, brainstorm + write a plan first.
- Not a substitute for `RULES.md` — always re-read the doc; it evolves.
