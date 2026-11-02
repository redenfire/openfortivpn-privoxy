[🇮🇹 Versione italiana](README.md)

# openfortivpn + Privoxy Docker

Docker container that connects a Fortinet VPN via openfortivpn and exposes an HTTP proxy through Privoxy on port `8118` (HTTPS requests are tunneled via `CONNECT`).

---

## Usage

```yaml
services:
  vpn:
    image: ghcr.io/redenfire/openfortivpn-privoxy:cert
    restart: unless-stopped
    environment:
      - VPN_USER=username
      - VPN_PASS=password
      - VPN_HOST=vpn.example.com
      - VPN_PORT=443
      - VPN_DOMAIN=internal.domain.local
      - PRIVOXY_PERMIT=192.168.1.0/24 10.0.0.0/8 localhost 127.0.0.1
      # Optional, see "Certificate validation":
      # - VPN_CA_FILE=/certs/ca.pem
      # - VPN_TRUSTED_CERTS=digest1,digest2
      # - VPN_CIPHER_LIST=DEFAULT@SECLEVEL=1
      # - VPN_SET_DNS=0
      # - VPN_PEERDNS=0
    volumes:
      # - ./certs/ca.pem:/certs/ca.pem:ro
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

## Certificate validation

The container **never disables TLS validation by default** and does not ship hard-coded certificates. The default strategy is the system trust store: the image installs `ca-certificates` and runs `update-ca-certificates`, so gateways with certificates issued by public CAs (Actalis, Let's Encrypt, DigiCert, etc.) work without setting anything.

The available strategies are, in order of preference:

1. **System trust store (default)** — no certificate variable. Covers public CAs.
2. **`VPN_CA_FILE`** — PEM bundle with a private/self-signed CA, mounted as a read-only volume. It is passed as `--ca-file=<file>`. The file must exist and be readable, otherwise the container exits with an error. Make sure it contains the chain required by your gateway (including intermediate CAs).
3. **`VPN_TRUSTED_CERTS`** — pinning one or more SHA-256 digests (64 hex characters), separated by spaces or commas. Each digest is passed as `--trusted-cert=<digest>`. This is the recommended choice for self-signed gateways or HA/load-balanced setups with different certificates. The list is de-duplicated and validated before startup.
4. **`VPN_CERT_HASH` (deprecated)** — backwards-compatible alias for a single digest. If set, it is added to the trusted list and a warning suggesting `VPN_TRUSTED_CERTS` is logged. For backwards compatibility the `sha256$` prefix is also accepted and stripped before passing the digest to openfortivpn.
5. **`VPN_AUTO_TRUST_CERT` (opt-in)** — if `true`, performs one connection attempt with a short timeout (`VPN_AUTO_TRUST_TIMEOUT`, default `15` seconds) **without** trusted certs, looks in the output for the digest suggested by openfortivpn (`--trusted-cert <digest>`, `--trusted-cert=<digest>` or `trusted-cert = <digest>`) and reconnects adding it to the list. If it cannot find the digest, the container exits with an error.
6. **`VPN_INSECURE_SSL=true` (discouraged)** — passes `--insecure-ssl` and disables validation. It is never enabled by default and an explicit warning is logged.

### Limitations of `VPN_AUTO_TRUST_CERT`

- It performs a **failed connection attempt on every container start** (not on every reconnection). The probe uses `--set-routes=0 --set-dns=0` so it installs no routes and does not change DNS.
- It adds **a single digest**: it does not handle multi-certificate/HA setups. In those cases use `VPN_TRUSTED_CERTS` with every digest.
- It is skipped when explicit trusted certs are present, when `VPN_CA_FILE` is set, or when `VPN_INSECURE_SSL` is active.
- If it cannot find a digest, it exits non-zero. This includes the case where the gateway uses a public CA and the probe connects without errors: in that situation `VPN_AUTO_TRUST_CERT` is unnecessary and must be disabled. The probe output is logged to make diagnosis easier.
- It is intended as a safety net, not as a replacement for explicit pinning: a known, version-controlled digest is more predictable and secure.

### TLS errors `tlsv1 alert internal error`

Some Fortinet gateways require older ciphers. Set:

```yaml
environment:
  - VPN_CIPHER_LIST=DEFAULT@SECLEVEL=1
```

The value is passed as `--cipher-list "<value>"` without modifying the image. No custom cipher list is set by default.

### Example scenarios

The [`docker-compose.yml`](docker-compose.yml) file contains three services with separate profiles:

| Scenario | Profile | Key variables |
|----------|---------|---------------|
| Public CA | `public-ca` | no certificate variable |
| Custom CA | `custom-ca` | `VPN_CA_FILE=/certs/ca.pem` + PEM volume |
| Multiple trusted certs | `trusted-certs` | `VPN_TRUSTED_CERTS=digest1,digest2` |

```bash
docker compose --profile public-ca up
docker compose --profile custom-ca up
docker compose --profile trusted-certs up
```

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
| `VPN_CA_FILE` | — | PEM CA bundle passed as `--ca-file` (optional) |
| `VPN_TRUSTED_CERTS` | — | One or more SHA-256 digests (64 hex), separated by spaces or commas; each becomes a `--trusted-cert` (optional) |
| `VPN_CERT_HASH` | — | **Deprecated**: alias for a single trusted cert; use `VPN_TRUSTED_CERTS` |
| `VPN_AUTO_TRUST_CERT` | `false` | If `true`, extracts the digest from the gateway error and reconnects with `--trusted-cert` |
| `VPN_AUTO_TRUST_TIMEOUT` | `15` | Timeout in seconds for the initial probe used by `VPN_AUTO_TRUST_CERT` |
| `VPN_CIPHER_LIST` | — | Value for `--cipher-list` (e.g. `DEFAULT@SECLEVEL=1`) |
| `VPN_INSECURE_SSL` | `false` | If `true`, passes `--insecure-ssl`. Disables TLS validation: discouraged |
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

### Image tags

The GitHub workflow publishes the new version with two tags:

| Tag | Purpose |
|-----|---------|
| `:cert` | moving tag for the new version |
| `:cert-2026.11` | version tag for the new release |

**`:latest` is no longer updated**: it stays frozen on the image from before the certificate change, so it remains available for rollback.

```yaml
# new version (moving tag)
image: ghcr.io/redenfire/openfortivpn-privoxy:cert

