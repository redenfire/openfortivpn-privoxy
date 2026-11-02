[🇬🇧 English version](README.en.md)

# openfortivpn + Privoxy Docker

Container Docker che connette una VPN Fortinet via openfortivpn ed espone un proxy HTTP via Privoxy sulla porta `8118` (le richieste HTTPS passano via `CONNECT`).

---

## Utilizzo

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
      - VPN_DOMAIN=dominio.interno.locale
      - PRIVOXY_PERMIT=192.168.1.0/24 10.0.0.0/8 localhost 127.0.0.1
      # Opzionali, vedi "Certificate validation":
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

Poi configura il browser/proxy del sistema su `http://localhost:8118`.

> `VPN_DOMAIN` deve essere un nome che risolve **solo tramite la VPN**: è usato come health check. Un dominio pubblico (es. `google.com`) risolverebbe anche a tunnel spento, falsando il controllo.

---

## Certificate validation

Il container **non disabilita mai la validazione TLS per default** e non contiene certificati cablati. La strategia predefinita è il trust store di sistema: l'immagine installa `ca-certificates` ed esegue `update-ca-certificates`, quindi i gateway con certificati emessi da CA pubbliche (Actalis, Let's Encrypt, DigiCert, ecc.) funzionano senza impostare nulla.

Le strategie disponibili sono, in ordine di preferenza:

1. **Trust store di sistema (default)** — nessuna variabile certificato. Copre le CA pubbliche.
2. **`VPN_CA_FILE`** — bundle PEM con una CA privata/self-signed, montato come volume read-only. Viene passato come `--ca-file=<file>`. Il file deve esistere ed essere leggibile, altrimenti il container esce con errore. Assicurati che contenga la catena necessaria al gateway (CA intermedie incluse).
3. **`VPN_TRUSTED_CERTS`** — pinning di uno o più digest SHA-256 (64 caratteri hex), separati da spazi o virgole. Ogni digest viene passato come `--trusted-cert=<digest>`. È la scelta consigliata per gateway self-signed o setup HA/load balancer con certificati diversi. La lista viene deduplicata e validata prima dell'avvio.
4. **`VPN_CERT_HASH` (deprecato)** — alias retrocompatibile per un singolo digest. Se impostato viene aggiunto alla lista dei trusted cert e viene loggato un warning che invita a usare `VPN_TRUSTED_CERTS`. Per compatibilità viene accettato anche il prefisso `sha256$`, che viene rimosso prima di passare il digest a openfortivpn.
5. **`VPN_AUTO_TRUST_CERT` (opt-in)** — se `true`, esegue un tentativo di connessione con timeout breve (`VPN_AUTO_TRUST_TIMEOUT`, default `15` secondi) **senza** trusted-cert, cerca nell'output il digest suggerito da openfortivpn (`--trusted-cert <digest>`, `--trusted-cert=<digest>` o `trusted-cert = <digest>`) e riavvia la connessione aggiungendolo alla lista. Se non trova il digest, il container esce con errore.
6. **`VPN_INSECURE_SSL=true` (sconsigliato)** — passa `--insecure-ssl` e disabilita la validazione. Non è mai attivo per default e viene loggato un warning esplicito.

### Limiti di `VPN_AUTO_TRUST_CERT`

- Esegue un tentativo di connessione **fallito a ogni avvio** del container (non a ogni riconnessione). Il probe usa `--set-routes=0 --set-dns=0` per non installare route né modificare il DNS.
- Aggiunge **un solo digest**: non gestisce setup multi-certificato/HA. In quei casi usa `VPN_TRUSTED_CERTS` con tutti i digest.
- Viene saltato se sono già presenti trusted-cert espliciti, se `VPN_CA_FILE` è impostato o se `VPN_INSECURE_SSL` è attivo.
- Se non trova un digest, termina con exit non-zero. Questo include il caso in cui il gateway usa una CA pubblica e il probe si connette senza errori: in quel caso `VPN_AUTO_TRUST_CERT` non serve e va disabilitato. Logga l'output del tentativo per facilitare la diagnosi.
- È pensato come rete di sicurezza, non come sostituto del pinning esplicito: un digest noto e versionato è più prevedibile e sicuro.

### Errori TLS `tlsv1 alert internal error`

Alcuni gateway Fortinet richiedono cipher più datate. Imposta:

```yaml
environment:
  - VPN_CIPHER_LIST=DEFAULT@SECLEVEL=1
```

Il valore viene passato come `--cipher-list "<valore>"` senza modificare l'immagine. Non viene impostato alcun cipher list custom per default.

### Scenari di esempio

Il file [`docker-compose.yml`](docker-compose.yml) contiene tre servizi con profili separati:

