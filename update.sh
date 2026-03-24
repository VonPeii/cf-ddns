#!/bin/bash

# =============================================
# 极客版 CF-DDNS v6
# 多域名（独立 Zone/Token） / 渐进式更新 / 失败重试 / 智能调度 / Web 面板
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

# --- 渐进式更新（金丝雀模式） ---
CANARY_MODE=${CANARY_MODE:-false}
CANARY_MAX_CHANGES=${CANARY_MAX_CHANGES:-1}

# --- 失败重试与退避 ---
API_MAX_RETRIES=${API_MAX_RETRIES:-3}
API_BASE_DELAY=${API_BASE_DELAY:-5}

# --- 智能调度间隔 ---
SMART_INTERVAL=${SMART_INTERVAL:-false}
SMART_STABLE_THRESHOLD=${SMART_STABLE_THRESHOLD:-3}
MAX_INTERVAL=${MAX_INTERVAL:-172800}
STABLE_COUNT_FILE="/tmp/stable_count"

# --- Web 面板 ---
WEB_PORT=${WEB_PORT:-8088}
WEB_DIR="/app/web"
DATA_DIR="${WEB_DIR}/data"
HISTORY_MAX=${HISTORY_MAX:-200}

# --- 运行时状态 ---
ROUND_HAS_CHANGES=0

# =========================================================
# 解析多域名配置：DOMAIN_1_NAME / DOMAIN_1_ZONE_ID / DOMAIN_1_TOKEN ...
# 输出全局数组: DOMAIN_NAMES[], DOMAIN_ZONES[], DOMAIN_TOKENS[]
# =========================================================
DOMAIN_NAMES=()
DOMAIN_ZONES=()
DOMAIN_TOKENS=()

