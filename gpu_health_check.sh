#!/bin/bash
# ============================================================================
# GPU 集群通信健康检测脚本
# 功能：
#   1. 单主机 GPU 间 P2P 通信带宽检测 (MetaxLink)
#   2. 单主机 GPU 跨 CPU 通信带宽检测 (PCIe)
#   3. 跨主机 GPU 通信带宽检测 (OM - 网络)
#   4. GPU 显存 (HBM) 读写带宽检测 & PCIe 链路状态检测 (合并)
#   5. 综合健康评分与报告
#
# 测试环境: MetaX C550 GPU, MACA 3.7.2.0
# ============================================================================

set -o pipefail

# ============================================================================
# 配置区域（已脱敏，可安全入库）
#   - HOSTS    默认空，必须经 --hosts <csv> 或环境变量 GHC_HOSTS 注入；
#              流水线侧 mccl-gpu-probe 必传 --hosts，不受影响。
#   - SSH_PASS 默认空 = 走 SSH 免密 key（推荐；MCCL 流水线本身要求配好免密）。
#              个别机器未配免密时，设环境变量 GHC_SSH_PASS=<密码> 注入。
#   严禁把真实主机 IP / 密码直接写回本文件后再提交。
# ============================================================================

# 主机列表（由 --hosts 或 GHC_HOSTS 注入；空 → 参数解析后 fail-fast）
HOSTS=()
if [[ -n "${GHC_HOSTS:-}" ]]; then
    IFS=',' read -ra HOSTS <<< "$GHC_HOSTS"
fi

# SSH 配置
SSH_USER="${GHC_SSH_USER:-root}"
SSH_PASS="${GHC_SSH_PASS:-}"
SSH_OPTS="${GHC_SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=30 -o LogLevel=ERROR}"

# 每台主机最大 GPU 数量（用于探测）
MAX_GPUS_PER_HOST=8

# 跨主机测试的代表性 GPU 对（src_host_idx:src_gpu,dst_host_idx:dst_gpu）
# 默认测试每对主机间 GPU0<->GPU0 的带宽
CROSS_HOST_GPU_PAIRS=("0:0,1:0" "0:0,2:0" "0:0,3:0" "1:0,2:0" "1:0,3:0" "2:0,3:0")

# OM 测试数据大小
OM_DATA_SIZES="1024MB"

# 跨主机测试超时（秒）
OM_TEST_TIMEOUT=120

# ============================================================================
# 阈值配置 (基于实测参考值设定)
# ============================================================================

# P2P MetaxLink 带宽阈值 (GB/s)
P2P_BW_CRITICAL=50     # 低于此值为严重异常
P2P_BW_WARNING=80      # 低于此值为警告
P2P_BW_GOOD=95         # 良好标准（参考值 ~99 GB/s）

# 跨CPU PCIe 带宽阈值 (GB/s)
PCIE_BW_CRITICAL=30
PCIE_BW_WARNING=45
PCIE_BW_GOOD=50        # 参考值 ~52-57 GB/s

# 跨主机 OM 带宽阈值 (MB/s)
OM_BW_CRITICAL=30000
OM_BW_WARNING=40000
OM_BW_GOOD=50000       # 参考值 ~53000 MB/s

# HBM 显存带宽阈值 (GB/s)
HBM_BW_CRITICAL=1000
HBM_BW_WARNING=1400
HBM_BW_GOOD=1600       # 参考值 ~1678 GB/s

# PCIe 预期速率 (GT/s)
PCIE_SPEED_EXPECTED=32.0
PCIE_WIDTH_EXPECTED="x16"

# ============================================================================
# 颜色与输出
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

PASS_MARK="${GREEN}✓${NC}"
FAIL_MARK="${RED}✗${NC}"
WARN_MARK="${YELLOW}⚠${NC}"

# ============================================================================
# 目录与文件
# ============================================================================
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_DIR="./gpu_health_results_${TIMESTAMP}"
LOG_DIR="${RESULT_DIR}/logs"
REPORT_FILE="${RESULT_DIR}/health_report.txt"

# 测试结果存储（关联数组需要 bash 4+）
declare -A GPU_COUNT
declare -A P2P_RESULTS
declare -A PCIE_RESULTS
declare -A HBM_RESULTS
declare -A OM_RESULTS
declare -A PCIE_STATUS
declare -A GPU_MODELS

# 错误计数
TOTAL_TESTS=0
PASS_TESTS=0
WARN_TESTS=0
FAIL_TESTS=0
ERROR_TESTS=0

# ============================================================================
# 工具函数
# ============================================================================

log() {
    local level=$1
    shift
    local msg="$*"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "[${timestamp}] [${level}] ${msg}"
    echo "[${timestamp}] [${level}] ${msg}" >> "${RESULT_DIR}/full.log" 2>/dev/null
}

log_info()  { log "INFO" "$@"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARN" "$@"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; log "ERROR" "$@"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $*"; log "PASS" "$@"; }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*"; log "FAIL" "$@"; }

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  $*"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────${NC}"
}

# 每个主机的 mxvs 所在目录（预检时自动探测）
declare -A MXVS_DIR

# SSH 执行命令（自动注入 mxvs PATH）
ssh_exec() {
    local host=$1
    shift
    local cmd="$*"
    local prefix=""
    if [[ -n "${MXVS_DIR[${host}]}" ]]; then
        prefix="export PATH=${MXVS_DIR[${host}]}:\$PATH && "
    fi
    if command -v sshpass &>/dev/null && [[ -n "${SSH_PASS}" ]]; then
        sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${host}" "${prefix}${cmd}" 2>&1
    else
        ssh ${SSH_OPTS} "${SSH_USER}@${host}" "${prefix}${cmd}" 2>&1
    fi
}

# SSH 执行命令（无密码，已配置免密时使用）
ssh_exec_nopass() {
    local host=$1
    shift
    ssh ${SSH_OPTS} "${SSH_USER}@${host}" "$@" 2>&1
}

# 远程后台执行并返回 PID
ssh_exec_bg() {
    local host=$1
    shift
    local cmd="$*"
    local prefix=""
    if [[ -n "${MXVS_DIR[${host}]}" ]]; then
        prefix="export PATH=${MXVS_DIR[${host}]}:\$PATH && "
    fi
    if command -v sshpass &>/dev/null && [[ -n "${SSH_PASS}" ]]; then
        sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${host}" "${prefix}${cmd}" &
    else
        ssh ${SSH_OPTS} "${SSH_USER}@${host}" "${prefix}${cmd}" &
    fi
    echo $!
}

# 检查 SSH 连通性
check_ssh() {
    local host=$1
    local result
    result=$(ssh_exec "${host}" "echo OK" 2>/dev/null)
    if [[ "$result" == "OK" ]]; then
        return 0
    else
        return 1
    fi
}

