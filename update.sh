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
ROUND_HAS_VALID_RESULT=0

# =========================================================
# 校验工具
# =========================================================
fail_startup() {
    echo "❌ $1" >&2
    exit 1
}

log() {
    local LEVEL="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LEVEL}] $*"
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_int() {
    is_uint "$1" && [ "$1" -gt 0 ]
}

is_bool() {
    [ "$1" = "true" ] || [ "$1" = "false" ]
}

check_required_command() {
    command -v "$1" > /dev/null 2>&1 || fail_startup "缺少依赖命令: $1"
}

normalize_ip_list() {
    awk 'NF && !seen[$0]++ { print $0 }'
}

count_ip_list() {
    awk 'NF { c++ } END { print c + 0 }'
}

init_runtime_files() {
    mkdir -p "$DATA_DIR" "${WEB_DIR}/cgi-bin"
    [ ! -f "${DATA_DIR}/history.json" ] && echo '[]' > "${DATA_DIR}/history.json"
    [ ! -f "${DATA_DIR}/progress.json" ] && echo '{"active":false,"phase":"idle","percent":0,"message":"等待第一轮测速","updated_at":"--:--:--"}' > "${DATA_DIR}/progress.json"
    [ ! -f "${DATA_DIR}/status.json" ] && jq -n \
        --argjson domains "$(printf '%s\n' "${DOMAIN_NAMES[@]}" | jq -R . | jq -s '.')" \
        --argjson smart_interval $([ "$SMART_INTERVAL" = "true" ] && echo true || echo false) \
        --argjson canary_mode $([ "$CANARY_MODE" = "true" ] && echo true || echo false) \
        --argjson ipv4_enabled $([ "$ENABLE_IPV4" = "true" ] && echo true || echo false) \
        --argjson ipv6_enabled $([ "$ENABLE_IPV6" = "true" ] && echo true || echo false) \
        --argjson abort_latency "$ABORT_LATENCY" \
        '{last_update:null,last_ts:null,sleep_seconds:0,domains:$domains,smart_interval:$smart_interval,
          canary_mode:$canary_mode,abort_latency:$abort_latency,
          ipv4:{enabled:$ipv4_enabled,top_latency:null,ips:[]},
          ipv6:{enabled:$ipv6_enabled,top_latency:null,ips:[]}}' > "${DATA_DIR}/status.json"
}

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