# new version (release tag)
image: ghcr.io/redenfire/openfortivpn-privoxy:cert-2026.11

# rollback to the previous version
image: ghcr.io/redenfire/openfortivpn-privoxy:latest
```

To make the old image reference explicit and permanent, save it as `:legacy` before the new pipeline runs for the first time:

```bash
docker pull ghcr.io/redenfire/openfortivpn-privoxy:latest
docker tag ghcr.io/redenfire/openfortivpn-privoxy:latest \
  ghcr.io/redenfire/openfortivpn-privoxy:legacy
docker push ghcr.io/redenfire/openfortivpn-privoxy:legacy
```

For a local build with both new tags:

```bash
docker build \
  -t ghcr.io/redenfire/openfortivpn-privoxy:cert \
  -t ghcr.io/redenfire/openfortivpn-privoxy:cert-2026.11 .

docker push ghcr.io/redenfire/openfortivpn-privoxy:cert
docker push ghcr.io/redenfire/openfortivpn-privoxy:cert-2026.11
```

Both tags are **mutable**: they move on every pipeline build (including the daily scheduled one). If you need a truly immutable reference, pin the digest:

```bash
docker pull ghcr.io/redenfire/openfortivpn-privoxy@sha256:<digest>
```

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

1. Validates the variables and certificate options, then starts Privoxy with the networks allowed by `PRIVOXY_PERMIT`
2. Launches `openfortivpn` in the background (it installs the VPN routes via `ppp0` by itself)
3. Waits for `ppp0` to get an IPv4 address (up to `VPN_CONNECT_TIMEOUT` seconds)
4. Every `VPN_CHECK_INTERVAL` seconds checks that openfortivpn and Privoxy are alive and that `ppp0` has an address. A DNS error is only logged, it does not tear down the VPN
5. If `ppp0` stays without an address for `VPN_FAIL_THRESHOLD` consecutive checks (or openfortivpn exits), it tears down the tunnel and reconnects after 10 seconds

Every configuration decision is logged with the `[vpn-config]` prefix: active validation method, trusted certs passed, custom CA use, cipher list and automatic fallback.

---

## Recommended manual tests

Replace host, user, password and domain with real values. Use `timeout` for tests that should not keep running.

```bash
IMG=openfortivpn-privoxy

# 1. Public CA: no certificate variable.
#    Expected in the logs: "[vpn-config] Validazione certificato: solo trust store di sistema..."
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 2. Custom CA: mount a readable PEM file.
#    Expected in the logs: "CA personalizzato attivo" and "nessun trusted-cert".
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -v "$PWD/certs/ca.pem:/certs/ca.pem:ro" \
  -e VPN_CA_FILE=/certs/ca.pem \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 2b. Missing CA file: must exit immediately with a non-zero status and a
#     clear message.
docker run --rm -e VPN_CA_FILE=/certs/missing.pem \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"; echo "exit=$?"

# 3. Multiple trusted certs separated by a space or comma.
#    Expected in the logs: "2 trusted-cert configurati".
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_TRUSTED_CERTS="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 3b. Invalid digest: must exit immediately with a non-zero status.
docker run --rm -e VPN_TRUSTED_CERTS=not-a-digest \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"; echo "exit=$?"

# 4. Backwards compatibility: VPN_CERT_HASH must work but log the deprecation
#    warning suggesting VPN_TRUSTED_CERTS.
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_CERT_HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 5. Auto-trust on a self-signed gateway: must show the probe, extract the
#    digest and reconnect with it.
timeout 60 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_AUTO_TRUST_CERT=true \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 6. Cipher list: must appear in the logs and as --cipher-list.
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_CIPHER_LIST="DEFAULT@SECLEVEL=1" \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 7. Insecure SSL: without VPN_INSECURE_SSL it must log "disabilitato";
#    with =true it must log the warning and pass --insecure-ssl.
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_INSECURE_SSL=true \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 8. Static check of the script (Debian/Ubuntu: dash; Alpine: ash).
sh -n entrypoint.sh
# If available: shellcheck -s sh entrypoint.sh
```

To verify that openfortivpn actually received both `--trusted-cert` options, check the log line `Validazione certificato: 2 trusted-cert configurati (...)`. Alternatively, with the container running:

```bash
docker exec <container> ps -ef | grep '[o]penfortivpn'
```

> `ps` also shows `--password`; do not paste the output into public issues or chats.

---

## Security

- `VPN_PASS` in an environment variable is readable via `docker inspect` and from Portainer. Do not commit the compose file with real credentials; use a restricted `env_file` where possible.
- The script never logs `VPN_PASS` or the contents of the CA file.
- `VPN_INSECURE_SSL` is never enabled by default: turn it on only as an explicit, informed choice.
- Privoxy listens on `0.0.0.0:8118`: without a correct `permit-access` it is an open proxy. Make sure the CIDRs in `PRIVOXY_PERMIT` are accepted by your Privoxy version.
- No certificate is downloaded at runtime from arbitrary URLs: only the system trust store and the user-provided PEM file are used.
