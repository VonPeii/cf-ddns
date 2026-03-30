#!/bin/bash

START_TS=$(date +%s -r /proc/1 2>/dev/null)
NOW=$(date +%s)
UPTIME=$((NOW - START_TS))

if [ ! -f /tmp/last_run ]; then
    [ "$UPTIME" -le 1800 ] && exit 0
    echo "启动超过 1800s 仍未生成 last_run"
    exit 1
fi

LAST=$(cat /tmp/last_run 2>/dev/null)
[ -z "$LAST" ] || ! [[ "$LAST" =~ ^[0-9]+$ ]] && { echo "last_run 异常"; exit 1; }
NOW=$(date +%s)
if [ "$SMART_INTERVAL" = "true" ] && [ -n "$MAX_INTERVAL" ]; then
    ALLOWED=$((MAX_INTERVAL + 900))
else
    ALLOWED=$((${INTERVAL:-21600} + 900))
fi
[ $((NOW - LAST)) -gt $ALLOWED ] && { echo "超时 $((NOW - LAST))s"; exit 1; }
exit 0
