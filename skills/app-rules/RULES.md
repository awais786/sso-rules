# App Rules — devstack invariants for every app behind ForwardAuth

Canonical rules every app in this devstack must follow. Applies to:
- Existing apps: **Plane**, **Outline**, **Penpot**, **SurfSense**
- Any future app added behind oauth2-proxy + Traefik ForwardAuth

When editing `docker-compose.yml`, `traefik/`, or any fork repo, this doc is the contract. Violations break the SSO chain.

---

## 1. Universal invariants

These rules apply to **every** app. No exceptions without a written tradeoff in this doc.

### SSO chain
- Every protected `-secure` Traefik router **MUST** carry `strip-auth-headers@docker, mpass-auth@docker` middlewares, in that order. Strip first; otherwise inbound `X-Auth-Request-*` is trusted before being scrubbed.
- Every backend reads identity from `X-Auth-Request-Email` (primary) → `X-Auth-Request-User` (fallback). If neither contains `@`, synthesize `{user}@${DEFAULT_EMAIL_DOMAIN}`. Reject the request only if both are empty.
  - **Canonical pattern** (Python apps — Plane, SurfSense):
    ```python
    DEFAULT_EMAIL_DOMAIN = os.getenv("DEFAULT_EMAIL_DOMAIN", "askii.ai")
    ```
    Equivalent in Node (Outline) / Clojure (Penpot) — same env var name, same default.
  - **Email synthesis is universal** — every backend that accepts bare-username Cognito pools needs it; missing synthesis (Penpot today) breaks first-login.
  - The same `DEFAULT_EMAIL_DOMAIN` env **MUST** be set on every app container so synthesis stays consistent across the stack — otherwise the same Cognito user gets `user@askii.ai` from one app and `user@somewhere-else.com` from another → two distinct user rows, two profiles, broken cross-app handoff.
- Every backend port is **internal-only**. Never publish backend ports on the host (`ports: ["8000:8000"]` is forbidden); access is exclusively through Traefik. Without that, `strip-auth-headers` is bypassable.
- Every app **MUST** set `AUTH_TYPE=SSO` env on its container (and the equivalent `NEXT_PUBLIC_*_AUTH_TYPE=SSO` on split-process frontends). This is the **header-trust gate** — backend / SPA must refuse to act on `X-Auth-Request-*` unless the gate is set. Without it, a misconfigured local dev or staging deploy silently trusts spoofed headers. The SPA must also hide local login/register/forgot-password UI when SSO is set.

### Bypass discipline
- Bypass routers (no `mpass-auth`) get `priority=20` (or higher). Secure catch-all routers stay at `priority=1-10`.
- Bypass paths are restricted to:
  - Static assets (`/_next/static`, `/static/`, `/js/`, `/css/`, `/images/`, `/fonts/`)
  - Health/docs (`/health`, `/docs`, `/openapi.json`)
  - Webhooks with their own token auth (`/api/hooks`)
  - **Admin bootstrap endpoints isolated from normal users** (`/god-mode` for Plane; the principle is "separate session universe, not reachable from the main app shell" — apps may use different paths)
  - Out-of-band sync protocols with their own auth (`/zero` — bearer token)
- **Never** bypass for routes returning user data or accepting mutations. If unsure, default to secure.

### TLS
- Devstack uses mkcert wildcard at `traefik/certs/local.crt` for `*.${PLATFORM_DOMAIN}`.
- Routers use `tls=true` (default cert store). **Never** `tls.certresolver=letsencrypt` — ACME is not configured.

### Build pattern
Every fork is one of:
- **Pattern A (interpreted):** Pull official image. Volume-mount fork source. Edit → restart service → live.
  - Restart shape: `COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml docker compose restart <svc> --no-deps`
- **Pattern B (compiled):** Build image once. Two sub-patterns for getting env values into the bundle:
  - **B1 — build-arg injection:** values baked at `docker build` time via Dockerfile `ARG` + `ENV`. Immutable per image. Plane Vite frontend uses this. Changing a value = rebuild.
  - **B2 — runtime placeholder substitution:** bake **placeholder tokens** (`__NEXT_PUBLIC_FOO__`) into the bundle, entrypoint script (e.g., `docker-entrypoint.js`, `nginx-entrypoint.sh`) substitutes real env values on container start. Same image, different deploys; changing a value = recreate container, no rebuild. SurfSense Next.js + Penpot nginx use this.
  - Build shape: `make dev.build.<app>.<component>` then recreate via `dev.restart.<app>`.

