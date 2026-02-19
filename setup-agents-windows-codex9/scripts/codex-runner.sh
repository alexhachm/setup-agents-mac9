#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  codex-runner.sh \
    --agent-id <id> \
    --mode <fresh|continue> \
    --model-alias <fast|deep|economy|highest|...> \
    --cwd <path> \
    --role-doc <path> \
    --loop-doc <path>
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

quote_shell() {
    printf '%q' "$1"
}

render_template() {
    local tpl="$1"
    local bin_q model_q cwd_q prompt_q
    bin_q="$(quote_shell "$RUNNER_BIN")"
    model_q="$(quote_shell "$MODEL_RESOLVED")"
    cwd_q="$(quote_shell "$RUNNER_CWD")"
    prompt_q="$(quote_shell "$PROMPT_FILE")"

    tpl="${tpl//'{{bin}}'/$bin_q}"
    tpl="${tpl//'{{model}}'/$model_q}"
    tpl="${tpl//'{{model_alias}}'/$(quote_shell "$MODEL_ALIAS")}"
    tpl="${tpl//'{{cwd}}'/$cwd_q}"
    tpl="${tpl//'{{prompt_file}}'/$prompt_q}"
    tpl="${tpl//'{{agent_id}}'/$(quote_shell "$AGENT_ID")}"
    printf '%s' "$tpl"
}

AGENT_ID=""
MODE=""
MODEL_ALIAS=""
RUNNER_CWD=""
ROLE_DOC=""
LOOP_DOC=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --agent-id) AGENT_ID="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --model-alias) MODEL_ALIAS="$2"; shift 2 ;;
        --cwd) RUNNER_CWD="$2"; shift 2 ;;
        --role-doc) ROLE_DOC="$2"; shift 2 ;;
        --loop-doc) LOOP_DOC="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$AGENT_ID" ] || die "--agent-id is required"
[ -n "$MODE" ] || die "--mode is required"
[ -n "$MODEL_ALIAS" ] || die "--model-alias is required"
[ -n "$RUNNER_CWD" ] || die "--cwd is required"
[ -n "$ROLE_DOC" ] || die "--role-doc is required"
[ -n "$LOOP_DOC" ] || die "--loop-doc is required"

case "$MODE" in
    fresh|continue) ;;
    *) die "--mode must be fresh or continue" ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROVIDER_FILE="$PROJECT_DIR/.codex/provider-codex.json"

RUNNER_BIN="codex"
FRESH_TEMPLATE='{{bin}} --model {{model}} --cwd {{cwd}} --prompt-file {{prompt_file}}'
CONTINUE_TEMPLATE='{{bin}} --continue --model {{model}} --cwd {{cwd}} --prompt-file {{prompt_file}}'
NATIVE_CONTINUE="true"
PROMPT_PATH_REL=".codex/runtime-prompts"
MODEL_RESOLVED="$MODEL_ALIAS"

if [ -f "$PROVIDER_FILE" ] && command -v jq >/dev/null 2>&1; then
    RUNNER_BIN="$(jq -r '.bin // "codex"' "$PROVIDER_FILE")"
    FRESH_TEMPLATE="$(jq -r '.launch_mode_templates.fresh // "{{bin}} --model {{model}} --cwd {{cwd}} --prompt-file {{prompt_file}}"' "$PROVIDER_FILE")"
    CONTINUE_TEMPLATE="$(jq -r '.launch_mode_templates.continue // "{{bin}} --continue --model {{model}} --cwd {{cwd}} --prompt-file {{prompt_file}}"' "$PROVIDER_FILE")"
    NATIVE_CONTINUE="$(jq -r '.session_mode.native_continue // true' "$PROVIDER_FILE")"
    PROMPT_PATH_REL="$(jq -r '.runner_behavior.startup_prompt_path // ".codex/runtime-prompts"' "$PROVIDER_FILE")"
    MODEL_RESOLVED="$(jq -r --arg alias "$MODEL_ALIAS" '.model_map[$alias] // $alias' "$PROVIDER_FILE")"
