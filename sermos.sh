#!/bin/bash
# ServMon Agent v1.0 - Linux Server Monitoring
# Compatible: Debian, Ubuntu, CentOS, RHEL, Rocky Linux, AlmaLinux

CONFIG_FILE="${CONFIG_FILE:-/opt/servmon/config.ini}"
LOG_FILE="${LOG_FILE:-/var/log/servmon.log}"
PID_FILE="${PID_FILE:-/var/run/servmon.pid}"
METRICS_DIR="${METRICS_DIR:-/var/log}"
API_ENDPOINT="${API_ENDPOINT:-}"
API_KEY="${API_KEY:-}"
INTERVAL="${INTERVAL:-60}"
HEAVY_FILE_THRESHOLD="${HEAVY_FILE_THRESHOLD:-100}"

# Cargar configuracion
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

# Logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Obtener IP publica y privada
get_ips() {
    local public_ip
    local private_ip
    public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
    private_ip=$(hostname -I | awk '{print $1}')
    echo "{\"public\":\"$public_ip\",\"private\":\"$private_ip\"}"
}

# Uso de CPU
get_cpu_usage() {
    local cpu_idle
    local cpu_usage
    cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'%' -f1)
    cpu_usage=$(echo "100 - $cpu_idle" | bc)
    echo "$cpu_usage"
}

# Informacion del procesador
get_cpu_info() {
    local model
    local cores
    local load1
    model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    cores=$(nproc)
    load1=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    echo "{\"model\":\"$model\",\"cores\":$cores,\"load_avg\":$load1}"
}

# Uso de memoria
get_memory() {
    local total
    local used
    local free
    local percent
    total=$(free -m | awk '/Mem:/ {print $2}')
    used=$(free -m | awk '/Mem:/ {print $3}')
    free=$(free -m | awk '/Mem:/ {print $4}')
    percent=$(echo "scale=2; ($used / $total) * 100" | bc)
    echo "{\"total_mb\":$total,\"used_mb\":$used,\"free_mb\":$free,\"usage_percent\":$percent}"
}

# Uso de disco
get_disk() {
    local total
    local used
    local available
    local percent
    total=$(df -m / | tail -1 | awk '{print $2}')
    used=$(df -m / | tail -1 | awk '{print $3}')
    available=$(df -m / | tail -1 | awk '{print $4}')
    percent=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
    echo "{\"total_mb\":$total,\"used_mb\":$used,\"available_mb\":$available,\"usage_percent\":$percent}"
}

# Discos montados
get_all_disks() {
    local disks
    disks=$(df -h | awk '$1 ~ /^\/dev\// {
        gsub("%", "", $5)
        printf "%s{\"mount\":\"%s\",\"size\":\"%s\",\"used\":\"%s\",\"available\":\"%s\",\"percent\":%s}", sep, $6, $2, $3, $4, $5
        sep=","
    }')
    echo "[$disks]"
}

# Saturacion (load average detallado)
get_saturation() {
    local load1
    local load5
    local load15
    local cores
    local saturation1
    load1=$(cat /proc/loadavg | awk '{print $1}')
    load5=$(cat /proc/loadavg | awk '{print $2}')
    load15=$(cat /proc/loadavg | awk '{print $3}')
    cores=$(nproc)
    saturation1=$(echo "scale=2; ($load1 / $cores) * 100" | bc)
    echo "{\"load_1min\":$load1,\"load_5min\":$load5,\"load_15min\":$load15,\"cores\":$cores,\"saturation_percent\":$saturation1}"
}

# Archivos pesados (>100MB por defecto)
get_heavy_files() {
    local threshold=${1:-100}
    local files
    files=$(find / -type f -size +"${threshold}"M -exec ls -lh {} + 2>/dev/null | awk '{
        printf "%s{\"path\":\"%s\",\"size\":\"%s\"}", sep, $9, $5
        sep=","
    }' | head -20)
    echo "[$files]"
}

# Dias sin apagar (uptime)
get_uptime_days() {
    local uptime_seconds
    local days
    uptime_seconds=$(cat /proc/uptime | awk '{print $1}')
    days=$(echo "scale=0; $uptime_seconds / 86400" | bc)
    echo "$days"
}

