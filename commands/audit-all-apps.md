---
description: Run the SSO security audit across every app in the devstack at once (Plane, Outline, Penpot, SurfSense, Twenty)
---

Run the `app-rules` skill in **multi-app sweep mode** — verify every universal invariant against every app currently behind oauth2-proxy + Traefik ForwardAuth, not just the diff in the current change.

Use this when:
- Onboarding to a new clone of the devstack — confirm the deployment matches the contract
- Periodic security review (monthly / pre-release)
- After a multi-app refactor (e.g., a Session TTL env-name change touched all of them)
- After landing a new app — confirm it joins the contract without regressing the others

Steps:

1. Invoke the `sso-rules:app-rules` skill via the Skill tool.
2. Read the canonical contract at `skills/app-rules/RULES.md` inside this plugin — `§1` (universal invariants), `§2` (app matrix), `§4` (threat model + per-threat closing invariants).
3. **Do not scope to a git diff.** Scope to every app's surface:
   - `docker-compose.yml` — every service block, every Traefik label
   - `traefik/dynamic/*.yml` — TLS / cert config
   - `Makefile` + `options.mk` — compose hygiene
   - Each fork's auth code (per `RULES.md` §2 ground-truth file paths) — read at least the SSO middleware/controller and the SPA logout handler
4. Verify each of the 16 invariants in `SKILL.md` §5 across **all 5 apps**. For rows that apply only to some apps (e.g., refresh TTL — SurfSense / Twenty / Outline OAuth provider only; sliding-refresh — oauth2-proxy + Penpot only), use `n/a` for the apps that don't apply per the row's Notes guidance.
5. Print **only** the 16-row table. Each Status cell is exactly `✅`, `❌`, or `n/a`. The Notes cell carries per-app file:line evidence — list one app per app with its own citation, comma-separated, so a reviewer can see at a glance which apps were verified and which (if any) failed.
6. End the table with:
   - `**All invariants hold across all 5 apps.**` if every cell is ✅ or `n/a`
   - `**N violations across <list-of-affected-apps>.**` followed by a single sentence calling out the most load-bearing fix first. Rows 1–6 and 12 are the security-critical ones — flag any failure there ahead of the operational rows.
7. If a fork's source isn't on disk under `/Users/apple/Documents/devstack/<app>/` (typical layout) or wherever the user's clone lives, mark that app's rows as `?` for invariants that need fork-side grep, and explicitly say which file you couldn't read. Do not speculate.

Output is the strict table — no preamble, no PASS/FAIL prose sections, no per-row narrative. The Notes column carries the evidence and the fix.