else
    case "$MODEL_ALIAS" in
        fast) MODEL_RESOLVED="codex-5.3-high" ;;
        deep) MODEL_RESOLVED="codex-5.3-high" ;;
        economy) MODEL_RESOLVED="gpt-5.2-pro" ;;
        highest) MODEL_RESOLVED="codex-5.3-xhigh" ;;
    esac
fi

# Provider env policy: clear legacy-style vars and set codex runtime vars.
# We avoid hardcoded provider-specific legacy names so this stays provider-neutral.
unset LEGACY_AGENT_MODE LEGACY_SESSION_ID LEGACY_PROVIDER_ENV 2>/dev/null || true

if [ -f "$PROVIDER_FILE" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r env_key; do
        [ -n "$env_key" ] || continue
        unset "$env_key" 2>/dev/null || true
    done < <(jq -r '.env_policy.unset[]? // empty' "$PROVIDER_FILE")

    while IFS=$'\t' read -r env_key env_val; do
        [ -n "$env_key" ] || continue
        env_val="${env_val//'{{cwd}}'/$RUNNER_CWD}"
        env_val="${env_val//'{{project_dir}}'/$PROJECT_DIR}"
        env_val="${env_val//'{{agent_id}}'/$AGENT_ID}"
        env_val="${env_val//'{{model_alias}}'/$MODEL_ALIAS}"
        env_val="${env_val//'{{model}}'/$MODEL_RESOLVED}"
        export "$env_key=$env_val"
    done < <(jq -r '.env_policy.set // {} | to_entries[] | "\(.key)\t\(.value)"' "$PROVIDER_FILE")
fi

export CODEX_PROJECT_DIR="$RUNNER_CWD"
export CODEX_AGENT_ID="$AGENT_ID"
export CODEX_MODEL_ALIAS="$MODEL_ALIAS"
export CODEX_MODEL_RESOLVED="$MODEL_RESOLVED"
export CODEX_SESSION_MODE="$MODE"

if [[ "$PROMPT_PATH_REL" = /* ]]; then
    PROMPT_DIR="$PROMPT_PATH_REL"
else
    PROMPT_DIR="$PROJECT_DIR/$PROMPT_PATH_REL"
fi
mkdir -p "$PROMPT_DIR"
PROMPT_FILE="$PROMPT_DIR/${AGENT_ID}-${MODE}-$(date -u +%Y%m%dT%H%M%SZ).md"

{
    echo "# Startup Context"
    echo "agent_id: $AGENT_ID"
    echo "mode: $MODE"
    echo "model_alias: $MODEL_ALIAS"
    echo "model_resolved: $MODEL_RESOLVED"
    echo

    echo "## Role Document"
    if [ -f "$ROLE_DOC" ]; then
        cat "$ROLE_DOC"
    else
        echo "(missing role document: $ROLE_DOC)"
    fi

    echo
    echo "## Loop Document"
    if [ -f "$LOOP_DOC" ]; then
        cat "$LOOP_DOC"
    else
        echo "(missing loop document: $LOOP_DOC)"
    fi

    if [ "$MODE" = "continue" ] && [ "$NATIVE_CONTINUE" != "true" ]; then
        echo
        echo "## Continue Note"
        echo "Native continue is disabled; resume from existing state and latest logs before acting."
    fi
} > "$PROMPT_FILE"

if [ "$MODE" = "continue" ] && [ "$NATIVE_CONTINUE" = "true" ]; then
    CMD_TEMPLATE="$CONTINUE_TEMPLATE"
else
    CMD_TEMPLATE="$FRESH_TEMPLATE"
fi

COMMAND="$(render_template "$CMD_TEMPLATE")"

cd "$RUNNER_CWD"
eval "exec $COMMAND"
