#!/usr/bin/env bash
# provider-failover.sh — Automatic AI provider failover with round-robin rotation.
#
# Sits inside the gateway cascade: when a provider hits rate limits (429),
# quota errors (402), or any upstream capacity issue, this script ensures
# the next healthy provider in the rotation is selected without losing the
# skill prompt.
#
# The prompt itself is NEVER stored here — the workflow's cascade (aeon.yml
# lines ~991-1013) passes $PROMPT to each provider attempt. This script
# only decides WHICH provider to try next and tracks rotation state.
#
# State file: $AEON_FAILOVER_STATE (default: /tmp/aeon-failover.json)
# Tracks: last_used, last_failed, failure_count per provider, rotation_index.
#
# Usage:
#   # List healthy providers in priority order (respects GATEWAY_ORDER)
#   AEON_LIST_HEALTHY=1 bash "$FAILOVER"
#
#   # Mark a provider as failed (called by the cascade on 429/402)
#   bash "$FAILOVER" mark-failed <provider-name> "<error-signature>"
#
#   # Get the next provider in round-robin rotation
#   bash "$FAILOVER" next
#
#   # Reset failure state for a provider (called on success)
#   bash "$FAILOVER" mark-recovered <provider-name>
#
set -euo pipefail

STATE_FILE="${AEON_FAILOVER_STATE:-/tmp/aeon-failover.json}"
GATEWAY_ORDER="${GATEWAY_ORDER:-claude anthropic openrouter bankr usepod venice surplus grok glm}"

# --- helpers ----------------------------------------------------------------

init_state() {
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<'EOF'
{
  "rotation_index": 0,
  "providers": {}
}
EOF
  fi
}

# Check if a provider's secret is configured
provider_available() {
  local provider="$1"
  case "$provider" in
    claude)     [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ;;
    anthropic)  [ -n "${ANTHROPIC_API_KEY:-}" ] ;;
    openrouter) [ -n "${OPENROUTER_API_KEY:-}" ] ;;
    bankr)      [ -n "${BANKR_LLM_KEY:-}" ] ;;
    usepod)     [ -n "${USEPOD_TOKEN:-}" ] ;;
    venice)     [ -n "${VENICE_API_KEY:-}" ] ;;
    surplus)    [ -n "${SURPLUS_API_KEY:-}" ] ;;
    grok)       [ -n "${XAI_API_KEY:-}" ] ;;
    glm)        [ -n "${GLM_API_KEY:-}" ] ;;
    *) false ;;
  esac
}

# Get the ordered list of available providers (respects GATEWAY_ORDER)
get_available_providers() {
  local providers=()
  for provider in $GATEWAY_ORDER; do
    if provider_available "$provider"; then
      providers+=("$provider")
    fi
  done
  printf '%s\n' "${providers[@]}"
}

# Mark a provider as failed (called when a provider returns 429/402/etc.)
mark_failed() {
  local provider="$1"
  local error="${2:-unknown}"
  init_state

  local tmp
  tmp=$(mktemp)
  # Use node for reliable JSON manipulation
  node -e "
    const fs = require('fs');
    const state = JSON.parse(fs.readFileSync('$STATE_FILE', 'utf8'));
    const now = Date.now();
    if (!state.providers['$provider']) state.providers['$provider'] = { failures: 0, last_error: '', last_failed: 0 };
    state.providers['$provider'].failures += 1;
    state.providers['$provider'].last_error = \`'$error'.slice(0, 200);
    state.providers['$provider'].last_failed = now;
    fs.writeFileSync('$tmp', JSON.stringify(state, null, 2));
  " 2>/dev/null || true
  mv "$tmp" "$STATE_FILE" 2>/dev/null || true
  echo "::warning::Provider '$provider' marked as failed: $error" >&2
}

# Mark a provider as recovered (called after a successful run)
mark_recovered() {
  local provider="$1"
  init_state

  local tmp
  tmp=$(mktemp)
  node -e "
    const fs = require('fs');
    const state = JSON.parse(fs.readFileSync('$STATE_FILE', 'utf8'));
    if (state.providers['$provider']) {
      state.providers['$provider'].failures = 0;
      state.providers['$provider'].last_error = '';
    }
    fs.writeFileSync('$tmp', JSON.stringify(state, null, 2));
  " 2>/dev/null || true
  mv "$tmp" "$STATE_FILE" 2>/dev/null || true
  echo "::notice::Provider '$provider' marked as recovered" >&2
}

# Get the next provider in round-robin rotation, skipping recently failed ones
# A provider is "recently failed" if it failed within the last COOLDOWN_SECS
get_next_provider() {
  local cooldown="${AEON_FAILOVER_COOLDOWN:-1800}" # 30 minutes
  local providers=()

  # Build available list
  for provider in $GATEWAY_ORDER; do
    if provider_available "$provider"; then
      providers+=("$provider")
    fi
  done

  if [ ${#providers[@]} -eq 0 ]; then
    echo "direct"
    return
  fi

  init_state

  # Get current rotation index and find the next healthy provider
  local result
  result=$(node -e "
    const fs = require('fs');
    const state = JSON.parse(fs.readFileSync('$STATE_FILE', 'utf8'));
    const now = Date.now();
    const cooldown_ms = ${cooldown} * 1000;
    const providers = ${providers[*]@Q};
    const arr = providers.split(' ');

    let idx = (state.rotation_index || 0) % arr.length;
    let attempts = 0;
    let selected = arr[idx];

    // Try each provider in rotation order, skip those failed within cooldown
    while (attempts < arr.length) {
      const p = arr[idx];
      const info = state.providers[p];
      if (!info || (now - (info.last_failed || 0)) > cooldown_ms) {
        selected = p;
        state.rotation_index = idx;
        break;
      }
      idx = (idx + 1) % arr.length;
      attempts++;
      selected = arr[idx];
    }

    state.rotation_index = idx;
    fs.writeFileSync('$STATE_FILE', JSON.stringify(state, null, 2));
    console.log(selected);
  " 2>/dev/null) || echo "${providers[0]}"

  echo "$result"
}

# List healthy providers (those not recently failed)
list_healthy() {
  local cooldown="${AEON_FAILOVER_COOLDOWN:-1800}"
  init_state

  node -e "
    const fs = require('fs');
    const state = JSON.parse(fs.readFileSync('$STATE_FILE', 'utf8'));
    const now = Date.now();
    const cooldown_ms = ${cooldown} * 1000;
    const providers = '${GATEWAY_ORDER}'.split(' ').filter(p => {
      const info = state.providers[p];
      return !info || (now - (info.last_failed || 0)) > cooldown_ms;
    }).join(' ');
    console.log(providers);
  " 2>/dev/null || echo "$GATEWAY_ORDER"
}

# --- main dispatch ----------------------------------------------------------

case "${1:-}" in
  list-healthy|list_healthy|"")
    init_state
    list_healthy
    ;;
  mark-failed)
    shift
    mark_failed "$1" "${2:-unknown error}"
    ;;
  mark-recovered)
    shift
    mark_recovered "$1"
    ;;
  next)
    get_next_provider
    ;;
  *)
    # Default: list healthy providers (used by AEON_LIST_CANDIDATES path)
    init_state
    list_healthy
    ;;
esac
