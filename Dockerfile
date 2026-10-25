FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    iproute2 \
    privoxy \
    ca-certificates \
    openfortivpn \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/^listen-address/d' /etc/privoxy/config \
 && echo 'listen-address 0.0.0.0:8118' >> /etc/privoxy/config

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8118

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/8118'

CMD ["/start.sh"]
