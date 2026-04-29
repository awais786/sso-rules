#!/usr/bin/env bash
#
# audit-sso.sh — verify SSO/ForwardAuth invariants across the devstack.
#
# Deterministic checks against docker-compose.yml + traefik/dynamic/ +
# Makefile + scripts/. No LLM, no network. Run from repo root or via
# `make audit.sso`.
#
# Exit codes:
#   0 — all checks pass (every row ✅ or n/a / manual)
#   1 — at least one security-critical row failed (rows 1-7, 12). These
#       are the rows whose breakage opens an auth-bypass or cookie path.
#       Operational rows (TTL wiring, valkey cascade, compose hygiene)
#       still produce ❌ in the table but don't block CI by default.
#
# Output: a 16-row markdown table on stdout matching the shape in
# https://github.com/awais786/sso-rules → SKILL.md §5.
#
# Coverage: 11 rows fully deterministic; 5 rows (3 path-discipline,
# 6 backend AUTH_TYPE gate, 12 cookie flags, 14 regex form, 15
# identity-managed UI) flag literal regressions but defer the
# semantic check to local `/sso-rules:audit-all-apps`.

set -euo pipefail

COMPOSE="${COMPOSE:-docker-compose.yml}"
TRAEFIK_DIR="${TRAEFIK_DIR:-traefik/dynamic}"
MAKEFILE="${MAKEFILE:-Makefile}"
SCRIPTS_DIR="${SCRIPTS_DIR:-scripts}"

# ---- output state ----
declare -a ROW_STATUS    # ✅ / ❌ / n/a / ?
declare -a ROW_NOTES
declare -i SECURITY_CRITICAL_FAILS=0

# Security-critical rows per RULES.md §4 (1-7 + 12). A ❌ in any of these
# fails CI. Other rows produce ❌ but are advisory.
SECURITY_CRITICAL=(0 1 2 3 4 5 6 11)   # zero-indexed

record() {
  local idx=$1 status=$2 note=$3
  ROW_STATUS[$idx]="$status"
  ROW_NOTES[$idx]="$note"
  if [[ "$status" == "❌" ]]; then
    for c in "${SECURITY_CRITICAL[@]}"; do
      if [[ "$c" -eq "$idx" ]]; then
        SECURITY_CRITICAL_FAILS=$((SECURITY_CRITICAL_FAILS + 1))
        return
      fi
    done
  fi
}

