#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

to_windows_path() {
    local input_path="$1"
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$input_path" 2>/dev/null || printf '%s' "$input_path"
    else
        printf '%s' "$input_path"
    fi
}

to_wsl_path() {
    local input_path="$1"
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -u "$input_path" 2>/dev/null || printf '%s' "$input_path"
    else
        printf '%s' "$input_path"
    fi
}

resolve_config_file() {
    local fallback="$HOME/.codex-multi-agent-config"
    if command -v wslpath >/dev/null 2>&1 && command -v cmd.exe >/dev/null 2>&1; then
        local win_home
        win_home="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | awk 'NF {print; exit}')"
        if [ -n "$win_home" ] && [ "$win_home" != "%USERPROFILE%" ]; then
            local wsl_home
            wsl_home="$(wslpath -u "$win_home" 2>/dev/null || true)"
            if [ -n "$wsl_home" ]; then
                printf '%s/.codex-multi-agent-config' "$wsl_home"
                return
            fi
        fi
    fi
    printf '%s' "$fallback"
}

update_worker_count_in_config() {
    local config_file="$1"
    local worker_count="$2"
    if [ ! -f "$config_file" ]; then
        return 0
    fi

    if grep -q '^worker_count=' "$config_file"; then
        sed -i.bak "s/^worker_count=.*/worker_count=$worker_count/" "$config_file" 2>/dev/null || \
            sed -i '' "s/^worker_count=.*/worker_count=$worker_count/" "$config_file" 2>/dev/null || true
        rm -f "$config_file.bak" 2>/dev/null || true
    else
        printf '\nworker_count=%s\n' "$worker_count" >> "$config_file"
    fi
}

resolve_model_id() {
    local alias="$1"
    local provider_file="$PROJECT_DIR/.codex/provider-codex.json"
    if [ -f "$provider_file" ] && command -v jq >/dev/null 2>&1; then
        local resolved
        resolved="$(jq -r --arg alias "$alias" '.model_map[$alias] // empty' "$provider_file" 2>/dev/null || true)"
        if [ -n "$resolved" ] && [ "$resolved" != "null" ]; then
            printf '%s' "$resolved"
            return
        fi
    fi

    case "$alias" in
        fast) printf '%s' 'codex-5.3-high' ;;
        deep) printf '%s' 'codex-5.3-high' ;;
        economy) printf '%s' 'gpt-5.2-pro' ;;
        highest) printf '%s' 'codex-5.3-xhigh' ;;
        *) printf '%s' "$alias" ;;
    esac
}

build_runner_command() {
    local agent_id="$1"
    local mode="$2"
    local model_alias="$3"
    local cwd_wsl="$4"
    local role_doc_wsl="$5"
    local loop_doc_wsl="$6"
    local project_wsl="$7"

    printf "cd '%s' && bash '%s/.codex/scripts/codex-runner.sh' --agent-id '%s' --mode '%s' --model-alias '%s' --cwd '%s' --role-doc '%s' --loop-doc '%s'" \
        "$cwd_wsl" "$project_wsl" "$agent_id" "$mode" "$model_alias" "$cwd_wsl" "$role_doc_wsl" "$loop_doc_wsl"
}

write_launcher_pair() {
    local launcher_dir="$1"
    local agent_id="$2"
    local banner="$3"
    local command_fresh="$4"
    local command_continue="$5"
    local escaped_fresh="${command_fresh//\"/\\\"}"
    local escaped_continue="${command_continue//\"/\\\"}"

    printf 'Clear-Host\nWrite-Host "`n  ████  %s  ████`n" -ForegroundColor Cyan\n& wsl.exe -e bash -lc "%s"\n' \
        "$banner" "$escaped_fresh" > "$launcher_dir/${agent_id}.ps1"
    printf 'Clear-Host\nWrite-Host "`n  ████  %s [CONTINUE]  ████`n" -ForegroundColor Cyan\n& wsl.exe -e bash -lc "%s"\n' \
        "$banner" "$escaped_continue" > "$launcher_dir/${agent_id}-continue.ps1"

    printf '@echo off\ncls\necho.\necho   ████  %s  ████\necho.\nwsl.exe -e bash -lc "%s"\n' \
        "$banner" "$escaped_fresh" > "$launcher_dir/${agent_id}.bat"
    printf '@echo off\ncls\necho.\necho   ████  %s [CONTINUE]  ████\necho.\nwsl.exe -e bash -lc "%s"\n' \
        "$banner" "$escaped_continue" > "$launcher_dir/${agent_id}-continue.bat"
}

