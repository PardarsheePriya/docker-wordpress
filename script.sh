#!/bin/bash

# Prompt user for site details
read -p "Enter the site name (e.g., site2): " SITE_NAME
read -p "Enter the port number (e.g., 8081): " PORT

# Save site name and port number to the database
MYSQL_HOST="139.84.166.143"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASSWORD="root_password"
DB_NAME="docker_monitor"

echo "Saving site details to the database..."
mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" <<EOF
USE ${DB_NAME};
INSERT INTO container_ports (container_name, port) VALUES ('${SITE_NAME}', ${PORT})
ON DUPLICATE KEY UPDATE port=${PORT};
EOF

# Check if the data was inserted successfully
if [ $? -eq 0 ]; then
    echo "Site details saved successfully: ${SITE_NAME} on port ${PORT}"
else
    echo "Failed to save site details. Please check your database connection and credentials."
    exit 1
fi

# Define variables
SITE_FOLDER="./sites/${SITE_NAME}"
WORDPRESS_FOLDER="${SITE_FOLDER}/wordpress"
DOCKER_COMPOSE_FILE="${SITE_FOLDER}/docker-compose-${SITE_NAME}.yml"
DOCKERFILE="${SITE_FOLDER}/Dockerfile"
WP_CONFIG="${WORDPRESS_FOLDER}/wp-config.php"
DB_USER="${SITE_NAME}"
DB_PASSWORD="${SITE_NAME}@2024"  # Strong password
NGINX_CONF_DIR="/etc/nginx/sites-available"  # Directory for Nginx configuration files
NGINX_CONF="${NGINX_CONF_DIR}/${SITE_NAME}.conf"  # Specific Nginx configuration file for this site
SUBNET="192.168.$((RANDOM % 200 + 50)).0/24"  # Generate a unique subnet dynamically

# Create the folder structure
mkdir -p "${WORDPRESS_FOLDER}"

# Download and extract WordPress
wget https://wordpress.org/latest.zip -O "${WORDPRESS_FOLDER}/latest.zip"
unzip "${WORDPRESS_FOLDER}/latest.zip" -d "${WORDPRESS_FOLDER}"
mv "${WORDPRESS_FOLDER}/wordpress/"* "${WORDPRESS_FOLDER}"
rmdir "${WORDPRESS_FOLDER}/wordpress"
rm "${WORDPRESS_FOLDER}/latest.zip"

# Fetch salts for wp-config.php
SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

# Create wp-config.php
cat <<EOL > "${WP_CONFIG}"
<?php
define( 'DB_NAME', '${SITE_NAME}' );
define( 'DB_USER', '${DB_USER}' );
define( 'DB_PASSWORD', '${DB_PASSWORD}' );
define( 'DB_HOST', '${MYSQL_HOST}:${MYSQL_PORT}' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

${SALTS}

\$table_prefix = 'wp_';

define( 'WP_DEBUG', false );

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', _DIR_ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
EOL

# Create MySQL database and user
echo "Creating MySQL database and user..."
mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS ${SITE_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${SITE_NAME}.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
EOF

# Create a Dockerfile for the WordPress site
cat <<EOL > "${DOCKERFILE}"
FROM php:8-fpm

RUN apt-get update && apt-get install -y \
    libpng-dev libjpeg-dev libfreetype6-dev libonig-dev libxml2-dev libzip-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd mysqli pdo pdo_mysql mbstring opcache

WORKDIR /var/www/html
COPY ./wordpress /var/www/html
RUN chown -R www-data:www-data /var/www/html && chmod -R 755 /var/www/html

EXPOSE 9000
CMD ["php-fpm"]
EOL

# Create a Docker Compose file for the WordPress container
cat <<EOL > "${DOCKER_COMPOSE_FILE}"
version: '3.8'

services:
  wordpress_${SITE_NAME}:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      WORDPRESS_DB_HOST: ${MYSQL_HOST}:${MYSQL_PORT}
      WORDPRESS_DB_NAME: ${SITE_NAME}
      WORDPRESS_DB_USER: ${DB_USER}
      WORDPRESS_DB_PASSWORD: ${DB_PASSWORD}
    volumes:
      - ./wordpress:/var/www/html
    networks:
      - wp-shared-network

networks:
  wp-shared-network:
    driver: bridge
    ipam:
      config:
        - subnet: ${SUBNET}
EOL

# Create a new Nginx configuration file for the site
echo "Creating Nginx configuration for site..."
cat <<EOL > "$NGINX_CONF"
server {
    listen ${PORT};
    server_name unitedzero.com;

    location / {
        proxy_pass http://wordpress_${SITE_NAME}:9000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Enable the new site by creating a symlink in sites-enabled
sudo ln -s "$NGINX_CONF" "/etc/nginx/sites-enabled/${SITE_NAME}.conf"

# Reload Nginx to apply changes
echo "Reloading Nginx..."
sudo systemctl reload nginx

# Prune old unused networks to avoid conflicts
echo "Cleaning up unused Docker networks..."
docker network prune -f

# Start the WordPress container
docker-compose -f "${DOCKER_COMPOSE_FILE}" up -d
echo "Site '${SITE_NAME}' is accessible at http://unitedzero.com:${PORT}."