Pick A vs B (and B1 vs B2) before writing the Dockerfile. Don't volume-mount source into a Pattern B container — values were baked at build, mounting source has zero effect. Don't bake real values into a B2 image — terser will dead-code-eliminate placeholder branches if it sees them as falsy literals.

### Session TTL
- Two canonical env vars in `.env`, kept aligned:
  ```
  SESSION_TTL_SECONDS=28800   # 8h, for apps reading seconds
  SESSION_TTL_DURATION=8h     # same, for apps reading duration strings
  ```
- Every session-issuing app **MUST** wire one of these into its native config (Django `SESSION_COOKIE_AGE`, Penpot `:auth-token-cookie-max-age`, oauth2-proxy `OAUTH2_PROXY_COOKIE_EXPIRE`, FastAPI `ACCESS_TOKEN_LIFETIME_SECONDS`).
- Apps that hardcode TTL (Outline currently — `addMonths(new Date(), 3)`) need a fork patch tracked in `docs/known-issues.md`.

### Logout
- Every SPA logout: clear app session (server-side endpoint) → clear client state (localStorage, mobx, IndexedDB) → top-level navigate to portal host:
  ```js
  window.location.hostname.replace(/^[^.]*\./, "foss.")
  // foss-pm.local.moneta.dev → foss.local.moneta.dev
  ```
- Current state: 1-layer (app session only). `_oauth2_proxy` and Cognito cookies survive. Trade-off documented in CLAUDE.md.
- Restoring 3-layer requires Cognito hosted `/logout` and the steps in CLAUDE.md "Logout simplification — 2026-04-17".
- Regex caveat: `^[^.]*\.` rewrites any first label. Tighten to `^foss-[^.]+\.` with `origin` fallback if deploying outside the `foss-*` naming scheme.

### Identity-managed fields
In SSO mode, email + password are owned by Cognito. Hide or hard-disable:
- Local password change UI
- Local email change UI / RPC (changing email locally breaks `X-Auth-Request-Email` lookup → user locked out)

### Compose hygiene
- **Never** run bare `docker compose ...` — drops the dev overlay's bind mounts.
- **Always:**
  ```bash
  COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml docker compose <cmd> --no-deps
  ```
- `--no-deps` prevents cascade into Valkey/Postgres unless explicitly intended.

### Stale-container hygiene
Old containers without the `foss-devstack-` prefix (left from prior compose-project names) get registered with Traefik and cause WRR 504s. Periodic check:
```bash
docker ps --format "{{.Names}}" | grep -v "foss-devstack-"
```
Stop anything that doesn't belong.

### Valkey cascade
Every Valkey consumer **MUST** declare:
```yaml
depends_on:
  valkey:
    restart: true
```
When Valkey is recreated, Compose restarts the dependent. Without this, oauth2-proxy and friends hold stale connection pools after a Valkey bounce → silent session-lookup failures.

---

## 2. App matrix (current state)

