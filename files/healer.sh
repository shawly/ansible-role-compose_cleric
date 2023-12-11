#!/usr/bin/env bash

set -euo pipefail

HEALER_LABEL_SPACE="de.shawly.healer"
HEALER_LABEL_ENABLED="${HEALER_LABEL_SPACE}.enabled"
HEALER_LABEL_MONITOR_ONLY="${HEALER_LABEL_SPACE}.monitor-only"
HEALER_LABEL_RESTART_LIMIT="${HEALER_LABEL_SPACE}.restart-limit"
HEALER_LABEL_RESTART_LIMIT_CMD="${HEALER_LABEL_SPACE}.restart-limit-cmd"

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
        healer_enabled healer_monitor_only healer_restart_limit healer_restart_limit_cmd \
        _up_error
    container_id=${1:?}
    container_data=$(docker inspect "$container_id" --format '{{json .}}')
    container_name=$(echo "$container_data" | jq -r '.Name')
    compose_project=$(echo "$container_data" | jq -r '.Config.Labels."com.docker.compose.project"')
    healer_enabled=$(echo "$container_data" | jq -r --arg HEALER_LABEL_ENABLED "${HEALER_LABEL_ENABLED}" '.Config.Labels[$HEALER_LABEL_ENABLED] |= ascii_downcase // false')
    healer_monitor_only=$(echo "$container_data" | jq -r --arg HEALER_LABEL_MONITOR_ONLY "${HEALER_LABEL_MONITOR_ONLY}" '.Config.Labels[$HEALER_LABEL_MONITOR_ONLY] |= ascii_downcase // false')
    healer_restart_limit=$(echo "$container_data" | jq -r --arg HEALER_LABEL_RESTART_LIMIT "${HEALER_LABEL_RESTART_LIMIT}" '.Config.Labels[$HEALER_LABEL_RESTART_LIMIT] // 10')
    healer_restart_limit_cmd=$(echo "$container_data" | jq -r --arg HEALER_LABEL_RESTART_LIMIT_CMD "${HEALER_LABEL_RESTART_LIMIT_CMD}" '.Config.Labels[$HEALER_LABEL_RESTART_LIMIT_CMD] // "ignore"')

    container_restarts="container_${container_id}_restarts"
    [[ -n "${!container_restarts:-}" ]] || export "${container_restarts}"=0
    if [[ "${!container_restarts}" -ge "${healer_restart_limit:-10}" ]]; then
        if [[ "${healer_restart_limit_cmd}" != "ignore" ]]; then
            echo "Container $container_name ($container_id) is unhealthy and has been restarted ${!container_restarts} times, $healer_restart_limit_cmd container..."
            docker "$healer_restart_limit_cmd" "$container_id"
            echo "Container $container_name ($container_id) has been stopped! Please fix the container manually."
        else
            echo "Container $container_name ($container_id) is unhealthy and has been restarted ${!container_restarts} times, ignoring..."
        fi
        return 0
    fi

    if [[ "${compose_project:-null}" == "null" ]]; then
        if [[ "${healer_enabled:-false}" == "true" ]]; then
            echo "Container $container_name ($container_id) is unhealthy, restarting (restarts: ${!container_restarts})..."
            export "${container_restarts}"=$((container_restarts + 1))
            docker restart "$container_id" &
        elif [[ "${healer_monitor_only:-false}" == "true" ]]; then
            echo "Container $container_name ($container_id) is unhealthy, but is set to monitor only, skipping..."
        else
            echo "Container $container_name ($container_id) is unhealthy, but healer is not enabled, skipping..."
        fi
        return 0
    fi

    if [[ "${compose_project:-null}" != "null" ]]; then
        compose_service=$(echo "$container_data" | jq -r '.Config.Labels."com.docker.compose.service"')
        project_working_dir=$(echo "$container_data" | jq -r '.Config.Labels."com.docker.compose.project.working_dir"')
        container_network_link=$(echo "$container_data" | jq -r '.HostConfig.NetworkMode | match("container:(.+)").captures | first | .string')

        if [[ "${healer_enabled:-false}" == "true" ]]; then
            echo "Service $container_name ($container_id) in project \"$compose_project\" is unhealthy, restarting service (restarts: ${!container_restarts})..."
            export "${container_restarts}"=$((container_restarts + 1))

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
        elif [[ "${healer_monitor_only:-false}" == "true" ]]; then
            echo "Service $compose_service ($container_id) in project $compose_project is unhealthy, but is set to monitor only, skipping..."
        else
            echo "Service $compose_service ($container_id) in project $compose_project is unhealthy, but healer is not enabled, skipping..."
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

echo "Starting Compose Healer..."

check_for_unhealthy_containers

wait_for_unhealthy_events
