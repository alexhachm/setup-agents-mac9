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

resolve_config_file() {
    local fallback="$HOME/.claude-multi-agent-config"
    if command -v wslpath >/dev/null 2>&1 && command -v cmd.exe >/dev/null 2>&1; then
        local win_home
        win_home="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | awk 'NF {print; exit}')"
        if [ -n "$win_home" ] && [ "$win_home" != "%USERPROFILE%" ]; then
            local wsl_home
            wsl_home="$(wslpath -u "$win_home" 2>/dev/null || true)"
            if [ -n "$wsl_home" ]; then
                printf '%s/.claude-multi-agent-config' "$wsl_home"
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

write_worker_launchers() {
    local worker_num="$1"
    local worker_wsl_path="$2"
    local launcher_dir="$3"
    local fresh_command
    local continue_command
    local escaped_fresh
    local escaped_continue

    fresh_command="cd '$worker_wsl_path' && exec claude --model opus --dangerously-skip-permissions '/worker-loop'"
    continue_command="cd '$worker_wsl_path' && exec claude --continue --model opus --dangerously-skip-permissions"
    escaped_fresh="${fresh_command//\"/\\\"}"
    escaped_continue="${continue_command//\"/\\\"}"

    printf 'Clear-Host\nWrite-Host "`n  ████  I AM WORKER-%s (Opus)  ████`n" -ForegroundColor Cyan\n& wsl.exe -e bash -lc "%s"\n' \
        "$worker_num" "$escaped_fresh" > "$launcher_dir/worker-${worker_num}.ps1"
    printf 'Clear-Host\nWrite-Host "`n  ████  I AM WORKER-%s (Opus) [CONTINUE]  ████`n" -ForegroundColor Cyan\n& wsl.exe -e bash -lc "%s"\n' \
        "$worker_num" "$escaped_continue" > "$launcher_dir/worker-${worker_num}-continue.ps1"

    printf '@echo off\ncls\necho.\necho   ████  I AM WORKER-%s (Opus)  ████\necho.\nwsl.exe -e bash -lc "%s"\n' \
        "$worker_num" "$escaped_fresh" > "$launcher_dir/worker-${worker_num}.bat"
    printf '@echo off\ncls\necho.\necho   ████  I AM WORKER-%s (Opus) [CONTINUE]  ████\necho.\nwsl.exe -e bash -lc "%s"\n' \
        "$worker_num" "$escaped_continue" > "$launcher_dir/worker-${worker_num}-continue.bat"
}

add_manifest_agent() {
    local agents_file="$1"
    local id="$2"
    local group="$3"
    local role="$4"
    local model="$5"
    local cwd_win="$6"
    local fresh_slash="$7"
    local cwd_wsl="$8"
    local command_fresh
    local command_continue
    local tmp_file

    command_fresh="cd '$cwd_wsl' && exec claude --model $model --dangerously-skip-permissions '$fresh_slash'"
    command_continue="cd '$cwd_wsl' && exec claude --continue --model $model --dangerously-skip-permissions"

    tmp_file="$(mktemp)"
    jq \
        --arg id "$id" \
        --arg group "$group" \
        --arg role "$role" \
        --arg model "$model" \
        --arg cwd "$cwd_win" \
        --arg launcher_win ".claude/launchers/$id.bat" \
        --arg launcher_win_continue ".claude/launchers/$id-continue.bat" \
        --arg launcher_ps1 ".claude/launchers/$id.ps1" \
        --arg launcher_ps1_continue ".claude/launchers/$id-continue.ps1" \
        --arg command_fresh "$command_fresh" \
        --arg command_continue "$command_continue" \
        '. + [{
            id: $id,
            group: $group,
            role: $role,
            model: $model,
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
    local agents_tmp
    local worker_total=0
    local worker_slots
    local created_at

    agents_tmp="$(mktemp)"
    echo '[]' > "$agents_tmp"

    add_manifest_agent "$agents_tmp" "master-1" "masters" "Interface (Sonnet)" "sonnet" "$project_win" "/master-loop" "$project_dir"
    add_manifest_agent "$agents_tmp" "master-2" "masters" "Architect (Opus)" "opus" "$project_win" "/scan-codebase" "$project_dir"
    add_manifest_agent "$agents_tmp" "master-3" "masters" "Allocator (Sonnet)" "sonnet" "$project_win" "/scan-codebase-allocator" "$project_dir"

    worker_slots="$(find "$project_dir/.worktrees" -maxdepth 1 -mindepth 1 -type d -name 'wt-*' 2>/dev/null | sed 's#.*/wt-##' | sort -n || true)"
    if [ -n "$worker_slots" ]; then
        while IFS= read -r slot; do
            [ -n "$slot" ] || continue
            worker_total=$((worker_total + 1))
            add_manifest_agent \
                "$agents_tmp" \
                "worker-$slot" \
                "workers" \
                "Worker $slot (Opus)" \
                "opus" \
                "$(to_windows_path "$project_dir/.worktrees/wt-$slot")" \
                "/worker-loop" \
                "$project_dir/.worktrees/wt-$slot"
        done <<< "$worker_slots"
    fi

    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n \
        --arg project_path "$project_win" \
        --argjson worker_count "$worker_total" \
        --arg created_at "$created_at" \
        --argjson agents "$(cat "$agents_tmp")" \
        '{version: 3, project_path: $project_path, worker_count: $worker_count, created_at: $created_at, agents: $agents}' \
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
shared_state_dir="$PROJECT_DIR/.claude-shared-state"
if [ -d "$shared_state_dir" ]; then
    rm -rf "$worktree_path/.claude/state"
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        win_link=$(cygpath -w "$worktree_path/.claude/state")
        win_target=$(cygpath -w "$shared_state_dir")
        cmd //c "mklink /J \"$win_link\" \"$win_target\"" > /dev/null 2>&1
    else
        ln -sf "../../../.claude-shared-state" "$worktree_path/.claude/state"
    fi
fi

# Link logs directory so new worker can write to shared log
mkdir -p "$worktree_path/.claude/logs"
rm -rf "$worktree_path/.claude/logs"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    win_link=$(cygpath -w "$worktree_path/.claude/logs")
    win_target=$(cygpath -w "$PROJECT_DIR/.claude/logs")
    cmd //c "mklink /J \"$win_link\" \"$win_target\"" > /dev/null 2>&1
else
    ln -sf "../../../.claude/logs" "$worktree_path/.claude/logs"
fi

# Copy worker CLAUDE.md
if [ -f "$PROJECT_DIR/.worktrees/wt-1/CLAUDE.md" ]; then
    cp "$PROJECT_DIR/.worktrees/wt-1/CLAUDE.md" "$worktree_path/CLAUDE.md"
fi

new_count="$(find .worktrees -maxdepth 1 -mindepth 1 -type d -name 'wt-*' 2>/dev/null | wc -l | tr -d ' ')"
config_file="$(resolve_config_file)"
update_worker_count_in_config "$config_file" "$new_count"

launcher_dir="$PROJECT_DIR/.claude/launchers"
mkdir -p "$launcher_dir"
write_worker_launchers "$next_num" "$PROJECT_DIR/$worktree_path" "$launcher_dir"
regenerate_manifest "$launcher_dir" "$PROJECT_DIR" "$(to_windows_path "$PROJECT_DIR")"

# Workers are launched on demand by Masters via launch-worker.sh
echo "Worker $next_num created in slot $next_num; launchers + manifest updated"
