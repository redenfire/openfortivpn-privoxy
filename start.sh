#!/bin/bash

# --- 1. AVVIO PRIVOXY ---
PRIVOXY_PERMIT=${PRIVOXY_PERMIT:?PRIVOXY_PERMIT non impostato}
for net in $PRIVOXY_PERMIT; do
    echo "permit-access  $net" >> /etc/privoxy/config
done
echo "Avvio Privoxy..."
/usr/sbin/privoxy --user privoxy /etc/privoxy/config

# --- 2. GESTIONE ROUTING ---
echo "Configurazione instradamento..."
DOCKER_GW=$(ip route show default | awk '/default/ {print $3}')
VPN_ROUTES=${VPN_ROUTES:?VPN_ROUTES non impostato}
if [ -n "$DOCKER_GW" ]; then
    for net in $VPN_ROUTES; do
        ip route add "$net" via "$DOCKER_GW" dev eth0 2>/dev/null
    done
fi

# --- 3. CICLO DI MANTENIMENTO VPN ---
echo "Inizio monitoraggio VPN..."

VPN_DOMAIN=${VPN_DOMAIN:-google.com}

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
        if ! getent hosts "$VPN_DOMAIN" &>/dev/null; then
            echo "$(date): VPN DOWN - DNS $VPN_DOMAIN non risolto."
            kill $VPN_PID 2>/dev/null
            sleep 5
            break
        fi

        if ! ip link show ppp0 up &>/dev/null; then
            echo "$(date): VPN DOWN - interfaccia ppp0 assente."
            kill $VPN_PID 2>/dev/null
            sleep 5
            break
        fi

        if ! kill -0 $VPN_PID 2>/dev/null; then
            echo "Processo VPN terminato inaspettatamente."
            break
        fi

        sleep 20
    done
done