# 探测主机 GPU 数量
discover_gpus() {
    local host=$1
    local gpu_count=0

    # 方法0: 使用 mxvs devices（最可靠，直接列出所有GPU）
    if [[ -n "${MXVS_DIR[${host}]}" ]]; then
        local devices_out
        devices_out=$(ssh_exec "${host}" "mxvs devices 2>&1" 2>/dev/null)
        # 统计 GPU Devices 表格中的数据行（行首为数字+空格+数字+空格+型号的模式）
        gpu_count=$(echo "$devices_out" | grep -cE '^\s+[0-9]+\s+[0-9]+\s+MetaX' 2>/dev/null || echo 0)
        gpu_count=$(echo "$gpu_count" | grep -oE '[0-9]+' | tail -1)
        [[ -z "$gpu_count" ]] && gpu_count=0
    fi

    # 方法1: 使用 mx-smi（输出中直接包含 "Attached GPUs: N"）
    if [[ $gpu_count -eq 0 ]]; then
        local smi_out
        smi_out=$(ssh_exec "${host}" "mx-smi 2>&1" 2>/dev/null)
        gpu_count=$(echo "$smi_out" | grep -oP 'Attached GPUs\s*:\s*\K\d+' 2>/dev/null || echo 0)
        gpu_count=$(echo "$gpu_count" | grep -oE '[0-9]+' | tail -1)
        [[ -z "$gpu_count" ]] && gpu_count=0
    fi

    # 方法2: 检查 /dev/mxgpu* 设备文件
    if [[ $gpu_count -eq 0 ]]; then
        gpu_count=$(ssh_exec "${host}" "ls /dev/mxgpu* 2>/dev/null | wc -l" 2>/dev/null || echo 0)
        gpu_count=$(echo "$gpu_count" | grep -oE '[0-9]+' | tail -1)
        [[ -z "$gpu_count" ]] && gpu_count=0
    fi

    GPU_COUNT["${host}"]=$gpu_count
    log_info "主机 ${host}: 发现 ${gpu_count} 个 GPU"
    return $gpu_count
}

# 获取 GPU 型号
get_gpu_model() {
    local host=$1
    local gpu_id=$2
    local model="Unknown"

    # 方法1: mxvs devices（优先，GPU Devices 表格 Model 列直接显示型号）
    local devices_out
    devices_out=$(ssh_exec "${host}" "mxvs devices 2>&1" 2>/dev/null)
    # 匹配 GPU Devices 表格行: "0  0  MetaX C550  0000:..."
    model=$(echo "$devices_out" | grep -oP '^\s+[0-9]+\s+[0-9]+\s+\K\S+(\s+\S+)?(?=\s+[0-9a-f]{4}:)' | head -1 2>/dev/null)
    if [[ -n "$model" ]]; then
        echo "$model"
        return
    fi

    # 方法2: mx-smi（每行直接包含型号名，如 "MetaX C550"）
    local smi_out
    smi_out=$(ssh_exec "${host}" "mx-smi 2>&1" 2>/dev/null)
    model=$(echo "$smi_out" | grep -oP '\|\s+[0-9]+\s+\K\S+(\s+\S+)?(?=\s+\|)' | head -1 2>/dev/null)
    if [[ -n "$model" ]]; then
        echo "$model"
        return
    fi
}

# 计算百分比（用于评估带宽相对参考值）
calc_percent() {
    local value=$1
    local reference=$2
    if [[ -z "$value" ]] || [[ "$value" == "N/A" ]] || [[ "$reference" == "0" ]]; then
        echo "N/A"
        return
    fi
    awk "BEGIN {printf \"%.1f%%\", ${value}/${reference}*100}" 2>/dev/null || echo "N/A"
}

# 带单位解析为数字
parse_bandwidth_gbs() {
    local bw_str=$1
    # 处理 "98.92 GB/s" 这样的格式
    echo "$bw_str" | grep -oP '[\d.]+(?=\s*GB/s)' | head -1
}

parse_bandwidth_mbs() {
    local bw_str=$1
    # 处理 "52892.56 MB/s" 这样的格式
    echo "$bw_str" | grep -oP '[\d.]+(?=\s*MB/s)' | head -1
}

# 评估带宽等级
evaluate_bw() {
    local bw=$1
    local critical=$2
    local warning=$3
    local good=$4

    if [[ -z "$bw" ]] || [[ "$bw" == "N/A" ]]; then
        echo "ERROR"
        return
    fi

    # 使用 awk 进行浮点数比较，通过退出码返回结果
    if awk "BEGIN {if (${bw} < ${critical}) exit 0; else exit 1}" 2>/dev/null; then
        echo "FAIL"
    elif awk "BEGIN {if (${bw} < ${warning}) exit 0; else exit 1}" 2>/dev/null; then
        echo "WARN"
    elif awk "BEGIN {if (${bw} < ${good}) exit 0; else exit 1}" 2>/dev/null; then
        echo "PASS"
    else
        echo "GOOD"
    fi
}

# 格式化状态输出
status_icon() {
    case $1 in
        PASS|GOOD) echo -e "${GREEN}✓ 优秀${NC}" ;;
        WARN)      echo -e "${YELLOW}⚠ 偏低${NC}" ;;
        FAIL)      echo -e "${RED}✗ 异常${NC}" ;;
        ERROR)     echo -e "${RED}✗ 错误${NC}" ;;
        *)         echo -e "${YELLOW}? 未知${NC}" ;;
    esac
}

# 判断是否同一 NUMA 节点(同一主板)
same_numa() {
    local host=$1
    local gpu1=$2
    local gpu2=$3

    local numa1 numa2
    numa1=$(ssh_exec "${host}" "mxvs memory benchmark --devices ${gpu1} 2>&1" 2>/dev/null | grep "NUMA NODE" | awk '{print $NF}')
    numa2=$(ssh_exec "${host}" "mxvs memory benchmark --devices ${gpu2} 2>&1" 2>/dev/null | grep "NUMA NODE" | awk '{print $NF}')

    if [[ "$numa1" == "$numa2" ]] && [[ -n "$numa1" ]]; then
        return 0  # 相同 NUMA
    else
        return 1  # 不同 NUMA
    fi
}

