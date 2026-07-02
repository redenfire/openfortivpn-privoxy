FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    wget \
    curl \
    expect \
    net-tools \
    iproute2 \
    privoxy \
    ca-certificates \
    openfortivpn \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/listen-address  127.0.0.1:8118/listen-address  0.0.0.0:8118/' /etc/privoxy/config

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8118

CMD ["/start.sh"]
