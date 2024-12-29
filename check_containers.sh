#!/bin/bash

# Path to the output HTML file
output_file="/usr/share/nginx/html/container_status.html"

# Function to check if a container is active
check_container_activity() {
    local container_name="$1"
    local status=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)

    if [[ "$status" == "true" ]]; then
        echo "ACTIVE"
    else
        echo "INACTIVE"
    fi
}

# Function to generate an HTML file with container statuses
generate_html() {
    local containers
    containers=$(docker ps -a --format "{{.Names}}")

    # Start of HTML
    cat <<EOF > "$output_file"
<!DOCTYPE html>
<html>
<head>
    <title>Docker Container Status</title>
    <style>
        table {
            width: 50%;
            border-collapse: collapse;
            margin: 20px auto;
        }
        th, td {
            border: 1px solid #ddd;
            padding: 8px;
            text-align: left;
        }
        th {
            background-color: #f2f2f2;
        }
    </style>
</head>
<body>
    <h2 style="text-align: center;">Docker Container Status</h2>
    <table>
        <tr>
            <th>CONTAINER NAME</th>
            <th>STATUS</th>
        </tr>
EOF

    # Loop through each container and add rows to the table
    for container in $containers; do
        local status
        status=$(check_container_activity "$container")
        echo "        <tr><td>$container</td><td>$status</td></tr>" >> "$output_file"
    done

    # End of HTML
    cat <<EOF >> "$output_file"
    </table>
</body>
</html>
EOF
}

# Main script execution
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed or not running. Please ensure Docker is installed and running."
    exit 1
fi

# Check if Nginx is installed
if ! command -v nginx &> /dev/null; then
    echo "Nginx is not installed. Please install Nginx to serve the HTML file."
    exit 1
fi

# Generate the HTML file
generate_html

echo "HTML file generated at $output_file."

# Provide instructions to view the HTML file
server_ip=$(hostname -I | awk '{print $1}')
echo "You can view the container status at http://$server_ip/container_status.html"