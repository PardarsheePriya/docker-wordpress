#!/bin/bash

# Prompt user for site details
read -p "Enter the site name (e.g., site2): " SITE_NAME
read -p "Enter the Nginx port for this site (default 8080): " PORT
PORT=${PORT:-8080}

# Save site name and port to the database
MYSQL_HOST="139.84.166.143"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASSWORD="root_password"  # Specify your password
DB_NAME="docker_monitor"

echo "Saving site details to the database..."
mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" <<EOF
USE ${DB_NAME};
INSERT INTO container_ports (container_name, port) VALUES ('${SITE_NAME}', ${PORT})
ON DUPLICATE KEY UPDATE port=${PORT};
EOF

# Define variables
SITE_FOLDER="./sites/${SITE_NAME}"
WORDPRESS_FOLDER="${SITE_FOLDER}/wordpress"
DOCKERFILE="${SITE_FOLDER}/Dockerfile"
WP_CONFIG="${WORDPRESS_FOLDER}/wp-config.php"
PHP_PORT=$(shuf -i 9001-9999 -n 1)
DB_USER="${SITE_NAME}"
DB_PASSWORD="${SITE_NAME}@${PORT}"

# Create the folder structure
mkdir -p "${WORDPRESS_FOLDER}"

# Download and extract WordPress into the wordpress folder
wget https://wordpress.org/latest.zip -O "${WORDPRESS_FOLDER}/latest.zip"
unzip "${WORDPRESS_FOLDER}/latest.zip" -d "${WORDPRESS_FOLDER}"
mv "${WORDPRESS_FOLDER}/wordpress/"* "${WORDPRESS_FOLDER}"
rmdir "${WORDPRESS_FOLDER}/wordpress"
rm "${WORDPRESS_FOLDER}/latest.zip"

# Fix permissions for WordPress files
sudo chown -R www-data:www-data "${WORDPRESS_FOLDER}"
sudo chmod -R 755 "${WORDPRESS_FOLDER}"

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
    define( 'ABSPATH', __DIR__ . '/' );
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

# Create a Dockerfile for the PHP-FPM container
cat <<EOL > "${DOCKERFILE}"
# Use the official PHP 8 FPM image as the base image
FROM php:8-fpm

# Install required PHP extensions
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libonig-dev \
    libxml2-dev \
    libzip-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd \
    && docker-php-ext-install mysqli \
    && docker-php-ext-install pdo pdo_mysql \
    && docker-php-ext-install mbstring

# Set the working directory
WORKDIR /var/www/html

# Copy WordPress files into the container
COPY ./wordpress /var/www/html

# Set permissions
RUN chown -R www-data:www-data /var/www/html && chmod -R 755 /var/www/html

# Expose PHP-FPM port
EXPOSE 9000

# Start PHP-FPM
CMD ["php-fpm"]

EOL

# Build and run the PHP-FPM container without using cache
docker build --no-cache -t wordpress-${SITE_NAME} "${SITE_FOLDER}"
docker rm -f wordpress_${SITE_NAME} || true  # Remove existing container if exists
docker run -d --name wordpress_${SITE_NAME} \
    -v "${WORDPRESS_FOLDER}:/var/www/html" \
    -p "${PHP_PORT}:9000" \
    wordpress-${SITE_NAME}

# Create a custom Nginx configuration
NGINX_CONFIG="/etc/nginx/conf.d/${SITE_NAME}.conf"

cat <<EOL > "${NGINX_CONFIG}"
server {
    listen ${PORT};
    server_name unitedzero.com;

    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:${PHP_PORT};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Reload Nginx and allow the port
sudo ufw allow ${PORT}
sudo nginx -t && sudo systemctl restart nginx

echo "Setup complete. Access your site at http://unitedzero.com:${PORT}/"