| Field | Plane | Outline | Penpot | SurfSense |
|-------|-------|---------|--------|-----------|
| Subdomain | `foss-pm` | `foss-docs` | `foss-design` | `foss-research` |
| Build pattern (backend) | A — Python/Django | B — Node compiled | B — Clojure uberjar | A — Python/FastAPI |
| Build pattern (frontend) | B — Vite baked | (single image) | B — ClojureScript | B — Next.js placeholder tokens |
| Backend image | `ghcr.io/pressingly/plane-backend:v1.2.3-sso` | `foss-devstack/outline:dev` | `foss-devstack/penpot-backend:dev` | `ghcr.io/pressingly/surfsense-backend:latest` |
| Frontend image | `foss-devstack/plane-web:dev` | (same as backend) | `foss-devstack/penpot-frontend:dev` | `ghcr.io/pressingly/surfsense-web:latest` |
| Fork branch (SSO) | `main` (foss-main) | `sso-auth` | `implement-sso-v2` | `foss-main` |
| 1-layer logout file | `apps/web/core/store/user/index.ts` | `app/stores/AuthStore.ts` + `app/scenes/Logout.tsx` | `frontend/src/app/main/data/auth.cljs` | `surfsense_web/lib/auth-utils.ts` |
| TTL env consumed | `SESSION_COOKIE_AGE` (Django) | ⚠️ hardcoded `addMonths(3)` | `PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE` | `ACCESS_TOKEN_LIFETIME_SECONDS` + refresh |
| Bypass paths | `/god-mode`, `/api/instances`, `/_next/static`, `/static/` | `/api/hooks`, `/_next/static` | `/js/`, `/css/`, `/images/`, `/fonts/` | `/health`, `/docs`, `/openapi.json`, `/_next/static`, `/zero` |
| SSO integration shape | Django middleware (unified process) | Inside `authentication.ts` middleware (unified) | Reitit RPC middleware (unified) | Cookie handoff at `/auth/jwt/proxy-login` (split FE/BE) |
| Email synthesis from username | ✅ `proxy_auth.py` | ✅ `authentication.ts` | ❌ pending — bare username fails validation | ✅ `proxy_auth.py` |

⚠️ = known issue, see `docs/known-issues.md`.

### App-specific notes

**Plane**
- `/god-mode` is a separate session universe; ForwardAuth must not touch it. Bypass router required.
- Postgres role for Plane needs `SUPERUSER` for first-time setup (init script in `postgres/initdb.d/`).
- Native auth URL patterns (`/auth/google/`, `/auth/github/`, `/auth/email/`, magic-link) are still mounted but unreachable. Disabling under `MPASS_SSO_ENABLED=true` is a pending hardening.

**SurfSense**
- Split process: Next.js frontend can't read `X-Auth-Request-Email` directly. Cookie handoff pattern at `/auth/jwt/proxy-login` issues a JWT, sets short-lived cookies (60s TTL), redirects to `/`. Frontend `(home)/page.tsx` reads cookies, stores JWT in localStorage.
- Alembic chain in fork **MUST** stay synced with upstream MODSetter/SurfSense. Drift → backend crash-loops with `Can't locate revision`. Fix: pull missing revisions from `real-upstream/main`. See CLAUDE.md.
- HuggingFace model + ffmpeg downloads on cold start (~5-10 min). Persisted by `surfsense-hf-cache` named volume.
- Streaming/SSE calls **MUST** use `authenticatedFetch`, not raw `fetch()`. Raw fetch bypasses the 401 wrapper — when JWT expires mid-stream the connection neither closes nor re-auths and the chat hangs silently. Affects `new-chat/page.tsx` and any future streaming surface.
- Zero cache replicas (port 4848) need their own replication slot on Postgres. Wiping the DB requires dropping the slot first (`SELECT pg_drop_replication_slot(...)`), then the volume `foss-devstack_surfsense-zero-cache-data`.
- Frontend uses Pattern B2 — env vars injected at startup by `docker-entrypoint.js`. Don't bake real `NEXT_PUBLIC_*` values via build-args; terser will dead-code-eliminate placeholder branches.

**Penpot**
- No dedicated SSO route — Reitit RPC middleware reads `X-Auth-Request-Email` as fallback (after session + access-token). Auto-provisions when `enable-x-auth-request-auto-register` is set in `PENPOT_FLAGS`.
- nginx-entrypoint substitutes runtime values (`MPASS_SIGNOUT_URL`, etc.) into the static bundle.
- `request-email-change` RPC is gated to reject when external IdP manages identity (commit `10441cf7d`).

**Outline**
- ForwardAuth integration is **inside** `server/middlewares/authentication.ts`, not a standalone middleware file. Two earlier standalone attempts hit a request/response race on first call.
- Auth check order: bearer header → `body.token` → `query.token` → `accessToken` cookie → `X-Auth-Request-Email`. SSO header last so subsequent requests short-circuit on the cookie.

---

## 3. Adding a new app — checklist

When introducing a 5th (or Nth) app, work through this list. Each item is required unless explicitly deferred with a written tradeoff.

