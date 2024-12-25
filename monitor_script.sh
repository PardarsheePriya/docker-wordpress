#!/bin/bash

# Database Details
MYSQL_HOST="139.84.166.143"
MYSQL_PORT="3306"
DB_NAME="docker_monitor"
DB_USER="root"
DB_PASSWORD="root_password"

# Interval for checking logs (in seconds)
CHECK_INTERVAL=60

# Inactivity timeout (in minutes) to stop containers
INACTIVITY_TIMEOUT=2
INACTIVITY_SECONDS=$((INACTIVITY_TIMEOUT * 60))

# Log directory for tracking activity
LOG_DIR="/tmp/docker_monitor_logs"
mkdir -p "${LOG_DIR}"

# Function to initialize the database table for container ports
initialize_database() {
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" <<EOF
CREATE TABLE IF NOT EXISTS container_ports (
    site_name VARCHAR(255) PRIMARY KEY,
    port INT NOT NULL
);
EOF
}

# Function to retrieve container port from the database based on the site name
get_container_port() {
    local site_name="$1"
    mysql -N -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" <<EOF
SELECT port FROM container_ports WHERE container_name='${site_name}';
EOF
}

# Function to extract site name from container name
extract_site_name() {
    local container_name="$1"
    echo "$container_name" | awk -F'_' '{print $1}'
}

# Function to check if a container is handling HTTP/HTTPS requests
check_container_activity() {
    local container_name="$1"
    local log_file="${LOG_DIR}/${container_name}.log"

    # Get container logs for the last 60 seconds
    docker logs --since "${CHECK_INTERVAL}s" "$container_name" > "$log_file" 2>/dev/null

    # Check for HTTP/HTTPS requests in the logs
    if grep -qE "GET|POST|PUT|DELETE|HEAD|OPTIONS" "$log_file"; then
        echo "$(date): Activity detected in container $container_name"
        return 0
    else
        echo "$(date): No activity detected in container $container_name"
        return 1
    fi
}

# Function to manage container states
manage_containers() {
    local containers
    containers=$(docker ps --filter "name=wordpress_" --format "{{.Names}}")

    for container in $containers; do
        local log_file="${LOG_DIR}/${container}_timestamp"

        # Check container activity
        if check_container_activity "$container"; then
            # Reset the timestamp if there's activity
            echo "$(date +%s)" > "$log_file"
        else
            # Read the last active timestamp
            local last_active
            if [[ -f "$log_file" ]]; then
                last_active=$(<"$log_file")
            else
                last_active=$(date +%s)
                echo "$last_active" > "$log_file"
            fi

            # Calculate inactivity duration
            local current_time
            current_time=$(date +%s)
            local inactivity_duration=$((current_time - last_active))

            if (( inactivity_duration > INACTIVITY_SECONDS )); then
                echo "$(date): Stopping inactive container $container"
                docker stop "$container"
                rm -f "$log_file"
            fi
        fi
    done
}

# Function to restart stopped containers on new requests
restart_containers_on_request() {
    local containers
    containers=$(docker ps --filter "name=wordpress_" --filter "status=exited" --format "{{.Names}}")

    for container in $containers; do
        echo "$(date): Checking stopped container $container"

        # Extract site name from container name
        local site_name
        site_name=$(extract_site_name "$container")

        # Retrieve the port from the database
        local container_port
        container_port=$(get_container_port "$site_name")

        if [[ -z "$container_port" ]]; then
            echo "$(date): No port mapping found in the database for site $site_name"
            continue
        fi

        echo "$(date): Testing HTTP/HTTPS request on port $container_port"
        if curl -s -I "http://localhost:${container_port}" | grep -q "HTTP"; then
            echo "$(date): Restarting container $container due to incoming HTTP request"
            docker start "$container"
        elif curl -s -I "https://localhost:${container_port}" --insecure | grep -q "HTTP"; then
            echo "$(date): Restarting container $container due to incoming HTTPS request"
            docker start "$container"
        else
            echo "$(date): No HTTP/HTTPS activity detected for container $container"
        fi
    done
}

# Function to handle Ctrl+C and gracefully stop the script
cleanup() {
    echo "$(date): Script interrupted. Stopping..."
    exit 0
}

# Initialize database table
initialize_database

# Trap Ctrl+C (SIGINT) and call the cleanup function
trap cleanup SIGINT

# Main loop
while true; do
    echo "$(date): Monitoring containers..."
    manage_containers
    restart_containers_on_request
    sleep "$CHECK_INTERVAL"
done