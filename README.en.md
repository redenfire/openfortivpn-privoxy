[🇮🇹 Versione italiana](README.md)

# openfortivpn + Privoxy Docker

Docker container that connects a Fortinet VPN via openfortivpn and exposes an HTTP/S proxy through Privoxy on port `8118`.

---

## Usage

```yaml
services:
  vpn:
    image: ghcr.io/redenfire/openfortivpn-privoxy
    restart: unless-stopped
    environment:
      - VPN_USER=username
      - VPN_PASS=password
      - VPN_HOST=vpn.example.com
      - VPN_PORT=443
      - VPN_ROUTES=192.168.x.0/24 10.x.x.x/10
      - PRIVOXY_PERMIT=192.168.x.0/24 10.x.x.x/10 localhost 127.0.0.1
      - VPN_DOMAIN=google.com
      # - VPN_CERT_HASH=sha256$xxxxxxxxxxxxxxxxxxxxxx
      # - VPN_SET_DNS=0
      # - VPN_PEERDNS=0
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ports:
      - "8118:8118"
```

Then point your browser/system proxy to `http://localhost:8118`.

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VPN_HOST` | — | VPN server host (required) |
| `VPN_PORT` | — | VPN server port (required) |
| `VPN_USER` | — | VPN username (required) |
| `VPN_PASS` | — | VPN password (required) |
| `VPN_DOMAIN` | `google.com` | Domain used for DNS health check |
| `VPN_ROUTES` | — | Routes to add via Docker gateway (space-separated, required) |
| `PRIVOXY_PERMIT` | — | Networks allowed by Privoxy (space-separated, required) |
| `VPN_CERT_HASH` | — | Trusted certificate hash for openfortivpn (optional) |
| `VPN_SET_DNS` | — | `--set-dns` flag for openfortivpn (optional) |
| `VPN_PEERDNS` | — | `--pppd-use-peerdns` flag for openfortivpn (optional) |

---

## Build

```bash
docker build -t openfortivpn-privoxy .
```

## Networks

The container needs `NET_ADMIN` and `NET_RAW` capabilities to create the `ppp0` interface and add routes.

You can attach it to custom Docker networks:

```yaml
networks:
  my_net:
    external: true
  app_net:
    external: true

services:
  vpn:
    networks:
      my_net:
        ipv4_address: 192.168.x.x
      app_net:
        ipv4_address: 10.x.x.x
```

---

## How it works

1. Starts Privoxy with allowed networks from `PRIVOXY_PERMIT`
2. Adds routes from `VPN_ROUTES` via the Docker gateway
3. Launches `openfortivpn` in background
4. Every 20 seconds checks: does `VPN_DOMAIN` resolve? Is `ppp0` up? Is openfortivpn running?
5. If any condition fails, kills and reconnects