# ============================================================================
# 测试 1: 单主机 GPU 间 P2P 带宽测试
# ============================================================================
test_intra_host_p2p() {
    local host=$1
    local gpu_count=${GPU_COUNT["${host}"]}

    print_header "单主机 P2P 测试 - ${host} (共 ${gpu_count} 个 GPU)"

    if [[ $gpu_count -lt 2 ]]; then
        log_warn "主机 ${host} GPU 数量不足，跳过 P2P 测试"
        return
    fi

    echo ""
    printf "  %-10s %-10s %-14s %-18s %-14s %-20s %s\n" \
        "GPU#A" "GPU#B" "拓扑" "实测带宽" "参考值" "达标率" "状态"
    print_separator

    local host_p2p_pass=0
    local host_p2p_warn=0
    local host_p2p_fail=0

    # 生成测试 GPU 对列表
    local pairs=()
    if $RING_MODE; then
        # 环状模式: 0→1, 1→2, ..., 7→0，共 gpu_count 路
        for ((i=0; i<gpu_count; i++)); do
            local j=$(( (i + 1) % gpu_count ))
            pairs+=("${i}:${j}")
        done
        log_info "环状模式: 仅测试 ${gpu_count} 路 (GPU 环形拓扑)"
    else
        # 星状（全互联）模式: 所有 GPU 两两配对
        for ((i=0; i<gpu_count; i++)); do
            for ((j=i+1; j<gpu_count; j++)); do
                pairs+=("${i}:${j}")
            done
        done
    fi

    for pair in "${pairs[@]}"; do
        local i="${pair%%:*}"
        local j="${pair##*:}"
        local test_key="${host}:${i}-${j}"
        TOTAL_TESTS=$((TOTAL_TESTS + 1))

        log_info "P2P 测试: ${host} GPU#${i} -> GPU#${j}"

        local output
        output=$(ssh_exec "${host}" "mxvs p2p --src-devices ${i} --dst-devices ${j}" 2>&1)

        # 保存原始输出
        echo "=== ${host} GPU#${i} <-> GPU#${j} ===" >> "${LOG_DIR}/${host}_p2p.log"
        echo "$output" >> "${LOG_DIR}/${host}_p2p.log"
        echo "" >> "${LOG_DIR}/${host}_p2p.log"

        # 解析结果
        local topology effective raw validation
        effective=$(echo "$output" | grep -E "GPU#[0-9].*GPU#[0-9]" | grep -oP '[\d.]+(?=\s*GB/s)' | head -1)

        if [[ -z "$effective" ]]; then
            effective=$(echo "$output" | grep -E "GPU#[0-9]" | grep -oP '[\d.]+(?=\s*GB/s)' | head -1)
        fi

        # 提取拓扑类型（NVLink / MetaXLink / PIX / PXB / SYS 等）
        topology="N/A"
        if echo "$output" | grep -qi "metaxlink"; then
            topology="MetaXLink"
        elif echo "$output" | grep -qi "nvlink"; then
            topology="NVLink"
        else
            local topo_tmp
            topo_tmp=$(echo "$output" | grep -oiE '\b(PIX|PXB|PHB|SYS)\b' | head -1)
            [[ -n "$topo_tmp" ]] && topology="$topo_tmp"
        fi

        # 认证结果：有带宽即视为通过，否则检查关键字
        local validation_result
        if [[ -n "$effective" ]] && [[ "$effective" != "N/A" ]]; then
            validation_result="PASS"
        elif echo "$output" | grep -qi "pass"; then
            validation_result="PASS"
        elif echo "$output" | grep -qi "fail"; then
            validation_result="FAIL"
        else
            validation_result="N/A"
        fi

        if [[ -z "$effective" ]]; then
            effective="N/A"
            topology="N/A"
        fi

        P2P_RESULTS["${test_key}"]="${effective}|${topology}|${validation_result}"

        local status
        if [[ "$effective" == "N/A" ]]; then
            status="ERROR"
            ERROR_TESTS=$((ERROR_TESTS + 1))
            host_p2p_fail=$((host_p2p_fail + 1))
        else
            local pct
            pct=$(calc_percent "$effective" "$P2P_BW_GOOD")
            status=$(evaluate_bw "$effective" "$P2P_BW_CRITICAL" "$P2P_BW_WARNING" "$P2P_BW_GOOD")

            case $status in
                GOOD|PASS) PASS_TESTS=$((PASS_TESTS + 1)); host_p2p_pass=$((host_p2p_pass + 1)) ;;
                WARN) WARN_TESTS=$((WARN_TESTS + 1)); host_p2p_warn=$((host_p2p_warn + 1)) ;;
                FAIL) FAIL_TESTS=$((FAIL_TESTS + 1)); host_p2p_fail=$((host_p2p_fail + 1)) ;;
                ERROR) ERROR_TESTS=$((ERROR_TESTS + 1)); host_p2p_fail=$((host_p2p_fail + 1)) ;;
            esac

            printf "  GPU#%-4s GPU#%-4s %-14s %-18s %-14s %-20s %s\n" \
                "${i}" "${j}" "${topology:-N/A}" "${effective} GB/s" "${P2P_BW_GOOD} GB/s" "${pct}" "$(status_icon $status)"
        fi
    done

    echo ""
    if [[ $host_p2p_fail -gt 0 ]]; then
        log_warn "P2P 汇总: ${GREEN}${host_p2p_pass} 正常${NC} / ${YELLOW}${host_p2p_warn} 偏低${NC} / ${RED}${host_p2p_fail} 异常${NC}"
    else
        log_pass "P2P 汇总: 全部 ${host_p2p_pass} 路通信正常"
    fi
}

# ============================================================================
# 测试 2: 单主机 GPU 跨 CPU 通信带宽测试 (PCIe)
# ============================================================================
test_intra_host_pcie() {
    local host=$1
    local gpu_count=${GPU_COUNT["${host}"]}

    print_header "单主机跨CPU PCIe 测试 - ${host}"

    echo ""
    printf "  %-10s %-10s %-18s %-18s %-14s %-20s %s\n" \
        "GPU#SRC" "GPU#DST" "实测带宽(SRC->DST)" "实测带宽(DST->SRC)" "参考值" "达标率" "状态"
    print_separator

    # 生成跨CPU测试对
    local pcie_pairs=()
    if $RING_MODE; then
        # 环状模式: 仅测跨CPU边界的两路 (3→4, 7→0)
        local ring_cross=("3:4" "7:0")
        for pair in "${ring_cross[@]}"; do
            local si="${pair%%:*}"
            local sj="${pair##*:}"
            if [[ $si -lt $gpu_count ]] && [[ $sj -lt $gpu_count ]]; then
                pcie_pairs+=("${si}:${sj}")
            fi
        done
        log_info "环状模式 PCIE: 仅测试 ${#pcie_pairs[@]} 路跨CPU链路"
    else
        # 默认: 遍历所有跨NUMA GPU对
        for ((i=0; i<gpu_count; i++)); do
            for ((j=i+1; j<gpu_count; j++)); do
                if ! same_numa "${host}" $i $j; then
                    pcie_pairs+=("${i}:${j}")
                fi
            done
        done
    fi

    for pair in "${pcie_pairs[@]}"; do
        local i="${pair%%:*}"
        local j="${pair##*:}"
        local test_key="${host}:pcie:${i}-${j}"
            TOTAL_TESTS=$((TOTAL_TESTS + 1))

            log_info "PCIE 测试: ${host} GPU#${i} <-> GPU#${j}"

            # GPU 信息
            local gpu_info
            gpu_info=$(ssh_exec "${host}" "mxvs pcie benchmark unidirection --src-devices ${i} --dst-devices ${j}" 2>&1)

            echo "=== ${host} GPU#${i} <-> GPU#${j} ===" >> "${LOG_DIR}/${host}_pcie.log"
            echo "$gpu_info" >> "${LOG_DIR}/${host}_pcie.log"
            echo "" >> "${LOG_DIR}/${host}_pcie.log"

            # 解析双向带宽
            local bw_cpu_to_board bw_board_to_cpu
            bw_cpu_to_board=$(echo "$gpu_info" | grep "CPU.*<<.*BOARD" | grep -oP '[\d.]+(?=\s*GB/s)' | head -1)
            bw_board_to_cpu=$(echo "$gpu_info" | grep "CPU.*>>.*BOARD" | grep -oP '[\d.]+(?=\s*GB/s)' | head -1)

            [[ -z "$bw_cpu_to_board" ]] && bw_cpu_to_board="N/A"
            [[ -z "$bw_board_to_cpu" ]] && bw_board_to_cpu="N/A"

            PCIE_RESULTS["${test_key}"]="${bw_cpu_to_board}|${bw_board_to_cpu}"

            # 评估（取两者中较低的值作为评估标准）
            local lower_bw
            if [[ "$bw_cpu_to_board" != "N/A" ]] && [[ "$bw_board_to_cpu" != "N/A" ]]; then
                lower_bw=$(echo "$bw_cpu_to_board $bw_board_to_cpu" | awk '{if ($1 < $2) print $1; else print $2}')
            elif [[ "$bw_cpu_to_board" != "N/A" ]]; then
                lower_bw="$bw_cpu_to_board"
            elif [[ "$bw_board_to_cpu" != "N/A" ]]; then
                lower_bw="$bw_board_to_cpu"
            else
                lower_bw="N/A"
            fi

            if [[ "$lower_bw" == "N/A" ]]; then
                ERROR_TESTS=$((ERROR_TESTS + 1))
                printf "  GPU#%-4s GPU#%-4s %-18s %-18s %-14s %-20s %s\n" \
                    "${i}" "${j}" "N/A" "N/A" "${PCIE_BW_GOOD} GB/s" "N/A" "$(status_icon ERROR)"
                continue
            fi

            local status pct
            status=$(evaluate_bw "$lower_bw" "$PCIE_BW_CRITICAL" "$PCIE_BW_WARNING" "$PCIE_BW_GOOD")
            pct=$(calc_percent "$lower_bw" "$PCIE_BW_GOOD")

            case $status in
                GOOD|PASS) PASS_TESTS=$((PASS_TESTS + 1)) ;;
                WARN) WARN_TESTS=$((WARN_TESTS + 1)) ;;
                FAIL) FAIL_TESTS=$((FAIL_TESTS + 1)) ;;
                ERROR) ERROR_TESTS=$((ERROR_TESTS + 1)) ;;
            esac

            printf "  GPU#%-4s GPU#%-4s %-18s %-18s %-14s %-20s %s\n" \
                "${i}" "${j}" "${bw_cpu_to_board} GB/s" "${bw_board_to_cpu} GB/s" \
                "${PCIE_BW_GOOD} GB/s" "${pct}" "$(status_icon $status)"
    done
    echo ""
}

