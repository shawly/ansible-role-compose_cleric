#!/usr/bin/env bash

set -euo pipefail

CLERIC_LABEL_SPACE="de.shawly.compose.cleric"
CLERIC_LABEL_ENABLED="${CLERIC_LABEL_SPACE}.enabled"
CLERIC_LABEL_MONITOR_ONLY="${CLERIC_LABEL_SPACE}.monitor-only"
CLERIC_LABEL_RESTART_LIMIT="${CLERIC_LABEL_SPACE}.restart-limit"
CLERIC_LABEL_RESTART_LIMIT_CMD="${CLERIC_LABEL_SPACE}.restart-limit-cmd"
CLERIC_LABEL_RESTART_WAIT="${CLERIC_LABEL_SPACE}.restart-wait"

command -v docker >/dev/null || {
    echo "Docker is not installed"
    exit 1
}

command -v jq >/dev/null || {
    echo "jq is not installed"
    exit 1
}

docker info >/dev/null || exit 1

# SIGTERM-handler
term_handler() {
    exit 143 # 128 + 15 -- SIGTERM
}

# shellcheck disable=2039
trap 'kill $$; term_handler' SIGTERM

try_healing_container() {
    local container_data container_id container_name container_network_link container_restarts \
        compose_project compose_service project_working_dir \
        cleric_enabled cleric_monitor_only cleric_restart_limit cleric_restart_limit_cmd \
        _up_error
    container_id=${1:?}
    container_data=$(docker inspect "$container_id" --format '{{json .}}')
    container_name=$(echo "$container_data" | jq -r '.Name')
    compose_project=$(echo "$container_data" | jq -r '.Config.Labels."com.docker.compose.project"')
    cleric_enabled=$(echo "$container_data" | jq -r --arg CLERIC_LABEL_ENABLED "${CLERIC_LABEL_ENABLED}" '.Config.Labels[$CLERIC_LABEL_ENABLED] // false' | tr '[:upper:]' '[:lower:]')
    cleric_monitor_only=$(echo "$container_data" | jq -r --arg CLERIC_LABEL_MONITOR_ONLY "${CLERIC_LABEL_MONITOR_ONLY}" '.Config.Labels[$CLERIC_LABEL_MONITOR_ONLY] // false' | tr '[:upper:]' '[:lower:]')
    cleric_restart_limit=$(echo "$container_data" | jq -r --arg CLERIC_LABEL_RESTART_LIMIT "${CLERIC_LABEL_RESTART_LIMIT}" '.Config.Labels[$CLERIC_LABEL_RESTART_LIMIT] // 10')
    cleric_restart_limit_cmd=$(echo "$container_data" | jq -r --arg CLERIC_LABEL_RESTART_LIMIT_CMD "${CLERIC_LABEL_RESTART_LIMIT_CMD}" '.Config.Labels[$CLERIC_LABEL_RESTART_LIMIT_CMD] // "ignore"')
    cleric_restart_wait=$(echo "$container_data" | jq -r --arg CLERIC_LABEL_RESTART_WAIT "${CLERIC_LABEL_RESTART_WAIT}" '.Config.Labels[$CLERIC_LABEL_RESTART_WAIT] // 15')

    if [[ "${cleric_restart_wait}" -gt 0 ]]; then
        echo "Container $container_name ($container_id) is unhealthy, waiting ${cleric_restart_wait}s before restarting..."
        sleep "${cleric_restart_wait}"
        container_data=$(docker inspect "$container_id" --format '{{json .}}')
        container_status=$(echo "$container_data" | jq -r '.State.Health.Status')
        if [[ "${container_status:-null}" == "healthy" ]]; then
            echo "Container $container_name ($container_id) recovered itself, not restarting..."
            return 0
        fi
    fi

    container_restarts="container_${container_id}_restarts"
    container_last_restart="container_${container_id}_last_restart"
    current_timestamp="$(date +%s)"
    [[ -n "${!container_restarts:-}" ]] || export "${container_restarts}"=0
    [[ -n "${!container_last_restart:-}" ]] || export "${container_last_restart}"="${current_timestamp}"
    if [[ "${!container_restarts}" -ge "${cleric_restart_limit:-10}" ]]; then
        if [[ "${cleric_restart_limit_cmd}" != "ignore" ]]; then
            echo "Container $container_name ($container_id) is unhealthy and has been restarted ${!container_restarts} times, $cleric_restart_limit_cmd container..."
            docker "$cleric_restart_limit_cmd" "$container_id"
            echo "Container $container_name ($container_id) has been stopped! Please fix the container manually."
        else
            echo "Container $container_name ($container_id) is unhealthy and has been restarted ${!container_restarts} times, ignoring..."
        fi
        return 0
    fi

    # if time between now and last restart is greater than 120 seconds, we can assume the service isn't restarting continuously
    time_delta=$((current_timestamp - !container_last_restart))
    if [[ "${time_delta}" -gt 120 ]]; then
        export "${container_restarts}"=0
    fi

    if [[ "${compose_project:-null}" == "null" ]]; then
        if [[ "${cleric_enabled:-false}" == "true" ]]; then
            echo "Container $container_name ($container_id) is unhealthy, restarting (restarts: ${!container_restarts})..."
            export "${container_restarts}"=$((container_restarts + 1))
            export "${container_last_restart}"="$(date +%s)"
            docker restart "$container_id" &
        elif [[ "${cleric_monitor_only:-false}" == "true" ]]; then
            echo "Container $container_name ($container_id) is unhealthy, but is set to monitor only, skipping..."
        else
            echo "Container $container_name ($container_id) is unhealthy, but cleric is not enabled, skipping..."
        fi
        return 0
    fi

    if [[ "${compose_project:-null}" != "null" ]]; then
        compose_service=$(echo "$container_data" | jq -r '.Config.Labels."com.docker.compose.service"')
        project_working_dir=$(echo "$container_data" | jq -r '.Config.Labels."com.docker.compose.project.working_dir"')
        container_network_link=$(echo "$container_data" | jq -r '.HostConfig.NetworkMode | match("container:(.+)").captures | first | .string')

        if [[ "${cleric_enabled:-false}" == "true" ]]; then
            echo "Service $container_name ($container_id) in project \"$compose_project\" is unhealthy, restarting service (restarts: ${!container_restarts})..."
            export "${container_restarts}"=$((container_restarts + 1))
            export "${container_last_restart}"="$(date +%s)"

            COMPOSE_FILE=$(echo "$container_data" | jq -r '.Config.Labels."com.docker.compose.project.config_files" | split(",") | join(":")')
            export COMPOSE_FILE
            if [[ "${container_network_link:-null}" != "null" ]] && ! docker inspect "${container_network_link:-null}" >/dev/null 2>&1; then
                # if the container that is unhealthy is linked to container but that container doesn't exist anymore, we change the cmd to up
                echo "Service $container_name ($container_id) uses network of missing container (${container_network_link:-null}), recreating..."
                docker compose --progress=plain --project-directory "${project_working_dir}" up -d "${compose_service}" || _up_error="$?"

                if [[ -n "${_up_error:-}" ]]; then
                    echo "docker compose up failed with exit code $_up_error, recreating stack ${compose_project}..."
                    docker compose --progress=plain --project-directory "${project_working_dir}" down
                    docker compose --progress=plain --project-directory "${project_working_dir}" up -d
                fi
            else
                docker compose --progress=plain --project-directory "${project_working_dir}" restart "${compose_service}" &
            fi
        elif [[ "${cleric_monitor_only:-false}" == "true" ]]; then
            echo "Service $compose_service ($container_id) in project $compose_project is unhealthy, but is set to monitor only, skipping..."
        else
            echo "Service $compose_service ($container_id) in project $compose_project is unhealthy, but cleric is not enabled, skipping..."
        fi

        return 0
    fi
}

check_for_unhealthy_containers() {
    echo "Checking for unhealthy containers..."
    local container
    local container_id
    while read -r container; do
        container_id=$(echo "$container" | jq -r '.ID')
        try_healing_container "$container_id"
    done < <(docker ps --no-trunc --format '{{json .}}' --filter 'health=unhealthy')
}

wait_for_unhealthy_events() {
    echo "Waiting for unhealthy events..."
    local docker_event
    local is_unhealthy
    local container_id
    while read -r docker_event; do
        is_unhealthy=$(echo "$docker_event" | jq -r '.status | test(".+unhealthy") // false')
        container_id=$(echo "$docker_event" | jq -r '.id')
        if [[ "${is_unhealthy:-null}" == "true" ]] && [[ "${container_id:-null}" != "null" ]]; then
            try_healing_container "$container_id"
        fi
    done < <(docker events --format '{{json .}}' --filter 'event=health_status')
}

echo "Starting Compose Cleric..."

check_for_unhealthy_containers

wait_for_unhealthy_events
