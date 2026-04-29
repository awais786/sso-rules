# App Rules — devstack invariants for every app behind ForwardAuth

Canonical rules every app in this devstack must follow. Applies to:
- Existing apps: **Plane**, **Outline**, **Penpot**, **SurfSense**, **Twenty**
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
  - **Email synthesis is universal** — every backend that accepts bare-username Cognito pools needs it. **Verified ground truth (source grep across all 4 forks):** Plane ✅ `apps/api/plane/settings/common.py:64`, Outline ✅ `server/env.ts:537` + `authentication.ts:319`, Penpot ✅ `backend/src/app/http/auth_request.clj:47` (env mapped to `:default-email-domain` keyword via Penpot config DSL), SurfSense ✅ `surfsense_backend/app/config/__init__.py:321`. All 4 default to `askii.ai`.
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
- Five canonical env vars in `.env`. Two access-pair (seconds + duration), two refresh-pair (seconds + duration), and one sliding-refresh interval. Apps wire whichever shape their native config takes:
  ```
  SESSION_TTL_SECONDS=28800            # 8h — access cookie / app session, seconds
  SESSION_TTL_DURATION=8h              # same window, duration string

  SESSION_REFRESH_TTL_SECONDS=57600    # 16h — refresh token, seconds (must be >= access)
  SESSION_REFRESH_TTL_DURATION=16h     # same window, duration string

  SESSION_COOKIE_REFRESH_SECONDS=3600  # 1h — sliding-refresh interval (must be < SESSION_TTL_SECONDS)
  ```
- The sliding-refresh window controls how often oauth2-proxy + Penpot **re-validate** the cookie while the user is active. Set to a value < `SESSION_TTL_SECONDS` (typically 1h). Result: an actively-clicking user never hits the 8h ceiling — the cookie keeps rolling forward as long as activity continues. Set to `0` to disable. Compose default is `3600`.
- Every session-issuing app **MUST** wire one of these into its native config — verified ground truth in `docker-compose.yml`:
  - **Plane (Django):** `SESSION_COOKIE_AGE = ${SESSION_TTL_SECONDS}`
  - **SurfSense (FastAPI):** `ACCESS_TOKEN_LIFETIME_SECONDS = ${SESSION_TTL_SECONDS}`, `REFRESH_TOKEN_LIFETIME_SECONDS = ${SESSION_REFRESH_TTL_SECONDS}`
  - **Penpot:** `PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE = ${SESSION_TTL_SECONDS}s`, `PENPOT_AUTH_TOKEN_COOKIE_RENEWAL_MAX_AGE = ${SESSION_COOKIE_REFRESH_SECONDS}s`
  - **oauth2-proxy:** `OAUTH2_PROXY_COOKIE_EXPIRE = ${SESSION_TTL_SECONDS}s`, `OAUTH2_PROXY_COOKIE_REFRESH = ${SESSION_COOKIE_REFRESH_SECONDS}s`
  - **Outline (ForwardAuth JWT cookie):** `SESSION_TTL_SECONDS` — fork patch in `server/middlewares/authentication.ts`, `server/utils/authentication.ts`, `server/routes/auth/index.ts` replaces the upstream `addMonths(3)` constant. Outline-as-OAuth-provider also wires `OAUTH_PROVIDER_ACCESS_TOKEN_LIFETIME` / `OAUTH_PROVIDER_REFRESH_TOKEN_LIFETIME`.
  - **Twenty (NestJS):** `ACCESS_TOKEN_EXPIRES_IN = ${SESSION_TTL_DURATION}`, `REFRESH_TOKEN_EXPIRES_IN = ${SESSION_REFRESH_TTL_DURATION}` — also drives the SSO cookie maxAge (refresh, not access).

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

| Field | Plane | Outline | Penpot | SurfSense | Twenty |
|-------|-------|---------|--------|-----------|--------|
| Subdomain | `foss-pm` | `foss-docs` | `foss-design` | `foss-research` | `foss-twenty` |
| Build pattern (backend) | A — Python/Django | B — Node compiled | B — Clojure uberjar | A — Python/FastAPI | B — NestJS unified image |
| Build pattern (frontend) | B — Vite baked | (single image) | B — ClojureScript | B — Next.js placeholder tokens | B2 — `window._env_` runtime injection (`generateFrontConfig`) |
| Backend image | `ghcr.io/pressingly/plane-backend:v1.2.3-sso` | `foss-devstack/outline:dev` | `foss-devstack/penpot-backend:dev` | `ghcr.io/pressingly/surfsense-backend:latest` | `foss-devstack/twenty:dev` |
| Frontend image | `foss-devstack/plane-web:dev` | (same as backend) | `foss-devstack/penpot-frontend:dev` | `ghcr.io/pressingly/surfsense-web:latest` | (same as backend) |
| Fork branch (SSO) | `main` (foss-main) | `sso-auth` | `implement-sso-v2` | `foss-main` | `sso-auth` |
| 1-layer logout file | `apps/web/core/store/user/index.ts` | `app/stores/AuthStore.ts` + `app/scenes/Logout.tsx` | `frontend/src/app/main/data/auth.cljs` | `surfsense_web/lib/auth-utils.ts` | `packages/twenty-front/src/modules/auth/hooks/useAuth.ts` |
| TTL env consumed | `SESSION_COOKIE_AGE` ← `SESSION_TTL_SECONDS` | ⚠️ hardcoded `addMonths(3)` (fork patch pending) | `PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE` ← `SESSION_TTL_SECONDS` | `ACCESS_TOKEN_LIFETIME_SECONDS` + `REFRESH_TOKEN_LIFETIME_SECONDS` ← `SESSION_TTL_SECONDS` / `SESSION_REFRESH_TTL_SECONDS` | `ACCESS_TOKEN_EXPIRES_IN` ← `SESSION_TTL_DURATION`; `REFRESH_TOKEN_EXPIRES_IN` ← `SESSION_REFRESH_TTL_DURATION` (cookie maxAge tracks **refresh**) |
| Bypass paths | `/god-mode`, `/api/instances`, `/_next/static`, `/static/` | `/api/hooks`, `/_next/static` | `/js/`, `/css/`, `/images/`, `/fonts/` | `/health`, `/docs`, `/openapi.json`, `/_next/static`, `/zero` | `/static/`, `/assets/`, `Path(/favicon.ico)` |
| SSO integration shape | Django middleware (unified process) | Inside `authentication.ts` middleware (unified) | Reitit RPC middleware (unified) | Cookie handoff at `/auth/jwt/proxy-login` (split FE/BE) | Standalone NestJS controller `GET /auth/sso/proxy-login` (unified) — sets `tokenPair` cookie consumed by Jotai, no Passport ceremony |
| Email synthesis from username | ✅ `DEFAULT_EMAIL_DOMAIN` at `apps/api/plane/settings/common.py:64` + `proxy_auth.py:66,70` | ✅ `DEFAULT_EMAIL_DOMAIN` at `server/env.ts:537` + `authentication.ts:319` | ✅ `DEFAULT_EMAIL_DOMAIN` (env → `:default-email-domain` config key) at `auth_request.clj:47` | ✅ `DEFAULT_EMAIL_DOMAIN` at `config/__init__.py:321` + `proxy_auth.py:90,94` | ✅ `DEFAULT_EMAIL_DOMAIN` at `sso-proxy-login.controller.ts:resolveEmail` — rejects when env unset (no silent `user@undefined`) |

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

**Twenty**
- Multi-workspace by design, but SSO is single-tenant: `ASKII_WORKSPACE_SUBDOMAIN` env tells the provisioning service which workspace SSO users join. Multi-tenant SSO would require routing by Cognito attribute / email domain / host — not implemented yet.
- Workspace bootstrap is intricate (per-workspace schema, default views, default roles, onboarding records). First-run requires native signup with `AUTH_TYPE` overridden to non-`SSO`, then the workspace's `subdomain` + `displayName` columns are renamed to match `ASKII_WORKSPACE_SUBDOMAIN`. Then `AUTH_TYPE=SSO` and recreate. See `docs/twenty.md`.
- The fork's image bundles its own postgres + redis but the devstack wires it to shared `postgres` + `valkey`. The init-db script auto-detects external mode via `PG_DATABASE_URL` (function `psql_target` in `init-db.sh`); reordering or hardcoding localhost would break startup against shared postgres.
- Cookie carries both access + refresh tokens — cookie `maxAge` derives from `REFRESH_TOKEN_EXPIRES_IN`, **not** the access TTL, so the browser doesn't drop the refresh token alongside the access token expiring. `Secure` flag derives from `SERVER_URL.startsWith('https')` so http:// dev setups work.
- SECURITY: `auth/sso/proxy-login` is a `@PublicEndpointGuard` route that trusts `X-Auth-Request-Email`. Trust chain (any link broken = auth-bypass): (1) Twenty's `:3000` is unpublished; (2) Traefik's `twenty-secure` runs `strip-auth-headers` BEFORE `mpass-auth`; (3) oauth2-proxy ForwardAuth re-injects the headers from the validated session. Documented inline at the controller class header.
- Identity-managed UI gating: login/signup form, password reset, change-password button, email field, 2FA workspace toggle, and 2FA setup page (`/settings/profile/two-factor-authentication/TOTP`) all read `useIsSsoEnabled()` and either hide or redirect to `/settings/profile`.

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

## 4. Threat model & security verification

Every change to compose, Traefik labels, or fork auth code must preserve the **trust chain that closes external header forging**. This section spells out which invariant defends against which threat, so the per-app `<status>` cells in the report can be set with a clear rationale.

### Threat 1 — external attacker forges identity headers

A client on the public internet sends `GET /<protected>` with `X-Auth-Request-Email: admin@askii.ai`.

**Closed by all three of:**