add_manifest_agent() {
    local agents_file="$1"
    local id="$2"
    local group="$3"
    local role="$4"
    local model_alias="$5"
    local cwd_win="$6"
    local cwd_wsl="$7"
    local role_doc_wsl="$8"
    local loop_doc_wsl="$9"
    local project_wsl="${10}"
    local launcher_dir="${11}"
    local model_resolved command_fresh command_continue banner tmp_file

    model_resolved="$(resolve_model_id "$model_alias")"
    command_fresh="$(build_runner_command "$id" "fresh" "$model_alias" "$cwd_wsl" "$role_doc_wsl" "$loop_doc_wsl" "$project_wsl")"
    command_continue="$(build_runner_command "$id" "continue" "$model_alias" "$cwd_wsl" "$role_doc_wsl" "$loop_doc_wsl" "$project_wsl")"

    case "$id" in
        master-1) banner='I AM MASTER-1 — YOUR INTERFACE (Fast)' ;;
        master-2) banner='I AM MASTER-2 — ARCHITECT (Deep)' ;;
        master-3) banner='I AM MASTER-3 — ALLOCATOR (Fast)' ;;
        *) banner="I AM ${id^^} (${model_alias})" ;;
    esac

    write_launcher_pair "$launcher_dir" "$id" "$banner" "$command_fresh" "$command_continue"

    tmp_file="$(mktemp)"
    jq \
        --arg id "$id" \
        --arg group "$group" \
        --arg role "$role" \
        --arg model_alias "$model_alias" \
        --arg model_resolved "$model_resolved" \
        --arg model "$model_alias" \
        --arg cwd "$cwd_win" \
        --arg launcher_win ".codex/launchers/$id.bat" \
        --arg launcher_win_continue ".codex/launchers/$id-continue.bat" \
        --arg launcher_ps1 ".codex/launchers/$id.ps1" \
        --arg launcher_ps1_continue ".codex/launchers/$id-continue.ps1" \
        --arg command_fresh "$command_fresh" \
        --arg command_continue "$command_continue" \
        '. + [{
            id: $id,
            group: $group,
            role: $role,
            model: $model,
            model_alias: $model_alias,
            model_resolved: $model_resolved,
            cwd: $cwd,
            launcher_win: $launcher_win,
            launcher_win_continue: $launcher_win_continue,
            launcher_ps1: $launcher_ps1,
            launcher_ps1_continue: $launcher_ps1_continue,
            command_fresh: $command_fresh,
            command_continue: $command_continue
        }]' "$agents_file" > "$tmp_file"
    mv "$tmp_file" "$agents_file"
}

