#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./deploy_blazor.sh domain.com app_name"
    exit 1
fi

# Install required packages
sudo apt install -y certbot python3-certbot-nginx

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

get_server_names() {
    local env=$1
    if [ "$env" = "prod" ]; then
        echo "www.$DOMAIN $DOMAIN"
    else
        echo "$env.$DOMAIN"
    fi
}

test_connectivity() {
    local env=$1
    local server_names=$(get_server_names $env)
    
    for domain in $server_names; do
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
    done
}

create_test_html() {
    local env=$1
    local port=$2
    local server_names=$(get_server_names $env)
    local first_domain=$(echo $server_names | cut -d' ' -f1)
    
    local test_content="<!DOCTYPE html>
<html>
<head>
    <title>Test Page - $first_domain</title>
</head>
<body>
    <h1>Test Page for $first_domain</h1>
    <p>If you can see this page, the web server is working correctly.</p>
    <p>Created on: $(date)</p>
</body>
</html>"

    echo "$test_content" | sudo tee "$BASE_DIR/$DOMAIN/$env$port/testserver.html"
}

create_service_file() {
    local env=$1
    local port=$2
    
    # Map ASPNETCORE_ENVIRONMENT value
    local aspnet_env
    case "$env" in
        "prod")
            aspnet_env="Production"
            ;;
        "stage")
            aspnet_env="Staging"
            ;;
        "dev")
            aspnet_env="Development"
            ;;
        *)
            aspnet_env="${env^}"
            ;;
    esac

    local service_content="[Unit]
Description=$APP_NAME $env Environment
After=network.target

[Service]
WorkingDirectory=/var/www/$DOMAIN/$env$port
ExecStart=/usr/bin/dotnet /var/www/$DOMAIN/$env$port/$APP_NAME.dll
Environment=ASPNETCORE_URLS=http://localhost:$port
Environment=ASPNETCORE_ENVIRONMENT=$aspnet_env
Restart=always
RestartSec=10
SyslogIdentifier=$APP_NAME-$env
User=www-data

[Install]
WantedBy=multi-user.target"

    echo "$service_content" | sudo tee "/etc/systemd/system/blazor-$env-$APP_NAME.service"
}

create_nginx_config() {
    local env=$1
    local port=$2
    local domain=$DOMAIN
    
    # Create the configuration directory if it doesn't exist
    sudo mkdir -p /etc/nginx/sites-available
    
    # Define rate limits based on environment
    local rate_limit="30r/s"
    local burst_limit="60"
    case "$env" in
        "prod")
            rate_limit="10r/s"
            burst_limit="20"
            csp="default-src 'self'; img-src 'self' data: https:; connect-src 'self' wss: https:; upgrade-insecure-requests;"
            ;;
        *)
            csp="default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data: https:; connect-src 'self' wss: https:; upgrade-insecure-requests;"
            ;;
    esac

    # Create the Nginx configuration
    cat << EOF | sudo tee "/etc/nginx/sites-available/$env.$domain"

# WebSocket upgrade mapping
map \$http_connection \$connection_upgrade {
    "~*Upgrade" \$http_connection;
    default keep-alive;
}