# ============================================================================
# 测试 4: GPU 显存 (HBM) 带宽测试 & PCIe 链路状态检查 (合并)
# 说明: 两者共用 mxvs memory benchmark 命令，一次执行同时获取 HBM 带宽和 PCIe 状态
# ============================================================================
test_hbm_bandwidth() {
    local host=$1
    local gpu_count=${GPU_COUNT["${host}"]}

    print_header "GPU 显存 (HBM) 带宽 & PCIe 链路状态 - ${host}"

    echo ""
    printf "  %-8s %-12s %-16s %-14s %-10s %-18s %-18s %s\n" \
        "GPU#ID" "BDF" "HBM带宽" "参考值" "达标率" "当前PCIe" "最大PCIe" "状态"
    print_separator

    for ((i=0; i<gpu_count; i++)); do
        local test_key="${host}:hbm:${i}"
        TOTAL_TESTS=$((TOTAL_TESTS + 1))

        log_info "HBM/PCIe 测试: ${host} GPU#${i}"

        local output
        output=$(ssh_exec "${host}" "mxvs memory benchmark --devices ${i}" 2>&1)

        echo "=== ${host} GPU#${i} ===" >> "${LOG_DIR}/${host}_hbm.log"
        echo "$output" >> "${LOG_DIR}/${host}_hbm.log"
        echo "" >> "${LOG_DIR}/${host}_hbm.log"

        # 解析 BDF
        local bdf
        bdf=$(echo "$output" | grep "BDF" | head -1 | awk '{print $NF}')
        [[ -z "$bdf" ]] && bdf="N/A"

        # 解析 HBM 带宽
        local hbm_bw
        hbm_bw=$(echo "$output" | grep -E "^\s*[0-9]+\s+[0-9a-f:.]+\s+[0-9]+\s" | grep -oP '[\d.]+(?=\s*GB/s)' | head -1)

        # 解析 GPU 型号和 PCIe 当前/最大状态
        local model pcie_current pcie_max
        model=$(echo "$output" | grep "MODEL" | head -1 | awk '{print $NF}')
        pcie_current=$(echo "$output" | grep "CURRENT PCIE" | head -1 | sed 's/.*speed: //' | sed 's/width: / /')
        pcie_max=$(echo "$output" | grep "MAXIMUM PCIE" | head -1 | sed 's/.*speed: //' | sed 's/width: / /')

        [[ -z "$model" ]] && model="Unknown"
        [[ -z "$hbm_bw" ]] && hbm_bw="N/A"

        GPU_MODELS["${host}:${i}"]="$model"
        PCIE_STATUS["${host}:${i}"]="${pcie_current:-N/A} | max: ${pcie_max:-N/A}"

        HBM_RESULTS["${test_key}"]="${hbm_bw}"

        # 评估 PCIe 降速
        local pcie_status="PASS"
        local cur_speed cur_width max_speed max_width
        cur_speed=$(echo "$pcie_current" | grep -oP '[\d.]+(?=\s*GT/s)')
        cur_width=$(echo "$pcie_current" | grep -oP 'x\d+')
        max_speed=$(echo "$pcie_max" | grep -oP '[\d.]+(?=\s*GT/s)')
        max_width=$(echo "$pcie_max" | grep -oP 'x\d+')

        if [[ -n "$cur_speed" ]] && [[ -n "$max_speed" ]]; then
            if awk "BEGIN {if (${cur_speed} < ${max_speed} * 0.8) exit 0; else exit 1}" 2>/dev/null; then
                pcie_status="WARN"
            fi
        fi
        if [[ -n "$cur_width" ]] && [[ -n "$max_width" ]]; then
            local cw mw
            cw=$(echo "$cur_width" | tr -d 'x')
            mw=$(echo "$max_width" | tr -d 'x')
            if [[ $cw -lt $mw ]]; then
                pcie_status="WARN"
            fi
        fi

        if [[ "$hbm_bw" == "N/A" ]]; then
            ERROR_TESTS=$((ERROR_TESTS + 1))
            printf "  GPU#%-4s %-12s %-16s %-14s %-10s %-18s %-18s %s\n" \
                "${i}" "${bdf}" "N/A" "${HBM_BW_GOOD} GB/s" "N/A" \
                "${pcie_current:-N/A}" "${pcie_max:-N/A}" "$(status_icon ERROR)"
            continue
        fi

        local status pct
        status=$(evaluate_bw "$hbm_bw" "$HBM_BW_CRITICAL" "$HBM_BW_WARNING" "$HBM_BW_GOOD")
        pct=$(calc_percent "$hbm_bw" "$HBM_BW_GOOD")

        case $status in
            GOOD|PASS) PASS_TESTS=$((PASS_TESTS + 1)) ;;
            WARN) WARN_TESTS=$((WARN_TESTS + 1)) ;;
            FAIL) FAIL_TESTS=$((FAIL_TESTS + 1)) ;;
            ERROR) ERROR_TESTS=$((ERROR_TESTS + 1)) ;;
        esac

        # 综合状态：HBM 和 PCIe 取最差
        local combined_status="$status"
        if [[ "$pcie_status" == "WARN" ]]; then
            [[ "$combined_status" == "GOOD" || "$combined_status" == "PASS" ]] && combined_status="WARN"
        fi

        local pcie_warn_mark=""
        [[ "$pcie_status" == "WARN" ]] && pcie_warn_mark=" ${YELLOW}(PCIe降速!)${NC}"

        printf "  GPU#%-4s %-12s %-16s %-14s %-10s %-18s %-18s %s%s\n" \
            "${i}" "${bdf}" "${hbm_bw} GB/s" "${HBM_BW_GOOD} GB/s" "${pct}" \
            "${pcie_current:-N/A}" "${pcie_max:-N/A}" "$(status_icon $combined_status)" "${pcie_warn_mark}"
    done
    echo ""
}