cleanup_on_exit() {
    rm -f /tmp/scan_active /tmp/trigger_scan
    if [ -d "$DATA_DIR" ]; then
        report_progress "idle" 0 "服务未在运行，等待容器重启" false
    fi
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
            log_warn "域名 #${INDEX} (${D_NAME}) 缺少 ZONE_ID 或 TOKEN，跳过"
            continue
        fi

        DOMAIN_NAMES+=("$D_NAME")
        DOMAIN_ZONES+=("$D_ZONE")
        DOMAIN_TOKENS+=("$D_TOKEN")
    done < <(compgen -A variable | grep -E '^DOMAIN_[0-9]+_NAME$' | sort -V)

    if [ ${#DOMAIN_NAMES[@]} -eq 0 ]; then
        fail_startup "未配置任何域名"
    fi
}

# =========================================================
# 启动校验
# =========================================================
validate_runtime_config() {
    check_required_command curl
    check_required_command jq
    check_required_command awk
    check_required_command sed
    check_required_command grep
    check_required_command sort
    check_required_command wc
    check_required_command httpd
    check_required_command seq

    [ -x /app/cfst ] || fail_startup "测速程序 /app/cfst 不存在或不可执行"

    is_positive_int "$INTERVAL" || fail_startup "INTERVAL 必须是正整数，当前值: $INTERVAL"
    is_positive_int "$CFST_TL" || fail_startup "CFST_TL 必须是正整数，当前值: $CFST_TL"
    is_positive_int "$CFST_SL" || fail_startup "CFST_SL 必须是正整数，当前值: $CFST_SL"
    is_positive_int "$IP_COUNT" || fail_startup "IP_COUNT 必须是正整数，当前值: $IP_COUNT"
    is_positive_int "$ABORT_LATENCY" || fail_startup "ABORT_LATENCY 必须是正整数，当前值: $ABORT_LATENCY"
    is_positive_int "$CANARY_MAX_CHANGES" || fail_startup "CANARY_MAX_CHANGES 必须是正整数，当前值: $CANARY_MAX_CHANGES"
    is_positive_int "$API_MAX_RETRIES" || fail_startup "API_MAX_RETRIES 必须是正整数，当前值: $API_MAX_RETRIES"
    is_positive_int "$API_BASE_DELAY" || fail_startup "API_BASE_DELAY 必须是正整数，当前值: $API_BASE_DELAY"
    is_positive_int "$SMART_STABLE_THRESHOLD" || fail_startup "SMART_STABLE_THRESHOLD 必须是正整数，当前值: $SMART_STABLE_THRESHOLD"
    is_positive_int "$MAX_INTERVAL" || fail_startup "MAX_INTERVAL 必须是正整数，当前值: $MAX_INTERVAL"
    is_positive_int "$HISTORY_MAX" || fail_startup "HISTORY_MAX 必须是正整数，当前值: $HISTORY_MAX"
    is_positive_int "$WEB_PORT" || fail_startup "WEB_PORT 必须是正整数，当前值: $WEB_PORT"
    [ "$WEB_PORT" -le 65535 ] || fail_startup "WEB_PORT 超出有效范围，当前值: $WEB_PORT"

    is_bool "$ENABLE_IPV4" || fail_startup "ENABLE_IPV4 只能是 true 或 false，当前值: $ENABLE_IPV4"
    is_bool "$ENABLE_IPV6" || fail_startup "ENABLE_IPV6 只能是 true 或 false，当前值: $ENABLE_IPV6"
    is_bool "$CANARY_MODE" || fail_startup "CANARY_MODE 只能是 true 或 false，当前值: $CANARY_MODE"
    is_bool "$SMART_INTERVAL" || fail_startup "SMART_INTERVAL 只能是 true 或 false，当前值: $SMART_INTERVAL"

    [ "$ENABLE_IPV4" = "true" ] || [ "$ENABLE_IPV6" = "true" ] || fail_startup "ENABLE_IPV4 和 ENABLE_IPV6 不能同时为 false"
    [ "$MAX_INTERVAL" -ge "$INTERVAL" ] || fail_startup "MAX_INTERVAL 不能小于 INTERVAL"
    [ "$ABORT_LATENCY" -ge "$CFST_TL" ] || fail_startup "ABORT_LATENCY 不能小于 CFST_TL，否则达标结果会被熔断"
    [ -n "$CFST_URL" ] || fail_startup "CFST_URL 不能为空"

    local i
    for i in "${!DOMAIN_NAMES[@]}"; do
        local D_NAME="${DOMAIN_NAMES[$i]}"
        local D_ZONE="${DOMAIN_ZONES[$i]}"
        local D_TOKEN="${DOMAIN_TOKENS[$i]}"

        [ -n "$D_NAME" ] || fail_startup "存在空的 DOMAIN_N_NAME"
        [ -n "$D_ZONE" ] || fail_startup "域名 ${D_NAME} 缺少 ZONE_ID"
        [ -n "$D_TOKEN" ] || fail_startup "域名 ${D_NAME} 缺少 TOKEN"
        [[ "$D_NAME" != *" "* ]] || fail_startup "域名 ${D_NAME} 含有空格"
        [[ "$D_ZONE" != "your_zone_id_here" ]] || fail_startup "域名 ${D_NAME} 的 ZONE_ID 仍是示例值"
        [[ "$D_TOKEN" != "your_api_token_here" ]] || fail_startup "域名 ${D_NAME} 的 TOKEN 仍是示例值"
    done
}

parse_domain_config
validate_runtime_config
trap cleanup_on_exit EXIT

# =========================================================
# 初始化
# =========================================================
init_runtime_files
clear_progress

log_info "========== 极客版 CF-DDNS v7 启动 =========="
log_info "域名数量: ${#DOMAIN_NAMES[@]}"
for i in "${!DOMAIN_NAMES[@]}"; do
    log_info "  [#$((i+1))] ${DOMAIN_NAMES[$i]}"
done
log_info "Web 面板: http://0.0.0.0:${WEB_PORT}"
log_info "同步策略: 每种记录类型目标保留 ${IP_COUNT} 条；非目标记录会删除；超额记录会自动收敛"
[ "$CANARY_MODE" = "true" ] && log_info "更新模式: 金丝雀，每轮最多替换 ${CANARY_MAX_CHANGES} 条"
[ "$CANARY_MODE" != "true" ] && log_info "更新模式: 全量同步"

# 启动 Web 服务器（支持 CGI）
httpd -p "${WEB_PORT}" -h "${WEB_DIR}"
log_info "Web 面板已启动"

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
            local ERRORS
            ERRORS=$(echo "$RESPONSE" | jq -r '.errors[]?.message' 2>/dev/null | tr '\n' '; ' | sed 's/; $//')
            [ -z "$ERRORS" ] && ERRORS="未知错误或非 JSON 响应"
            log_error "Cloudflare API ${METHOD} ${ENDPOINT} 最终失败: ${ERRORS}"
            echo "$RESPONSE"
            return 1
        fi

        log_warn "Cloudflare API ${METHOD} ${ENDPOINT} 失败 (${i}/${API_MAX_RETRIES})，${DELAY}s 后重试"
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
            log_info "收到手动触发信号"
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

    NEW_IPS=$(printf '%s\n' $NEW_IPS | normalize_ip_list)
    local TARGET_COUNT
    TARGET_COUNT=$(printf '%s\n' "$NEW_IPS" | count_ip_list)
    [ "$TARGET_COUNT" -gt 0 ] || { log_warn "[${RECORD_TYPE}] ${DOMAIN} 没有可用目标 IP，跳过更新"; return; }

    local API_RESPONSE
    API_RESPONSE=$(cf_api "$TOKEN" GET "/zones/${ZONE_ID}/dns_records?name=${DOMAIN}&type=${RECORD_TYPE}")
    [ $? -ne 0 ] && { log_error "[${RECORD_TYPE}] ${DOMAIN} API 查询失败"; return; }

    local CURRENT_RECORDS=$(echo "$API_RESPONSE" | jq -r '.result[] | "\(.id)|\(.content)"')
    local -a CURRENT_REC_ARRAY=() IPS_TO_ADD=() RECS_TO_DEL=() OVERFLOW_RECS=()

    while IFS= read -r C_REC; do
        [ -n "$C_REC" ] && CURRENT_REC_ARRAY+=("$C_REC")
    done <<< "$CURRENT_RECORDS"

    for N_IP in $NEW_IPS; do
        local MATCH=0
        for C_REC in "${CURRENT_REC_ARRAY[@]}"; do [ "$N_IP" = "${C_REC#*|}" ] && MATCH=1 && break; done
        [ $MATCH -eq 0 ] && IPS_TO_ADD+=("$N_IP")
    done

    for C_REC in "${CURRENT_REC_ARRAY[@]}"; do
        local C_IP="${C_REC#*|}" MATCH=0
        for N_IP in $NEW_IPS; do [ "$C_IP" = "$N_IP" ] && MATCH=1 && break; done
        [ $MATCH -eq 0 ] && RECS_TO_DEL+=("$C_REC")
    done

    local CURRENT_COUNT=${#CURRENT_REC_ARRAY[@]}
    local EXCESS=$((CURRENT_COUNT - TARGET_COUNT))
    if [ "$EXCESS" -gt 0 ]; then
        for C_REC in "${CURRENT_REC_ARRAY[@]}"; do
            [ "$EXCESS" -le 0 ] && break

            local C_IP="${C_REC#*|}"
            local KEEP=0
            for N_IP in $NEW_IPS; do
                if [ "$C_IP" = "$N_IP" ]; then
                    KEEP=1
                    break
                fi
            done

            [ "$KEEP" -eq 0 ] && continue

            local ALREADY_DEL=0
            for D_REC in "${RECS_TO_DEL[@]}"; do
                [ "$C_REC" = "$D_REC" ] && ALREADY_DEL=1 && break
            done
            [ "$ALREADY_DEL" -eq 1 ] && continue

            OVERFLOW_RECS+=("$C_REC")
            EXCESS=$((EXCESS - 1))
        done
    fi

    if [ ${#OVERFLOW_RECS[@]} -gt 0 ]; then
        log_warn "[${RECORD_TYPE}] ${DOMAIN} 检测到超额记录 ${#OVERFLOW_RECS[@]} 条，开始收敛"
        RECS_TO_DEL+=("${OVERFLOW_RECS[@]}")
    fi

    local TOTAL_ADD=${#IPS_TO_ADD[@]} TOTAL_DEL=${#RECS_TO_DEL[@]}
    local TOTAL_CHANGES=$((TOTAL_ADD + TOTAL_DEL))
    [ $TOTAL_CHANGES -eq 0 ] && { log_info "[${RECORD_TYPE}] ${DOMAIN} 无变化"; return; }
    log_info "[${RECORD_TYPE}] ${DOMAIN} 目标 ${TARGET_COUNT} 条，当前 ${CURRENT_COUNT} 条，待新增 ${TOTAL_ADD}，待删除 ${TOTAL_DEL}"

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
                log_info "[${RECORD_TYPE}] ${DOMAIN} +${IP}"
                if cf_api "$TOKEN" DELETE "/zones/${ZONE_ID}/dns_records/${C_ID}" > /dev/null; then
                    log_info "[${RECORD_TYPE}] ${DOMAIN} -${C_IP}"
                    ADD_OK=$((ADD_OK + 1))
                    DEL_OK=$((DEL_OK + 1))
                    SLOTS=$((SLOTS - 1))
                else
                    log_warn "[${RECORD_TYPE}] ${DOMAIN} 删除旧记录失败，保留新增的 ${IP}"
                fi
            fi
        done

        local ADD_START=$REPLACEMENTS
        for idx in $(seq "$ADD_START" $((TOTAL_ADD - 1))); do
            [ "$SLOTS" -le 0 ] && break

            local IP="${IPS_TO_ADD[$idx]}"
            if cf_api "$TOKEN" POST "/zones/${ZONE_ID}/dns_records" \
                "{\"type\":\"${RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}" > /dev/null; then
                log_info "[${RECORD_TYPE}] ${DOMAIN} +${IP}"
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
                log_info "[${RECORD_TYPE}] ${DOMAIN} -${C_IP}"
                DEL_OK=$((DEL_OK + 1))
                SLOTS=$((SLOTS - 1))
            fi
        done
    else
        for idx in $(seq 0 $((TOTAL_ADD - 1))); do
            local IP="${IPS_TO_ADD[$idx]}"
            if cf_api "$TOKEN" POST "/zones/${ZONE_ID}/dns_records" \
                "{\"type\":\"${RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}" > /dev/null; then
                log_info "[${RECORD_TYPE}] ${DOMAIN} +${IP}"
                ADD_OK=$((ADD_OK + 1))
            fi
        done

        for idx in $(seq 0 $((TOTAL_DEL - 1))); do
            local REC="${RECS_TO_DEL[$idx]}"
            local C_ID="${REC%|*}"
            local C_IP="${REC#*|}"
            if cf_api "$TOKEN" DELETE "/zones/${ZONE_ID}/dns_records/${C_ID}" > /dev/null; then
                log_info "[${RECORD_TYPE}] ${DOMAIN} -${C_IP}"
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
    log_info "开始测速: ${TYPE}"
    if ! /app/cfst "${CFST_ARGS[@]}" > /dev/null 2>&1; then
        log_warn "${TYPE} 测速程序退出异常，保留上次有效结果"
    fi

    [ ! -f "$TMP_FILE" ] && { log_warn "${TYPE} 结果文件不存在，保留上次有效结果"; return; }

    local TOP_LATENCY=$(awk -F, 'NR==2{print $5}' "$TMP_FILE" | tr -d ' \r\n')
    if [ -z "$TOP_LATENCY" ] || [ "$TOP_LATENCY" = "0.00" ]; then
        log_warn "${TYPE} 测速失败或无达标 IP，保留上次有效结果"
        rm -f "$TMP_FILE"
        return
    fi

    mv -f "$TMP_FILE" "$RESULT_FILE"
    ROUND_HAS_VALID_RESULT=1

    local IS_MELT=$(awk -v l="$TOP_LATENCY" -v a="$ABORT_LATENCY" 'BEGIN{print(l>a?1:0)}')
    if [ "$IS_MELT" -eq 1 ]; then
        log_warn "${TYPE} 熔断: ${TOP_LATENCY}ms > ${ABORT_LATENCY}ms"
        report_progress "meltdown" "$((BASE_PCT + SPAN_PCT))" "熔断保护：延迟 ${TOP_LATENCY}ms 超标"
        return
    fi

    local BEST_IPS=$(awk -F, 'NR>1 && $5>0{print $1}' "$RESULT_FILE" | head -n ${IP_COUNT} | tr -d ' \r')
    BEST_IPS=$(printf '%s\n' $BEST_IPS | normalize_ip_list)
    local BEST_COUNT
    BEST_COUNT=$(printf '%s\n' "$BEST_IPS" | count_ip_list)
    [ "$BEST_COUNT" -gt 0 ] || { log_warn "${TYPE} 没有可用目标 IP，跳过 DNS 更新"; return; }
    log_info "${TYPE} 测速达标 (Top1: ${TOP_LATENCY}ms)"
    log_info "${TYPE} 本轮目标记录数: ${BEST_COUNT}"

    local DOMAIN_COUNT=${#DOMAIN_NAMES[@]}
    for i in "${!DOMAIN_NAMES[@]}"; do
        local D_PCT=$((BASE_PCT + SPAN_PCT * (i + 1) / (DOMAIN_COUNT + 1)))
        report_progress "dns_update" "$D_PCT" "更新 ${DOMAIN_NAMES[$i]} 的 ${REC_TYPE} 记录..."
        log_info "更新 [${REC_TYPE}] [#$((i+1))] ${DOMAIN_NAMES[$i]}"
        update_dns_for_domain "$REC_TYPE" "$BEST_IPS" "${DOMAIN_NAMES[$i]}" "${DOMAIN_ZONES[$i]}" "${DOMAIN_TOKENS[$i]}"
    done
}

# =========================================================
# 主循环
# =========================================================
while true; do
    log_info "================================================="
    log_info "新一轮测速任务"

    touch /tmp/scan_active
    ROUND_HAS_CHANGES=0
    ROUND_HAS_VALID_RESULT=0
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
    [ "$ROUND_HAS_VALID_RESULT" -eq 1 ] && log_info "本轮至少生成了 1 份有效测速结果"
    [ "$ROUND_HAS_VALID_RESULT" -eq 0 ] && log_warn "本轮没有新的有效测速结果，状态页继续显示历史有效结果"

    report_progress "done" 100 "本轮完成"
    sleep 2
    clear_progress

    if [ "$SMART_INTERVAL" = "true" ]; then
        STABLE_NOW=$(cat "$STABLE_COUNT_FILE" 2>/dev/null || echo 0)
        [ "$ROUND_HAS_CHANGES" -eq 1 ] && log_info "智能调度: 有变更，重置为 ${SLEEP_TIME}s"
        [ "$SLEEP_TIME" -gt "$INTERVAL" ] && log_info "智能调度: 连续 ${STABLE_NOW} 轮稳定，升至 ${SLEEP_TIME}s"
    fi

    log_info "休眠 ${SLEEP_TIME} 秒"
    REMAIN_MIN=$((SLEEP_TIME / 60))
    report_progress "sleeping" 0 "休眠中，约 ${REMAIN_MIN} 分钟后下一轮" false

    interruptible_sleep "$SLEEP_TIME"
done
