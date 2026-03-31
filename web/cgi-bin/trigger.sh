#!/bin/bash
echo "Content-Type: application/json"
echo ""

if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    echo '{"ok":true}'
    exit 0
fi

if [ "$REQUEST_METHOD" != "POST" ]; then
    echo '{"ok":false,"msg":"仅支持 POST"}'
    exit 0
fi

EXPECTED_TOKEN=$(jq -r '.trigger_token // empty' /app/web/data/ui.json 2>/dev/null)
if [ -z "$EXPECTED_TOKEN" ] || [ "$HTTP_X_TRIGGER_TOKEN" != "$EXPECTED_TOKEN" ]; then
    echo '{"ok":false,"msg":"触发令牌无效"}'
    exit 0
fi

if [ -f /tmp/scan_active ]; then
    echo '{"ok":false,"msg":"扫描正在进行中"}'
    exit 0
fi

touch /tmp/trigger_scan
echo '{"ok":true,"msg":"已触发手动扫描"}'