| Layer | What stops the attack |
|-------|----------------------|
| `:port` not published on host | The attacker can't reach the backend directly. Traefik on `:443` is the only ingress. |
| `strip-auth-headers` applied BEFORE `mpass-auth` on every `<app>-secure` router | Inbound `X-Auth-Request-*` from any browser is deleted at the edge before any handler sees it. |
| `mpass-auth` (oauth2-proxy ForwardAuth) | Without a valid `_oauth2_proxy` cookie → 302 to Cognito. With a valid cookie → oauth2-proxy injects the **real** authenticated user's email, overwriting any client-supplied value. |

**Verifying for an app:** confirm all three for its `<app>-secure` router. Reordering, removing, or downgrading any link silently re-opens the forgery path.

### Threat 2 — sibling-container compromise (internal)

An attacker who breaks one app's process gets shell on a docker container with full network access to every other app's backend port. From there they can dial `twenty:3000` directly with a forged header and impersonate any user.

**Not fully closed.** Network isolation contains external attackers but not lateral movement on the docker network. Acknowledged limitations:

- The compromised app already has its own DB credentials in env, so direct postgres queries bypass auth-at-app entirely.
- Valkey is unauthenticated in this devstack, so session fixation is also reachable.
- `_oauth2_proxy` cookies in Valkey can be read by anyone on the docker network.

**Defense-in-depth options (none currently applied):**

- Per-app docker network (Traefik bridges to all apps; apps can't dial each other) — strongest, ~15 lines of compose.
- App-level shared-secret header injected by Traefik on every `*-secure` router and validated server-side — narrower, requires a fork patch in every app.
- Per-app valkey passwords / ACL'd databases.
- Read-only postgres roles for any code path that doesn't write.

If a PR proposes a shared-secret guard or similar narrow hardening, weigh it against the cross-cutting nature of the threat: a per-endpoint check leaves postgres / valkey / S3 access untouched. Either roll the same pattern across all 5 apps or document the limitation in `docs/known-issues.md`.

### Threat 3 — backend acts on `X-Auth-Request-*` without ForwardAuth verifying

If `AUTH_TYPE=SSO` is missing from a backend container, the app may default to a non-SSO mode where it doesn't enforce the header-trust gate. A misconfigured local dev or staging then silently trusts spoofed headers.

**Closed by:** `AUTH_TYPE=SSO` (and the `NEXT_PUBLIC_*_AUTH_TYPE` mirror on split frontends) on every app container, plus a backend-side check that refuses to act on `X-Auth-Request-Email` unless the env is set.

**Verifying for an app:** grep the backend for `AUTH_TYPE` reads; confirm the SSO middleware/controller refuses identity headers when the env is anything other than `SSO`.

### Threat 4 — cookie misconfiguration (Secure / SameSite / HttpOnly)

If a session cookie is minted with `secure: false` on https origins, or `sameSite: 'none'` without `secure`, it can be read by intermediaries or accessed cross-origin. If `httpOnly: false` is required for the SPA to read it, the cookie must be short-lived and cleared after use.

**Closed by, per-app:**

- `secure` flag derives from `SERVER_URL.startsWith('https')`, never hardcoded `true` (breaks http:// dev) or `false` (breaks production).
- `sameSite: 'lax'` for cross-tab session continuity.
- `httpOnly: true` for cookies the SPA never reads. SurfSense + Twenty use short-lived `httpOnly: false` cookies for the SSO handoff (60s TTL, cleared by SPA after read).

**Verifying for an app:** find every `res.cookie(...)` / `Set-Cookie` site; confirm the flags. Hardcoded `secure: true` is the most common drift (works in prod, breaks dev).

### Threat 5 — identity-managed UI lets the user break their own SSO lookup

If the SPA exposes "change email" or "change password" while `AUTH_TYPE=SSO`, a user can change their local email to something Cognito doesn't return as `X-Auth-Request-Email` — locking themselves out on the next request.

**Closed by:** SSO-aware gating on every identity-managed surface — login/signup form, password change, password reset, email change, 2FA enforcement toggle, 2FA TOTP setup. Either hide the UI or hard-redirect away.

**Verifying for an app:** grep for `useIsSsoEnabled` / `AUTH_TYPE` reads in the frontend; confirm each identity-managed component checks it.

### Threat 6 — logout regression to `/oauth2/sign_out`

The 2026-04-17 simplification dropped the oauth2-proxy `/sign_out` hop because Cognito hosted `/logout` isn't available on this app client and the intermediate hop produces a visibly broken redirect. A future PR re-introducing `/oauth2/sign_out` would re-introduce the broken UX.

**Closed by:** every app's logout target is the bare portal host (`window.location.hostname.replace(/^[^.]*\./, "foss.")`), no `/oauth2/sign_out` suffix.

**Verifying for an app:** grep the SPA's logout handler for the literal `oauth2/sign_out` — should not appear unless the app has explicit Cognito hosted logout config.

---

## 5. Diagnosis quick-reference

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

## 6. References

- `CLAUDE.md` — narrative + full diagnosis table
- `docs/known-issues.md` — open issues (Outline TTL hardcode, Penpot bare-username, etc.)
- `docs/mpass-sso.md` — full design narrative
- `docs/mpass-sso-rollout.md` — stage-by-stage delivery log
- `docs/<app>.md` + `docs/<app>-smoke-test.md` — per-app integration + verification
