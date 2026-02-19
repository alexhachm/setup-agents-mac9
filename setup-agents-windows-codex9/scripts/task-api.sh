#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_DIR/.codex-shared-state"
TASKS_FILE="$STATE_DIR/tasks.json"
LOCK_FILE="$TASKS_FILE.lock"

usage() {
    cat <<'USAGE'
Usage:
  task-api.sh create --subject <text> --description <text> [--request-id <id>] [--priority <p>] [--assigned-to <worker>] [--owner <agent>] [--status <status>]
  task-api.sh create --json '<task-json>'
  task-api.sh list [--assigned-to <worker>] [--status <status>] [--request-id <id>] [--priority <p>] [--format json|table]
  task-api.sh claim --id <task-id> --owner <agent>
  task-api.sh update --id <task-id> [--status <status>] [--owner <agent>] [--priority <p>] [--subject <text>] [--description <text>] [--assigned-to <worker>] [--request-id <id>]
  task-api.sh complete --id <task-id> [--owner <agent>]
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required"
}

ensure_store() {
    mkdir -p "$STATE_DIR"
    if [ ! -f "$TASKS_FILE" ]; then
        printf '{"next_id":1,"tasks":[],"last_updated_at":null}\n' > "$TASKS_FILE"
    fi
    if ! jq -e 'has("tasks") and has("next_id")' "$TASKS_FILE" >/dev/null 2>&1; then
        printf '{"next_id":1,"tasks":[],"last_updated_at":null}\n' > "$TASKS_FILE"
    fi
}

lock_with_fallback() {
    local fn="$1"
    shift

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        flock -w 10 9 || die "could not acquire task lock"
        "$fn" "$@"
        exec 9>&-
        return
    fi

    local lockdir="${TASKS_FILE}.lockdir"
    local attempts=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            die "could not acquire task lock"
        fi
        sleep 0.1
    done

    "$fn" "$@"
    rmdir "$lockdir" 2>/dev/null || true
}

extract_from_description() {
    local key="$1"
    local description="$2"
    printf '%s\n' "$description" | sed -n "s/^${key}:[[:space:]]*//p" | head -n 1
}

normalize_priority() {
    local p="$1"
    printf '%s' "${p:-normal}" | tr '[:upper:]' '[:lower:]'
}

create_locked() {
    local subject="$1"
    local description="$2"
    local request_id="$3"
    local priority="$4"
    local assigned_to="$5"
    local owner="$6"
    local status="$7"
    local now id updated

    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    id="$(jq -r '.next_id // 1 | "task-\(.)"' "$TASKS_FILE")"

    updated="$(
        jq \
            --arg id "$id" \
            --arg subject "$subject" \
            --arg description "$description" \
            --arg request_id "$request_id" \
            --arg priority "$priority" \
            --arg assigned_to "$assigned_to" \
            --arg owner "$owner" \
            --arg status "$status" \
            --arg now "$now" \
            '
            .tasks = (.tasks // [])
            | .next_id = ((.next_id // 1) + 1)
            | .tasks += [{
                id: $id,
                subject: $subject,
                description: $description,
                status: $status,
                priority: $priority,
                request_id: (if $request_id == "" then null else $request_id end),
                assigned_to: (if $assigned_to == "" then null else $assigned_to end),
                owner: (if $owner == "" then null else $owner end),
                created_at: $now,
                updated_at: $now,
                completed_at: null
            }]
            | .last_updated_at = $now
            ' "$TASKS_FILE"
    )"

    printf '%s\n' "$updated" > "$TASKS_FILE"
    printf '%s\n' "$id"
}

create_task() {
    local subject=""
    local description=""
    local request_id=""
    local priority="normal"
    local assigned_to=""
    local owner=""
    local status="pending"
    local json_input=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --subject) subject="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --request-id) request_id="$2"; shift 2 ;;
            --priority) priority="$2"; shift 2 ;;
            --assigned-to) assigned_to="$2"; shift 2 ;;
            --owner) owner="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            --json) json_input="$2"; shift 2 ;;
            *) die "unknown create option: $1" ;;
        esac
    done

    if [ -n "$json_input" ]; then
        subject="$(jq -r '.subject // empty' <<<"$json_input")"
        description="$(jq -r '.description // empty' <<<"$json_input")"
        request_id="$(jq -r '.request_id // empty' <<<"$json_input")"
        priority="$(jq -r '.priority // "normal"' <<<"$json_input")"
        assigned_to="$(jq -r '.assigned_to // empty' <<<"$json_input")"
        owner="$(jq -r '.owner // empty' <<<"$json_input")"
        status="$(jq -r '.status // "pending"' <<<"$json_input")"
    fi

    [ -n "$subject" ] || die "--subject is required"
    [ -n "$description" ] || die "--description is required"

    [ -n "$request_id" ] || request_id="$(extract_from_description "REQUEST_ID" "$description")"
    [ -n "$assigned_to" ] || assigned_to="$(extract_from_description "ASSIGNED_TO" "$description")"
    if [ -z "$priority" ]; then
        priority="normal"
    fi
    if [ "$priority" = "normal" ]; then
        parsed_priority="$(extract_from_description "PRIORITY" "$description" | tr '[:upper:]' '[:lower:]')"
        [ -n "$parsed_priority" ] && priority="$parsed_priority"
    fi

    priority="$(normalize_priority "$priority")"

    local id
    id="$(lock_with_fallback create_locked "$subject" "$description" "$request_id" "$priority" "$assigned_to" "$owner" "$status")"
    echo "created $id"
}

