#!/bin/bash

# Prompt user for site details
read -p "Enter the site name (e.g., site2): " SITE_NAME
read -p "Enter the port number for Nginx (default 8080): " PORT
PORT=${PORT:-8080}

# Save site name and port to the database
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
NGINX_CONFIG_FOLDER="${SITE_FOLDER}/nginx"
NGINX_CONFIG="${NGINX_CONFIG_FOLDER}/default-${SITE_NAME}.conf"
DOCKER_COMPOSE_FILE="${SITE_FOLDER}/docker-compose-${SITE_NAME}.yml"
DOCKERFILE="${SITE_FOLDER}/Dockerfile"
WP_CONFIG="${WORDPRESS_FOLDER}/wp-config.php"
DB_USER="${SITE_NAME}"
DB_PASSWORD="${SITE_NAME}@${PORT}"  # Strong password combining site name and port
SUBNET="192.168.$((RANDOM % 200 + 50)).0/24"  # Generate a unique subnet dynamically

# Create the folder structure
mkdir -p "${WORDPRESS_FOLDER}"
mkdir -p "${NGINX_CONFIG_FOLDER}"

# Download and extract WordPress into the wordpress folder
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

# Create a custom Nginx configuration for the site
cat <<EOL > "${NGINX_CONFIG}"
server {
    listen 80;
    server_name localhost;

    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass wordpress_${SITE_NAME}:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Create a Docker Compose file for the WordPress site
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

  nginx_${SITE_NAME}:
    image: nginx:latest
    volumes:
      - ./nginx/default-${SITE_NAME}.conf:/etc/nginx/conf.d/default.conf
      - ./wordpress:/var/www/html
    ports:
      - "${PORT}:80"
    depends_on:
      - wordpress_${SITE_NAME}
    networks:
      - wp-shared-network

networks:
  wp-shared-network:
    driver: bridge
    ipam:
      config:
        - subnet: ${SUBNET}
EOL

# Prune old unused networks to avoid conflicts
echo "Cleaning up unused Docker networks..."
docker network prune -f

# Start the containers
docker-compose -f "${DOCKER_COMPOSE_FILE}" up -d
echo "Containers for site '${SITE_NAME}' are running on port ${PORT} with subnet ${SUBNET}."