# Puertos abiertos
get_open_ports() {
    local ports
    ports=$(ss -tuln | awk 'NR > 1 && $1 ~ /^(tcp|udp)/ {
        local_address=$5
        n=split(local_address, parts, ":")
        port=parts[n]
        if (port != "" && port ~ /^[0-9]+$/) {
            printf "%s{\"port\":%s,\"protocol\":\"%s\",\"service\":\"%s\"}", sep, port, $1, $1
            sep=","
        }
    }')
    echo "[$ports]"
}

# Procesos principales por consumo
get_top_processes() {
    local procs
    procs=$(ps aux --sort=-%mem | head -6 | tail -5 | awk '{
        printf "%s{\"pid\":%s,\"user\":\"%s\",\"cpu\":%s,\"mem\":%s,\"command\":\"%s\"}", sep, $2, $1, $3, $4, $11
        sep=","
    }')
    echo "[$procs]"
}

# Informacion del sistema
get_system_info() {
    local hostname_value
    local os
    local kernel
    local arch
    hostname_value=$(hostname)
    os=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    kernel=$(uname -r)
    arch=$(uname -m)
    echo "{\"hostname\":\"$hostname_value\",\"os\":\"$os\",\"kernel\":\"$kernel\",\"arch\":\"$arch\"}"
}

# Recolectar todas las metricas
collect_metrics() {
    local timestamp
    local system_info
    local ips
    local cpu_usage
    local cpu_info
    local memory
    local disk
    local all_disks
    local saturation
    local heavy_files
    local uptime_days
    local open_ports
    local top_processes
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    system_info=$(get_system_info)
    ips=$(get_ips)
    cpu_usage=$(get_cpu_usage)
    cpu_info=$(get_cpu_info)
    memory=$(get_memory)
    disk=$(get_disk)
    all_disks=$(get_all_disks)
    saturation=$(get_saturation)
    heavy_files=$(get_heavy_files "$HEAVY_FILE_THRESHOLD")
    uptime_days=$(get_uptime_days)
    open_ports=$(get_open_ports)
    top_processes=$(get_top_processes)

    cat <<EOF
{
    "timestamp": "$timestamp",
    "system": $system_info,
    "network": $ips,
    "cpu": {
        "usage_percent": $cpu_usage,
        "info": $cpu_info
    },
    "memory": $memory,
    "disk": {
        "root": $disk,
        "all_mounts": $all_disks
    },
    "saturation": $saturation,
    "heavy_files": $heavy_files,
    "uptime_days": $uptime_days,
    "open_ports": $open_ports,
    "top_processes": $top_processes
}
EOF
}

# Enviar a API
send_to_api() {
    local data="$1"
    if [[ -n "$API_ENDPOINT" && -n "$API_KEY" ]]; then
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d "$data" \
            "$API_ENDPOINT" \
            --max-time 10 \
            -o /dev/null \
            -w "%{http_code}"
    else
        echo "NO_ENDPOINT"
    fi
}

# Guardar localmente si falla el envio
save_local() {
    local data="$1"
    local date_str
    local file
    date_str=$(date +%Y%m%d)
    mkdir -p "$METRICS_DIR"
    file="$METRICS_DIR/servmon-metrics-$date_str.json"
    echo "$data" >> "$file"
}

# Bucle principal
main_loop() {
    log "ServMon Agent iniciado - Intervalo: ${INTERVAL}s"

    while true; do
        local metrics
        local response
        metrics=$(collect_metrics)

        # Guardar siempre localmente
        save_local "$metrics"

        # Intentar enviar a API
        if [[ -n "$API_ENDPOINT" ]]; then
            response=$(send_to_api "$metrics")
            if [[ "$response" == "200" ]]; then
                log "Metricas enviadas correctamente"
            else
                log "ERROR: No se pudieron enviar metricas (HTTP $response)"
            fi
        fi

        sleep "$INTERVAL"
    done
}

# Manejar senales
cleanup() {
    log "ServMon Agent detenido"
    rm -f "$PID_FILE"
    exit 0
}

run_agent() {
    trap cleanup SIGTERM SIGINT
    echo $$ > "$PID_FILE"
    load_config
    main_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_agent
fi
