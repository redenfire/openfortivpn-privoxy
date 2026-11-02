#!/bin/sh
# Entrypoint for the openfortivpn + Privoxy container.
#
# Designed to run with a POSIX shell (dash on Debian/Ubuntu, ash on Alpine).
# It never logs VPN_PASS nor the contents of the CA file.

set -u
# Digests and CIDRs do not need pathname expansion; disabling it makes the
# intentional word-splitting of comma/space separated lists safe.
set -f

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log() {
    printf '%s [vpn-config] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    log "WARN: $*"
}

err() {
    log "ERROR: $*" >&2
}

die() {
    err "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
normalize_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on)  printf '1' ;;
        0|false|no|off|'') printf '0' ;;
        *) return 1 ;;
    esac
}

validate_uint() {
    _name=$1
    _value=$2
    case "$_value" in
        ''|*[!0-9]*) die "$_name deve essere un intero non negativo (valore: '$_value')" ;;
    esac
}

validate_positive_uint() {
    _name=$1
    _value=$2
    validate_uint "$_name" "$_value"
    [ "$_value" -gt 0 ] || die "$_name deve essere maggiore di zero (valore: '$_value')"
}

# Append a digest to the trusted list, validating and de-duplicating it.
# The optional "sha256$" prefix (sometimes copied from the FortiGate UI) is
# accepted for backwards compatibility but is not passed to openfortivpn.
TRUSTED_CERTS=""
add_trusted_cert() {
    _cert=$(printf '%s' "${1:-}" | tr -d '[:space:]')
    [ -n "$_cert" ] || return 0

    case "$_cert" in
        'sha256$'*)
            _cert=${_cert#'sha256$'}
            warn "prefisso 'sha256\$' rimosso dal digest: openfortivpn vuole solo l'hex SHA-256."
            ;;
    esac

    _len=$(printf '%s' "$_cert" | wc -c | tr -d '[:space:]')
    if [ "$_len" -ne 64 ]; then
        die "digest trusted-cert non valido: attesi 64 caratteri hex, trovati $_len ($_cert)"
    fi
    if printf '%s' "$_cert" | grep -q '[^0-9A-Fa-f]'; then
        die "digest trusted-cert non valido: contiene caratteri non hex ($_cert)"
    fi

    # openfortivpn compares lower-case hex strings.
    _cert=$(printf '%s' "$_cert" | tr 'A-F' 'a-f')

    case " $TRUSTED_CERTS " in
        *" $_cert "*)
            warn "digest trusted-cert duplicato ignorato: $_cert"
            ;;
        *)
            TRUSTED_CERTS="${TRUSTED_CERTS}${TRUSTED_CERTS:+ }$_cert"
            ;;
    esac
}

# Extract the digest recommended by openfortivpn from its output.
# Handles both "--trusted-cert <digest>" / "--trusted-cert=<digest>" and the
# "trusted-cert = <digest>" configuration-file form used by some versions.
extract_trusted_digest() {
    _file=$1
    _digest=$(sed -n 's/.*--trusted-cert[[:space:]=]*\([0-9A-Fa-f]\{64\}\).*/\1/p' "$_file" | head -n 1)
    if [ -z "$_digest" ]; then
        _digest=$(sed -n 's/.*trusted-cert[[:space:]]*=[[:space:]]*\([0-9A-Fa-f]\{64\}\).*/\1/p' "$_file" | head -n 1)
    fi
    printf '%s' "$_digest"
}

has_certificate_error() {
    grep -Eqi 'certificate validation failed|--trusted-cert|trusted-cert[[:space:]]*=' "$1"
}

dns_resolves() {
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$1" >/dev/null 2>&1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$1" >/dev/null 2>&1
    else
        # No resolver helper available: do not turn a diagnostic into a failure.
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Required configuration
# ---------------------------------------------------------------------------
[ -n "${VPN_HOST:-}" ] || die "VPN_HOST non impostato"
[ -n "${VPN_USER:-}" ] || die "VPN_USER non impostato"
[ -n "${VPN_PASS:-}" ] || die "VPN_PASS non impostato"
[ -n "${VPN_DOMAIN:-}" ] || die "VPN_DOMAIN non impostato"
[ -n "${PRIVOXY_PERMIT:-}" ] || die "PRIVOXY_PERMIT non impostato"

VPN_PORT=${VPN_PORT:-443}
VPN_SET_DNS=${VPN_SET_DNS:-}
VPN_PEERDNS=${VPN_PEERDNS:-}
VPN_CA_FILE=${VPN_CA_FILE:-}
VPN_TRUSTED_CERTS=${VPN_TRUSTED_CERTS:-}
VPN_CERT_HASH=${VPN_CERT_HASH:-}
VPN_CIPHER_LIST=${VPN_CIPHER_LIST:-}

VPN_CHECK_INTERVAL=${VPN_CHECK_INTERVAL:-20}
VPN_CONNECT_TIMEOUT=${VPN_CONNECT_TIMEOUT:-60}
VPN_FAIL_THRESHOLD=${VPN_FAIL_THRESHOLD:-3}
VPN_AUTO_TRUST_TIMEOUT=${VPN_AUTO_TRUST_TIMEOUT:-15}
VPN_AUTO_TRUST_CERT=${VPN_AUTO_TRUST_CERT:-false}
VPN_INSECURE_SSL=${VPN_INSECURE_SSL:-false}

case "$VPN_PORT" in
    ''|*[!0-9]*) die "VPN_PORT deve essere un intero tra 1 e 65535 (valore: '$VPN_PORT')" ;;
esac
[ "$VPN_PORT" -ge 1 ] && [ "$VPN_PORT" -le 65535 ] || \
    die "VPN_PORT deve essere un intero tra 1 e 65535 (valore: '$VPN_PORT')"

validate_positive_uint VPN_CHECK_INTERVAL "$VPN_CHECK_INTERVAL"
validate_positive_uint VPN_CONNECT_TIMEOUT "$VPN_CONNECT_TIMEOUT"
validate_positive_uint VPN_FAIL_THRESHOLD "$VPN_FAIL_THRESHOLD"
validate_positive_uint VPN_AUTO_TRUST_TIMEOUT "$VPN_AUTO_TRUST_TIMEOUT"

if ! AUTO_TRUST=$(normalize_bool "$VPN_AUTO_TRUST_CERT"); then
    die "VPN_AUTO_TRUST_CERT deve essere true o false (valore: '$VPN_AUTO_TRUST_CERT')"
fi
if ! INSECURE_SSL=$(normalize_bool "$VPN_INSECURE_SSL"); then
    die "VPN_INSECURE_SSL deve essere true o false (valore: '$VPN_INSECURE_SSL')"
fi

# ---------------------------------------------------------------------------
# Certificate configuration
# ---------------------------------------------------------------------------
if [ -n "$VPN_CA_FILE" ]; then
    [ -e "$VPN_CA_FILE" ] || die "VPN_CA_FILE impostato ma il file non esiste: $VPN_CA_FILE"
    [ -f "$VPN_CA_FILE" ] || die "VPN_CA_FILE non è un file regolare: $VPN_CA_FILE"
    [ -r "$VPN_CA_FILE" ] || die "VPN_CA_FILE non è leggibile: $VPN_CA_FILE"
    log "CA personalizzato attivo: $VPN_CA_FILE (verrà passato come --ca-file)."
else
    log "CA personalizzato non impostato: uso il trust store di sistema."
fi

# VPN_TRUSTED_CERTS accepts one or more digests separated by spaces or commas.
if [ -n "$VPN_TRUSTED_CERTS" ]; then
    _normalized=$(printf '%s' "$VPN_TRUSTED_CERTS" | tr ',' ' ')
    for _item in $_normalized; do
        add_trusted_cert "$_item"
    done
fi

# Backwards compatibility: VPN_CERT_HASH is a single trusted digest.
if [ -n "$VPN_CERT_HASH" ]; then
    warn "VPN_CERT_HASH è deprecato: usa VPN_TRUSTED_CERTS (accetta più digest separati da spazi o virgole)."
    add_trusted_cert "$VPN_CERT_HASH"
fi

# ---------------------------------------------------------------------------
# Build the openfortivpn argument list.
# Positional parameters are used so that passwords and cipher lists containing
# spaces/special characters are never re-parsed by a shell.
# ---------------------------------------------------------------------------
set -- "$VPN_HOST:$VPN_PORT" \
    --username="$VPN_USER" \
    --password="$VPN_PASS"

if [ -n "$VPN_SET_DNS" ]; then
    set -- "$@" --set-dns="$VPN_SET_DNS"
fi
if [ -n "$VPN_PEERDNS" ]; then
    set -- "$@" --pppd-use-peerdns="$VPN_PEERDNS"
fi
if [ -n "$VPN_CA_FILE" ]; then
    set -- "$@" --ca-file="$VPN_CA_FILE"
fi
if [ -n "$VPN_CIPHER_LIST" ]; then
    set -- "$@" --cipher-list="$VPN_CIPHER_LIST"
fi
if [ "$INSECURE_SSL" -eq 1 ]; then
    set -- "$@" --insecure-ssl
fi

# ---------------------------------------------------------------------------
# Optional auto-trust: probe once without trusted certs, extract the digest
# suggested by openfortivpn, then add it to the trusted list.
# ---------------------------------------------------------------------------
if [ "$AUTO_TRUST" -eq 1 ]; then
    if [ -n "$TRUSTED_CERTS" ]; then
        log "VPN_AUTO_TRUST_CERT=true: saltato, sono già configurati trusted-cert espliciti."
    elif [ -n "$VPN_CA_FILE" ]; then
        log "VPN_AUTO_TRUST_CERT=true: saltato, è configurato VPN_CA_FILE."
    elif [ "$INSECURE_SSL" -eq 1 ]; then
        log "VPN_AUTO_TRUST_CERT=true: saltato, VPN_INSECURE_SSL è attivo."
    else
        command -v timeout >/dev/null 2>&1 || \
            die "VPN_AUTO_TRUST_CERT=true richiede il comando 'timeout'."

        log "VPN_AUTO_TRUST_CERT=true: tentativo di connessione senza trusted-cert (timeout ${VPN_AUTO_TRUST_TIMEOUT}s) per estrarre il digest."
        _probe_log=$(mktemp /tmp/openfortivpn-probe.XXXXXX 2>/dev/null) || \
            _probe_log="/tmp/openfortivpn-probe.$$"
        : > "$_probe_log"

        # The probe must not install routes or change DNS: it only needs to
        # reach the certificate validation stage.
        timeout "$VPN_AUTO_TRUST_TIMEOUT" openfortivpn "$@" \
            --set-routes=0 --set-dns=0 > "$_probe_log" 2>&1
        _probe_rc=$?

        _detected_digest=$(extract_trusted_digest "$_probe_log")

        if [ -n "$_detected_digest" ]; then
            log "VPN_AUTO_TRUST_CERT: digest estratto dal gateway: $_detected_digest"
            add_trusted_cert "$_detected_digest"
        else
            if has_certificate_error "$_probe_log"; then
                err "VPN_AUTO_TRUST_CERT: il gateway ha rifiutato il certificato ma non è stato possibile estrarre un digest valido."
            else
                err "VPN_AUTO_TRUST_CERT: nessun digest --trusted-cert trovato nell'output del tentativo (exit=$_probe_rc)."
                err "Se il gateway usa una CA pubblica o VPN_CA_FILE, disabilita VPN_AUTO_TRUST_CERT."
            fi
            err "Output del tentativo (la password non viene mai stampata):"
            sed 's/^/[vpn-config] probe: /' "$_probe_log" >&2
            rm -f "$_probe_log"
            exit 1
        fi

        rm -f "$_probe_log"
        # If the probe managed to bring the tunnel up, clean it up before the
        # real connection starts.
        ip link del ppp0 2>/dev/null || true
    fi
fi

