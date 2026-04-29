---
description: Verify devstack SSO/ForwardAuth invariants for the current change (or a target path)
argument-hint: "[optional path: docker-compose.yml | traefik/ | app fork dir]"
---

Run the `app-rules` skill to enforce devstack invariants for apps behind oauth2-proxy + Traefik ForwardAuth.

Target: $ARGUMENTS

Steps:
1. Invoke the `sso-rules:app-rules` skill via the Skill tool.
2. Read the canonical contract at `skills/app-rules/RULES.md` inside this plugin.
3. If `$ARGUMENTS` is provided, scope the check to that path. Otherwise, scope to:
   - the current git diff (staged + unstaged), and
   - any `docker-compose.yml`, `traefik/`, or fork repo (plane/outline/penpot/surfsense/twenty) changes.
4. For each in-scope change, verify against:
   - §1 Universal invariants (SSO chain, bypass routers, build pattern, logout, session TTL, cookie security flags, compose hygiene)
   - §2 App matrix (per-app shape columns)
   - §3 Adding-a-new-app checklist (only if a new app is being introduced)
   - §4 Threat model — confirm rows 1–6 and 12 (the security-critical set) are honored
5. Print **only** the 16-row table from `SKILL.md` §5. Each Status cell is exactly `✅`, `❌`, or `n/a` (the latter only on the rows whose Notes column explicitly allows it). Notes carry a file:line citation on ✅ or a file:line + concrete fix on ❌. End the table with `**All invariants hold.**` or `**N violations.**` followed by a single sentence calling out the most load-bearing fix first.
6. If nothing in scope touches SSO/ForwardAuth surface, write a one-sentence "no in-scope changes" line instead of the table — do not invent findings.

For a multi-app sweep across every app at once (not scoped to a diff), use `/sso-rules:audit-all-apps`.