list_task_rows() {
    local assigned_to="$1"
    local status="$2"
    local request_id="$3"
    local priority="$4"

    jq -r \
        --arg assigned_to "$assigned_to" \
        --arg status "$status" \
        --arg request_id "$request_id" \
        --arg priority "$priority" \
        '
        .tasks
        | map(select(
            ($assigned_to == "" or .assigned_to == $assigned_to)
            and ($status == "" or .status == $status)
            and ($request_id == "" or .request_id == $request_id)
            and ($priority == "" or .priority == $priority)
        ))
        | sort_by(.created_at)
        ' "$TASKS_FILE"
}

list_tasks() {
    local assigned_to=""
    local status=""
    local request_id=""
    local priority=""
    local format="table"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --assigned-to) assigned_to="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            --request-id) request_id="$2"; shift 2 ;;
            --priority) priority="$2"; shift 2 ;;
            --format) format="$2"; shift 2 ;;
            *) die "unknown list option: $1" ;;
        esac
    done

    local rows
    rows="$(list_task_rows "$assigned_to" "$status" "$request_id" "$priority")"

    if [ "$format" = "json" ]; then
        printf '%s\n' "$rows"
        return
    fi

    local count
    count="$(jq -r 'length' <<<"$rows")"
    if [ "$count" -eq 0 ]; then
        echo "no tasks"
        return
    fi

    printf '%-10s %-12s %-8s %-12s %-14s %s\n' "ID" "STATUS" "PRIOR" "ASSIGNED" "REQUEST" "SUBJECT"
    jq -r '.[] | [.id, .status, .priority, (.assigned_to // "-"), (.request_id // "-"), .subject] | @tsv' <<<"$rows" |
        while IFS=$'\t' read -r id status_v priority_v assigned_v request_v subject_v; do
            printf '%-10s %-12s %-8s %-12s %-14s %s\n' "$id" "$status_v" "$priority_v" "$assigned_v" "$request_v" "$subject_v"
        done
}

ensure_task_exists() {
    local id="$1"
    jq -e --arg id "$id" '.tasks[]? | select(.id == $id)' "$TASKS_FILE" >/dev/null || die "task not found: $id"
}

update_locked() {
    local id="$1"
    local status="$2"
    local owner="$3"
    local priority="$4"
    local subject="$5"
    local description="$6"
    local assigned_to="$7"
    local request_id="$8"
    local now updated

    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    updated="$(
        jq \
            --arg id "$id" \
            --arg status "$status" \
            --arg owner "$owner" \
            --arg priority "$priority" \
            --arg subject "$subject" \
            --arg description "$description" \
            --arg assigned_to "$assigned_to" \
            --arg request_id "$request_id" \
            --arg now "$now" \
            '
            .tasks = (.tasks // [])
            | .tasks |= map(
                if .id == $id then
                    (if $status != "" then .status = $status else . end)
                    | (if $owner != "" then .owner = $owner else . end)
                    | (if $priority != "" then .priority = $priority else . end)
                    | (if $subject != "" then .subject = $subject else . end)
                    | (if $description != "" then .description = $description else . end)
                    | (if $assigned_to != "" then .assigned_to = $assigned_to else . end)
                    | (if $request_id != "" then .request_id = $request_id else . end)
                    | .updated_at = $now
                    | (if $status == "completed" then .completed_at = $now else . end)
                else
                    .
                end
            )
            | .last_updated_at = $now
            ' "$TASKS_FILE"
    )"

    printf '%s\n' "$updated" > "$TASKS_FILE"
}

claim_task() {
    local id=""
    local owner=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --owner) owner="$2"; shift 2 ;;
            *) die "unknown claim option: $1" ;;
        esac
    done

    [ -n "$id" ] || die "--id is required"
    [ -n "$owner" ] || die "--owner is required"

    ensure_task_exists "$id"
    lock_with_fallback update_locked "$id" "in_progress" "$owner" "" "" "" "" ""
    echo "claimed $id"
}

update_task() {
    local id=""
    local status=""
    local owner=""
    local priority=""
    local subject=""
    local description=""
    local assigned_to=""
    local request_id=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            --owner) owner="$2"; shift 2 ;;
            --priority) priority="$2"; shift 2 ;;
            --subject) subject="$2"; shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --assigned-to) assigned_to="$2"; shift 2 ;;
            --request-id) request_id="$2"; shift 2 ;;
            *) die "unknown update option: $1" ;;
        esac
    done

    [ -n "$id" ] || die "--id is required"
    [ -n "$status$owner$priority$subject$description$assigned_to$request_id" ] || die "no fields provided to update"

    [ -z "$priority" ] || priority="$(normalize_priority "$priority")"
    ensure_task_exists "$id"
    lock_with_fallback update_locked "$id" "$status" "$owner" "$priority" "$subject" "$description" "$assigned_to" "$request_id"
    echo "updated $id"
}

complete_task() {
    local id=""
    local owner=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --owner) owner="$2"; shift 2 ;;
            *) die "unknown complete option: $1" ;;
        esac
    done

    [ -n "$id" ] || die "--id is required"
    ensure_task_exists "$id"
    lock_with_fallback update_locked "$id" "completed" "$owner" "" "" "" "" ""
    echo "completed $id"
}

main() {
    need_jq
    ensure_store

    local command="${1:-}"
    [ -n "$command" ] || { usage; exit 1; }
    shift || true

    case "$command" in
        create) create_task "$@" ;;
        list) list_tasks "$@" ;;
        claim) claim_task "$@" ;;
        update) update_task "$@" ;;
        complete) complete_task "$@" ;;
        -h|--help|help) usage ;;
        *) die "unknown command: $command" ;;
    esac
}

main "$@"
