# Excalidraw Unified

Excalidraw with real-time collaboration support in a single Docker container. Includes frontend, collaboration server (room), and Nginx as reverse proxy.

## Architecture

```
Container (port 6001)
├── Nginx (reverse proxy)
├── Excalidraw Frontend (static files)
└── Excalidraw Room Server (WebSocket on internal port 3002)
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `EXCALIDRAW_URL` | Public URL where Excalidraw will be accessed. Used to configure the collaboration WebSocket. | `http://localhost` |

The WebSocket URL is derived automatically:
- `https://example.com` → `wss://example.com`
- `http://example.com` → `ws://example.com`

## Deployment

### Docker

```bash
docker build -t excalidraw-unified .

docker run -d \
  -p 6001:6001 \
  -e EXCALIDRAW_URL=https://draw.example.com \
  excalidraw-unified
```

### Dokploy

1. Create a new application of type **Dockerfile**
2. Configure the Git repository or upload the Dockerfile
3. In **Environment Variables**, add:
   ```
   EXCALIDRAW_URL=https://your-domain.com
   ```
4. Configure the domain pointing to port `6001`
5. Deploy

### Docker Compose

```yaml
services:
  excalidraw:
    build: .
    ports:
      - "6001:6001"
    environment:
      - EXCALIDRAW_URL=https://draw.example.com
    restart: unless-stopped
```

## Health Check

The container exposes a health check endpoint at `/health` on port 6001.

## License

This project only packages the official projects:
- [excalidraw/excalidraw](https://github.com/excalidraw/excalidraw)
- [excalidraw/excalidraw-room](https://github.com/excalidraw/excalidraw-room)