# ============================================================================
# 测试 4: 跨主机 GPU 通信带宽测试 (OM)
# ============================================================================
test_cross_host_om() {
    local host_a=$1
    local host_b=$2
    local gpu_a=$3
    local gpu_b=$4

    local test_key="om:${host_a}:${gpu_a}<->${host_b}:${gpu_b}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    log_info "OM 测试: ${host_a}:GPU#${gpu_a} <-> ${host_b}:GPU#${gpu_b}"

    # 预清理: 杀掉 host_b 上残留的 mxvs om server，释放端口
    ssh_exec "${host_b}" "pkill -f 'mxvs om server' 2>/dev/null; sleep 1" 2>/dev/null || true

    # 在 host_b 上启动 server（在远端监听）
    local server_pid
    log_info "在 ${host_b} 启动 mxvs om server..."
    ssh_exec_bg "${host_b}" "mxvs om server 2>&1"
    server_pid=$!
    sleep 3

    # 在 host_a 上启动 client（timeout 不能调用 bash 函数，使用原生 ssh）
    local output=""
    local client_result=1
    local prefix_a=""
    [[ -n "${MXVS_DIR[${host_a}]}" ]] && prefix_a="export PATH=${MXVS_DIR[${host_a}]}:\$PATH && "

    if kill -0 $server_pid 2>/dev/null; then
        log_info "在 ${host_a} 启动 mxvs om client -> ${host_b}..."
        if command -v sshpass &>/dev/null && [[ -n "${SSH_PASS}" ]]; then
            output=$(timeout ${OM_TEST_TIMEOUT} sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${host_a}" "${prefix_a}mxvs om client --dst-addr ${host_b} --src-devices ${gpu_a} --dst-devices ${gpu_b} -w 0 --data-sizes ${OM_DATA_SIZES}" 2>&1)
        else
            output=$(timeout ${OM_TEST_TIMEOUT} ssh ${SSH_OPTS} "${SSH_USER}@${host_a}" "${prefix_a}mxvs om client --dst-addr ${host_b} --src-devices ${gpu_a} --dst-devices ${gpu_b} -w 0 --data-sizes ${OM_DATA_SIZES}" 2>&1)
        fi
        client_result=$?
    else
        log_error "${host_b} 上 mxvs om server 启动失败"
        output="SERVER_START_FAILED"
    fi

    # 清理 server
    log_info "停止 ${host_b} 上的 mxvs om server..."
    ssh_exec "${host_b}" "pkill -f 'mxvs om server'" 2>/dev/null
    kill $server_pid 2>/dev/null
    wait $server_pid 2>/dev/null

    # 保存日志
    echo "=== ${host_a}:GPU#${gpu_a} -> ${host_b}:GPU#${gpu_b} ===" >> "${LOG_DIR}/om.log"
    echo "$output" >> "${LOG_DIR}/om.log"
    echo "" >> "${LOG_DIR}/om.log"

    # 解析结果（多种模式尝试）
    local om_bw=""
    # 模式1: 查找 "MB/s" 前面的数字
    om_bw=$(echo "$output" | grep -oP '[\d.]+(?=\s*MB/s)' | tail -1)
    # 模式2: 行尾的数字
    [[ -z "$om_bw" ]] && om_bw=$(echo "$output" | grep "GPU#" | grep -oP '[\d.]+(?=\s*$)' | head -1)
    # 模式3: avg / average 后面的数字
    [[ -z "$om_bw" ]] && om_bw=$(echo "$output" | grep -ioP '(?:avg|average)[^0-9]*\K[\d.]+' | head -1)
    # 模式4: 任意浮点数
    [[ -z "$om_bw" ]] && om_bw=$(echo "$output" | grep -oP '[\d]{4,}\.[\d]+' | head -1)

    [[ -z "$om_bw" ]] && om_bw="N/A"

    OM_RESULTS["${test_key}"]="${om_bw}"

    # 评估
    echo ""
    printf "  %-22s %-22s %-18s %-14s %-20s %s\n" \
        "源: ${host_a}:GPU#${gpu_a}" "目标: ${host_b}:GPU#${gpu_b}" \
        "${om_bw} MB/s" "${OM_BW_GOOD} MB/s" \
        "$(calc_percent "$om_bw" "$OM_BW_GOOD")" \
        "$(status_icon $(evaluate_bw "$om_bw" "$OM_BW_CRITICAL" "$OM_BW_WARNING" "$OM_BW_GOOD"))"

    if [[ "$om_bw" == "N/A" ]]; then
        ERROR_TESTS=$((ERROR_TESTS + 1))
        log_error "OM 测试失败: ${host_a}:GPU#${gpu_a} <-> ${host_b}:GPU#${gpu_b}"
        # 打印原始输出前几行帮助诊断
        local trimmed
        trimmed=$(echo "$output" | grep -v "^export PATH\|^$\|^\[" | head -5)
        [[ -n "$trimmed" ]] && echo "      原始输出: $trimmed"
        return 1
    fi

    local status
    status=$(evaluate_bw "$om_bw" "$OM_BW_CRITICAL" "$OM_BW_WARNING" "$OM_BW_GOOD")
    case $status in
        GOOD|PASS) PASS_TESTS=$((PASS_TESTS + 1)) ;;
        WARN) WARN_TESTS=$((WARN_TESTS + 1)) ;;
        FAIL) FAIL_TESTS=$((FAIL_TESTS + 1)) ;;
        *) ERROR_TESTS=$((ERROR_TESTS + 1)) ;;
    esac
}

# ============================================================================
# 跨主机 OM 综合测试
# ============================================================================
test_all_cross_host() {
    print_header "跨主机 GPU 通信测试 (OM)"

    echo -e "${YELLOW}注意: 跨主机 OM 测试需要逐对进行，耗时较长...${NC}"
    echo ""

    printf "  %-22s %-22s %-18s %-14s %-20s %s\n" \
        "源 GPU" "目标 GPU" "实测带宽" "参考值" "达标率" "状态"
    print_separator

    local tested_pairs=()
    for pair_def in "${CROSS_HOST_GPU_PAIRS[@]}"; do
        # 解析 "src_host:src_gpu,dst_host:dst_gpu"
        local src_part dst_part
        src_part=$(echo "$pair_def" | cut -d',' -f1)
        dst_part=$(echo "$pair_def" | cut -d',' -f2)

        local src_host_idx src_gpu dst_host_idx dst_gpu
        src_host_idx=$(echo "$src_part" | cut -d':' -f1)
        src_gpu=$(echo "$src_part" | cut -d':' -f2)
        dst_host_idx=$(echo "$dst_part" | cut -d':' -f1)
        dst_gpu=$(echo "$dst_part" | cut -d':' -f2)

        local host_a="${HOSTS[$src_host_idx]}"
        local host_b="${HOSTS[$dst_host_idx]}"

        if [[ -z "$host_a" ]] || [[ -z "$host_b" ]]; then
            log_error "无效的主机索引: src=${src_host_idx} dst=${dst_host_idx}"
            continue
        fi

        # 跳过 GPU 数量为 0 的主机
        local gpu_a_count=${GPU_COUNT["${host_a}"]:-0}
        local gpu_b_count=${GPU_COUNT["${host_b}"]:-0}
        if [[ $gpu_a_count -eq 0 ]]; then
            log_warn "跳过 OM 测试: ${host_a} 无 GPU"
            continue
        fi
        if [[ $gpu_b_count -eq 0 ]]; then
            log_warn "跳过 OM 测试: ${host_b} 无 GPU"
            continue
        fi
        # 检查 GPU 索引是否在范围内
        if [[ $src_gpu -ge $gpu_a_count ]] || [[ $dst_gpu -ge $gpu_b_count ]]; then
            log_warn "跳过 OM 测试: GPU 索引超出范围 (${host_a}:${src_gpu}/${gpu_a_count}, ${host_b}:${dst_gpu}/${gpu_b_count})"
            continue
        fi

        test_cross_host_om "$host_a" "$host_b" "$src_gpu" "$dst_gpu"
        sleep 2
    done
    echo ""
}

