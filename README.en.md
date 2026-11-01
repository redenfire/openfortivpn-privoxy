[🇮🇹 Versione italiana](README.md)

# openfortivpn + Privoxy Docker

Docker container that connects a Fortinet VPN via openfortivpn and exposes an HTTP proxy through Privoxy on port `8118` (HTTPS requests are tunneled via `CONNECT`).

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
      - VPN_DOMAIN=internal.domain.local
      - PRIVOXY_PERMIT=192.168.1.0/24 10.0.0.0/8 localhost 127.0.0.1
      # - VPN_CERT_HASH=sha256$xxxxxxxxxxxxxxxxxxxxxx
      # - VPN_SET_DNS=0
      # - VPN_PEERDNS=0
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/ppp:/dev/ppp
    ports:
      - "8118:8118"
```

Then point your browser/system proxy to `http://localhost:8118`.

> `VPN_DOMAIN` must be a name that resolves **only through the VPN**: it is used as the health check. A public domain (e.g. `google.com`) would resolve even with the tunnel down, defeating the check.

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VPN_HOST` | — | VPN server host (required) |
| `VPN_PORT` | `443` | VPN server port |
| `VPN_USER` | — | VPN username (required) |
| `VPN_PASS` | — | VPN password (required) |
| `VPN_DOMAIN` | — | Internal domain used only for DNS diagnostics, not to decide whether the VPN is up (required) |
| `PRIVOXY_PERMIT` | — | Networks allowed by Privoxy (space-separated, required) |
| `VPN_CERT_HASH` | — | Trusted certificate hash for openfortivpn (optional) |
| `VPN_SET_DNS` | — | `--set-dns` flag for openfortivpn (optional; in Docker consider `0` if `/etc/resolv.conf` is read-only) |
| `VPN_PEERDNS` | — | `--pppd-use-peerdns` flag for openfortivpn (optional) |
| `VPN_CHECK_INTERVAL` | `20` | Seconds between VPN status checks |
| `VPN_CONNECT_TIMEOUT` | `60` | Seconds to wait for `ppp0` to get an IPv4 address |
| `VPN_FAIL_THRESHOLD` | `3` | Consecutive failed checks before restarting the VPN |

Routes to the VPN networks are installed by openfortivpn itself: you do not need to configure them manually.

---

## Build

```bash
docker build -t openfortivpn-privoxy .
```

The image builds openfortivpn from the latest upstream release (multi-stage build), because the version shipped by Ubuntu 22.04 is too old for recent FortiOS. Use `--build-arg OPENFORTIVPN_VERSION=x.y.z` to pick another version.

## Networks and permissions

The container needs `NET_ADMIN` to create `ppp0` plus access to the host `/dev/ppp` device (`privileged` is not required). Check that it exists:

```bash
ls -l /dev/ppp
```

If missing, load the module on the host: `modprobe ppp_generic`.

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

1. Starts Privoxy with the networks allowed by `PRIVOXY_PERMIT`
2. Launches `openfortivpn` in the background (it installs the VPN routes via `ppp0` by itself)
3. Waits for `ppp0` to get an IPv4 address (up to `VPN_CONNECT_TIMEOUT` seconds)
4. Every `VPN_CHECK_INTERVAL` seconds checks that openfortivpn and Privoxy are alive and that `ppp0` has an address. A DNS error is only logged, it does not tear down the VPN
5. If `ppp0` stays without an address for `VPN_FAIL_THRESHOLD` consecutive checks (or openfortivpn exits), it tears down the tunnel and reconnects after 10 seconds

---

## Security

- `VPN_PASS` in an environment variable is readable via `docker inspect` and from Portainer. Do not commit the compose file with real credentials; use a restricted `env_file` where possible.
- Privoxy listens on `0.0.0.0:8118`: without a correct `permit-access` it is an open proxy. Make sure the CIDRs in `PRIVOXY_PERMIT` are accepted by your Privoxy version.
