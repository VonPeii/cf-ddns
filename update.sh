#!/bin/bash

# =============================================
# 极客版 CF-DDNS v7
# 多域名独立凭据 / 渐进式更新 / 失败重试 / 智能调度 / Web 面板 / 手动触发
# =============================================

# --- 基础环境变量 ---
INTERVAL=${INTERVAL:-21600}
CFST_TL=${CFST_TL:-250}
CFST_SL=${CFST_SL:-5}
CFST_URL=${CFST_URL:-"https://speed.cloudflare.com/__down?bytes=50000000"}
IP_COUNT=${IP_COUNT:-5}
ENABLE_IPV4=${ENABLE_IPV4:-true}
ENABLE_IPV6=${ENABLE_IPV6:-false}
ABORT_LATENCY=${ABORT_LATENCY:-300}

CANARY_MODE=${CANARY_MODE:-false}
CANARY_MAX_CHANGES=${CANARY_MAX_CHANGES:-1}

API_MAX_RETRIES=${API_MAX_RETRIES:-3}
API_BASE_DELAY=${API_BASE_DELAY:-5}

SMART_INTERVAL=${SMART_INTERVAL:-false}
SMART_STABLE_THRESHOLD=${SMART_STABLE_THRESHOLD:-3}
MAX_INTERVAL=${MAX_INTERVAL:-172800}
STABLE_COUNT_FILE="/tmp/stable_count"

WEB_PORT=${WEB_PORT:-8088}
WEB_DIR="/app/web"
DATA_DIR="${WEB_DIR}/data"
HISTORY_MAX=${HISTORY_MAX:-200}

ROUND_HAS_CHANGES=0

# =========================================================
# 进度上报
# =========================================================
report_progress() {
    local PHASE="$1"
    local PERCENT="$2"
    local MSG="$3"
    local ACTIVE=${4:-true}

    jq -n \
        --argjson active "$ACTIVE" \
        --arg phase "$PHASE" \
        --argjson percent "$PERCENT" \
        --arg message "$MSG" \
        --arg updated_at "$(date '+%H:%M:%S')" \
        '{active:$active, phase:$phase, percent:$percent, message:$message, updated_at:$updated_at}' \
        > "${DATA_DIR}/progress.json.tmp" && mv "${DATA_DIR}/progress.json.tmp" "${DATA_DIR}/progress.json"
}

clear_progress() {
    report_progress "idle" 0 "等待下一轮测速" false
    rm -f /tmp/scan_active
}

# =========================================================
# 解析多域名配置
# =========================================================
DOMAIN_NAMES=()
DOMAIN_ZONES=()
DOMAIN_TOKENS=()

