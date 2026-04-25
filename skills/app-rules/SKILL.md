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
- **`AUTH_TYPE=SSO`** env is set on every app container
- **TLS** uses `tls=true` only — never `tls.certresolver=letsencrypt`
- **Build pattern** is consistent: Pattern A (interpreted) gets volume mounts; Pattern B (compiled) gets placeholder tokens (`__NEXT_PUBLIC_FOO__`), not real values, baked into the image
- **Session TTL** wires `SESSION_TTL_SECONDS` or `SESSION_TTL_DURATION` into the app's native config (Django `SESSION_COOKIE_AGE`, Penpot `:auth-token-cookie-max-age`, oauth2-proxy `OAUTH2_PROXY_COOKIE_EXPIRE`, FastAPI `ACCESS_TOKEN_LIFETIME_SECONDS`)
- **Valkey consumers** declare `depends_on: valkey: { restart: true }` (sessions cascade on Valkey recreate)
- **Logout** clears app session + uses the portal-host regex (`hostname.replace(/^[^.]*\./, "foss.")`)
- **Identity-managed UI** hidden: no local password/email change in SSO mode
- **Compose commands** in scripts/Makefile use `COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml ... --no-deps` — never bare `docker compose`

### 3. If adding a new app
Walk the "Adding a new app" 10-item checklist in `RULES.md` §3. Each item is required unless deferred with a written tradeoff documented in your repo's `docs/known-issues.md`.

### 4. If changing identity / cookies / session shape
Cross-check against the matrix in `RULES.md` §2. Confirm:
- The change applies consistently across all apps (SSO chain rules are uniform; per-app integration shape is the only variation)
- The "App-specific notes" subsection for the affected app stays accurate (update it if not)

### 5. Report

Print:

| Invariant | Status | Notes |
|-----------|--------|-------|
| strip-auth-headers + mpass-auth on -secure | ✅/❌ | which routers checked |
| bypass router priority + path discipline | ✅/❌ | flag any user-data path bypassed |
| backend ports unexposed | ✅/❌ | list any with `ports:` |
| AUTH_TYPE=SSO env | ✅/❌ | which apps missing |
| TLS = mkcert (no certresolver) | ✅/❌ | flag any letsencrypt |
| build pattern correctness | ✅/❌ | placeholder tokens for Pattern B |
| session TTL wired | ✅/❌ | which apps don't honor SESSION_TTL_* |
| valkey cascade declared | ✅/❌ | services missing restart: true |
| logout shape | ✅/❌ | regex + portal navigate |
| compose hygiene | ✅/❌ | bare `docker compose` in scripts |

End with: **All invariants hold** or **N violations** with the most load-bearing fix called out first.

## What this skill is NOT
- Not a runtime health check — that's a separate `/review`-style skill.
- Not a design tool — for new app intake, brainstorm + write a plan first.
- Not a substitute for `RULES.md` — always re-read the doc; it evolves.