# ============================================================================
# 生成综合报告
# ============================================================================
generate_report() {
    print_header "综合健康检测报告"

    {
        echo "============================================"
        echo " GPU 集群通信健康检测报告"
        echo " 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "============================================"
        echo ""
        echo "检测主机: ${HOSTS[*]}"
        echo ""

        # 汇总统计
        echo "── 测试统计 ──"
        echo "  总测试项:     ${TOTAL_TESTS}"
        echo "  ${GREEN}通过 (优秀):  ${PASS_TESTS}${NC}"
        echo "  ${YELLOW}警告 (偏低):  ${WARN_TESTS}${NC}"
        echo "  ${RED}失败 (异常):  ${FAIL_TESTS}${NC}"
        echo "  错误:         ${ERROR_TESTS}"

        local pass_rate=0
        if [[ $TOTAL_TESTS -gt 0 ]]; then
            pass_rate=$(awk "BEGIN {printf \"%.1f\", (${PASS_TESTS}+${WARN_TESTS})/${TOTAL_TESTS}*100}" 2>/dev/null || echo "N/A")
        fi
        echo "  可用率:       ${pass_rate}%"
        echo ""

        # 各主机GPU概览
        echo "── 主机 GPU 概览 ──"
        printf "  %-18s %-10s %s\n" "主机 IP" "GPU 数量" "GPU 型号"
        for host in "${HOSTS[@]}"; do
            local gpu_count=${GPU_COUNT["${host}"]}
            local model="${GPU_MODELS["${host}:0"]:-Unknown}"
            printf "  %-18s %-10s %s\n" "${host}" "${gpu_count:-?}" "${model}"
        done
        echo ""

        # P2P 结果汇总
        echo "── 单主机 P2P (MetaxLink) 结果 ──"
        for key in "${!P2P_RESULTS[@]}"; do
            local p2p_data="${P2P_RESULTS[$key]}"
            local p2p_bw=$(echo "$p2p_data" | cut -d'|' -f1)
            local p2p_topo=$(echo "$p2p_data" | cut -d'|' -f2)
            local p2p_valid=$(echo "$p2p_data" | cut -d'|' -f3)
            printf "  %-30s %-12s %-10s %s\n" "${key}" "${p2p_bw}" "${p2p_topo:-N/A}" "${p2p_valid:-N/A}"
        done
        echo ""

        # HBM 结果汇总
        echo "── GPU 显存 (HBM) 带宽 ──"
        for key in "${!HBM_RESULTS[@]}"; do
            printf "  %-30s %s\n" "${key}" "${HBM_RESULTS[$key]} GB/s"
        done
        echo ""

        # OM 结果汇总
        echo "── 跨主机 OM 网络通信 ──"
        for key in "${!OM_RESULTS[@]}"; do
            printf "  %-30s %s MB/s\n" "${key}" "${OM_RESULTS[$key]}"
        done
        echo ""

        # 异常项汇总
        echo "── 需关注的异常项 ──"
        local anomaly_count=0

        for key in "${!P2P_RESULTS[@]}"; do
            local p2p_data="${P2P_RESULTS[$key]}"
            local bw=$(echo "$p2p_data" | cut -d'|' -f1)
            local status
            status=$(evaluate_bw "$bw" "$P2P_BW_CRITICAL" "$P2P_BW_WARNING" "$P2P_BW_GOOD")
            if [[ "$status" == "WARN" ]] || [[ "$status" == "FAIL" ]]; then
                echo "  [${status}] P2P ${key}: ${bw} GB/s (参考: ${P2P_BW_GOOD} GB/s)"
                anomaly_count=$((anomaly_count + 1))
            fi
        done

        for key in "${!HBM_RESULTS[@]}"; do
            local bw="${HBM_RESULTS[$key]}"
            local status
            status=$(evaluate_bw "$bw" "$HBM_BW_CRITICAL" "$HBM_BW_WARNING" "$HBM_BW_GOOD")
            if [[ "$status" == "WARN" ]] || [[ "$status" == "FAIL" ]]; then
                echo "  [${status}] HBM ${key}: ${bw} GB/s (参考: ${HBM_BW_GOOD} GB/s)"
                anomaly_count=$((anomaly_count + 1))
            fi
        done

        for key in "${!OM_RESULTS[@]}"; do
            local bw="${OM_RESULTS[$key]}"
            local status
            status=$(evaluate_bw "$bw" "$OM_BW_CRITICAL" "$OM_BW_WARNING" "$OM_BW_GOOD")
            if [[ "$status" == "WARN" ]] || [[ "$status" == "FAIL" ]]; then
                echo "  [${status}] OM ${key}: ${bw} MB/s (参考: ${OM_BW_GOOD} MB/s)"
                anomaly_count=$((anomaly_count + 1))
            fi
        done

        # PCIe 状态
        for key in "${!PCIE_STATUS[@]}"; do
            local pcie_info="${PCIE_STATUS[$key]}"
            if [[ -n "$pcie_info" ]]; then
                local cur_speed
                cur_speed=$(echo "$pcie_info" | grep -oP '[\d.]+(?=\s*GT/s)' | head -1)
                if [[ -n "$cur_speed" ]] && awk "BEGIN {if (${cur_speed} < ${PCIE_SPEED_EXPECTED} * 0.8) exit 0; else exit 1}" 2>/dev/null; then
                    echo "  [WARN] PCIe ${key}: 当前 ${pcie_info}"
                    anomaly_count=$((anomaly_count + 1))
                fi
            fi
        done

        if [[ $anomaly_count -eq 0 ]]; then
            echo "  ${GREEN}无异常项，所有检测通过！${NC}"
        fi

        echo ""
        echo "── 详细日志 ──"
        echo "  P2P 日志:    ${LOG_DIR}/*_p2p.log"
        echo "  PCIe 日志:   ${LOG_DIR}/*_pcie.log"
        echo "  HBM 日志:    ${LOG_DIR}/*_hbm.log"
        echo "  OM 日志:     ${LOG_DIR}/om.log"
        echo "  完整日志:    ${RESULT_DIR}/full.log"
        echo ""
        echo "============================================"
    } | tee "${REPORT_FILE}"

    echo ""
    echo -e "${BOLD}报告已保存至: ${GREEN}${REPORT_FILE}${NC}"
    echo -e "${BOLD}详细日志目录: ${GREEN}${LOG_DIR}${NC}"
    echo ""
}

