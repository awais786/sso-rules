# sso-rules-plugin

Claude Code skill that enforces SSO + bypass + build-pattern invariants on every app behind oauth2-proxy + Traefik ForwardAuth in a `foss-server-bundle-devstack`.

Targets the four-app stack — **Plane**, **Outline**, **Penpot**, **SurfSense** — and any new app added behind ForwardAuth.

## What it does

When you edit `docker-compose.yml`, `traefik/`, or any fork repo, run `/app-rules` (or invoke the skill from the Skill tool) and it will:

- Verify every `-secure` Traefik router carries `strip-auth-headers@docker, mpass-auth@docker` in that order
- Check bypass routers for priority + path discipline (no user-data routes bypassed)
- Confirm backend ports are internal-only (no host publish)
- Confirm `AUTH_TYPE=SSO` env on every app container
- Flag `tls.certresolver=letsencrypt` (devstack uses mkcert)
- Verify session TTL env (`SESSION_TTL_SECONDS` / `SESSION_TTL_DURATION`) is wired into each app's native config
- Verify Valkey consumers declare `depends_on: valkey: { restart: true }`
- Verify logout shape (1-layer with portal-host regex)
- Verify compose hygiene (`COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml ... --no-deps` everywhere)

For new app intake, walks the "Adding a new app" 10-item checklist in `RULES.md` §3.

## Install

```
/plugin marketplace add awais786/sso-rules
/plugin install sso-rules
```

After install:

```
/app-rules
```

## Use cases

- **Editing `docker-compose.yml`** — verify a new env / router / volume mount doesn't break an invariant
- **Editing `traefik/` labels** — verify ForwardAuth chain is intact
- **Editing a fork repo** (Plane, Outline, Penpot, SurfSense) — verify auth integration shape stays canonical
- **Adding a 5th app** — walk the new-app checklist before merging
- **Reviewing a teammate's PR** — quick invariant scan before approval

## Files

```
sso-rules/
├── .claude-plugin/plugin.json     # plugin manifest
├── marketplace.json                # marketplace listing
├── skills/
│   └── app-rules/
│       ├── SKILL.md                # the skill itself (loaded by Claude Code)
│       └── RULES.md                # canonical rules doc (linked from SKILL.md)
└── README.md                       # this file
```

## Provenance

Rules distilled from the foss-server-bundle-devstack `CLAUDE.md` + `docs/mpass-sso*.md` + per-app design docs. The mpass SSO rollout (April 2026) produced these as deployment invariants.

For full narrative + diagnosis tables, see the source devstack's `CLAUDE.md`.

## License

MIT
