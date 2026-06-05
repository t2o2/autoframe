#!/usr/bin/env bash
# workflow-loader.sh — parse workflow.toml and export WF_* stage variables
#
# Source this file after the stage .env has been sourced (so LOCK_PREFIX is set).
# On success, exports WF_* variables for the current stage.
# On any failure (missing file, parse error, stage not found), logs a warning
# and returns without exporting — the caller's .env values remain authoritative.
#
# Required env var (set by stage .env before sourcing):
#   LOCK_PREFIX  — lowercase stage identifier, e.g. "process" (used as the lookup key)
#
# Optional env vars:
#   WORKFLOW_TOML  — explicit path to workflow.toml (overrides discovery)
#
# Exported on success (one set per stage):
#   WF_POLL_STATES_GQL         WF_POLL_STATES_DISPLAY   WF_CLAIM_STATE
#   WF_DONE_STATE               WF_REVERT_STATE           WF_PASS_STATE
#   WF_FAIL_STATE               WF_SLASH_COMMAND          WF_LOCK_PREFIX
#   WF_STAGE_VERB               WF_WATCH_STATES           WF_STALE_THRESHOLD
#   WF_LINEAR_STALE_THRESHOLD   WF_AGENT_PREAMBLE

# ── Locate workflow.toml ──────────────────────────────────────────────────────

_wf_loader_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_wf_find_toml() {
    # 1. Explicit override
    if [[ -n "${WORKFLOW_TOML:-}" && -f "$WORKFLOW_TOML" ]]; then
        echo "$WORKFLOW_TOML"
        return 0
    fi
    # 2. Target repo inside container
    if [[ -f "/workspace/repo/workflow.toml" ]]; then
        echo "/workspace/repo/workflow.toml"
        return 0
    fi
    # 3. Bundled default shipped alongside scripts (container: /opt/autoframe/workflow.toml;
    #    local dev: two levels up from scripts/lib/ → repo root)
    local bundled="${_wf_loader_dir}/../../workflow.toml"
    if [[ -f "$bundled" ]]; then
        echo "$bundled"
        return 0
    fi
    return 1
}

# ── Parse and export ──────────────────────────────────────────────────────────

_wf_load() {
    local stage_key="${LOCK_PREFIX:-}"
    if [[ -z "$stage_key" ]]; then
        echo "[workflow-loader] WARN: LOCK_PREFIX not set — skipping workflow load" >&2
        return 0
    fi

    local wf_file
    if ! wf_file=$(_wf_find_toml); then
        echo "[workflow-loader] WARN: workflow.toml not found — using .env fallback" >&2
        return 0
    fi

    local exports
    exports=$(python3 - "$wf_file" "$stage_key" << 'PYEOF'
import sys, os, re, shlex, tomllib

wf_path   = sys.argv[1]
stage_key = sys.argv[2]

def warn(msg):
    print(f"[workflow-loader] WARN: {msg}", file=sys.stderr)

# ── Read and parse TOML ───────────────────────────────────────────────────────

try:
    with open(wf_path, 'rb') as f:
        cfg = tomllib.load(f)
except OSError as e:
    warn(f"Cannot read {wf_path}: {e}")
    sys.exit(0)
except tomllib.TOMLDecodeError as e:
    warn(f"TOML parse error in {wf_path}: {e}")
    sys.exit(0)

# ── Expand ${VAR} and ${VAR:-default} references ──────────────────────────────

def expand_env(val):
    if not isinstance(val, str):
        return val
    def replacer(m):
        var, default = m.group(1), m.group(3) or ''
        return os.environ.get(var, default)
    return re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:-)(.*?))?\}', replacer, val)

# ── Find the matching stage ───────────────────────────────────────────────────

target_stage = next(
    (s for s in cfg.get('stages', []) if s.get('name') == stage_key),
    None
)
if target_stage is None:
    warn(f"Stage '{stage_key}' not found in {wf_path}")
    sys.exit(0)

# ── Extract fields ────────────────────────────────────────────────────────────

def get_str(key):
    return expand_env(str(target_stage.get(key, '') or ''))

def get_list(key):
    raw = target_stage.get(key, [])
    if isinstance(raw, list):
        return [expand_env(str(v)) for v in raw]
    return [expand_env(str(raw))] if raw else []

def get_int_str(key):
    val = target_stage.get(key, '')
    # Empty string means "unset" (e.g. approve's linear_stale_threshold_s)
    if val == '' or val is None:
        return ''
    return str(int(val))

poll_states      = get_list('poll')
watch_states_lst = get_list('watch_states')
claim_state      = get_str('claim')
done_state       = get_str('done')
revert_state     = get_str('revert')
pass_state       = get_str('pass_state')
fail_state       = get_str('fail_state')
command          = get_str('command')
lock_prefix      = get_str('lock_prefix')
stage_verb       = get_str('stage_verb')
stale_threshold  = get_int_str('stale_threshold_s')
linear_stale     = get_int_str('linear_stale_threshold_s')

# ── Build GQL and display variants from poll_states ───────────────────────────
# GQL:     "Plan Approved","Changes Required"   (bare double-quoted names)
# Display: 'Plan Approved' and 'Changes Required'

if poll_states:
    poll_states_gql     = ','.join(f'"{s}"' for s in poll_states)
    display_parts       = [f"'{s}'" for s in poll_states]
    poll_states_display = ' and '.join(display_parts)
else:
    poll_states_gql     = ''
    poll_states_display = ''

# ── Build watch_states colon-separated ───────────────────────────────────────

watch_states_str = ':'.join(watch_states_lst)

# ── Extract preamble from [preamble] table ────────────────────────────────────

preamble = cfg.get('preamble', {}).get('text', '') or ''
preamble = preamble.strip()

# ── Emit export statements using shlex.quote for safety ──────────────────────

exports = {
    'WF_POLL_STATES_GQL':        poll_states_gql,
    'WF_POLL_STATES_DISPLAY':    poll_states_display,
    'WF_CLAIM_STATE':            claim_state,
    'WF_DONE_STATE':             done_state,
    'WF_REVERT_STATE':           revert_state,
    'WF_PASS_STATE':             pass_state,
    'WF_FAIL_STATE':             fail_state,
    'WF_SLASH_COMMAND':          command,
    'WF_LOCK_PREFIX':            lock_prefix,
    'WF_STAGE_VERB':             stage_verb,
    'WF_WATCH_STATES':           watch_states_str,
    'WF_STALE_THRESHOLD':        stale_threshold,
    'WF_LINEAR_STALE_THRESHOLD': linear_stale,
    'WF_AGENT_PREAMBLE':         preamble,
}

for name, val in exports.items():
    print(f'export {name}={shlex.quote(val)}')
PYEOF
    )

    local py_exit=$?
    if [[ $py_exit -ne 0 ]]; then
        echo "[workflow-loader] WARN: Python parser exited $py_exit — using .env fallback" >&2
        return 0
    fi

    if [[ -z "$exports" ]]; then
        # Python printed nothing — stage not found or invalid file; warning already emitted
        return 0
    fi

    eval "$exports"
    WORKFLOW_LOADED=1
    export WORKFLOW_LOADED
}

_wf_load
unset -f _wf_find_toml _wf_load