# ============================================================================
# 预检
# ============================================================================
preflight_check() {
    print_header "环境预检"

    # 检查必需工具
    local tools=("ssh" "bc" "awk" "grep")
    local missing_tools=()

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        else
            log_pass "${tool} 可用"
        fi
    done

    if command -v sshpass &>/dev/null && [[ -n "${SSH_PASS}" ]]; then
        log_pass "sshpass 可用 (SSH 密码认证, 密码经 GHC_SSH_PASS 注入)"
    else
        log_warn "未启用 SSH 密码认证 (sshpass 缺失或 SSH_PASS 为空)，请确保已配置 SSH 免密 key"
        log_warn "密码认证: 安装 sshpass 并设 GHC_SSH_PASS=<密码>；免密: 配好 .ssh/authorized_keys"
    fi

    if ! command -v bc &>/dev/null && ! command -v awk &>/dev/null; then
        log_error "bc 和 awk 至少需要一个用于数值计算"
        return 1
    fi

    # 检查 SSH 连通性
    echo ""
    log_info "检查主机 SSH 连通性..."
    local all_reachable=true

    for host in "${HOSTS[@]}"; do
        printf "  ${host} ... "
        if check_ssh "${host}"; then
            echo -e "${GREEN}联通${NC}"
        else
            echo -e "${RED}不通${NC}"
            all_reachable=false
        fi
    done

    if ! $all_reachable; then
        log_error "部分主机不可达，请检查网络和 SSH 配置"
        log_error "确保已配置 SSH 免密登录或安装 sshpass"
        return 1
    fi

    echo ""
    log_info "检查 mxvs 工具可用性..."
    for host in "${HOSTS[@]}"; do
        local mxvs_path=""
        # 方法1: 直接在 PATH 中查找
        mxvs_path=$(ssh_exec "${host}" "which mxvs 2>/dev/null" 2>/dev/null)
        if [[ -n "$mxvs_path" ]] && [[ "$mxvs_path" != *"NOT_FOUND"* ]] && [[ "$mxvs_path" != *"which:"* ]]; then
            MXVS_DIR["${host}"]=$(dirname "${mxvs_path}")
            log_pass "${host}: mxvs 可用 (${mxvs_path})"
            continue
        fi
        # 方法2: 在常见安装路径中搜索
        mxvs_path=$(ssh_exec "${host}" \
            "for d in /opt/maca/bin /usr/local/maca/bin /opt/meta/bin /usr/local/bin /opt/bin; do test -x \$d/mxvs && echo \$d/mxvs && break; done" 2>/dev/null)
        if [[ -n "$mxvs_path" ]]; then
            MXVS_DIR["${host}"]=$(dirname "${mxvs_path}")
            log_pass "${host}: mxvs 可用 (${mxvs_path})"
            continue
        fi
        # 方法3: 通过 find 搜索（较慢，作为最后手段）
        mxvs_path=$(ssh_exec "${host}" \
            "find /opt /usr/local -maxdepth 4 -name mxvs -type f 2>/dev/null | head -1" 2>/dev/null)
        if [[ -n "$mxvs_path" ]]; then
            MXVS_DIR["${host}"]=$(dirname "${mxvs_path}")
            log_pass "${host}: mxvs 可用 (${mxvs_path})"
            continue
        fi
        log_error "${host}: mxvs 未找到"
        all_reachable=false
    done

    if ! $all_reachable; then
        return 1
    fi

    return 0
}

