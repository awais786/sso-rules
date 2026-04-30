# Apps Overview — SSO Integration & Tech Stack

Five apps behind oauth2-proxy + Traefik ForwardAuth. Each app's auth flow, build pattern, and per-app integration shape.

## Quick reference

| App | Subdomain | Tech (backend / frontend) | Image | Fork branch |
|-----|-----------|---------------------------|-------|-------------|
| **Plane** | `foss-pm` | Python 3.11 + Django 4.2 + DRF / Next.js (split) | `ghcr.io/pressingly/plane-backend:v1.2.3-sso` + `foss-devstack/plane-web:dev` | [`Pressingly/plane`](https://github.com/Pressingly/plane) `foss-main` |
| **Outline** | `foss-docs` | Node.js 20 + Koa + React (single image) | `outlinewiki/outline` or `foss-devstack/outline:dev` | [`Pressingly/outline`](https://github.com/Pressingly/outline) `foss-main` (+ PR #8) |
| **Penpot** | `foss-design` | Clojure + JVM uberjar + Reitit / ClojureScript via Shadow-cljs (split) | `foss-devstack/penpot-backend:dev` + `foss-devstack/penpot-frontend:dev` | [`Pressingly/penpot`](https://github.com/Pressingly/penpot) `implement-sso-v2` |
| **SurfSense** | `foss-research` | Python 3.12 + FastAPI + SQLAlchemy 2 + Alembic / Next.js 15 + React 19 (split) | `ghcr.io/pressingly/surfsense-backend` + `ghcr.io/pressingly/surfsense-web` | [`Pressingly/SurfSense`](https://github.com/Pressingly/SurfSense) `foss-main` |
| **Twenty** | `foss-twenty` | NestJS + TypeORM + postgres / Vite + React (unified image) | `foss-devstack/twenty:dev` (built from fork) | [`awais786/twenty`](https://github.com/awais786/twenty) `sso-auth` |

## Build pattern

Each app is **A** (interpreted, source volume-mounted, edit→restart) or **B** (compiled image, build to apply changes). **B2** = compiled image with placeholder tokens substituted at startup (window._env_ / nginx-entrypoint).

| App | Backend pattern | Frontend pattern |
|-----|-----------------|------------------|
| Plane | A — Python/Django, volume-mounted source | B — Vite SPA, env baked at build (build-args) |
| Outline | B — Node compiled (single image, no separate frontend) | (same as backend) |
| Penpot | B — Clojure uberjar | B2 — ClojureScript bundle, nginx-entrypoint substitutes runtime tokens |
| SurfSense | A — Python/FastAPI, volume-mounted from fork's `surfsense_backend/app/` | B2 — Next.js, `docker-entrypoint.js` substitutes `__NEXT_PUBLIC_*__` placeholders at startup |
| Twenty | B — NestJS unified image (API + bundled SPA) | B2 — Vite bundle, `generateFrontConfig` writes `window._env_` at startup |

## SSO integration shape

How each app reads `X-Auth-Request-Email` from oauth2-proxy and turns it into an authenticated session.

| App | Where the header is consumed | What it issues |
|-----|------------------------------|----------------|
| Plane | `apps/api/plane/middleware/proxy_auth.py` — Django ProxyAuthMiddleware | Django session cookie (`SESSION_COOKIE_AGE`) |
| Outline | `server/middlewares/authentication.ts` — FORWARDAUTH_SERVICE branch inside the existing auth middleware | JWT cookie (`accessToken`) — fork patch reads `SESSION_TTL_SECONDS` |
| Penpot | `backend/src/app/http/auth_request.clj` — Reitit RPC middleware (header read as fallback after session + access-token) | Penpot auth-token cookie (`PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE`) |
| SurfSense | `surfsense_backend/app/...` — dedicated `GET /auth/jwt/proxy-login` endpoint, cookie handoff (60s short-lived cookies → SPA reads them, stores JWT in localStorage, clears cookies) | JWT (access + refresh), localStorage-stored |
| Twenty | `packages/twenty-server/src/engine/core-modules/auth/controllers/sso-proxy-login.controller.ts` — standalone NestJS controller `GET /auth/sso/proxy-login`, no Passport ceremony | `tokenPair` cookie (access JWT + refresh JWT, JSON-encoded) — Jotai reads it |

## Identity-managed UI gating

When `AUTH_TYPE=SSO`, each app's SPA hides login / password / email-change UI so users can't break their own SSO lookup by changing their email.

| App | Gating mechanism | Surfaces gated |
|-----|------------------|----------------|
| Plane | `MPASS_SSO_ENABLED` env (or per-fork) | login form, signup, email change, password change (per fork's audit) |
| Outline | `env.AUTH_TYPE === 'SSO'` in `app/scenes/Logout.tsx` + auth UI | local auth UI hidden under SSO |
| Penpot | `enable-x-auth-request-headers` flag in `PENPOT_FLAGS` + `request-email-change` RPC gated | email change RPC rejects when external IdP manages identity |
| SurfSense | `NEXT_PUBLIC_FASTAPI_BACKEND_AUTH_TYPE: SSO` env read by SPA | sign-in / sign-up forms hidden, redirect to /auth/jwt/proxy-login |
| Twenty | `useIsSsoEnabled` hook (`window._env_.AUTH_TYPE === 'SSO'`) | SignInUp form, PasswordReset, change-password button (`useCanChangePassword`), EmailField (read-only), Toggle2FA, TOTP setup page (Navigate redirect) |

## Session TTL wiring

Canonical envs in `.env`:
```
SESSION_TTL_SECONDS=28800              # 8h — access cookie / app session
SESSION_TTL_DURATION=8h                # same window, duration string
SESSION_REFRESH_TTL_SECONDS=57600      # 16h — refresh token (>= access)
SESSION_REFRESH_TTL_DURATION=16h       # same window, duration string
SESSION_COOKIE_REFRESH_SECONDS=3600    # 1h — sliding refresh interval
```

| App | Native env consumed | Type |
|-----|---------------------|------|
| Plane | `SESSION_COOKIE_AGE` ← `SESSION_TTL_SECONDS` | Access only |
| Outline | `SESSION_TTL_SECONDS` (raw, fork patch reads it) + `OAUTH_PROVIDER_*_LIFETIME` | Access (cookie) + refresh (when acting as OAuth provider) |
| Penpot | `PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE` ← `SESSION_TTL_SECONDS`, `PENPOT_AUTH_TOKEN_COOKIE_RENEWAL_MAX_AGE` ← `SESSION_COOKIE_REFRESH_SECONDS` | Access + sliding refresh |
| SurfSense | `ACCESS_TOKEN_LIFETIME_SECONDS` ← `SESSION_TTL_SECONDS`, `REFRESH_TOKEN_LIFETIME_SECONDS` ← `SESSION_REFRESH_TTL_SECONDS` | Access + refresh |
| Twenty | `ACCESS_TOKEN_EXPIRES_IN` ← `SESSION_TTL_DURATION`, `REFRESH_TOKEN_EXPIRES_IN` ← `SESSION_REFRESH_TTL_DURATION` (cookie maxAge tracks **refresh**, not access) | Access + refresh |
| oauth2-proxy | `OAUTH2_PROXY_COOKIE_EXPIRE` ← `SESSION_TTL_SECONDS`, `OAUTH2_PROXY_COOKIE_REFRESH` ← `SESSION_COOKIE_REFRESH_SECONDS` | Access + sliding refresh |

## Bypass routers (Traefik)

Each app has `*-bypass` / `*-public` / `*-static` routers at `priority=20+` that skip ForwardAuth. Restricted to static / health / webhooks / admin-bootstrap / out-of-band-sync only — never user data or mutations.

| App | Bypass paths |
|-----|-------------|
| Plane | `/god-mode`, `/api/instances`, `/auth/get-csrf-token`, `/_next/static`, `/static/`, `/site.webmanifest.json`, `/manifest.json`, `/favicon.ico`, `/robots.txt` |
| Outline | `/api/hooks`, `/_next/static`, `/static/`, `/favicon.ico`, `/robots.txt`, `/opensearch.xml`, `/manifest.webmanifest` |
| Penpot | `/js/`, `/css/`, `/images/`, `/fonts/` |
| SurfSense | `/health` (`/docs` and `/openapi.json` were previously bypassed; gated post 2026-04-30), `/_next/static`, `/zero` (bearer-token auth, separate model) |
| Twenty | `/static/`, `/assets/`, `Path(/favicon.ico)` |

## Logout

All 5 apps use the **1-layer logout** shape since 2026-04-17 — clear app session, navigate to portal host. No oauth2-proxy `/sign_out` hop (not available with current Cognito app client).

```js
const portalHost = window.location.hostname.replace(/^[^.]*\./, "foss.");
window.location.href = `${window.location.protocol}//${portalHost}/`;
```

| App | Logout file |
|-----|-------------|
| Plane | `apps/web/core/store/user/index.ts` |
| Outline | `app/stores/AuthStore.ts` + `app/scenes/Logout.tsx` |
| Penpot | `frontend/src/app/main/data/auth.cljs` |
| SurfSense | `surfsense_web/lib/auth-utils.ts` |
| Twenty | `packages/twenty-front/src/modules/auth/hooks/useAuth.ts` |

## Per-app gotchas

**Plane** — `/god-mode` is a separate session universe; ForwardAuth doesn't touch it. Postgres role for Plane needs `SUPERUSER` for first-time setup.

**Outline** — ForwardAuth integration lives **inside** `authentication.ts`, not a standalone middleware. Two earlier standalone attempts hit a request/response race on first call. Auth check order: bearer header → body.token → query.token → accessToken cookie → X-Auth-Request-Email (so subsequent requests short-circuit on the cookie).

**Penpot** — No dedicated SSO route — Reitit RPC middleware reads `X-Auth-Request-Email` as fallback after session + access-token. Auto-provisions when `enable-x-auth-request-auto-register` is in `PENPOT_FLAGS`. nginx-entrypoint substitutes runtime values into the static bundle.

**SurfSense** — Split FE/BE forces a cookie-handoff pattern (60s TTL cookies → SPA reads, stores JWT, clears). Alembic chain in fork **must** stay synced with upstream MODSetter/SurfSense — drift causes backend crash-loops with `Can't locate revision`. HuggingFace model + ffmpeg downloads on cold start (~5-10 min); persisted by `surfsense-hf-cache` named volume. Streaming/SSE must use `authenticatedFetch`, not raw `fetch()` — raw bypasses the 401 wrapper.

**Twenty** — Multi-workspace by design but SSO is single-tenant: `ASKII_WORKSPACE_SUBDOMAIN` env tells the provisioning service which workspace SSO users join. Workspace bootstrap requires native signup (with `AUTH_TYPE` overridden to non-`SSO`) for first user, then SQL UPDATE the workspace's subdomain + `displayName` to match `ASKII_WORKSPACE_SUBDOMAIN`. Init-db script auto-detects external postgres via `PG_DATABASE_URL` (function `psql_target` in `init-db.sh`) — required because the bundled image expects embedded postgres but devstack uses the shared instance. Cookie carries access + refresh tokens; cookie maxAge derives from `REFRESH_TOKEN_EXPIRES_IN`, **not** access TTL, so the browser doesn't drop the refresh alongside the expiring access token. SSO trust chain documented inline in `sso-proxy-login.controller.ts` class header.

## References

- Canonical contract: `skills/app-rules/RULES.md` (in this plugin)
- Threat model: `skills/app-rules/RULES.md` §4
- Per-app smoke tests: `docs/<app>-smoke-test.md` in each devstack repo
- Per-app integration notes: `docs/<app>.md` in each devstack repo
