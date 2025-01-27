# /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;

# Optimize HTTP/2 specifically
worker_rlimit_nofile 65535;

events {
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

http {
    # HTTP/2 specific settings
    http2_max_field_size 16k;
    http2_max_header_size 32k;
    http2_max_requests 5000;
    http2_push_preload on;

    # Basic Settings
    include mime.types;
    default_type application/octet-stream;
    types {
        application/wasm wasm;
    }

    # Blazor optimization
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    reset_timedout_connection on;
    client_body_timeout 10;
    send_timeout 2;
    client_max_body_size 10m;

    # Buffer size optimizations for Blazor
    client_body_buffer_size 128k;
    client_header_buffer_size 3m;
    large_client_header_buffers 4 256k;
    output_buffers 2 512k;
    postpone_output 1460;

    # Compression Settings
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/wasm;
    gzip_min_length 1000;

    # Brotli Settings
    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/wasm;

    # SSL Settings for HTTP/2
    ssl_protocols TLSv1.3;  # TLS 1.3 only in 2025
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_buffer_size 4k;

    # Hide server tokens
    server_tokens off;

    # File cache settings
    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # Access log settings
    access_log /var/log/nginx/access.log combined buffer=512k flush=1m;
    error_log /var/log/nginx/error.log warn;

    # Include other configurations
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