| Scenario | Profilo | Variabili chiave |
|----------|---------|------------------|
| CA pubblica | `public-ca` | nessuna variabile certificato |
| CA personalizzata | `custom-ca` | `VPN_CA_FILE=/certs/ca.pem` + volume PEM |
| Trusted cert multipli | `trusted-certs` | `VPN_TRUSTED_CERTS=digest1,digest2` |

```bash
docker compose --profile public-ca up
docker compose --profile custom-ca up
docker compose --profile trusted-certs up
```

---

## Variabili d'ambiente

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `VPN_HOST` | — | Host del server VPN (obbligatorio) |
| `VPN_PORT` | `443` | Porta del server VPN |
| `VPN_USER` | — | Utente VPN (obbligatorio) |
| `VPN_PASS` | — | Password VPN (obbligatorio) |
| `VPN_DOMAIN` | — | Dominio interno usato solo per diagnostica DNS, non per decidere se la VPN è attiva (obbligatorio) |
| `PRIVOXY_PERMIT` | — | Reti permesse da Privoxy (separate da spazio, obbligatorio) |
| `VPN_CA_FILE` | — | Bundle PEM della CA da passare come `--ca-file` (opzionale) |
| `VPN_TRUSTED_CERTS` | — | Uno o più digest SHA-256 (64 hex), separati da spazi o virgole; ognuno diventa un `--trusted-cert` (opzionale) |
| `VPN_CERT_HASH` | — | **Deprecato**: alias per un singolo trusted-cert; usare `VPN_TRUSTED_CERTS` |
| `VPN_AUTO_TRUST_CERT` | `false` | Se `true`, prova a estrarre il digest dal messaggio di errore del gateway e riconnette con `--trusted-cert` |
| `VPN_AUTO_TRUST_TIMEOUT` | `15` | Secondi del tentativo iniziale usato da `VPN_AUTO_TRUST_CERT` |
| `VPN_CIPHER_LIST` | — | Valore per `--cipher-list` (es. `DEFAULT@SECLEVEL=1`) |
| `VPN_INSECURE_SSL` | `false` | Se `true`, passa `--insecure-ssl`. Disabilita la validazione TLS: sconsigliato |
| `VPN_SET_DNS` | — | Flag `--set-dns` per openfortivpn (opzionale; in Docker valuta `0` se `/etc/resolv.conf` è read-only) |
| `VPN_PEERDNS` | — | Flag `--pppd-use-peerdns` per openfortivpn (opzionale) |
| `VPN_CHECK_INTERVAL` | `20` | Secondi tra i controlli dello stato VPN |
| `VPN_CONNECT_TIMEOUT` | `60` | Secondi di attesa perché `ppp0` ottenga un indirizzo IPv4 |
| `VPN_FAIL_THRESHOLD` | `3` | Controlli consecutivi falliti prima di riavviare la VPN |

Le route verso le reti VPN vengono installate direttamente da openfortivpn: non serve configurarle a mano.

---

## Build

```bash
docker build -t openfortivpn-privoxy .
```

L'immagine compila openfortivpn dall'ultima release upstream (build multi-stage), perché la versione nei repository di Ubuntu 22.04 è troppo vecchia per FortiOS recenti. Per cambiare versione usa `--build-arg OPENFORTIVPN_VERSION=x.y.z`.

### Tag immagine

La workflow GitHub pubblica la nuova versione con due tag:

| Tag | Uso |
|-----|-----|
| `:cert` | tag "mobile" della nuova versione |
| `:cert-2026.11` | tag di versione della nuova release |

**`:latest` non viene più aggiornata**: resta ferma sull'immagine precedente alla modifica dei certificati ed è sempre disponibile per il rollback.

```yaml
# nuova versione (tag mobile)
image: ghcr.io/redenfire/openfortivpn-privoxy:cert

# nuova versione (tag di release)
image: ghcr.io/redenfire/openfortivpn-privoxy:cert-2026.11

# rollback alla versione precedente
image: ghcr.io/redenfire/openfortivpn-privoxy:latest
```

Per rendere esplicito e permanente il riferimento alla vecchia immagine, prima del primo push della nuova pipeline conviene salvarla anche come `:legacy`:

```bash
docker pull ghcr.io/redenfire/openfortivpn-privoxy:latest
docker tag ghcr.io/redenfire/openfortivpn-privoxy:latest \
  ghcr.io/redenfire/openfortivpn-privoxy:legacy
docker push ghcr.io/redenfire/openfortivpn-privoxy:legacy
```

Per una build locale con entrambi i nuovi tag:

```bash
docker build \
  -t ghcr.io/redenfire/openfortivpn-privoxy:cert \
  -t ghcr.io/redenfire/openfortivpn-privoxy:cert-2026.11 .

docker push ghcr.io/redenfire/openfortivpn-privoxy:cert
docker push ghcr.io/redenfire/openfortivpn-privoxy:cert-2026.11
```