# ============================================================================
# 主流程
# ============================================================================
main() {
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║       GPU 集群通信健康检测工具 v1.0                   ║"
    echo "  ║       MetaX C550 / MACA 3.7.2.0                      ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  检测主机: ${HOSTS[*]}"
    echo ""

    # 创建结果目录
    mkdir -p "${RESULT_DIR}" "${LOG_DIR}"

    # 预检
    if ! preflight_check; then
        log_error "预检失败，退出"
        exit 1
    fi

    # 发现所有主机的 GPU
    print_header "GPU 设备发现"
    for host in "${HOSTS[@]}"; do
        discover_gpus "${host}"
        local gpu_count=${GPU_COUNT["${host}"]}
        if [[ $gpu_count -eq 0 ]]; then
            log_error "主机 ${host} 未发现 GPU，将从检测中排除"
        else
            # 获取 GPU 型号
            local model
            model=$(get_gpu_model "${host}" 0)
            GPU_MODELS["${host}:0"]="$model"
            log_pass "${host}: ${gpu_count} 个 GPU (${model})"
        fi
    done

    # ============================================================
    # Phase 1: 单主机检测
    # ============================================================
    if ! $ONLY_OM; then
        print_header "Phase 1: 单主机 GPU 检测"

        for host in "${HOSTS[@]}"; do
            local gpu_count=${GPU_COUNT["${host}"]}
            if [[ $gpu_count -eq 0 ]]; then
                log_warn "跳过 ${host} (无 GPU)"
                continue
            fi

            # 1a. HBM 显存带宽 & PCIe 链路状态 (合并检测)
            if ! $SKIP_HBM; then
                test_hbm_bandwidth "${host}"
            fi

            # 1c. P2P 通信带宽
            if ! $SKIP_P2P; then
                test_intra_host_p2p "${host}"
            fi

            # 1d. 跨 CPU PCIe 通信
            if ! $SKIP_PCIE; then
                test_intra_host_pcie "${host}"
            else
                log_info "跳过跨 CPU PCIe 测试 (--skip-pcie)"
            fi
        done
    fi

    # ============================================================
    # Phase 2: 跨主机检测
    # ============================================================
    if ! $SKIP_OM; then
        print_header "Phase 2: 跨主机 GPU 通信检测"

        # 检查是否有足够的主机进行跨主机测试
        local viable_hosts=0
        for host in "${HOSTS[@]}"; do
            if [[ ${GPU_COUNT["${host}"]} -gt 0 ]]; then
                viable_hosts=$((viable_hosts + 1))
            fi
        done

        if [[ $viable_hosts -ge 2 ]]; then
            test_all_cross_host
        else
            log_warn "可用主机数量不足 (${viable_hosts})，跳过跨主机测试"
        fi
    else
        log_info "跳过跨主机 OM 测试 (--skip-om)"
    fi

    # ============================================================
    # 生成报告
    # ============================================================
    generate_report

    # 最终结果
    echo ""
    if [[ $FAIL_TESTS -eq 0 ]] && [[ $ERROR_TESTS -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${GREEN}  ✓ 所有检测通过！GPU 集群通信状态健康。${NC}"
        echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    else
        echo -e "${BOLD}${RED}════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${RED}  ✗ 存在 ${FAIL_TESTS} 项失败，${ERROR_TESTS} 项错误，请检查！${NC}"
        echo -e "${BOLD}${RED}════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "  详细报告: ${REPORT_FILE}"
    fi

    echo ""
    echo "  结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# ============================================================================
# 远程部署模式：当本地没有 mxvs 时自动部署到集群主机执行
# ============================================================================
SELF_DEPLOY=false          # 内部标记，防止无限递归
REMOTE_WORK_DIR="/tmp/gpu_health_$$"

# 检查本地是否具备 GPU 检测能力
is_gpu_host() {
    command -v mxvs &>/dev/null && return 0
    # 也检查是否有 GPU 设备
    ls /dev/mxgpu* &>/dev/null && return 0
    return 1
}

# 自动部署到远程主机执行
auto_deploy() {
    local deploy_host=""
    local pass_opt=""

    # 找第一个 SSH 可达的主机
    for host in "${HOSTS[@]}"; do
        if check_ssh "${host}"; then
            deploy_host="${host}"
            break
        fi
    done

    if [[ -z "$deploy_host" ]]; then
        echo -e "${RED}[ERROR]${NC} 所有主机 SSH 不可达，无法自动部署"
        echo ""
        echo "请手动将脚本拷贝到集群主机执行:"
        echo "  scp $0 root@<host>:/tmp/"
        echo "  ssh root@<host> 'bash /tmp/$(basename "$0")'"
        exit 1
    fi

    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  检测到当前环境非 GPU 主机，自动部署到 ${deploy_host}${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo ""

    # 拷贝脚本到远程主机
    log_info "拷贝脚本到 ${deploy_host} ..."
    if command -v sshpass &>/dev/null && [[ -n "${SSH_PASS}" ]]; then
        sshpass -p "${SSH_PASS}" scp ${SSH_OPTS} "$0" "${SSH_USER}@${deploy_host}:${REMOTE_WORK_DIR}/gpu_health_check.sh" 2>&1
    else
        scp ${SSH_OPTS} "$0" "${SSH_USER}@${deploy_host}:${REMOTE_WORK_DIR}/gpu_health_check.sh" 2>&1
    fi

    if [[ $? -ne 0 ]]; then
        log_error "脚本拷贝失败"
        exit 1
    fi
    log_pass "脚本已拷贝到 ${deploy_host}"

    # 远程执行（传递所有参数，并加上 --no-deploy 防止递归）
    log_info "在 ${deploy_host} 上启动检测..."
    echo ""

    local remote_cmd="cd ${REMOTE_WORK_DIR} && bash gpu_health_check.sh --no-deploy ${ORIGINAL_ARGS}"
    local remote_exit_code=0

    if command -v sshpass &>/dev/null && [[ -n "${SSH_PASS}" ]]; then
        sshpass -p "${SSH_PASS}" ssh -t ${SSH_OPTS} "${SSH_USER}@${deploy_host}" "${remote_cmd}"
        remote_exit_code=$?
    else
        ssh -t ${SSH_OPTS} "${SSH_USER}@${deploy_host}" "${remote_cmd}"
        remote_exit_code=$?
    fi

    echo ""
    log_info "远程执行完成 (退出码: ${remote_exit_code})"

    # 拉取结果到本地
    local local_result_dir="./gpu_health_results_remote"
    mkdir -p "${local_result_dir}"

    log_info "拉取检测结果到本地..."
    local latest_dir
    if command -v sshpass &>/dev/null && [[ -n "${SSH_PASS}" ]]; then
        latest_dir=$(sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${deploy_host}" \
            "ls -td ${REMOTE_WORK_DIR}/gpu_health_results_* 2>/dev/null | head -1")
        if [[ -n "$latest_dir" ]]; then
            sshpass -p "${SSH_PASS}" scp -r ${SSH_OPTS} "${SSH_USER}@${deploy_host}:${latest_dir}" "${local_result_dir}/" 2>/dev/null
        fi
    else
        latest_dir=$(ssh ${SSH_OPTS} "${SSH_USER}@${deploy_host}" \
            "ls -td ${REMOTE_WORK_DIR}/gpu_health_results_* 2>/dev/null | head -1")
        if [[ -n "$latest_dir" ]]; then
            scp -r ${SSH_OPTS} "${SSH_USER}@${deploy_host}:${latest_dir}" "${local_result_dir}/" 2>/dev/null
        fi
    fi

    if [[ -n "$latest_dir" ]] && [[ -d "${local_result_dir}" ]]; then
        local_result_dir="${local_result_dir}/$(basename "$latest_dir")"
        log_pass "结果已保存至: ${local_result_dir}"
        echo ""
        # 显示报告
        if [[ -f "${local_result_dir}/health_report.txt" ]]; then
            echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
            cat "${local_result_dir}/health_report.txt" 2>/dev/null | tail -30
        fi
    else
        log_warn "未能拉取远程结果（可能已保存在 ${deploy_host}:${REMOTE_WORK_DIR}）"
    fi

    # 清理远程临时文件
    log_info "清理远程临时文件..."
    ssh_exec "${deploy_host}" "rm -rf ${REMOTE_WORK_DIR}" 2>/dev/null

    exit $remote_exit_code
}

# ============================================================================
# 命令行参数处理
# ============================================================================
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "GPU 集群通信健康检测脚本"
    echo ""
    echo "选项:"
    echo "  -h, --help           显示此帮助信息"
    echo "  --hosts IP1,IP2,...  指定主机列表 (逗号分隔，覆盖默认配置)"
    echo "  --skip-om            跳过跨主机 OM 测试"
    echo "  --skip-p2p           跳过单主机 P2P 测试"
    echo "  --skip-pcie          跳过跨 CPU PCIe 通信带宽测试"
    echo "  --skip-hbm           跳过 HBM 显存带宽测试"
    echo "  --only-om            仅执行跨主机 OM 测试"
    echo "  --gpu-pairs PAIRS    指定跨主机 GPU 对 (格式: 'h:g,h:g h:g,h:g')"
    echo "  --star               星形检测: 8GPU测28路 各GPU之前全测试"
    echo "  --no-deploy          禁用自动部署 (已在远程主机上时内部使用)"
    echo ""
    echo "环境要求:"
    echo "  - SSH 免密登录（默认）；或设 GHC_SSH_PASS=<密码> 走 sshpass 密码认证"
    echo "  - 主机列表必须经 --hosts 或 GHC_HOSTS 注入（脚本默认不带主机）"
    echo "  - 各主机安装 mxvs 工具"
    echo "  - bc 或 awk (数值计算)"
    echo ""
    echo "示例:"
    echo "  $0 --hosts <IP1>,<IP2>                      # 完整检测 (自动部署)"
    echo "  GHC_HOSTS=<IP1>,<IP2> GHC_SSH_PASS=<密码> $0  # 环境变量注入"
    echo "  $0 --skip-om                                # 仅单主机检测"
    echo "  $0 --star                                   # 各GPU之前全测，默认只检测相邻GPU"
    echo ""
}

SKIP_OM=false
SKIP_P2P=false
SKIP_PCIE=false
SKIP_HBM=false
ONLY_OM=false
CUSTOM_HOSTS=""
NO_DEPLOY=false
RING_MODE=true
ORIGINAL_ARGS=""

# 保存原始参数
ORIGINAL_ARGS="$*"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --hosts)
            CUSTOM_HOSTS="$2"
            shift 2
            ;;
        --skip-om)
            SKIP_OM=true
            shift
            ;;
        --skip-p2p)
            SKIP_P2P=true
            shift
            ;;
        --skip-pcie)
            SKIP_PCIE=true
            shift
            ;;
        --skip-hbm)
            SKIP_HBM=true
            shift
            ;;
        --only-om)
            ONLY_OM=true
            shift
            ;;
        --gpu-pairs)
            IFS=' ' read -ra CROSS_HOST_GPU_PAIRS <<< "$2"
            shift 2
            ;;
        --no-deploy)
            NO_DEPLOY=true
            shift
            ;;
        --star)
            RING_MODE=false
            shift
            ;;
        *)
            echo "未知选项: $1"
            usage
            exit 1
            ;;
    esac
done

# 覆盖主机列表
if [[ -n "$CUSTOM_HOSTS" ]]; then
    IFS=',' read -ra HOSTS <<< "$CUSTOM_HOSTS"
fi

# HOSTS 为空 → 明确失败（入库版本默认不带主机；严禁回退到"零主机静默全过"）。
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "严重错误: 未指定检测主机。一句话用法："
    echo "  bash $0 --hosts <IP1>,<IP2>,..."
    echo "  或先设环境变量 GHC_HOSTS=<IP1>,<IP2>,... 再调用"
    exit 1
fi

# ============================================================
# 自动部署判断：本地无 GPU 环境则自动拷贝到远程主机执行
# ============================================================
if ! $NO_DEPLOY && ! is_gpu_host; then
    auto_deploy
    # auto_deploy 内部会 exit，不会执行到这里
fi

# 运行主流程
main

exit 0
