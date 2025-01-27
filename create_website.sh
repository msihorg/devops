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
    local proxy_conf="# HTTP/2 support
proxy_http_version 1.1;

# Buffer settings
proxy_buffering off;
proxy_buffer_size 128k;
proxy_buffers 4 256k;
proxy_busy_buffers_size 256k;

# Header configurations
proxy_set_header Host \$host;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection 'upgrade';
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_set_header X-Forwarded-Host \$host;
proxy_set_header X-Forwarded-Port \$server_port;

# Security headers
proxy_set_header X-Content-Type-Options 'nosniff';
proxy_set_header X-XSS-Protection '1; mode=block';
proxy_set_header Referrer-Policy 'strict-origin-when-cross-origin';

# Cache and timeout settings
proxy_cache_bypass \$http_upgrade;
proxy_read_timeout 600s;
proxy_connect_timeout 600s;
proxy_send_timeout 600s;
client_max_body_size 50M;

# WebSocket specific settings
proxy_set_header Connection 'upgrade';
proxy_cache off;
proxy_http_version 1.1;

# Compression for better performance
gzip on;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/wasm;
gzip_min_length 1000;
gzip_proxied any;

# CORS headers if needed
#add_header 'Access-Control-Allow-Origin' '*' always;
#add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE' always;
#add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;

# Error handling
proxy_intercept_errors on;
proxy_next_upstream error timeout http_500 http_502 http_503 http_504;"

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
    load_module modules/ngx_http_brotli_module.so;

    events {
        worker_connections 10000;
        use epoll;
        multi_accept on;
    }

    http {
        include /etc/nginx/proxy.conf;
        include mime.types;
        
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        server_tokens off;

        # Brotli Settings
        brotli on;
        brotli_comp_level 6;
        brotli_types application/javascript application/json application/wasm text/css;

        # Gzip Settings
        gzip on;
        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level 6;
        gzip_types application/javascript application/json application/wasm text/css;

        # Rate Limiting
        limit_req_zone \$binary_remote_addr zone=api:10m rate=$rate_limit;
        
        server {
            listen 80;
            server_name $env.$DOMAIN;

            # Blazor WebAssembly
            location / {
                root /var/www/$DOMAIN/$env$port;
                try_files \$uri \$uri/ /index.html =404;
                
                # Cache static files
                location ~* \.(css|js|wasm)$ {
                    expires 30d;
                    add_header Cache-Control \"public, no-transform\";
                }

                # WebSocket support for SignalR
                location /_blazor {
                    proxy_pass http://localhost:$port;
                    proxy_http_version 1.1;
                    proxy_set_header Upgrade \$http_upgrade;
                    proxy_set_header Connection \"upgrade\";
                    proxy_cache_bypass \$http_upgrade;
                }
            }

            # For framework files
            location /_framework {
                expires 7d;  # More reasonable timeframe
                add_header Cache-Control "public, must-revalidate";
            }

            # For WASM files
            location ~* \.wasm$ {
                expires 7d;
                add_header Cache-Control "public, must-revalidate";
                add_header Content-Type application/wasm;
            }

            # API endpoints
            location /api {
                proxy_pass http://localhost:$port;
                include /etc/nginx/proxy.conf;
                limit_req zone=api burst=$burst_limit nodelay;
                limit_req_status 429;
            }

            # Health check endpoint
            location /health {
                proxy_pass http://localhost:$port;
                access_log off;
                include /etc/nginx/proxy.conf;
            }

            location /testserver.html {
                root /var/www/$DOMAIN/$env$port;
            }

            

            # Allow version query parameters to bypass cache
            location ~* ^.+\.(css|js|wasm)$ {
                expires 30d;
    
                # Break cache if query string changes
                add_header Cache-Control "public, no-cache, must-revalidate, proxy-revalidate";
                if ($args) {
                    expires -1;
                }
            }       

            # Handle versioned files differently
            location ~* ^.+\.[0-9a-f]{8}\.(css|js|wasm)$ {
                expires 1y;
                add_header Cache-Control "public, immutable";
            }

            # Security Headers
            add_header X-Frame-Options SAMEORIGIN;
            add_header X-Content-Type-Options nosniff;
            add_header X-XSS-Protection \"1; mode=block\";
            add_header Content-Security-Policy \"default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; connect-src 'self' wss:;\";
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