Entrambi i tag sono **mutabili**: vengono spostati a ogni build della pipeline (inclusa quella schedulata ogni giorno). Se ti serve un riferimento davvero immutabile, blocca il digest:

```bash
docker pull ghcr.io/redenfire/openfortivpn-privoxy@sha256:<digest>
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

1. Valida le variabili e le opzioni del certificato, poi avvia Privoxy con le reti permesse da `PRIVOXY_PERMIT`
2. Lancia `openfortivpn` in background (installa da sé le route VPN via `ppp0`)
3. Attende che `ppp0` ottenga un indirizzo IPv4 (fino a `VPN_CONNECT_TIMEOUT` secondi)
4. Ogni `VPN_CHECK_INTERVAL` secondi controlla che openfortivpn e Privoxy siano vivi e che `ppp0` abbia un indirizzo. Un errore DNS viene solo loggato, non chiude la VPN
5. Se `ppp0` resta senza indirizzo per `VPN_FAIL_THRESHOLD` controlli consecutivi (o openfortivpn muore), chiude il tunnel e riconnette dopo 10 secondi

Ogni decisione di configurazione viene loggata con il prefisso `[vpn-config]`: metodo di validazione attivo, trusted-cert passati, uso di CA custom, cipher list e fallback automatico.

---

## Test manuali consigliati

Sostituisci host, utente, password e dominio con valori reali. Per i test che non devono restare in esecuzione usa `timeout`.

```bash
IMG=openfortivpn-privoxy

# 1. CA pubblica: nessuna variabile certificato.
#    Atteso nei log: "[vpn-config] Validazione certificato: solo trust store di sistema..."
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 2. CA personalizzata: monta un PEM leggibile.
#    Atteso nei log: "CA personalizzato attivo" e "nessun trusted-cert".
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -v "$PWD/certs/ca.pem:/certs/ca.pem:ro" \
  -e VPN_CA_FILE=/certs/ca.pem \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 2b. File CA mancante: deve uscire subito con exit != 0 e messaggio chiaro.
docker run --rm -e VPN_CA_FILE=/certs/missing.pem \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"; echo "exit=$?"

# 3. Trusted cert multipli separati da spazio o virgola.
#    Atteso nei log: "2 trusted-cert configurati".
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_TRUSTED_CERTS="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 3b. Digest non valido: deve uscire subito con exit != 0.
docker run --rm -e VPN_TRUSTED_CERTS=non-un-digest \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"; echo "exit=$?"

# 4. Retrocompatibilità: VPN_CERT_HASH deve funzionare ma loggare il warning
#    di deprecazione che suggerisce VPN_TRUSTED_CERTS.
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_CERT_HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 5. Auto-trust su gateway self-signed: deve mostrare il probe, estrarre il
#    digest e riconnettersi con esso.
timeout 60 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_AUTO_TRUST_CERT=true \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 6. Cipher list: deve comparire nel log e come --cipher-list.
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_CIPHER_LIST="DEFAULT@SECLEVEL=1" \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 7. Insecure SSL: senza VPN_INSECURE_SSL deve loggare "disabilitato";
#    con =true deve loggare il warning e passare --insecure-ssl.
timeout 30 docker run --rm --cap-add NET_ADMIN --device /dev/ppp:/dev/ppp \
  -e VPN_INSECURE_SSL=true \
  -e VPN_HOST=vpn.example.com -e VPN_USER=user -e VPN_PASS=pass \
  -e VPN_DOMAIN=internal.domain.local -e PRIVOXY_PERMIT=127.0.0.1 \
  "$IMG"

# 8. Controllo statico dello script (Debian/Ubuntu: dash; Alpine: ash).
sh -n entrypoint.sh
# Se disponibile: shellcheck -s sh entrypoint.sh
```

Per verificare che openfortivpn abbia ricevuto davvero i due `--trusted-cert`, controlla la riga di log `Validazione certificato: 2 trusted-cert configurati (...)`. In alternativa, con il container in esecuzione:

```bash
docker exec <container> ps -ef | grep '[o]penfortivpn'
```

> Il comando `ps` mostra anche `--password`; non incollare l'output in issue o chat pubbliche.

---

## Sicurezza

- `VPN_PASS` in variabile d'ambiente è leggibile con `docker inspect` e da Portainer. Non committare il compose con credenziali reali; se possibile usa un `env_file` con permessi ristretti.
- Lo script non logga mai `VPN_PASS` né il contenuto del file CA.
- `VPN_INSECURE_SSL` non è mai attivo per default: abilitalo solo come scelta esplicita e consapevole.
- Privoxy ascolta su `0.0.0.0:8118`: senza un `permit-access` corretto è un proxy aperto. Verifica che i CIDR in `PRIVOXY_PERMIT` siano accettati dalla tua versione di Privoxy.
- Non viene scaricato alcun certificato a runtime da URL arbitrari: si usano solo il trust store di sistema e il file PEM fornito dall'utente.