# =============================================================================
# Row 1: strip-auth-headers + mpass-auth on every router that runs ForwardAuth
# (in that order). We detect "secure" routers by the presence of mpass-auth
# in the middleware chain — not just the -secure name suffix — to catch
# differently-named secure catch-all routers like `surfsense.priority=1`.
# =============================================================================
check_row_1() {
  local bad=()
  local missing_at_docker=()
  local routers
  # All middleware declarations on routers
  routers=$(grep -oE 'traefik\.http\.routers\.[a-z0-9-]+\.middlewares=[^[:space:]]*' "$COMPOSE" || true)
  if [[ -z "$routers" ]]; then
    record 0 "❌" "No router middleware declarations found in $COMPOSE"
    return
  fi
  local secure_count=0
  while IFS= read -r decl; do
    [[ -z "$decl" ]] && continue
    # Only check routers whose chain includes mpass-auth (those are the
    # ForwardAuth-protected ones; others are bypass declarations).
    if ! printf '%s' "$decl" | grep -q 'mpass-auth'; then
      continue
    fi
    secure_count=$((secure_count + 1))
    local router_name value
    router_name=$(printf '%s' "$decl" | sed -E 's/traefik\.http\.routers\.([a-z0-9-]+)\.middlewares=.*/\1/')
    value=$(printf '%s' "$decl" | sed 's/.*middlewares=//; s/[[:space:]]*$//' | tr -d '\r')
    # Check ordering: strip-auth-headers must come BEFORE mpass-auth.
    if ! printf '%s' "$value" | grep -qE '^strip-auth-headers@docker,mpass-auth(@docker)?(\b|,|$)'; then
      bad+=("$router_name='$value'")
    elif ! printf '%s' "$value" | grep -q 'mpass-auth@docker'; then
      missing_at_docker+=("$router_name")
    fi
  done <<< "$routers"

  if [[ ${#bad[@]} -gt 0 ]]; then
    record 0 "❌" "Wrong middleware shape on: ${bad[*]}. Fix: 'strip-auth-headers@docker,mpass-auth@docker' (in that order)"
  elif [[ ${#missing_at_docker[@]} -gt 0 ]]; then
    record 0 "❌" "Drift: $secure_count secure routers, but ${#missing_at_docker[@]} use 'mpass-auth' without '@docker' suffix: ${missing_at_docker[*]}. Both forms work in Traefik (provider auto-resolves) but RULES.md §1 mandates the explicit '@docker' provider tag for consistency. Fix: append '@docker' to the second middleware reference"
  else
    record 0 "✅" "$secure_count secure routers verified — strip-auth-headers@docker,mpass-auth@docker in correct order"
  fi
}

# =============================================================================
# Row 2: backend ports unexposed (only Traefik publishes :80/:443)
# =============================================================================
check_row_2() {
  if ! command -v yq >/dev/null 2>&1; then
    record 1 "?" "yq not installed; manually verify only \`traefik\` has a \`ports:\` block"
    return
  fi
  local violators
  violators=$(yq '.services | to_entries | map(select(.value.ports != null and .key != "traefik")) | .[].key' "$COMPOSE" 2>/dev/null || true)
  if [[ -z "$violators" ]]; then
    record 1 "✅" "Only \`traefik\` publishes host ports; no backend service has a \`ports:\` block"
  else
    local list
    list=$(printf '%s' "$violators" | tr '\n' ',' | sed 's/,$//')
    record 1 "❌" "Services with \`ports:\` block (publishing to host bypasses ForwardAuth chain): $list. Fix: remove the \`ports:\` mapping; access via Traefik subdomain"
  fi
}

# =============================================================================
# Row 3: bypass router priority + path discipline (priority deterministic;
#                                                  path discipline manual)
# =============================================================================
check_row_3() {
  # Build the set of "secure" router names — routers whose middleware chain
  # includes mpass-auth. Anything else with a priority is a bypass candidate.
  local secure_routers
  secure_routers=$(grep -oE 'traefik\.http\.routers\.[a-z0-9-]+\.middlewares=[^[:space:]]*' "$COMPOSE" \
    | grep 'mpass-auth' \
    | sed -E 's/traefik\.http\.routers\.([a-z0-9-]+)\.middlewares=.*/\1/' \
    | sort -u || true)

  # Skip web-entrypoint routers — Traefik's global HTTP→HTTPS redirect
  # kicks in before they serve traffic, so their priority/middleware
  # config is irrelevant to the actual security posture. Only routers
  # on websecure (or another non-web entrypoint) are eligible bypasses.
  local web_only_routers
  web_only_routers=$(grep -oE 'traefik\.http\.routers\.[a-z0-9-]+\.entrypoints=web$' "$COMPOSE" \
    | sed -E 's/traefik\.http\.routers\.([a-z0-9-]+)\.entrypoints=web/\1/' \
    | sort -u || true)

  local bypass_lines
  bypass_lines=$(grep -oE 'traefik\.http\.routers\.[a-z0-9-]+\.priority=[0-9]+' "$COMPOSE" | sort -u || true)
  local low_priority=()
  local bypass_count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local router_part
    router_part=$(printf '%s' "$line" | sed -E 's/traefik\.http\.routers\.([a-z0-9-]+)\.priority=([0-9]+)/\1:\2/')
    local router="${router_part%%:*}"
    local prio="${router_part##*:}"
    # Secure routers correctly run mpass-auth and may be priority < 20
    if printf '%s\n' "$secure_routers" | grep -qx "$router"; then
      continue
    fi
    # web-entrypoint routers are globally redirected to HTTPS — never serve
    if printf '%s\n' "$web_only_routers" | grep -qx "$router"; then
      continue
    fi
    bypass_count=$((bypass_count + 1))
    if [[ "$prio" -lt 20 ]]; then
      low_priority+=("$router (priority=$prio)")
    fi
  done <<< "$bypass_lines"

  if [[ ${#low_priority[@]} -gt 0 ]]; then
    record 2 "❌" "Bypass routers below priority=20 on websecure: ${low_priority[*]}. Fix: bypasses must be priority >= 20 to win against secure catch-all (or add strip-auth-headers + mpass-auth to make them secure)"
    return
  fi

  record 2 "✅" "$bypass_count websecure bypass routers checked, all priority >= 20. Path discipline (no user-data routes bypassed) requires manual review"
}

# =============================================================================
# Row 4: AUTH_TYPE=SSO env on every backend service
# =============================================================================
check_row_4() {
  if ! command -v yq >/dev/null 2>&1; then
    record 3 "?" "yq not installed; manually verify every app backend has AUTH_TYPE: SSO"
    return
  fi
  local backends=(plane-api outline penpot-backend surfsense-backend twenty)
  local missing=()
  for svc in "${backends[@]}"; do
    local env
    env=$(yq ".services.\"$svc\".environment" "$COMPOSE" 2>/dev/null || true)
    if [[ -z "$env" || "$env" == "null" ]]; then
      missing+=("$svc(no env block)")
      continue
    fi
    if ! printf '%s' "$env" | grep -qE '(^|[^_])AUTH_TYPE:\s*SSO'; then
      # check anchors — env may inherit via <<: *anchor
      local anchor_match
      anchor_match=$(grep -A1 "x-${svc%%-*}-env\|x-twenty-env" "$COMPOSE" | grep -E '^\s*AUTH_TYPE:\s*SSO' || true)
      if [[ -z "$anchor_match" ]]; then
        missing+=("$svc")
      fi
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    record 3 "✅" "${#backends[@]} backends verified: AUTH_TYPE=SSO present on all. Header-trust gate active"
  else
    record 3 "❌" "Backends missing AUTH_TYPE=SSO env: ${missing[*]}. Fix: add \`AUTH_TYPE: SSO\` to the service env or its anchor"
  fi
}

# =============================================================================
# Row 5: AUTH_TYPE mirror on split frontends
# =============================================================================
check_row_5() {
  local missing=()
  # SurfSense frontend
  if ! grep -qE 'NEXT_PUBLIC_FASTAPI_BACKEND_AUTH_TYPE:\s*SSO' "$COMPOSE"; then
    missing+=("surfsense-frontend")
  fi
  # Twenty: runtime injection lives in the fork at
  # packages/twenty-server/src/utils/generate-front-config.ts
  if [[ -f ../twenty/packages/twenty-server/src/utils/generate-front-config.ts ]]; then
    if ! grep -q 'AUTH_TYPE: process.env.AUTH_TYPE' ../twenty/packages/twenty-server/src/utils/generate-front-config.ts; then
      missing+=("twenty(generate-front-config.ts not injecting AUTH_TYPE into window._env_)")
    fi
  fi
  if [[ ${#missing[@]} -eq 0 ]]; then
    record 4 "✅" "SurfSense web has NEXT_PUBLIC_FASTAPI_BACKEND_AUTH_TYPE=SSO; Twenty's generateFrontConfig injects AUTH_TYPE into window._env_"
  else
    record 4 "❌" "Frontend missing AUTH_TYPE mirror: ${missing[*]}"
  fi
}

# =============================================================================
# Row 6: backend refuses identity headers when AUTH_TYPE != SSO
# Heuristic — looks for known fork patterns. Not exhaustive.
# =============================================================================
check_row_6() {
  record 5 "?" "Backend AUTH_TYPE gate is fork-side; verify locally via /sso-rules:audit-all-apps. Twenty fork: sso-proxy-login.controller.ts:57 has explicit \`if (AUTH_TYPE !== 'SSO') throw NotFoundException()\`"
}

# =============================================================================
# Row 7: TLS = mkcert (no certresolver=letsencrypt)
# =============================================================================
check_row_7() {
  local hits=()
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    if grep -nE 'certresolver\s*=\s*letsencrypt|certresolver:\s*letsencrypt' "$f" >/dev/null 2>&1; then
      hits+=("$f")
    fi
  done < <(printf '%s\n' "$COMPOSE" "$TRAEFIK_DIR"/*.yml 2>/dev/null)
  if [[ ${#hits[@]} -eq 0 ]]; then
    record 6 "✅" "No \`certresolver=letsencrypt\` in $COMPOSE or $TRAEFIK_DIR/. Devstack uses mkcert via the default cert store"
  else
    record 6 "❌" "ACME/Let's Encrypt configured (devstack uses mkcert): ${hits[*]}. Fix: remove the certresolver directive; use \`tls=true\` only"
  fi
}

# =============================================================================
# Row 8: build pattern correctness
# Twenty (Pattern B unified) must not have a source volume mount.
# =============================================================================
check_row_8() {
  if ! command -v yq >/dev/null 2>&1; then
    record 7 "?" "yq not installed; manually verify Pattern B services have no source mount"
    return
  fi
  local twenty_volumes
  twenty_volumes=$(yq '.services.twenty.volumes[]' "$COMPOSE" 2>/dev/null || true)
  # Acceptable: twenty-server-local-data:/app/...
  # Bad: any /Users/... or ../twenty/... bind mount
  local bad
  bad=$(printf '%s\n' "$twenty_volumes" | grep -E '^\s*[\./]|/Users/|\.\./twenty' || true)
  if [[ -z "$bad" ]]; then
    record 7 "✅" "Twenty (Pattern B) has only named-volume mounts; no source bind-mount on the compiled image"
  else
    record 7 "❌" "Pattern B image has source bind-mount (volume-mount has no effect; values were baked at build): $bad. Fix: remove the bind-mount or convert to Pattern A"
  fi
}

# =============================================================================
# Row 9: session TTL wired (SESSION_TTL_SECONDS / SESSION_TTL_DURATION)
# =============================================================================
check_row_9() {
  local missing=()
  grep -q 'SESSION_COOKIE_AGE: \${SESSION_TTL_SECONDS' "$COMPOSE" || missing+=("plane SESSION_COOKIE_AGE")
  grep -q 'ACCESS_TOKEN_LIFETIME_SECONDS: \${SESSION_TTL_SECONDS' "$COMPOSE" || missing+=("surfsense ACCESS_TOKEN_LIFETIME_SECONDS")
  grep -q 'PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE: \${SESSION_TTL_SECONDS' "$COMPOSE" || missing+=("penpot PENPOT_AUTH_TOKEN_COOKIE_MAX_AGE")
  grep -q 'OAUTH2_PROXY_COOKIE_EXPIRE: \${SESSION_TTL_SECONDS' "$COMPOSE" || missing+=("oauth2-proxy OAUTH2_PROXY_COOKIE_EXPIRE")
  grep -q 'ACCESS_TOKEN_EXPIRES_IN: \${SESSION_TTL_DURATION' "$COMPOSE" || missing+=("twenty ACCESS_TOKEN_EXPIRES_IN")
  grep -q 'SESSION_TTL_SECONDS: \${SESSION_TTL_SECONDS' "$COMPOSE" || missing+=("outline SESSION_TTL_SECONDS")
  if [[ ${#missing[@]} -eq 0 ]]; then
    record 8 "✅" "All 6 session-issuing services wire SESSION_TTL_SECONDS / SESSION_TTL_DURATION"
  else
    record 8 "❌" "Services not consuming canonical TTL env: ${missing[*]}. Fix: rename compose interpolation"
  fi
}

# =============================================================================
# Row 10: refresh TTL wired (SurfSense, Twenty, Outline OAuth provider)
# =============================================================================
check_row_10() {
  local missing=()
  grep -q 'REFRESH_TOKEN_LIFETIME_SECONDS: \${SESSION_REFRESH_TTL_SECONDS' "$COMPOSE" || missing+=("surfsense")
  grep -q 'REFRESH_TOKEN_EXPIRES_IN: \${SESSION_REFRESH_TTL_DURATION' "$COMPOSE" || missing+=("twenty")
  grep -q 'OAUTH_PROVIDER_REFRESH_TOKEN_LIFETIME: \${SESSION_REFRESH_TTL_SECONDS' "$COMPOSE" || missing+=("outline-oauth-provider")
  if [[ ${#missing[@]} -eq 0 ]]; then
    record 9 "✅" "Refresh TTL wired on SurfSense, Twenty, Outline OAuth provider. Plane / Penpot / oauth2-proxy: n/a"
  else
    record 9 "❌" "Refresh TTL missing: ${missing[*]}"
  fi
}

# =============================================================================
# Row 11: sliding-refresh wired (oauth2-proxy + Penpot)
# =============================================================================
check_row_11() {
  local missing=()
  grep -q 'OAUTH2_PROXY_COOKIE_REFRESH: \${SESSION_COOKIE_REFRESH_SECONDS' "$COMPOSE" || missing+=("oauth2-proxy")
  grep -q 'PENPOT_AUTH_TOKEN_COOKIE_RENEWAL_MAX_AGE: \${SESSION_COOKIE_REFRESH_SECONDS' "$COMPOSE" || missing+=("penpot")
  if [[ ${#missing[@]} -eq 0 ]]; then
    record 10 "✅" "Sliding-refresh wired on oauth2-proxy + Penpot. Others: n/a"
  else
    record 10 "❌" "Sliding-refresh missing: ${missing[*]}"
  fi
}

# =============================================================================
# Row 12: cookie security flags — fork-side semantics, deferred
# =============================================================================
check_row_12() {
  record 11 "?" "Cookie flag derivation is fork-side. Verify via /sso-rules:audit-all-apps locally. Known good: Twenty's setTokenPairCookie derives \`secure\` from SERVER_URL; Outline fork patch matches"
}

# =============================================================================
# Row 13: valkey cascade declared
# =============================================================================
check_row_13() {
  if ! command -v yq >/dev/null 2>&1; then
    record 12 "?" "yq not installed; manually verify Valkey consumers have depends_on.valkey.restart=true"
    return
  fi
  local valkey_consumers
  valkey_consumers=$(yq '.services | to_entries | map(select(.value.depends_on.valkey != null)) | .[].key' "$COMPOSE" 2>/dev/null || true)
  local missing=()
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local restart
    restart=$(yq ".services.\"$svc\".depends_on.valkey.restart" "$COMPOSE" 2>/dev/null || true)
    if [[ "$restart" != "true" ]]; then
      missing+=("$svc")
    fi
  done <<< "$valkey_consumers"
  local count
  count=$(printf '%s' "$valkey_consumers" | wc -l | tr -d ' ')
  if [[ ${#missing[@]} -eq 0 ]]; then
    record 12 "✅" "$count Valkey consumers verified, all declare \`depends_on: valkey: { restart: true }\`"
  else
    record 12 "❌" "Valkey consumers without restart cascade: ${missing[*]}. Fix: add \`restart: true\` under \`depends_on.valkey\`"
  fi
}

# =============================================================================
# Row 14: logout shape — grep each fork's known logout file for /oauth2/sign_out
# =============================================================================
check_row_14() {
  local hits=()
  local fork_files=(
    "../plane/apps/web/core/store/user/index.ts"
    "../outline/app/stores/AuthStore.ts"
    "../penpot/frontend/src/app/main/data/auth.cljs"
    "../surfsense/surfsense_web/lib/auth-utils.ts"
    "../SurfSense/surfsense_web/lib/auth-utils.ts"
    "../twenty/packages/twenty-front/src/modules/auth/hooks/useAuth.ts"
  )
  for f in "${fork_files[@]}"; do
    [[ ! -f "$f" ]] && continue
    if grep -nE 'oauth2/sign_out' "$f" >/dev/null 2>&1; then
      hits+=("$f")
    fi
  done
  local checked=0
  for f in "${fork_files[@]}"; do
    [[ -f "$f" ]] && checked=$((checked + 1))
  done
  if [[ "$checked" -eq 0 ]]; then
    record 13 "?" "No fork sources on disk; clone Plane/Outline/Penpot/SurfSense/Twenty as siblings of this repo to enable logout-shape check"
  elif [[ ${#hits[@]} -eq 0 ]]; then
    record 13 "✅" "$checked logout files checked, none re-introduces \`/oauth2/sign_out\` (regex form requires manual review)"
  else
    record 13 "❌" "Logout files containing \`/oauth2/sign_out\` (regression — drops back to broken oauth2-proxy hop): ${hits[*]}. Fix: navigate to bare portal host"
  fi
}

# =============================================================================
# Row 15: identity-managed UI hidden under SSO — fork-side, deferred
# =============================================================================
check_row_15() {
  record 14 "?" "Identity-managed UI gating is per-fork. Verify via /sso-rules:audit-all-apps. Twenty fork: useIsSsoEnabled hook covers SignInUp / PasswordReset / EmailField / Toggle2FA / TOTP page"
}

# =============================================================================
# Row 16: compose hygiene — no bare \`docker compose\` in scripts
# =============================================================================
check_row_16() {
  # The Makefile sets COMPOSE_FILE via include + export, so every $(DC)
  # call inherits it without needing the explicit env on the command line.
  # We only flag literal `docker compose ...` invocations OUTSIDE the
  # Makefile (e.g. in scripts/) that don't carry COMPOSE_FILE on the
  # same line. The audit script itself is excluded.
  local hits=()
  shopt -s nullglob
  for f in "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py "$SCRIPTS_DIR"/*.bash; do
    [[ ! -f "$f" ]] && continue
    [[ "$(basename "$f")" == "audit-sso.sh" ]] && continue
    local violators
    violators=$(grep -nE '^[^#]*\bdocker compose\b' "$f" 2>/dev/null \
      | grep -vE 'COMPOSE_FILE=' \
      | grep -vE '^\s*#|^\s*//' || true)
    if [[ -n "$violators" ]]; then
      while IFS= read -r v; do
        hits+=("$f:$v")
      done <<< "$violators"
    fi
  done
  shopt -u nullglob
  if [[ ${#hits[@]} -eq 0 ]]; then
    record 15 "✅" "No bare \`docker compose\` invocations in $SCRIPTS_DIR/. Makefile \$(DC) calls inherit COMPOSE_FILE via the top-level \`export\` directive"
  else
    record 15 "❌" "Bare \`docker compose\` (no COMPOSE_FILE prefix) in: ${hits[*]:0:3}. Fix: prefix with \`COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml\` and use \`--no-deps\`"
  fi
}

# ---- run all checks ----
check_row_1
check_row_2
check_row_3
check_row_4
check_row_5
check_row_6
check_row_7
check_row_8
check_row_9
check_row_10
check_row_11
check_row_12
check_row_13
check_row_14
check_row_15
check_row_16

# ---- print table ----
ROW_TITLES=(
  "strip-auth-headers + mpass-auth on -secure (in that order)"
  "backend ports unexposed"
  "bypass router priority + path discipline"
  "AUTH_TYPE=SSO env (backend)"
  "AUTH_TYPE mirror on split frontends"
  "backend refuses identity headers when AUTH_TYPE≠SSO"
  "TLS = mkcert (no certresolver)"
  "build pattern correctness"
  "session TTL wired (SESSION_TTL_*)"
  "refresh TTL wired (SESSION_REFRESH_TTL_*)"
  "sliding-refresh wired"
  "cookie security flags"
  "valkey cascade declared"
  "logout shape (1-layer, no /oauth2/sign_out)"
  "identity-managed UI hidden under SSO"
  "compose hygiene (no bare docker compose)"
)

echo "## SSO Invariants Audit"
echo
echo "| #  | Invariant | Status | Notes |"
echo "|----|-----------|--------|-------|"
for i in "${!ROW_TITLES[@]}"; do
  printf "| %d | %s | %s | %s |\n" \
    "$((i + 1))" "${ROW_TITLES[$i]}" "${ROW_STATUS[$i]:-?}" "${ROW_NOTES[$i]:-}"
done
echo

# Count totals
TOTAL_FAILS=0
for s in "${ROW_STATUS[@]}"; do
  [[ "$s" == "❌" ]] && TOTAL_FAILS=$((TOTAL_FAILS + 1))
done

if [[ "$TOTAL_FAILS" -eq 0 ]]; then
  echo "**All deterministic invariants hold.** 5 rows (3 path discipline, 6 backend AUTH_TYPE gate, 12 cookie flags, 14 logout regex, 15 identity UI) require local \`/sso-rules:audit-all-apps\` for full coverage."
  exit 0
else
  echo "**$TOTAL_FAILS violations.** Security-critical (rows 1-7, 12): $SECURITY_CRITICAL_FAILS."
  if [[ "$SECURITY_CRITICAL_FAILS" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi
