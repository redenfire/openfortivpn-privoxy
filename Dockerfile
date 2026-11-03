FROM ubuntu:22.04 AS builder

ARG OPENFORTIVPN_VERSION=1.24.1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    build-essential \
    autoconf \
    automake \
    pkg-config \
    libssl-dev \
    && curl -fsSL "https://github.com/adrienverge/openfortivpn/archive/refs/tags/v${OPENFORTIVPN_VERSION}.tar.gz" -o /tmp/openfortivpn.tar.gz \
    && tar -xzf /tmp/openfortivpn.tar.gz -C /tmp \
    && cd "/tmp/openfortivpn-${OPENFORTIVPN_VERSION}" \
    && ./autogen.sh \
    && ./configure --prefix=/usr \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out \
    && rm -rf /tmp/openfortivpn*


FROM ubuntu:22.04

# Selects the entrypoint, so the same Dockerfile builds both image variants:
#   start.sh       -> base image  (:latest), the plain env-driven version
#   entrypoint.sh  -> cert image  (:vpn_cert), automatic certificate handling
ARG VPN_ENTRYPOINT=start.sh

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    iproute2 \
    libssl3 \
    openssl \
    ppp \
    privoxy \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/usr/ /usr/

RUN sed -i '/^listen-address/d' /etc/privoxy/config \
 && echo 'listen-address 0.0.0.0:8118' >> /etc/privoxy/config

COPY ${VPN_ENTRYPOINT} /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8118

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/8118'

CMD ["/entrypoint.sh"]
