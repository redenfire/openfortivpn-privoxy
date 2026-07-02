[🇬🇧 English version](README.en.md)

# openfortivpn + Privoxy Docker

Container Docker che connette una VPN Fortinet via openfortivpn ed espone un proxy HTTP/S via Privoxy sulla porta `8118`.

---

## Utilizzo

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

Poi configura il browser/proxy del sistema su `http://localhost:8118`.

---

## Variabili d'ambiente

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `VPN_HOST` | — | Host del server VPN (obbligatorio) |
| `VPN_PORT` | — | Porta del server VPN (obbligatorio) |
| `VPN_USER` | — | Utente VPN (obbligatorio) |
| `VPN_PASS` | — | Password VPN (obbligatorio) |
| `VPN_DOMAIN` | `google.com` | Dominio usato per l'health check DNS |
| `VPN_ROUTES` | — | Route da aggiungere via gateway Docker (separate da spazio, obbligatorio) |
| `PRIVOXY_PERMIT` | — | Reti permesse da Privoxy (separate da spazio, obbligatorio) |
| `VPN_CERT_HASH` | — | Hash del certificato trusted per openfortivpn (opzionale) |
| `VPN_SET_DNS` | — | Flag `--set-dns` per openfortivpn (opzionale) |
| `VPN_PEERDNS` | — | Flag `--pppd-use-peerdns` per openfortivpn (opzionale) |

---

## Build

```bash
docker build -t openfortivpn-privoxy .
```

## Reti

Il container richiede i permessi `NET_ADMIN` e `NET_RAW` per creare l'interfaccia `ppp0` e aggiungere le route.

Puoi collegarlo a reti Docker custom:

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

## Come funziona

1. Avvia Privoxy con le reti permesse da `PRIVOXY_PERMIT`
2. Aggiunge le route definite in `VPN_ROUTES` via il gateway Docker
3. Lancia `openfortivpn` in background
4. Ogni 20 secondi controlla: DNS risolve `VPN_DOMAIN`? Interfaccia `ppp0` è up? Processo openfortivpn è vivo?
5. Se una condizione fallisce, kill e riconnessione