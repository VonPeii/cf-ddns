#!/bin/bash
# healthcheck.sh: Docker 健康检查

if [ ! -f /tmp/last_run ]; then
    exit 0
fi

LAST=$(cat /tmp/last_run 2>/dev/null)

if [ -z "$LAST" ] || ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
    echo "last_run 内容异常。"
    exit 1
fi

NOW=$(date +%s)

if [ "$SMART_INTERVAL" = "true" ] && [ -n "$MAX_INTERVAL" ]; then
    ALLOWED_DELAY=$((MAX_INTERVAL + 900))
else
    ALLOWED_DELAY=$((${INTERVAL:-21600} + 900))
fi

if [ $((NOW - LAST)) -gt $ALLOWED_DELAY ]; then
    echo "超时！距上次运行已过 $((NOW - LAST)) 秒。"
    exit 1
fi

exit 0