parse_domain_config() {
    local i=1
    while true; do
        local NAME_VAR="DOMAIN_${i}_NAME"
        local ZONE_VAR="DOMAIN_${i}_ZONE_ID"
        local TOKEN_VAR="DOMAIN_${i}_TOKEN"

        local D_NAME="${!NAME_VAR}"
        local D_ZONE="${!ZONE_VAR}"
        local D_TOKEN="${!TOKEN_VAR}"

        # 没有更多域名了，退出
        [ -z "$D_NAME" ] && break

        # 校验必填字段
        if [ -z "$D_ZONE" ] || [ -z "$D_TOKEN" ]; then
            echo "⚠️ 域名 #${i} (${D_NAME}) 缺少 ZONE_ID 或 TOKEN，跳过！"
            i=$((i + 1))
            continue
        fi

        DOMAIN_NAMES+=("$D_NAME")
        DOMAIN_ZONES+=("$D_ZONE")
        DOMAIN_TOKENS+=("$D_TOKEN")
        i=$((i + 1))
    done

    if [ ${#DOMAIN_NAMES[@]} -eq 0 ]; then
        echo "❌ 未配置任何域名！请检查 DOMAIN_1_NAME / DOMAIN_1_ZONE_ID / DOMAIN_1_TOKEN 等环境变量。"
        exit 1
    fi
}

parse_domain_config

# =========================================================
# 初始化
# =========================================================
mkdir -p "$DATA_DIR"
[ ! -f "${DATA_DIR}/history.json" ] && echo '[]' > "${DATA_DIR}/history.json"

echo "========== 极客版 CF-DDNS v6 启动 =========="
echo "域名数量: ${#DOMAIN_NAMES[@]}"
for i in "${!DOMAIN_NAMES[@]}"; do
    echo "  [#$((i+1))] ${DOMAIN_NAMES[$i]}"
done
echo "基础间隔: ${INTERVAL} 秒"
echo "启用 IPv4: ${ENABLE_IPV4} | 启用 IPv6: ${ENABLE_IPV6}"
echo "熔断阈值: ${ABORT_LATENCY} ms"
echo "金丝雀模式: ${CANARY_MODE}"
echo "智能调度: ${SMART_INTERVAL}"
echo "Web 面板: http://0.0.0.0:${WEB_PORT}"

# 启动 Web 服务器
httpd -p "${WEB_PORT}" -h "${WEB_DIR}"
echo "✅ Web 面板已启动"

# =========================================================
# 带重试与指数退避的 Cloudflare API 调用
# 用法: cf_api TOKEN METHOD ENDPOINT [DATA]
# =========================================================
cf_api() {
    local TOKEN="$1"
    local METHOD="$2"
    local ENDPOINT="$3"
    local DATA="$4"
    local DELAY=${API_BASE_DELAY}

    for i in $(seq 1 "$API_MAX_RETRIES"); do
        local RESPONSE
        if [ -n "$DATA" ]; then
            RESPONSE=$(curl -s --max-time 30 -X "$METHOD" \
                "https://api.cloudflare.com/client/v4${ENDPOINT}" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json" \
                --data "$DATA")
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
            local ERR_MSG=$(echo "$RESPONSE" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)
            echo "  ❌ API 最终失败 (${API_MAX_RETRIES}次): ${ERR_MSG}" >&2
            echo "$RESPONSE"
            return 1
        fi

        echo "  ⚠️ API 失败 (${i}/${API_MAX_RETRIES})，${DELAY}s 后重试..." >&2
        sleep "$DELAY"
        DELAY=$((DELAY * 2))
    done
}

# =========================================================
# 智能调度：计算休眠时间
# =========================================================
get_smart_sleep() {
    if [ "$SMART_INTERVAL" != "true" ]; then
        echo "$INTERVAL"
        return
    fi

    local COUNT=0
    if [ -f "$STABLE_COUNT_FILE" ]; then
        COUNT=$(cat "$STABLE_COUNT_FILE" 2>/dev/null)
        [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
    fi

    if [ "$ROUND_HAS_CHANGES" -eq 1 ]; then
        echo 0 > "$STABLE_COUNT_FILE"
        echo "$INTERVAL"
        return
    fi

    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$STABLE_COUNT_FILE"

    local DOUBLES=$((COUNT / SMART_STABLE_THRESHOLD))
    local SLEEP_TIME=$INTERVAL

    for _ in $(seq 1 "$DOUBLES"); do
        SLEEP_TIME=$((SLEEP_TIME * 2))
        if [ "$SLEEP_TIME" -ge "$MAX_INTERVAL" ]; then
            SLEEP_TIME=$MAX_INTERVAL
            break
        fi
    done

    echo "$SLEEP_TIME"
}

# =========================================================
# 持久化：status.json + history.json
# =========================================================
persist_results() {
    local SLEEP_SEC=$1
    local NOW_STR=$(date '+%Y-%m-%d %H:%M:%S')
    local NOW_TS=$(date +%s)

    # IPv4 结果
    local IPV4_DATA="[]"
    local IPV4_TOP_LAT="null"
    local IPV4_TOP_SPEED="null"
    if [ "$ENABLE_IPV4" = "true" ] && [ -f "/app/result_IPv4.csv" ]; then
        IPV4_DATA=$(awk -F, 'NR>1 && $5>0 {
            gsub(/ /, "", $1); gsub(/ /, "", $5); gsub(/ /, "", $6)
            printf "{\"ip\":\"%s\",\"latency\":%s,\"speed\":%s}\n", $1, $5, $6
        }' /app/result_IPv4.csv | head -n "$IP_COUNT" | jq -s '.' 2>/dev/null)
        [ -z "$IPV4_DATA" ] && IPV4_DATA="[]"
        IPV4_TOP_LAT=$(echo "$IPV4_DATA" | jq '.[0].latency // null')
        IPV4_TOP_SPEED=$(echo "$IPV4_DATA" | jq '.[0].speed // null')
    fi

    # IPv6 结果
    local IPV6_DATA="[]"
    local IPV6_TOP_LAT="null"
    local IPV6_TOP_SPEED="null"
    if [ "$ENABLE_IPV6" = "true" ] && [ -f "/app/result_IPv6.csv" ]; then
        IPV6_DATA=$(awk -F, 'NR>1 && $5>0 {
            gsub(/ /, "", $1); gsub(/ /, "", $5); gsub(/ /, "", $6)
            printf "{\"ip\":\"%s\",\"latency\":%s,\"speed\":%s}\n", $1, $5, $6
        }' /app/result_IPv6.csv | head -n "$IP_COUNT" | jq -s '.' 2>/dev/null)
        [ -z "$IPV6_DATA" ] && IPV6_DATA="[]"
        IPV6_TOP_LAT=$(echo "$IPV6_DATA" | jq '.[0].latency // null')
        IPV6_TOP_SPEED=$(echo "$IPV6_DATA" | jq '.[0].speed // null')
    fi

    # 域名列表 JSON
    local DOMAINS_JSON=$(printf '%s\n' "${DOMAIN_NAMES[@]}" | jq -R . | jq -s '.')

    # status.json
    jq -n \
        --arg last_update "$NOW_STR" \
        --argjson last_ts "$NOW_TS" \
        --argjson sleep_seconds "$SLEEP_SEC" \
        --argjson domains "$DOMAINS_JSON" \
        --argjson smart_interval $([ "$SMART_INTERVAL" = "true" ] && echo true || echo false) \
        --argjson canary_mode $([ "$CANARY_MODE" = "true" ] && echo true || echo false) \
        --argjson ipv4_enabled $([ "$ENABLE_IPV4" = "true" ] && echo true || echo false) \
        --argjson ipv4_data "$IPV4_DATA" \
        --argjson ipv4_top_lat "$IPV4_TOP_LAT" \
        --argjson ipv6_enabled $([ "$ENABLE_IPV6" = "true" ] && echo true || echo false) \
        --argjson ipv6_data "$IPV6_DATA" \
        --argjson ipv6_top_lat "$IPV6_TOP_LAT" \
        --argjson abort_latency "$ABORT_LATENCY" \
        '{
            last_update: $last_update,
            last_ts: $last_ts,
            sleep_seconds: $sleep_seconds,
            domains: $domains,
            smart_interval: $smart_interval,
            canary_mode: $canary_mode,
            abort_latency: $abort_latency,
            ipv4: { enabled: $ipv4_enabled, top_latency: $ipv4_top_lat, ips: $ipv4_data },
            ipv6: { enabled: $ipv6_enabled, top_latency: $ipv6_top_lat, ips: $ipv6_data }
        }' > "${DATA_DIR}/status.json.tmp" && mv "${DATA_DIR}/status.json.tmp" "${DATA_DIR}/status.json"

    # history.json
    local HISTORY_ENTRY=$(jq -n \
        --arg time "$NOW_STR" \
        --argjson ts "$NOW_TS" \
        --argjson v4_lat "$IPV4_TOP_LAT" \
        --argjson v4_spd "$IPV4_TOP_SPEED" \
        --argjson v6_lat "$IPV6_TOP_LAT" \
        --argjson v6_spd "$IPV6_TOP_SPEED" \
        '{time: $time, ts: $ts, v4_lat: $v4_lat, v4_spd: $v4_spd, v6_lat: $v6_lat, v6_spd: $v6_spd}')

    jq --argjson entry "$HISTORY_ENTRY" --argjson max "$HISTORY_MAX" \
        '. + [$entry] | .[-$max:]' "${DATA_DIR}/history.json" > "${DATA_DIR}/history.json.tmp" \
        && mv "${DATA_DIR}/history.json.tmp" "${DATA_DIR}/history.json"

    echo "  📊 状态已持久化"
}

# =========================================================
# DNS Diff 更新（指定域名 + 对应凭据）
# =========================================================
update_dns_for_domain() {
    local RECORD_TYPE=$1
    local NEW_IPS=$2
    local DOMAIN=$3
    local ZONE_ID=$4
    local TOKEN=$5

    local API_RESPONSE
    API_RESPONSE=$(cf_api "$TOKEN" GET "/zones/${ZONE_ID}/dns_records?name=${DOMAIN}&type=${RECORD_TYPE}")

    if [ $? -ne 0 ]; then
        echo "    ❌ [${RECORD_TYPE}] ${DOMAIN} API 查询失败，跳过。"
        return
    fi

    local CURRENT_RECORDS=$(echo "$API_RESPONSE" | jq -r '.result[] | "\(.id)|\(.content)"')

    # 计算差异
    local -a IPS_TO_ADD=()
    local -a RECS_TO_DEL=()

    for N_IP in $NEW_IPS; do
        local MATCH=0
        for C_REC in $CURRENT_RECORDS; do
            [ "$N_IP" = "${C_REC#*|}" ] && MATCH=1 && break
        done
        [ $MATCH -eq 0 ] && IPS_TO_ADD+=("$N_IP")
    done

    for C_REC in $CURRENT_RECORDS; do
        local C_IP="${C_REC#*|}"
        local MATCH=0
        for N_IP in $NEW_IPS; do
            [ "$C_IP" = "$N_IP" ] && MATCH=1 && break
        done
        [ $MATCH -eq 0 ] && RECS_TO_DEL+=("$C_REC")
    done

    local TOTAL_ADD=${#IPS_TO_ADD[@]}
    local TOTAL_DEL=${#RECS_TO_DEL[@]}
    local TOTAL_CHANGES=$((TOTAL_ADD + TOTAL_DEL))

    if [ $TOTAL_CHANGES -eq 0 ]; then
        echo "    [${RECORD_TYPE}] ${DOMAIN} 无变化"
        return
    fi

    # 金丝雀限流
    local APPLY_ADD=$TOTAL_ADD
    local APPLY_DEL=$TOTAL_DEL
    local IS_CANARY=0

    if [ "$CANARY_MODE" = "true" ]; then
        local REMAIN=$CANARY_MAX_CHANGES
        [ $APPLY_ADD -gt $REMAIN ] && APPLY_ADD=$REMAIN
        REMAIN=$((REMAIN - APPLY_ADD))
        [ $REMAIN -lt 0 ] && REMAIN=0
        [ $APPLY_DEL -gt $REMAIN ] && APPLY_DEL=$REMAIN

        if [ $((APPLY_ADD + APPLY_DEL)) -lt $TOTAL_CHANGES ]; then
            IS_CANARY=1
            echo "    🐤 [${RECORD_TYPE}] ${DOMAIN} 金丝雀：$((APPLY_ADD+APPLY_DEL))/${TOTAL_CHANGES} 变更"
        fi
    fi

    # 执行添加
    local ADD_OK=0
    for idx in $(seq 0 $((APPLY_ADD - 1))); do
        local IP="${IPS_TO_ADD[$idx]}"
        if cf_api "$TOKEN" POST "/zones/${ZONE_ID}/dns_records" \
            "{\"type\":\"${RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}" > /dev/null; then
            echo "    🎉 [${RECORD_TYPE}] ${DOMAIN} +${IP}"
            ADD_OK=$((ADD_OK + 1))
        else
            echo "    ❌ [${RECORD_TYPE}] ${DOMAIN} 添加失败: ${IP}"
        fi
    done

    # 执行删除
    local DEL_OK=0
    for idx in $(seq 0 $((APPLY_DEL - 1))); do
        local REC="${RECS_TO_DEL[$idx]}"
        local C_ID="${REC%|*}"
        local C_IP="${REC#*|}"
        if cf_api "$TOKEN" DELETE "/zones/${ZONE_ID}/dns_records/${C_ID}" > /dev/null; then
            echo "    🗑️ [${RECORD_TYPE}] ${DOMAIN} -${C_IP}"
            DEL_OK=$((DEL_OK + 1))
        else
            echo "    ❌ [${RECORD_TYPE}] ${DOMAIN} 删除失败: ${C_IP}"
        fi
    done

    if [ $ADD_OK -gt 0 ] || [ $DEL_OK -gt 0 ]; then
        ROUND_HAS_CHANGES=1
        echo "    ✅ [${RECORD_TYPE}] ${DOMAIN} 完成: +${ADD_OK} -${DEL_OK}"
        [ $IS_CANARY -eq 1 ] && echo "       🐤 剩余 $((TOTAL_CHANGES - ADD_OK - DEL_OK)) 个变更留待后续轮次"
    fi
}

# =========================================================
# 测速 + 多域名分发（各域名用各自的凭据）
# =========================================================
run_speedtest() {
    local TYPE=$1
    local REC_TYPE="A"
    local RESULT_FILE="/app/result_${TYPE}.csv"

    local -a CFST_ARGS=(-o "$RESULT_FILE" -tl "$CFST_TL" -sl "$CFST_SL" -url "$CFST_URL")

    if [ "$TYPE" = "IPv6" ]; then
        CFST_ARGS+=(-ipv6)
        REC_TYPE="AAAA"
    fi

    echo "[$(date '+%H:%M:%S')] 开始测速: ${TYPE} ..."
    /app/cfst "${CFST_ARGS[@]}" > /dev/null 2>&1

    if [ ! -f "$RESULT_FILE" ]; then
        echo "  ⚠️ ${TYPE} 结果文件不存在，跳过。"
        return
    fi

    local TOP_LATENCY=$(awk -F, 'NR==2 {print $5}' "$RESULT_FILE" | tr -d ' ')

    if [ -z "$TOP_LATENCY" ] || [ "$TOP_LATENCY" = "0.00" ]; then
        echo "  ⚠️ ${TYPE} 测速失败，跳过。"
        return
    fi

    # 熔断
    local IS_MELT=$(awk -v l="$TOP_LATENCY" -v a="$ABORT_LATENCY" 'BEGIN{print(l>a?1:0)}')
    if [ "$IS_MELT" -eq 1 ]; then
        echo "  🚨 熔断！Top1延迟 ${TOP_LATENCY}ms > 阈值 ${ABORT_LATENCY}ms，跳过更新。"
        return
    fi

    local BEST_IPS=$(awk -F, 'NR>1 && $5>0 {print $1}' "$RESULT_FILE" | head -n ${IP_COUNT})
    echo "  ✅ 测速达标 (Top1: ${TOP_LATENCY}ms)，分发到所有域名..."

    # 遍历所有域名，各用各的凭据
    for i in "${!DOMAIN_NAMES[@]}"; do
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

    ROUND_HAS_CHANGES=0

    [ "$ENABLE_IPV4" = "true" ] && run_speedtest "IPv4"
    [ "$ENABLE_IPV6" = "true" ] && run_speedtest "IPv6"

    date +%s > /tmp/last_run

    SLEEP_TIME=$(get_smart_sleep)
    persist_results "$SLEEP_TIME"

    if [ "$SMART_INTERVAL" = "true" ]; then
        STABLE_NOW=$(cat "$STABLE_COUNT_FILE" 2>/dev/null || echo 0)
        if [ "$ROUND_HAS_CHANGES" -eq 1 ]; then
            echo "[$(date '+%H:%M:%S')] 📊 智能调度：有变更，重置为 ${SLEEP_TIME}s"
        elif [ "$SLEEP_TIME" -gt "$INTERVAL" ]; then
            echo "[$(date '+%H:%M:%S')] 📊 智能调度：连续 ${STABLE_NOW} 轮稳定，升至 ${SLEEP_TIME}s"
        fi
    fi

    echo "[$(date '+%H:%M:%S')] 休眠 ${SLEEP_TIME} 秒..."
    sleep "$SLEEP_TIME"
done