parse_domain_config() {
    local NAME_VAR
    while IFS= read -r NAME_VAR; do
        local INDEX="${NAME_VAR#DOMAIN_}"
        INDEX="${INDEX%_NAME}"
        local ZONE_VAR="DOMAIN_${INDEX}_ZONE_ID"
        local TOKEN_VAR="DOMAIN_${INDEX}_TOKEN"

        local D_NAME="${!NAME_VAR}"
        local D_ZONE="${!ZONE_VAR}"
        local D_TOKEN="${!TOKEN_VAR}"

        if [ -z "$D_ZONE" ] || [ -z "$D_TOKEN" ]; then
            echo "⚠️ 域名 #${INDEX} (${D_NAME}) 缺少 ZONE_ID 或 TOKEN，跳过！"
            continue
        fi

        DOMAIN_NAMES+=("$D_NAME")
        DOMAIN_ZONES+=("$D_ZONE")
        DOMAIN_TOKENS+=("$D_TOKEN")
    done < <(compgen -A variable | grep -E '^DOMAIN_[0-9]+_NAME$' | sort -V)

    if [ ${#DOMAIN_NAMES[@]} -eq 0 ]; then
        echo "❌ 未配置任何域名！"
        exit 1
    fi
}

parse_domain_config

# =========================================================
# 初始化
# =========================================================
mkdir -p "$DATA_DIR" "${WEB_DIR}/cgi-bin"
[ ! -f "${DATA_DIR}/history.json" ] && echo '[]' > "${DATA_DIR}/history.json"
clear_progress

echo "========== 极客版 CF-DDNS v7 启动 =========="
echo "域名数量: ${#DOMAIN_NAMES[@]}"
for i in "${!DOMAIN_NAMES[@]}"; do
    echo "  [#$((i+1))] ${DOMAIN_NAMES[$i]}"
done
echo "Web 面板: http://0.0.0.0:${WEB_PORT}"

# 启动 Web 服务器（支持 CGI）
httpd -p "${WEB_PORT}" -h "${WEB_DIR}"
echo "✅ Web 面板已启动"

# =========================================================
# API 调用（带重试）
# =========================================================
cf_api() {
    local TOKEN="$1" METHOD="$2" ENDPOINT="$3" DATA="$4"
    local DELAY=${API_BASE_DELAY}

    for i in $(seq 1 "$API_MAX_RETRIES"); do
        local RESPONSE
        if [ -n "$DATA" ]; then
            RESPONSE=$(curl -s --max-time 30 -X "$METHOD" \
                "https://api.cloudflare.com/client/v4${ENDPOINT}" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json" --data "$DATA")
        else
            RESPONSE=$(curl -s --max-time 30 -X "$METHOD" \
                "https://api.cloudflare.com/client/v4${ENDPOINT}" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json")
        fi

        if echo "$RESPONSE" | jq -e '.success == true' > /dev/null 2>&1; then
            echo "$RESPONSE"
            return 0
        fi

        if [ "$i" -eq "$API_MAX_RETRIES" ]; then
            echo "$RESPONSE"
            return 1
        fi

        echo "  ⚠️ API 失败 (${i}/${API_MAX_RETRIES})，${DELAY}s 后重试..." >&2
        sleep "$DELAY"
        DELAY=$((DELAY * 2))
    done
}

# =========================================================
# 智能调度
# =========================================================
get_smart_sleep() {
    if [ "$SMART_INTERVAL" != "true" ]; then echo "$INTERVAL"; return; fi

    local COUNT=0
    [ -f "$STABLE_COUNT_FILE" ] && { COUNT=$(cat "$STABLE_COUNT_FILE" 2>/dev/null); [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0; }

    if [ "$ROUND_HAS_CHANGES" -eq 1 ]; then
        echo 0 > "$STABLE_COUNT_FILE"
        echo "$INTERVAL"; return
    fi

    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$STABLE_COUNT_FILE"

    local DOUBLES=$((COUNT / SMART_STABLE_THRESHOLD)) SLEEP_TIME=$INTERVAL
    for _ in $(seq 1 "$DOUBLES"); do
        SLEEP_TIME=$((SLEEP_TIME * 2))
        [ "$SLEEP_TIME" -ge "$MAX_INTERVAL" ] && SLEEP_TIME=$MAX_INTERVAL && break
    done
    echo "$SLEEP_TIME"
}

# =========================================================
# 可中断睡眠（每 3 秒检查手动触发）
# =========================================================
interruptible_sleep() {
    local TOTAL=$1 ELAPSED=0
    while [ $ELAPSED -lt $TOTAL ]; do
        if [ -f /tmp/trigger_scan ]; then
            rm -f /tmp/trigger_scan
            echo "[$(date '+%H:%M:%S')] ⚡ 收到手动触发信号！"
            return 1
        fi
        sleep 3
        ELAPSED=$((ELAPSED + 3))

        # 每 30 秒更新一次倒计时进度
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            local REMAIN=$((TOTAL - ELAPSED))
            local REMAIN_MIN=$((REMAIN / 60))
            report_progress "sleeping" 0 "休眠中，约 ${REMAIN_MIN} 分钟后下一轮" false
        fi
    done
    return 0
}

# =========================================================
# 持久化
# =========================================================
persist_results() {
    local SLEEP_SEC=$1
    local NOW_STR=$(date '+%Y-%m-%d %H:%M:%S') NOW_TS=$(date +%s)

    local IPV4_DATA="[]" IPV4_TOP_LAT="null" IPV4_TOP_SPEED="null"
    if [ "$ENABLE_IPV4" = "true" ] && [ -f "/app/result_IPv4.csv" ]; then
        IPV4_DATA=$(awk -F, 'NR>1 && $5>0 {
            gsub(/[ \r\n]/,"",$1); gsub(/[ \r\n]/,"",$5); gsub(/[ \r\n]/,"",$6)
            printf "{\"ip\":\"%s\",\"latency\":%s,\"speed\":%s}\n",$1,$5,$6
        }' /app/result_IPv4.csv | head -n "$IP_COUNT" | jq -s '.' 2>/dev/null)
        [ -z "$IPV4_DATA" ] && IPV4_DATA="[]"
        IPV4_TOP_LAT=$(echo "$IPV4_DATA" | jq '.[0].latency // null')
        IPV4_TOP_SPEED=$(echo "$IPV4_DATA" | jq '.[0].speed // null')
    fi

    local IPV6_DATA="[]" IPV6_TOP_LAT="null" IPV6_TOP_SPEED="null"
    if [ "$ENABLE_IPV6" = "true" ] && [ -f "/app/result_IPv6.csv" ]; then
        IPV6_DATA=$(awk -F, 'NR>1 && $5>0 {
            gsub(/[ \r\n]/,"",$1); gsub(/[ \r\n]/,"",$5); gsub(/[ \r\n]/,"",$6)
            printf "{\"ip\":\"%s\",\"latency\":%s,\"speed\":%s}\n",$1,$5,$6
        }' /app/result_IPv6.csv | head -n "$IP_COUNT" | jq -s '.' 2>/dev/null)
        [ -z "$IPV6_DATA" ] && IPV6_DATA="[]"
        IPV6_TOP_LAT=$(echo "$IPV6_DATA" | jq '.[0].latency // null')
        IPV6_TOP_SPEED=$(echo "$IPV6_DATA" | jq '.[0].speed // null')
    fi

    local DOMAINS_JSON=$(printf '%s\n' "${DOMAIN_NAMES[@]}" | jq -R . | jq -s '.')

    jq -n \
        --arg last_update "$NOW_STR" --argjson last_ts "$NOW_TS" \
        --argjson sleep_seconds "$SLEEP_SEC" --argjson domains "$DOMAINS_JSON" \
        --argjson smart_interval $([ "$SMART_INTERVAL" = "true" ] && echo true || echo false) \
        --argjson canary_mode $([ "$CANARY_MODE" = "true" ] && echo true || echo false) \
        --argjson ipv4_enabled $([ "$ENABLE_IPV4" = "true" ] && echo true || echo false) \
        --argjson ipv4_data "$IPV4_DATA" --argjson ipv4_top_lat "$IPV4_TOP_LAT" \
        --argjson ipv6_enabled $([ "$ENABLE_IPV6" = "true" ] && echo true || echo false) \
        --argjson ipv6_data "$IPV6_DATA" --argjson ipv6_top_lat "$IPV6_TOP_LAT" \
        --argjson abort_latency "$ABORT_LATENCY" \
        '{last_update:$last_update, last_ts:$last_ts, sleep_seconds:$sleep_seconds, domains:$domains,
          smart_interval:$smart_interval, canary_mode:$canary_mode, abort_latency:$abort_latency,
          ipv4:{enabled:$ipv4_enabled, top_latency:$ipv4_top_lat, ips:$ipv4_data},
          ipv6:{enabled:$ipv6_enabled, top_latency:$ipv6_top_lat, ips:$ipv6_data}}' \
        > "${DATA_DIR}/status.json.tmp" && mv "${DATA_DIR}/status.json.tmp" "${DATA_DIR}/status.json"

    local ENTRY=$(jq -n --arg t "$NOW_STR" --argjson ts "$NOW_TS" \
        --argjson v4l "$IPV4_TOP_LAT" --argjson v4s "$IPV4_TOP_SPEED" \
        --argjson v6l "$IPV6_TOP_LAT" --argjson v6s "$IPV6_TOP_SPEED" \
        '{time:$t, ts:$ts, v4_lat:$v4l, v4_spd:$v4s, v6_lat:$v6l, v6_spd:$v6s}')

    jq --argjson e "$ENTRY" --argjson m "$HISTORY_MAX" '. + [$e] | .[-$m:]' \
        "${DATA_DIR}/history.json" > "${DATA_DIR}/history.json.tmp" \
        && mv "${DATA_DIR}/history.json.tmp" "${DATA_DIR}/history.json"
}

# =========================================================
# DNS 更新（单域名）
# =========================================================
update_dns_for_domain() {
    local RECORD_TYPE=$1 NEW_IPS=$2 DOMAIN=$3 ZONE_ID=$4 TOKEN=$5

    local API_RESPONSE
    API_RESPONSE=$(cf_api "$TOKEN" GET "/zones/${ZONE_ID}/dns_records?name=${DOMAIN}&type=${RECORD_TYPE}")
    [ $? -ne 0 ] && { echo "    ❌ [${RECORD_TYPE}] ${DOMAIN} API 查询失败"; return; }

    local CURRENT_RECORDS=$(echo "$API_RESPONSE" | jq -r '.result[] | "\(.id)|\(.content)"')
    local -a IPS_TO_ADD=() RECS_TO_DEL=()

    for N_IP in $NEW_IPS; do
        local MATCH=0
        for C_REC in $CURRENT_RECORDS; do [ "$N_IP" = "${C_REC#*|}" ] && MATCH=1 && break; done
        [ $MATCH -eq 0 ] && IPS_TO_ADD+=("$N_IP")
    done

    for C_REC in $CURRENT_RECORDS; do
        local C_IP="${C_REC#*|}" MATCH=0
        for N_IP in $NEW_IPS; do [ "$C_IP" = "$N_IP" ] && MATCH=1 && break; done
        [ $MATCH -eq 0 ] && RECS_TO_DEL+=("$C_REC")
    done

    local TOTAL_ADD=${#IPS_TO_ADD[@]} TOTAL_DEL=${#RECS_TO_DEL[@]}
    local TOTAL_CHANGES=$((TOTAL_ADD + TOTAL_DEL))
    [ $TOTAL_CHANGES -eq 0 ] && { echo "    [${RECORD_TYPE}] ${DOMAIN} 无变化"; return; }

    local ADD_OK=0
    local DEL_OK=0

    if [ "$CANARY_MODE" = "true" ]; then
        local REPLACEMENTS=$TOTAL_ADD
        [ $TOTAL_DEL -lt $REPLACEMENTS ] && REPLACEMENTS=$TOTAL_DEL
        local SLOTS=$CANARY_MAX_CHANGES

        for idx in $(seq 0 $((REPLACEMENTS - 1))); do
            [ "$SLOTS" -le 0 ] && break

            local IP="${IPS_TO_ADD[$idx]}"
            local REC="${RECS_TO_DEL[$idx]}"
            local C_ID="${REC%|*}"
            local C_IP="${REC#*|}"

            if cf_api "$TOKEN" POST "/zones/${ZONE_ID}/dns_records" \
                "{\"type\":\"${RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}" > /dev/null; then
                echo "    🎉 [${RECORD_TYPE}] ${DOMAIN} +${IP}"
                if cf_api "$TOKEN" DELETE "/zones/${ZONE_ID}/dns_records/${C_ID}" > /dev/null; then
                    echo "    🗑️ [${RECORD_TYPE}] ${DOMAIN} -${C_IP}"
                    ADD_OK=$((ADD_OK + 1))
                    DEL_OK=$((DEL_OK + 1))
                    SLOTS=$((SLOTS - 1))
                else
                    echo "    ⚠️ [${RECORD_TYPE}] ${DOMAIN} 删除旧记录失败，保留新增的 ${IP}"
                fi
            fi
        done

        local ADD_START=$REPLACEMENTS
        for idx in $(seq "$ADD_START" $((TOTAL_ADD - 1))); do
            [ "$SLOTS" -le 0 ] && break

            local IP="${IPS_TO_ADD[$idx]}"
            if cf_api "$TOKEN" POST "/zones/${ZONE_ID}/dns_records" \
                "{\"type\":\"${RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}" > /dev/null; then
                echo "    🎉 [${RECORD_TYPE}] ${DOMAIN} +${IP}"
                ADD_OK=$((ADD_OK + 1))
                SLOTS=$((SLOTS - 1))
            fi
        done

        local DEL_START=$REPLACEMENTS
        for idx in $(seq "$DEL_START" $((TOTAL_DEL - 1))); do
            [ "$SLOTS" -le 0 ] && break

            local REC="${RECS_TO_DEL[$idx]}"
            local C_ID="${REC%|*}"
            local C_IP="${REC#*|}"
            if cf_api "$TOKEN" DELETE "/zones/${ZONE_ID}/dns_records/${C_ID}" > /dev/null; then
                echo "    🗑️ [${RECORD_TYPE}] ${DOMAIN} -${C_IP}"
                DEL_OK=$((DEL_OK + 1))
                SLOTS=$((SLOTS - 1))
            fi
        done
    else
        for idx in $(seq 0 $((TOTAL_ADD - 1))); do
            local IP="${IPS_TO_ADD[$idx]}"
            if cf_api "$TOKEN" POST "/zones/${ZONE_ID}/dns_records" \
                "{\"type\":\"${RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}" > /dev/null; then
                echo "    🎉 [${RECORD_TYPE}] ${DOMAIN} +${IP}"
                ADD_OK=$((ADD_OK + 1))
            fi
        done

        for idx in $(seq 0 $((TOTAL_DEL - 1))); do
            local REC="${RECS_TO_DEL[$idx]}"
            local C_ID="${REC%|*}"
            local C_IP="${REC#*|}"
            if cf_api "$TOKEN" DELETE "/zones/${ZONE_ID}/dns_records/${C_ID}" > /dev/null; then
                echo "    🗑️ [${RECORD_TYPE}] ${DOMAIN} -${C_IP}"
                DEL_OK=$((DEL_OK + 1))
            fi
        done
    fi

    [ $ADD_OK -gt 0 ] || [ $DEL_OK -gt 0 ] && ROUND_HAS_CHANGES=1
}

# =========================================================
# 测速 + 分发（带进度上报）
# =========================================================
# =========================================================
# 测速 + 分发（带进度上报）
# =========================================================
run_speedtest() {
    local TYPE=$1 REC_TYPE="A" 
    local RESULT_FILE="/app/result_${TYPE}.csv"
    local TMP_FILE="/tmp/result_${TYPE}_tmp.csv"
    local BASE_PCT=$2 SPAN_PCT=$3

    local -a CFST_ARGS=(-o "$TMP_FILE" -tl "$CFST_TL" -sl "$CFST_SL" -url "$CFST_URL")
    [ "$TYPE" = "IPv6" ] && { CFST_ARGS+=(-ipv6); REC_TYPE="AAAA"; }

    report_progress "speedtest_${TYPE}" "$BASE_PCT" "正在测速 ${TYPE}..."
    echo "[$(date '+%H:%M:%S')] 开始测速: ${TYPE} ..."
    /app/cfst "${CFST_ARGS[@]}" > /dev/null 2>&1

    [ ! -f "$TMP_FILE" ] && { echo "  ⚠️ ${TYPE} 结果文件不存在"; return; }

    local TOP_LATENCY=$(awk -F, 'NR==2{print $5}' "$TMP_FILE" | tr -d ' \r\n')
    if [ -z "$TOP_LATENCY" ] || [ "$TOP_LATENCY" = "0.00" ]; then
        echo "  ⚠️ ${TYPE} 测速失败或无达标IP，保留上次有效结果"
        return
    fi

    # 🚨 核心修复点：只有测速成功了，才覆盖掉正式的结果文件！
    mv -f "$TMP_FILE" "$RESULT_FILE"

    local IS_MELT=$(awk -v l="$TOP_LATENCY" -v a="$ABORT_LATENCY" 'BEGIN{print(l>a?1:0)}')
    if [ "$IS_MELT" -eq 1 ]; then
        echo "  🚨 熔断！${TOP_LATENCY}ms > ${ABORT_LATENCY}ms"
        report_progress "meltdown" "$((BASE_PCT + SPAN_PCT))" "熔断保护：延迟 ${TOP_LATENCY}ms 超标"
        return
    fi

    local BEST_IPS=$(awk -F, 'NR>1 && $5>0{print $1}' "$RESULT_FILE" | head -n ${IP_COUNT} | tr -d ' \r')
    echo "  ✅ 测速达标 (Top1: ${TOP_LATENCY}ms)"

    local DOMAIN_COUNT=${#DOMAIN_NAMES[@]}
    for i in "${!DOMAIN_NAMES[@]}"; do
        local D_PCT=$((BASE_PCT + SPAN_PCT * (i + 1) / (DOMAIN_COUNT + 1)))
        report_progress "dns_update" "$D_PCT" "更新 ${DOMAIN_NAMES[$i]} 的 ${REC_TYPE} 记录..."
        echo "  → [#$((i+1))] ${DOMAIN_NAMES[$i]}"
        update_dns_for_domain "$REC_TYPE" "$BEST_IPS" "${DOMAIN_NAMES[$i]}" "${DOMAIN_ZONES[$i]}" "${DOMAIN_TOKENS[$i]}"
    done
}

# =========================================================
# 主循环
# =========================================================
while true; do
    echo "================================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 新一轮测速任务"

    touch /tmp/scan_active
    ROUND_HAS_CHANGES=0
    report_progress "starting" 2 "正在启动测速任务..."

    if [ "$ENABLE_IPV4" = "true" ] && [ "$ENABLE_IPV6" = "true" ]; then
        run_speedtest "IPv4" 5 42
        run_speedtest "IPv6" 50 42
    elif [ "$ENABLE_IPV4" = "true" ]; then
        run_speedtest "IPv4" 5 85
    elif [ "$ENABLE_IPV6" = "true" ]; then
        run_speedtest "IPv6" 5 85
    fi

    report_progress "persist" 94 "正在保存结果..."
    date +%s > /tmp/last_run
    SLEEP_TIME=$(get_smart_sleep)
    persist_results "$SLEEP_TIME"

    report_progress "done" 100 "本轮完成"
    sleep 2
    clear_progress

    if [ "$SMART_INTERVAL" = "true" ]; then
        STABLE_NOW=$(cat "$STABLE_COUNT_FILE" 2>/dev/null || echo 0)
        [ "$ROUND_HAS_CHANGES" -eq 1 ] && echo "[$(date '+%H:%M:%S')] 📊 智能调度：有变更，重置为 ${SLEEP_TIME}s"
        [ "$SLEEP_TIME" -gt "$INTERVAL" ] && echo "[$(date '+%H:%M:%S')] 📊 智能调度：连续 ${STABLE_NOW} 轮稳定，升至 ${SLEEP_TIME}s"
    fi

    echo "[$(date '+%H:%M:%S')] 休眠 ${SLEEP_TIME} 秒..."
    REMAIN_MIN=$((SLEEP_TIME / 60))
    report_progress "sleeping" 0 "休眠中，约 ${REMAIN_MIN} 分钟后下一轮" false

    interruptible_sleep "$SLEEP_TIME"
done
