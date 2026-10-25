#!/bin/bash
set -u

# --- 1. AVVIO PRIVOXY ---
PRIVOXY_PERMIT=${PRIVOXY_PERMIT:?PRIVOXY_PERMIT non impostato}
for net in $PRIVOXY_PERMIT; do
    grep -qF "permit-access  $net" /etc/privoxy/config || \
        echo "permit-access  $net" >> /etc/privoxy/config
done

echo "Avvio Privoxy..."
/usr/sbin/privoxy --no-daemon --user privoxy /etc/privoxy/config &
PRIVOXY_PID=$!

# --- 2. CICLO DI MANTENIMENTO VPN ---
echo "Inizio monitoraggio VPN..."

VPN_HOST=${VPN_HOST:?VPN_HOST non impostato}
VPN_PORT=${VPN_PORT:-443}
VPN_USER=${VPN_USER:?VPN_USER non impostato}
VPN_PASS=${VPN_PASS:?VPN_PASS non impostato}
VPN_DOMAIN=${VPN_DOMAIN:?VPN_DOMAIN non impostato}

while true; do
    echo "Tentativo di connessione VPN..."

    openfortivpn "$VPN_HOST":"$VPN_PORT" \
        --username="$VPN_USER" \
        --password="$VPN_PASS" \
        ${VPN_CERT_HASH:+--trusted-cert "$VPN_CERT_HASH"} \
        ${VPN_SET_DNS:+--set-dns="$VPN_SET_DNS"} \
        ${VPN_PEERDNS:+--pppd-use-peerdns="$VPN_PEERDNS"} &

    VPN_PID=$!

    sleep 30

    while true; do
        if ! kill -0 "$VPN_PID" 2>/dev/null; then
            echo "Processo VPN terminato inaspettatamente."
            break
        fi

        if ! kill -0 "$PRIVOXY_PID" 2>/dev/null; then
            echo "$(date): Privoxy morto, lo riavvio."
            /usr/sbin/privoxy --no-daemon --user privoxy /etc/privoxy/config &
            PRIVOXY_PID=$!
        fi

        if ! ip -4 addr show dev ppp0 2>/dev/null | grep -q 'inet '; then
            echo "$(date): VPN DOWN - ppp0 senza indirizzo."
            break
        fi

        if ! getent hosts "$VPN_DOMAIN" &>/dev/null; then
            echo "$(date): VPN DOWN - DNS $VPN_DOMAIN non risolto."
            break
        fi

        sleep 20
    done

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
