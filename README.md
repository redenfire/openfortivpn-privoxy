[🇬🇧 English version](README.en.md)

# openfortivpn + Privoxy Docker

Container Docker che connette una VPN Fortinet via openfortivpn ed espone un proxy HTTP via Privoxy sulla porta `8118` (le richieste HTTPS passano via `CONNECT`).

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
      - VPN_DOMAIN=dominio.interno.locale
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

Poi configura il browser/proxy del sistema su `http://localhost:8118`.

> `VPN_DOMAIN` deve essere un nome che risolve **solo tramite la VPN**: è usato come health check. Un dominio pubblico (es. `google.com`) risolverebbe anche a tunnel spento, falsando il controllo.

---

## Variabili d'ambiente

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `VPN_HOST` | — | Host del server VPN (obbligatorio) |
| `VPN_PORT` | `443` | Porta del server VPN |
| `VPN_USER` | — | Utente VPN (obbligatorio) |
| `VPN_PASS` | — | Password VPN (obbligatorio) |
| `VPN_DOMAIN` | — | Dominio interno usato per l'health check DNS (obbligatorio) |
| `PRIVOXY_PERMIT` | — | Reti permesse da Privoxy (separate da spazio, obbligatorio) |
| `VPN_CERT_HASH` | — | Hash del certificato trusted per openfortivpn (opzionale) |
| `VPN_SET_DNS` | — | Flag `--set-dns` per openfortivpn (opzionale) |
| `VPN_PEERDNS` | — | Flag `--pppd-use-peerdns` per openfortivpn (opzionale) |

Le route verso le reti VPN vengono installate direttamente da openfortivpn: non serve configurarle a mano.

---

## Build

```bash
docker build -t openfortivpn-privoxy .
```

## Reti e permessi

Il container richiede `NET_ADMIN` per creare `ppp0` più l'accesso al device `/dev/ppp` dell'host (non serve `privileged`). Verifica che esista:

```bash
ls -l /dev/ppp
```

Se manca, carica il modulo sull'host: `modprobe ppp_generic`.

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
2. Lancia `openfortivpn` in background (installa da sé le route VPN via `ppp0`)
3. Ogni 20 secondi controlla: `ppp0` ha un indirizzo IPv4? `VPN_DOMAIN` risolve? openfortivpn e Privoxy sono vivi?
4. Se una condizione fallisce, chiude il tunnel e riconnette dopo 10 secondi

---

## Sicurezza

- `VPN_PASS` in variabile d'ambiente è leggibile con `docker inspect` e da Portainer. Non committare il compose con credenziali reali; se possibile usa un `env_file` con permessi ristretti.
- Privoxy ascolta su `0.0.0.0:8118`: senza un `permit-access` corretto è un proxy aperto. Verifica che i CIDR in `PRIVOXY_PERMIT` siano accettati dalla tua versione di Privoxy.
