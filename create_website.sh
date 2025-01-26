#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
   echo "Usage: ./create_folders.sh domain.com app_name"
   exit 1
fi

DOMAIN="$1"
APP_NAME="$2"
BASE_DIR="/var/www"
DEV_BASE=2000
STAGE_BASE=3000
PROD_BASE=4000

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

test_connectivity() {
    local env=$1
    local domain="$env.$DOMAIN"
    
    echo "Testing connectivity for $domain..."
    
    # Test HTTP
    if curl -s -o /dev/null -w "%{http_code}" "http://$domain/testserver.html" | grep -q "200"; then
        echo "✓ HTTP connection successful"
    else
        echo "✗ HTTP connection failed"
    fi
    
    # Test HTTPS if certificate exists
    if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
        if curl -s -o /dev/null -w "%{http_code}" "https://$domain/testserver.html" | grep -q "200"; then
            echo "✓ HTTPS connection successful"
        else
            echo "✗ HTTPS connection failed"
        fi
    else
        echo "! HTTPS not configured"
    fi
    echo
}

create_test_html() {
    local env=$1
    local port=$2
    local protocol="HTTP"
    if [ -f "/etc/letsencrypt/live/$env.$DOMAIN/fullchain.pem" ]; then
        protocol="HTTP/HTTPS"
    fi
    
    local test_content="<!DOCTYPE html>
<html>
<head>
    <title>Test Page - $env.$DOMAIN</title>
</head>
<body>
    <h1>Test Page for $env.$DOMAIN</h1>
    <p>If you can see this page, the web server is working correctly over $protocol.</p>
    <p>Environment: $env</p>
    <p>Protocol: $protocol</p>
    <p>Timestamp: $(date)</p>
</body>
</html>"
    
    echo "$test_content" | sudo tee "$BASE_DIR/$DOMAIN/$env$port/testserver.html"
}

create_service_file() {
   local env=$1
   local port=$2
   local service_content="[Unit]
Description=$APP_NAME $env Environment
After=network.target

[Service]
WorkingDirectory=/var/www/$DOMAIN/$env$port
ExecStart=/usr/bin/dotnet /var/www/$DOMAIN/$env$port/$APP_NAME.dll
Environment=ASPNETCORE_URLS=http://localhost:$port
Environment=ASPNETCORE_ENVIRONMENT=${env^}
Restart=always
RestartSec=10
SyslogIdentifier=$APP_NAME-$env
User=www-data

[Install]
WantedBy=multi-user.target"

   echo "$service_content" | sudo tee "/etc/systemd/system/blazor-$env-$APP_NAME.service"
}

create_proxy_conf() {
    local proxy_conf="proxy_http_version 1.1;
proxy_buffering off;
proxy_set_header Host \$host;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection keep-alive;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_cache_bypass \$http_upgrade;"

    echo "$proxy_conf" | sudo tee "/etc/nginx/proxy.conf"
}

create_nginx_config() {
   local env=$1
   local port=$2
   local ssl_configured=false
   
   if [ -f "/etc/letsencrypt/live/$env.$DOMAIN/fullchain.pem" ]; then
       ssl_configured=true
   fi

   create_proxy_conf

   local nginx_content="http {
    include /etc/nginx/proxy.conf;
    limit_req_zone \$binary_remote_addr zone=one:10m rate=5r/s;
    server_tokens off;
    sendfile on;
    keepalive_timeout 29;
    client_body_timeout 10;
    client_header_timeout 10;
    send_timeout 10;

    upstream ${APP_NAME,,}app {
        server 127.0.0.1:$port;
    }

    server {
        listen 80;
        server_name $env.$DOMAIN;"

    if [ "$ssl_configured" = true ]; then
        nginx_content+="
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        ssl_certificate /etc/letsencrypt/live/$env.$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$env.$DOMAIN/privkey.pem;
        ssl_session_timeout 1d;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
        ssl_session_cache shared:SSL:10m;
        ssl_session_tickets off;
        ssl_stapling off;"
    fi

    nginx_content+="
    location / {
        root /var/www/$DOMAIN/$env$port;
        try_files $uri $uri/ /index.html =404;
        proxy_pass http://${APP_NAME,,}app:$port;
        limit_req zone=one burst=60 nodelay;
    }

    location /testserver.html {
        root $BASE_DIR/$env.$DOMAIN;
        internal;
    }

    # Security headers
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
}"
   
   echo "$nginx_content" | sudo tee "/etc/nginx/sites-available/$env.$DOMAIN"
   if [ ! -f "/etc/nginx/sites-enabled/$env.$DOMAIN" ]; then
       sudo ln -s "/etc/nginx/sites-available/$env.$DOMAIN" "/etc/nginx/sites-enabled/"
   fi
}

setup_ssl() {
    local env=$1
    if [ ! -f "/etc/letsencrypt/live/$env.$DOMAIN/fullchain.pem" ]; then
        sudo certbot --nginx -d $env.$DOMAIN
        # Update Nginx config after SSL setup
        create_nginx_config $env $port
    fi
}

for env in dev stage prod; do
   base_var="${env^^}_BASE"
   port=$(get_next_port ${!base_var})
   
   # Create directory and set permissions
   sudo mkdir -p "$BASE_DIR/$DOMAIN/$env$port"
   sudo chown www-data:www-data "$BASE_DIR/$DOMAIN/$env$port"
   
   # Create test HTML file
   create_test_html $env $port
   
   # Set up configurations
   create_service_file $env $port
   create_nginx_config $env $port
   setup_ssl $env
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
   test_connectivity $env
done