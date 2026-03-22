FROM alpine:3.21

RUN apk add --no-cache curl bash tzdata libc6-compat jq busybox-extras

ENV TZ=Asia/Shanghai
WORKDIR /app

ADD cfst_linux_arm64.tar.gz /app/
RUN chmod +x /app/cfst

COPY update.sh /app/update.sh
COPY healthcheck.sh /app/healthcheck.sh
COPY web/index.html /app/web/index.html
RUN chmod +x /app/update.sh /app/healthcheck.sh \
    && mkdir -p /app/web/data

HEALTHCHECK --interval=10m --timeout=10s --retries=3 \
    CMD bash /app/healthcheck.sh

CMD ["bash", "/app/update.sh"]
