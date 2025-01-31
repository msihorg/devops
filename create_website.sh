#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./create_folders.sh domain.com app_name"
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
        echo "$DOMAIN www.$DOMAIN"
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

# Create necessary directories
sudo mkdir -p /var/www/certbot
sudo mkdir -p /etc/nginx/ssl

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
    
    if [ "$env" = "prod" ]; then
        echo "$DOMAIN and www.$DOMAIN - Port: $port"
    else
        echo "$env.$DOMAIN - Port: $port"
    fi
    
    test_connectivity $env
done

echo -e "\nImportant next steps:"
echo "1. Update your DNS records to point to this server"
echo "2. Deploy your application files to the appropriate directories"
echo "3. Check the logs if you encounter any issues:"
echo "   - Nginx logs: /var/log/nginx/"
echo "   - Application logs: journalctl -u blazor-*"