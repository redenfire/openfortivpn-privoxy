#!/bin/bash
set -u

# --- CONFIGURAZIONE ---
VPN_HOST=${VPN_HOST:?VPN_HOST non impostato}
VPN_PORT=${VPN_PORT:-443}
VPN_USER=${VPN_USER:?VPN_USER non impostato}
VPN_PASS=${VPN_PASS:?VPN_PASS non impostato}
VPN_DOMAIN=${VPN_DOMAIN:?VPN_DOMAIN non impostato}
PRIVOXY_PERMIT=${PRIVOXY_PERMIT:?PRIVOXY_PERMIT non impostato}

# Ogni quanti secondi controllare lo stato della VPN
VPN_CHECK_INTERVAL=${VPN_CHECK_INTERVAL:-20}
# Quanti secondi attendere che ppp0 ottenga un indirizzo IPv4
VPN_CONNECT_TIMEOUT=${VPN_CONNECT_TIMEOUT:-60}
# Quanti controlli consecutivi falliti prima di riavviare la VPN
VPN_FAIL_THRESHOLD=${VPN_FAIL_THRESHOLD:-3}

# --- 1. AVVIO PRIVOXY ---
for net in $PRIVOXY_PERMIT; do
    grep -qF "permit-access  $net" /etc/privoxy/config || \
        echo "permit-access  $net" >> /etc/privoxy/config
done

start_privoxy() {
    echo "Avvio Privoxy..."
    /usr/sbin/privoxy --no-daemon --user privoxy /etc/privoxy/config &
    PRIVOXY_PID=$!
}

start_privoxy

# --- 2. CICLO DI MANTENIMENTO VPN ---
echo "Inizio monitoraggio VPN..."

while true; do
    echo "Tentativo di connessione VPN..."

    openfortivpn "$VPN_HOST":"$VPN_PORT" \
        --username="$VPN_USER" \
        --password="$VPN_PASS" \
        ${VPN_CERT_HASH:+--trusted-cert "$VPN_CERT_HASH"} \
        ${VPN_SET_DNS:+--set-dns="$VPN_SET_DNS"} \
        ${VPN_PEERDNS:+--pppd-use-peerdns="$VPN_PEERDNS"} &

    VPN_PID=$!

    # Attesa iniziale: ppp0 deve ottenere un indirizzo IPv4.
    ready=0
    for ((i = 0; i < VPN_CONNECT_TIMEOUT; i++)); do
        if ! kill -0 "$VPN_PID" 2>/dev/null; then
            echo "$(date): openfortivpn terminato durante la connessione."
            break
        fi
        if ip -4 addr show dev ppp0 2>/dev/null | grep -q 'inet '; then
            ready=1
            break
        fi
        sleep 1
    done

    if [ "$ready" -eq 1 ]; then
        echo "$(date): VPN attiva (ppp0 con indirizzo IPv4)."
    else
        echo "$(date): VPN non attiva dopo ${VPN_CONNECT_TIMEOUT}s."
    fi

    # Sorveglianza: si chiude solo se la VPN muore o ppp0 perde l'indirizzo
    # per piu' controlli consecutivi. Un errore DNS non e' fatale.
    fails=0
    while kill -0 "$VPN_PID" 2>/dev/null; do
        if ! kill -0 "$PRIVOXY_PID" 2>/dev/null; then
            echo "$(date): Privoxy morto, lo riavvio."
            start_privoxy
        fi

        if ip -4 addr show dev ppp0 2>/dev/null | grep -q 'inet '; then
            fails=0
        else
            fails=$((fails + 1))
            echo "$(date): VPN DOWN - ppp0 senza indirizzo ($fails/$VPN_FAIL_THRESHOLD)."
            if [ "$fails" -ge "$VPN_FAIL_THRESHOLD" ]; then
                break
            fi
        fi

        # Diagnostica soltanto: non chiudere la VPN se il DNS non risolve.
        if ! getent hosts "$VPN_DOMAIN" &>/dev/null; then
            echo "$(date): WARN - DNS $VPN_DOMAIN non risolto (ignorato)."
        fi

        sleep "$VPN_CHECK_INTERVAL"
    done

    echo "$(date): chiusura VPN..."
    kill "$VPN_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do
        kill -0 "$VPN_PID" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$VPN_PID" 2>/dev/null
    wait "$VPN_PID" 2>/dev/null
    ip link del ppp0 2>/dev/null

    echo "$(date): riconnessione tra 10 secondi..."
    sleep 10
done
