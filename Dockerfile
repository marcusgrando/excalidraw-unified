# =============================================================================
# Excalidraw Unified - Single image with Frontend + Room + Nginx
# Using Bun for faster builds and runtime
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Build Excalidraw Frontend
# -----------------------------------------------------------------------------
FROM oven/bun:1-alpine AS frontend-builder

WORKDIR /opt/excalidraw

RUN apk add --no-cache git

RUN git clone --depth 1 https://github.com/excalidraw/excalidraw.git .

RUN bun install

ENV VITE_APP_WS_SERVER_URL="__EXCALIDRAW_WS_URL__"
ENV VITE_APP_DISABLE_TRACKING=true
ENV NODE_ENV=production

RUN bun run build:app:docker

# -----------------------------------------------------------------------------
# Stage 2: Build Excalidraw Room Server
# -----------------------------------------------------------------------------
FROM oven/bun:1-alpine AS room-builder

WORKDIR /opt/room

RUN apk add --no-cache git

RUN git clone --depth 1 https://github.com/excalidraw/excalidraw-room.git .

RUN bun install && bun run build

RUN rm -rf node_modules && bun install --production

# -----------------------------------------------------------------------------
# Stage 3: Final Image
# -----------------------------------------------------------------------------
FROM oven/bun:1-alpine

LABEL maintainer="excalidraw-unified"
LABEL description="Excalidraw with collaboration support in a single container"

RUN apk add --no-cache nginx supervisor bash

RUN mkdir -p /var/log/supervisor /run/nginx /app/frontend /app/room

COPY --from=frontend-builder /opt/excalidraw/excalidraw-app/build /app/frontend
COPY --from=room-builder /opt/room/dist /app/room/dist
COPY --from=room-builder /opt/room/node_modules /app/room/node_modules
COPY --from=room-builder /opt/room/package.json /app/room/

# -----------------------------------------------------------------------------
# Nginx Configuration (inline)
# -----------------------------------------------------------------------------
RUN cat > /etc/nginx/nginx.conf << 'NGINX_EOF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/rss+xml application/atom+xml image/svg+xml;

    upstream room_server {
        server 127.0.0.1:3002;
    }

    server {
        listen 6001;
        server_name _;

        root /app/frontend;
        index index.html;

        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;

        location /socket.io/ {
            proxy_pass http://room_server;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 86400;
            proxy_send_timeout 86400;
        }

        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
            try_files $uri =404;
        }

        location / {
            try_files $uri $uri/ /index.html;
        }

        location /health {
            access_log off;
            return 200 "OK\n";
            add_header Content-Type text/plain;
        }
    }
}
NGINX_EOF

# -----------------------------------------------------------------------------
# Supervisor Configuration (inline)
# -----------------------------------------------------------------------------
RUN cat > /etc/supervisor/conf.d/supervisord.conf << 'SUPERVISOR_EOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
loglevel=info

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:room]
command=bun run /app/room/dist/index.js
directory=/app/room
autostart=true
autorestart=true
priority=20
environment=PORT="3002",NODE_ENV="production"
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
SUPERVISOR_EOF

# -----------------------------------------------------------------------------
# Entrypoint Script (inline)
# -----------------------------------------------------------------------------
RUN cat > /entrypoint.sh << 'ENTRYPOINT_EOF'
#!/bin/bash
set -e

PLACEHOLDER="__EXCALIDRAW_WS_URL__"
FRONTEND_DIR="/app/frontend"

if [ -z "$EXCALIDRAW_URL" ]; then
    echo "[entrypoint] EXCALIDRAW_URL not set, using http://localhost"
    EXCALIDRAW_URL="http://localhost"
fi

EXCALIDRAW_URL="${EXCALIDRAW_URL%/}"

if [[ "$EXCALIDRAW_URL" == https://* ]]; then
    WS_URL="${EXCALIDRAW_URL/https:/wss:}"
else
    WS_URL="${EXCALIDRAW_URL/http:/ws:}"
fi

echo "[entrypoint] Base URL: $EXCALIDRAW_URL"
echo "[entrypoint] WebSocket URL: $WS_URL"

find "$FRONTEND_DIR" -name "*.js" -type f | while read -r file; do
    if grep -q "$PLACEHOLDER" "$file" 2>/dev/null; then
        sed -i "s|$PLACEHOLDER|$WS_URL|g" "$file"
    fi
done

echo "[entrypoint] Starting services..."
exec "$@"
ENTRYPOINT_EOF

RUN chmod +x /entrypoint.sh

ENV EXCALIDRAW_URL=http://localhost

EXPOSE 6001

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:6001/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