# Append the validated trusted certs and log every decision.
if [ -n "$TRUSTED_CERTS" ]; then
    _trusted_count=0
    for _cert in $TRUSTED_CERTS; do
        _trusted_count=$((_trusted_count + 1))
        set -- "$@" --trusted-cert="$_cert"
    done
    log "Validazione certificato: $_trusted_count trusted-cert configurati (${TRUSTED_CERTS})."
else
    log "Validazione certificato: solo trust store di sistema / CA pubblica; nessun trusted-cert."
fi

if [ -n "$VPN_CIPHER_LIST" ]; then
    log "Cipher list: $VPN_CIPHER_LIST (verrà passata come --cipher-list)."
else
    log "Cipher list: default di openfortivpn."
fi

if [ "$INSECURE_SSL" -eq 1 ]; then
    warn "VPN_INSECURE_SSL=true: --insecure-ssl ATTIVO. La validazione del certificato del gateway è disabilitata."
else
    log "insecure-ssl: disabilitato (comportamento predefinito sicuro)."
fi

# ---------------------------------------------------------------------------
# Privoxy startup
# ---------------------------------------------------------------------------
for _net in $PRIVOXY_PERMIT; do
    if ! awk -v net="$_net" \
        '$1 == "permit-access" && $2 == net { found = 1 } END { exit(found ? 0 : 1) }' \
        /etc/privoxy/config; then
        echo "permit-access  $_net" >> /etc/privoxy/config
    fi
done

start_privoxy() {
    log "Avvio Privoxy..."
    /usr/sbin/privoxy --no-daemon --user privoxy /etc/privoxy/config &
    PRIVOXY_PID=$!
}

start_privoxy

# ---------------------------------------------------------------------------
# VPN supervision loop
# ---------------------------------------------------------------------------
log "Inizio monitoraggio VPN (${VPN_HOST}:${VPN_PORT})."

while true; do
    log "Tentativo di connessione VPN..."

    openfortivpn "$@" &
    VPN_PID=$!

    # Initial wait: ppp0 must get an IPv4 address.
    _ready=0
    _i=0
    while [ "$_i" -lt "$VPN_CONNECT_TIMEOUT" ]; do
        if ! kill -0 "$VPN_PID" 2>/dev/null; then
            log "openfortivpn terminato durante la connessione."
            break
        fi
        if ip -4 addr show dev ppp0 2>/dev/null | grep -q 'inet '; then
            _ready=1
            break
        fi
        sleep 1
        _i=$((_i + 1))
    done

    if [ "$_ready" -eq 1 ]; then
        log "VPN attiva (ppp0 con indirizzo IPv4)."
    else
        log "VPN non attiva dopo ${VPN_CONNECT_TIMEOUT}s."
    fi

    # Supervision: tear the tunnel down only if openfortivpn exits or ppp0
    # loses its address for several consecutive checks. DNS errors are not
    # fatal.
    _fails=0
    while kill -0 "$VPN_PID" 2>/dev/null; do
        if ! kill -0 "$PRIVOXY_PID" 2>/dev/null; then
            log "Privoxy morto, lo riavvio."
            start_privoxy
        fi

        if ip -4 addr show dev ppp0 2>/dev/null | grep -q 'inet '; then
            _fails=0
        else
            _fails=$((_fails + 1))
            log "VPN DOWN - ppp0 senza indirizzo ($_fails/$VPN_FAIL_THRESHOLD)."
            if [ "$_fails" -ge "$VPN_FAIL_THRESHOLD" ]; then
                break
            fi
        fi

        # Diagnostic only: a DNS failure does not tear the VPN down.
        if ! dns_resolves "$VPN_DOMAIN"; then
            log "WARN: DNS $VPN_DOMAIN non risolto (ignorato)."
        fi

        sleep "$VPN_CHECK_INTERVAL"
    done

    log "Chiusura VPN..."
    kill "$VPN_PID" 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 5 ]; do
        kill -0 "$VPN_PID" 2>/dev/null || break
        sleep 1
        _i=$((_i + 1))
    done
    kill -9 "$VPN_PID" 2>/dev/null || true
    wait "$VPN_PID" 2>/dev/null || true
    ip link del ppp0 2>/dev/null || true

    log "Riconnessione tra 10 secondi..."
    sleep 10
done