1. **Subdomain.** Pick `foss-<name>.${PLATFORM_DOMAIN}`. Add to mkcert SAN list if not already covered by `*.${PLATFORM_DOMAIN}` wildcard.
2. **Cognito.** No new client needed — all 4 existing apps share one. The single callback `https://foss-auth.${PLATFORM_DOMAIN}/oauth2/callback` covers any new subdomain.
3. **Build pattern.** Decide A or B before writing the Dockerfile. Document choice in this file.
4. **Image source.** Pull upstream + volume-mount source (Pattern A) OR fork + bake placeholder tokens (Pattern B). Don't mix.
5. **Compose service.**
   - `image:` — set
   - `depends_on: valkey: { restart: true }` — required if it touches sessions
   - `depends_on: postgres: ...` — if it has its own DB
   - **No** `ports:` mapping (internal-only)
   - `AUTH_TYPE=SSO` env
   - `SESSION_TTL_*` env wired into the app's native config var
6. **Traefik routers.**
   - `<name>-secure` router with full host rule, `priority=1`, middlewares `strip-auth-headers@docker, mpass-auth@docker`
   - Bypass routers at `priority=20+` for static / health / webhooks. Justify each path against the bypass discipline.
7. **Backend identity reading.** `X-Auth-Request-Email` first, `X-Auth-Request-User` fallback, synthesize `{user}@${SMB_NAME}.com` if no `@`.
8. **Logout.** Implement the 1-layer shape: app endpoint clears session → SPA clears client state → navigate to `hostname.replace(/^[^.]*\./, "foss.")`.
9. **Hide local auth UI.** Login/register/forgot-password/email-change/password-change. SSO mode owns identity.
10. **Smoke test.** Add `docs/<name>-smoke-test.md` covering: SSO redirect, JWT/session issuance, app-API call with `X-Auth-Request-Email`, logout → portal, re-auth round-trip.

If the app is split frontend/backend (like SurfSense), expect to add a **JWT cookie handoff step**: dedicated backend endpoint (e.g., `/auth/jwt/proxy-login`) reads `X-Auth-Request-Email`, issues JWT + refresh as **short-lived cookies (60s TTL)**, 302 → `/`. Frontend root reads cookies, stores JWT in localStorage / client state, clears cookies, navigates to `/dashboard`. No `/auth/callback` route — keeps Traefik routing simple.

If unified process (like Plane/Outline/Penpot), the middleware can read the header directly.

---

## 4. Diagnosis quick-reference

Symptoms and first-check (full table in CLAUDE.md):

| Symptom | First check |
|---------|-------------|
| 504 on a healthy container | Stale container without `foss-devstack-` prefix in `docker ps` |
| Cognito redirect loop | Valkey recreated without cascading oauth2-proxy → `make dev.restart.valkey` |
| Compiled app using wrong URL | Image was Pattern B but built with hardcoded values, not placeholders |
| Stuck at `/auth/jwt/proxy-login` (SurfSense) | Backend bind mount missing — check `/app` not `/code` |
| User logged in after logout | Expected since 2026-04-17 (1-layer). For 3-layer see CLAUDE.md. |
| Logout lands on wrong host | Hostname regex wrong for non-`foss-*` deployments — tighten to `^foss-[^.]+\.` |
| `tls.certresolver=letsencrypt` errors | Remove — devstack uses mkcert |
| All apps down | oauth2-proxy crash-looping (DNS to Cognito OIDC discovery) |
| Streaming chat / SSE hangs after token TTL | Frontend using raw `fetch()` instead of `authenticatedFetch` — stream never closes when JWT expires |
| App accepts `X-Auth-Request-Email` but not from oauth2-proxy | `AUTH_TYPE=SSO` env not set on the container — header-trust gate disabled |

---

## 5. References

- `CLAUDE.md` — narrative + full diagnosis table
- `docs/known-issues.md` — open issues (Outline TTL hardcode, Penpot bare-username, etc.)
- `docs/mpass-sso.md` — full design narrative
- `docs/mpass-sso-rollout.md` — stage-by-stage delivery log
- `docs/<app>.md` + `docs/<app>-smoke-test.md` — per-app integration + verification
