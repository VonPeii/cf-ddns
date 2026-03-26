#!/bin/bash
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: POST, OPTIONS"
echo ""

if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    echo '{"ok":true}'
    exit 0
fi

if [ -f /tmp/scan_active ]; then
    echo '{"ok":false,"msg":"扫描正在进行中"}'
    exit 0
fi

touch /tmp/trigger_scan
echo '{"ok":true,"msg":"已触发手动扫描"}'
