#!/bin/bash
# make executable: chmod +x script.sh

# Check if required arguments are provided
if [ -z "$1" ] || [ -z "$2" ]; then
   echo "Usage: ./create_folders.sh domain.com app_name"
   exit 1
fi

# Set variables
DOMAIN="$1"
APP_NAME="$2"
BASE_DIR="/var/www"
# Port ranges for each environment
DEV_BASE=2000    # Dev ports: 2001-2999
STAGE_BASE=3000  # Stage ports: 3001-3999
PROD_BASE=4000   # Prod ports: 4001-4999

# Find next available port in range for environment
get_next_port() {
   local env_base=$1
   local max_port=$env_base
   for port in $(find $BASE_DIR -type d -name "*[0-9]*" | grep -oP "[0-9]+$"); do
       if (( port > max_port && port < env_base+1000 )); then
           max_port=$port
       fi
   done
   echo $((max_port+1))
}

# Create systemd service file for Blazor app
create_service_file() {
   local env=$1
   local port=$2
   local service_content="[Unit]
Description=$APP_NAME $env Environment
After=network.target

[Service]
WorkingDirectory=/var/www/$env.$DOMAIN
ExecStart=/usr/bin/dotnet /var/www/$env.$DOMAIN/$APP_NAME.dll
Environment=ASPNETCORE_URLS=http://localhost:$port
Environment=ASPNETCORE_ENVIRONMENT=${env^}
Restart=always
RestartSec=10
SyslogIdentifier=$APP_NAME-$env
User=www-data

[Install]
WantedBy
=multi-user.target"

   echo "$service_content" | sudo tee "/etc/systemd/system/blazor-$env-$APP_NAME.service"
}

# Create Nginx configuration with SSL support
create_nginx_config() {
   local env=$1
   local port=$2
   local nginx_content="server {
   listen 80;
   listen 443 ssl;
   server_name $env.$DOMAIN;
   
   location / {
       proxy_pass http://localhost:$port;
       proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection keep-alive;
       proxy_set_header Host \$host;
       proxy_cache_bypass \$http_upgrade;
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto \$scheme;
   }

   # Additional security headers
   add_header X-Frame-Options \"SAMEORIGIN\";
   add_header X-XSS-Protection \"1; mode=block\";
   add_header X-Content-Type-Options \"nosniff\";
}"
   
   echo "$nginx_content" | sudo tee "/etc/nginx/sites-available/$env.$DOMAIN"
   # Create symbolic link if it doesn't exist
   if [ ! -f "/etc/nginx/sites-enabled/$env.$DOMAIN" ]; then
       sudo ln -s "/etc/nginx/sites-available/$env.$DOMAIN" "/etc/nginx/sites-enabled/"
   fi
}

# Create folders and configs for each environment# make executable: chmod +x script.sh
for env in dev stage prod; do
   base_var="${env^^}_BASE"
   port=$(get_next_port ${!base_var})
   
   # Create directory structure
   sudo mkdir -p "$BASE_DIR/$DOMAIN/$env$port"
   sudo chown www-data:www-data "$BASE_DIR/$DOMAIN/$env$port"
   
   # Set up service and nginx
   create_service_file $env $port
   create_nginx_config $env $port
   
   # Generate SSL certificate
   sudo certbot --nginx -d $env.$DOMAIN
done

# Reload services
sudo systemctl daemon-reload
sudo nginx -t && sudo systemctl reload nginx

# Start services
for env in dev stage prod; do
   sudo systemctl enable blazor-$env-$APP_NAME
   sudo systemctl start blazor-$env-$APP_NAME
done

echo "Setup completed successfully!"
echo "Created environments:"
for env in dev stage prod; do
   base_var="${env^^}_BASE"
   port=$(get_next_port ${!base_var})
   echo "$env.$DOMAIN - Port: $port"
done