regenerate_manifest() {
    local launcher_dir="$1"
    local project_dir="$2"
    local project_win="$3"
    local project_wsl="$4"
    local agents_tmp worker_total worker_slots created_at

    worker_total=0
    agents_tmp="$(mktemp)"
    echo '[]' > "$agents_tmp"

    add_manifest_agent "$agents_tmp" "master-1" "masters" "Interface (Fast)" "fast" \
        "$project_win" "$project_wsl" \
        "$project_wsl/.codex/docs/master-1-role.md" "$project_wsl/.codex/commands/master-loop.md" \
        "$project_wsl" "$launcher_dir"

    add_manifest_agent "$agents_tmp" "master-2" "masters" "Architect (Deep)" "deep" \
        "$project_win" "$project_wsl" \
        "$project_wsl/.codex/docs/master-2-role.md" "$project_wsl/.codex/commands/scan-codebase.md" \
        "$project_wsl" "$launcher_dir"

    add_manifest_agent "$agents_tmp" "master-3" "masters" "Allocator (Fast)" "fast" \
        "$project_win" "$project_wsl" \
        "$project_wsl/.codex/docs/master-3-role.md" "$project_wsl/.codex/commands/scan-codebase-allocator.md" \
        "$project_wsl" "$launcher_dir"

    worker_slots="$(find "$project_dir/.worktrees" -maxdepth 1 -mindepth 1 -type d -name 'wt-*' 2>/dev/null | sed 's#.*/wt-##' | sort -n || true)"
    if [ -n "$worker_slots" ]; then
        while IFS= read -r slot; do
            [ -n "$slot" ] || continue
            worker_total=$((worker_total + 1))

            local worker_win worker_wsl
            worker_win="$(to_windows_path "$project_dir/.worktrees/wt-$slot")"
            worker_wsl="$project_wsl/.worktrees/wt-$slot"
            add_manifest_agent "$agents_tmp" "worker-$slot" "workers" "Worker $slot (Deep)" "deep" \
                "$worker_win" "$worker_wsl" \
                "$worker_wsl/AGENTS.md" "$worker_wsl/.codex/commands/worker-loop.md" \
                "$project_wsl" "$launcher_dir"
        done <<< "$worker_slots"
    fi

    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n \
        --arg provider "codex" \
        --arg project_path "$project_win" \
        --argjson worker_count "$worker_total" \
        --arg created_at "$created_at" \
        --argjson agents "$(cat "$agents_tmp")" \
        '{version: 4, provider: $provider, project_path: $project_path, worker_count: $worker_count, created_at: $created_at, agents: $agents}' \
        > "$launcher_dir/manifest.json"

    rm -f "$agents_tmp"
}

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to add workers (manifest regeneration)"
    exit 1
fi

# Find the lowest available worker slot (1-8) by checking for gaps
next_num=""
for i in $(seq 1 8); do
    if [ ! -d ".worktrees/wt-$i" ]; then
        next_num=$i
        break
    fi
done

if [ -z "$next_num" ]; then
    echo "ERROR: Maximum 8 workers — all slots occupied"
    exit 1
fi

branch_name="agent-$next_num"
worktree_path=".worktrees/wt-$next_num"

git branch -D "$branch_name" 2>/dev/null || true
git worktree add "$worktree_path" -b "$branch_name"

# Link shared state into the new worktree (junction on Windows, symlink elsewhere)
shared_state_dir="$PROJECT_DIR/.codex-shared-state"
if [ -d "$shared_state_dir" ]; then
    rm -rf "$worktree_path/.codex/state"
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        win_link=$(cygpath -w "$worktree_path/.codex/state")
        win_target=$(cygpath -w "$shared_state_dir")
        cmd //c "mklink /J \"$win_link\" \"$win_target\"" > /dev/null 2>&1
    else
        ln -sf "../../../.codex-shared-state" "$worktree_path/.codex/state"
    fi
fi

# Link logs directory so new worker can write to shared log
mkdir -p "$worktree_path/.codex/logs"
rm -rf "$worktree_path/.codex/logs"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    win_link=$(cygpath -w "$worktree_path/.codex/logs")
    win_target=$(cygpath -w "$PROJECT_DIR/.codex/logs")
    cmd //c "mklink /J \"$win_link\" \"$win_target\"" > /dev/null 2>&1
else
    ln -sf "../../../.codex/logs" "$worktree_path/.codex/logs"
fi

# Copy worker AGENTS.md
if [ -f "$PROJECT_DIR/.worktrees/wt-1/AGENTS.md" ]; then
    cp "$PROJECT_DIR/.worktrees/wt-1/AGENTS.md" "$worktree_path/AGENTS.md"
fi

new_count="$(find .worktrees -maxdepth 1 -mindepth 1 -type d -name 'wt-*' 2>/dev/null | wc -l | tr -d ' ')"
config_file="$(resolve_config_file)"
update_worker_count_in_config "$config_file" "$new_count"

launcher_dir="$PROJECT_DIR/.codex/launchers"
mkdir -p "$launcher_dir"
regenerate_manifest "$launcher_dir" "$PROJECT_DIR" "$(to_windows_path "$PROJECT_DIR")" "$(to_wsl_path "$PROJECT_DIR")"

# Workers are launched on demand by Masters via launch-worker.sh
echo "Worker $next_num created in slot $next_num; launchers + manifest updated"
