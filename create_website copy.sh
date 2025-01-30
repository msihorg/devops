#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./create_folders.sh domain.com app_name"
    exit 1
fi

# Install required packages
sudo apt install -y nginx-module-brotli certbot python3-certbot-nginx

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
        if ((port > max_port && port < env_base + 1000)); then
            max_port=$port
        fi
    done
    echo $((max_port + 1))
}

test_connectivity() {
    local env=$1
    local domain="$env.$DOMAIN"

    echo "Testing connectivity for $domain..."

    if curl -s -o /dev/null -w "%{http_code}" "http://$domain/testserver.html" | grep -q "200"; then
        echo "✓ HTTP connection successful"
    else
        echo "✗ HTTP connection failed"
    fi

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
    local test_content="<!DOCTYPE html>
<html>
<head>
    <title>Test Page - $env.$DOMAIN</title>
</head>
<body>
    <h1>Test Page for $env.$DOMAIN</h1>
    <p>If you can see this page, the web server is working correctly.</p>
    <p>Environment: $env</p>
    <p>Created on: $(date)</p>
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
proxy_cache_bypass \$http_upgrade;
proxy_read_timeout 300;
proxy_connect_timeout 300;"

    echo "$proxy_conf" | sudo tee "/etc/nginx/proxy.conf"
}

create_nginx_config() {
    local env=$1
    local port=$2

    # Set rate limits based on environment
    local rate_limit="30r/s"
    local burst_limit="60"
    if [ "$env" = "prod" ]; then
        rate_limit="10r/s"
        burst_limit="20"
    fi

    create_proxy_conf

    local nginx_content="
 # /etc/nginx/sites-available/app-${ENV}.conf
map $http_connection $connection_upgrade {
    "~*Upgrade" $http_connection;
    default keep-alive;
}

server {
    listen 80;
    server_name ${ENV}.${DOMAIN};
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${ENV}.${DOMAIN};
    root /var/www/${DOMAIN}/${ENV};

    # SSL Configuration
    ssl_certificate /etc/nginx/ssl/${ENV}.${DOMAIN}.crt;
    ssl_certificate_key /etc/nginx/ssl/${ENV}.${DOMAIN}.key;

    # Logging
    access_log /var/log/nginx/${ENV}_access.log combined buffer=512k flush=1m;
    error_log /var/log/nginx/${ENV}_error.log warn;

    # Global security headers for all locations
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    
    # Environment-specific CSP
    set $csp "default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data: https:; connect-src 'self' wss: https:; upgrade-insecure-requests;";
    if ($env = "dev") {
        set $csp "${csp} style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval';";
    }
    add_header Content-Security-Policy $csp always;

    # Root location for static Blazor WASM files
    location / {
        try_files $uri $uri/ /index.html =404;
    }

    # Static framework files
    location /_framework {
        expires 7d;
        add_header Cache-Control "public, must-revalidate";
    }

    # WASM files
    location ~* \.wasm$ {
        expires 7d;
        add_header Cache-Control "public, must-revalidate";
        add_header Content-Type application/wasm;
    }

    # API Endpoints
    location /api {
        proxy_pass http://localhost:$port;
        include /etc/nginx/proxy.conf;
        
        # Environment-specific rate limiting
        if ($env = "prod") {
            limit_req zone=prod_api burst=10 nodelay;
            limit_req_status 429;
        }
        if ($env = "test") {
            limit_req zone=test_api burst=20 nodelay;
            limit_req_status 429;
        }
        if ($env = "dev") {
            limit_req zone=dev_api burst=30 nodelay;
            limit_req_status 429;
        }
        
        # Return error for blocked IPs
        if ($limit_key) {
            return 429;
        }
        
        # Custom error response
        error_page 429 /rate_limit.html;
    }

    # SignalR WebSocket
    location /_blazor {
        proxy_pass http://localhost:$port;
        include /etc/nginx/proxy.conf;
    }

    # Health checks
    location /health {
        proxy_pass http://localhost:$port/health;
        include /etc/nginx/proxy.conf;
        access_log off;
    }

    # Development tools
    location /swagger {
        if ($env != "dev") {
            return 404;
        }
        proxy_pass http://localhost:$port;
        include /etc/nginx/proxy.conf;
    }

    # Static assets with versioning support
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        
        if ($args) {
            expires -1;
        }
    }

    # Versioned static files
    location ~* ^.+\.[0-9a-f]{8}\.(css|js|wasm)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
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
    fi
}

for env in dev stage prod; do
    base_var="${env^^}_BASE"
    port=$(get_next_port ${!base_var})

    sudo mkdir -p "$BASE_DIR/$DOMAIN/$env$port"
    sudo chown www-data:www-data "$BASE_DIR/$DOMAIN/$env$port"

    create_test_html $env $port
    create_service_file $env $port
    create_nginx_config $env $port
    setup_ssl $env
done

sudo systemctl daemon-reload
sudo nginx -t && sudo systemctl reload nginx

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