# HTTP redirect to HTTPS
server {
    listen 80;
    server_name $(get_server_names $env);
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name $(get_server_names $env);
    root /var/www/$domain/$env$port;

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/$([ "$env" = "prod" ] && echo "www.$domain" || echo "$env.$domain")/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$([ "$env" = "prod" ] && echo "www.$domain" || echo "$env.$domain")/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header Content-Security-Policy "$csp" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    # Logging
    access_log /var/log/nginx/${env}.${domain}_access.log combined buffer=512k flush=1m;
    error_log /var/log/nginx/${env}.${domain}_error.log warn;

    # Blazor framework files
    location /_framework {
        expires 7d;
        add_header Cache-Control "public, must-revalidate, max-age=604800";
    }

    # WASM files
    location ~* \.wasm$ {
        expires 7d;
        add_header Cache-Control "public, must-revalidate, max-age=604800";
        add_header Content-Type "application/wasm";
    }

    # API endpoints with rate limiting
    location /api {
        proxy_pass http://localhost:$port;
        include /etc/nginx/proxy.conf;
        
        limit_req zone=${env}_api burst=$burst_limit nodelay;
        limit_req_status 429;
        
        error_page 429 /rate_limit.html;
    }

    # SignalR/WebSocket endpoint
    location /_blazor {
        proxy_pass http://localhost:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300s;
    }

    # Health checks
    location /health {
        proxy_pass http://localhost:$port/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        access_log off;
        proxy_cache off;
    }

    # Development tools (only in non-prod environments)
    location /swagger {
        $([ "$env" = "prod" ] && echo "return 404;" || echo "")
        proxy_pass http://localhost:$port;
        include /etc/nginx/proxy.conf;
    }

    # Static files with versioning
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform, max-age=2592000";
        try_files \$uri =404;
    }

    # Versioned static files (immutable content)
    location ~* '^.+\.[0-9a-f]{8}\.(css|js)$'{
        expires 1y;
        add_header Cache-Control "public, immutable, max-age=31536000";
        try_files \$uri =404;
    }

    # Root location
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }
}
EOF

    # Create symbolic link if it doesn't exist
    if [ ! -f "/etc/nginx/sites-enabled/$env.$domain" ]; then
        sudo ln -s "/etc/nginx/sites-available/$env.$domain" "/etc/nginx/sites-enabled/"
    fi

    # Verify the configuration
    sudo nginx -t
}

setup_ssl() {
    local env=$1
    local server_names=$(get_server_names $env)
    local domain_args=""
    
    # Build domain arguments for certbot
    for domain in $server_names; do
        domain_args="$domain_args -d $domain"
    done
    
    if [ "$env" = "prod" ]; then
        # For production, check both www and naked domain
        if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            sudo certbot certonly --nginx $domain_args
        fi
    else
        # For other environments, check the subdomain
        if [ ! -f "/etc/letsencrypt/live/$env.$DOMAIN/fullchain.pem" ]; then
            sudo certbot certonly --nginx $domain_args
        fi
    fi
}

create_proxy_conf() {
    # Create proxy.conf if it doesn't exist
    if [ ! -f "/etc/nginx/proxy.conf" ]; then
        cat << 'EOF' | sudo tee "/etc/nginx/proxy.conf"
# HTTP/2 support
proxy_http_version 1.1;

# Buffer settings
proxy_buffering off;
proxy_buffer_size 128k;
proxy_buffers 4 256k;
proxy_busy_buffers_size 256k;

# Header configurations
proxy_set_header Host $host;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# Security headers
proxy_set_header X-Content-Type-Options 'nosniff';
proxy_set_header X-XSS-Protection '1; mode=block';
proxy_set_header Referrer-Policy 'strict-origin-when-cross-origin';

# Cache and timeout settings
proxy_cache_bypass $http_upgrade;
proxy_read_timeout 600s;
proxy_connect_timeout 600s;
proxy_send_timeout 600s;
client_max_body_size 50M;

# Compression
gzip on;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/wasm;
gzip_min_length 1000;
gzip_proxied any;
EOF
    fi
}

# Main execution starts here
# Create necessary directories
sudo mkdir -p /var/www/certbot
sudo mkdir -p /etc/nginx/ssl
sudo mkdir -p /etc/nginx/conf.d

# Create proxy.conf
create_proxy_conf

# Deploy each environment
for env in dev stage prod; do
    base_var="${env^^}_BASE"
    port=$(get_next_port ${!base_var})
    
    # Create directories
    sudo mkdir -p "$BASE_DIR/$DOMAIN/$env$port"
    sudo chown -R www-data:www-data "$BASE_DIR/$DOMAIN/$env$port"
    
    # Create configuration files
    create_test_html $env $port
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

# Print setup summary
echo -e "\nSetup completed successfully!"
echo -e "\nCreated environments:"
for env in dev stage prod; do
    base_var="${env^^}_BASE"
    port=$(get_next_port ${!base_var})