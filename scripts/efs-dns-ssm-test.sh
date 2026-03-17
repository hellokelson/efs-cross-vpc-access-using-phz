#!/bin/bash
set -euo pipefail

# ============================================================
# EFS DNS 解析批量测试脚本（通过 SSM 远程执行）
#
# 功能：通过 SSM 在多台 EC2 上运行 nslookup，收集结果并生成
#       Markdown 对比报告（含基线对比）
#
# 前提：EC2 实例已安装 SSM Agent 且处于 Online 状态
#
# 用法：bash efs-dns-ssm-test.sh [--region <REGION>] [--output-dir <DIR>] [--baseline <FILE>]
# ============================================================

# ---------- 默认值 ----------
REGION="us-east-1"
OUTPUT_DIR=""
BASELINE_FILE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- 参数解析 ----------
usage() {
    echo "用法: bash $0 [--region <REGION>] [--output-dir <DIR>] [--baseline <FILE>]"
    echo ""
    echo "参数:"
    echo "  --region       AWS Region（默认: us-east-1）"
    echo "  --output-dir   输出目录（默认: 脚本同级目录下 .claude-workspace/outputs/<date>）"
    echo "  --baseline     基线结果文件路径（用于对比，可选）"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --region)     REGION="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --baseline)   BASELINE_FILE="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "未知参数: $1"; usage ;;
    esac
done

if [ -z "${OUTPUT_DIR}" ]; then
    OUTPUT_DIR="${SCRIPT_DIR}/output/$(date '+%Y-%m-%d')"
fi

# ============================================================
# 配置区 — 根据实际环境修改
# ============================================================

# --- 实例列表: "名称|实例ID|VPC名|AZ" ---
# 请替换为您的 EC2 实例信息（需已安装 SSM Agent 且处于 Online 状态）
INSTANCES=(
    # === 示例（请删除并替换为您的实例） ===
    # "Consumer-VPC-1a|i-0123456789abcdef0|Consumer-VPC|us-east-1a"
    # "Consumer-VPC-1b|i-0abcdef1234567890|Consumer-VPC|us-east-1b"

    # ===== 请在此处添加您的实例 =====
    "PLACEHOLDER|i-REPLACE_ME|MyVPC|us-east-1a"
)

# --- DNS 查询列表: "EFS名称|DNS名称|查询类型" ---
# 请替换为您的 EFS 文件系统 ID 和 Region
# 格式: "友好名称|完整DNS名|查询类型"
DNS_QUERIES=(
    # === 示例（请删除并替换为您的 EFS） ===
    # 多 MT EFS 示例：
    # "My-Regional-EFS|fs-0123456789abcdef0.efs.us-east-1.amazonaws.com|General DNS"
    # "My-Regional-EFS|us-east-1a.fs-0123456789abcdef0.efs.us-east-1.amazonaws.com|AZ DNS (1a)"
    # "My-Regional-EFS|us-east-1b.fs-0123456789abcdef0.efs.us-east-1.amazonaws.com|AZ DNS (1b)"
    #
    # 单 MT EFS 示例：
    # "My-OneZone-EFS|fs-0abcdef1234567890.efs.us-east-1.amazonaws.com|General DNS"
    # "My-OneZone-EFS|us-east-1a.fs-0abcdef1234567890.efs.us-east-1.amazonaws.com|AZ DNS (1a)"

    # ===== 请在此处添加您的 EFS DNS 查询 =====
    "PLACEHOLDER|fs-REPLACE_ME.efs.${REGION}.amazonaws.com|General DNS"
)

# --- Mount Target IP → AZ 映射（用于判断是否跨 AZ） ---
# 格式: "IP|AZ"
# 请根据 `aws efs describe-mount-targets` 的结果填写
MT_IP_AZ_MAP=(
    # "10.0.1.17|us-east-1a"
    # "10.0.2.51|us-east-1b"

    # ===== 请在此处添加您的 MT IP 映射 =====
    "0.0.0.0|unknown"
)

ip_to_az() {
    local ip="$1"
    for entry in "${MT_IP_AZ_MAP[@]}"; do
        local map_ip="${entry%%|*}"
        local map_az="${entry#*|}"
        if [ "${ip}" = "${map_ip}" ]; then
            echo "${map_az}"
            return
        fi
    done
    echo "unknown"
}

# ============================================================
# 以下内容无需修改
# ============================================================

# 检查是否还是占位符
if echo "${INSTANCES[0]}" | grep -q "REPLACE_ME" || echo "${DNS_QUERIES[0]}" | grep -q "REPLACE_ME"; then
    echo "错误: 请先修改脚本【配置区】中的实例和 EFS 信息"
    echo "  1. 替换 INSTANCES 中的实例 ID、VPC 名和 AZ"
    echo "  2. 替换 DNS_QUERIES 中的 EFS 文件系统 ID"
    echo "  3. 替换 MT_IP_AZ_MAP 中的 Mount Target IP 和 AZ"
    echo ""
    echo "可通过以下命令查询您的信息:"
    echo "  aws ssm describe-instance-information --region ${REGION} --query 'InstanceInformationList[*].[InstanceId,ComputerName]' --output table"
    echo "  aws efs describe-file-systems --region ${REGION} --query 'FileSystems[*].[FileSystemId,Name]' --output table"
    echo "  aws efs describe-mount-targets --file-system-id <EFS-ID> --region ${REGION} --query 'MountTargets[*].[AvailabilityZoneName,IpAddress]' --output table"
    exit 1
fi

QUERY_COUNT=${#DNS_QUERIES[@]}

mkdir -p "${OUTPUT_DIR}"

echo "=========================================================="
echo "  EFS DNS 解析批量测试（SSM 远程执行）"
echo "=========================================================="
echo ""
echo "Region:    ${REGION}"
echo "实例数:    ${#INSTANCES[@]}"
echo "查询数/实例: ${QUERY_COUNT}"
echo "输出目录:  ${OUTPUT_DIR}"
echo ""

# --- 构建远程 nslookup 命令列表 ---
SSM_COMMANDS='["echo === INSTANCE INFO ===","TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H '"'"'X-aws-ec2-metadata-token-ttl-seconds: 60'"'"')","AZ=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/placement/availability-zone)","IP=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/local-ipv4)","echo \"AZ: $AZ | IP: $IP\"","echo \"\""'

for entry in "${DNS_QUERIES[@]}"; do
    IFS='|' read -r _ dns_name _ <<< "${entry}"
    SSM_COMMANDS="${SSM_COMMANDS}"',"echo \"--- nslookup '"${dns_name}"' ---\"","nslookup '"${dns_name}"' 2>&1 || true","echo \"\""'
done
SSM_COMMANDS="${SSM_COMMANDS}]"

# --- 第一步：发送 SSM 命令 ---
COMMAND_IDS=()
for entry in "${INSTANCES[@]}"; do
    IFS='|' read -r name iid _ _ <<< "${entry}"
    echo "发送 SSM → ${name} (${iid})..."

    CMD_ID=$(aws ssm send-command \
        --instance-ids "${iid}" \
        --document-name "AWS-RunShellScript" \
        --parameters "{\"commands\":${SSM_COMMANDS}}" \
        --region "${REGION}" \
        --query 'Command.CommandId' \
        --output text 2>&1) && {
        echo "  ✓ CommandId: ${CMD_ID}"
        COMMAND_IDS+=("${CMD_ID}")
    } || {
        echo "  ✗ 失败: ${CMD_ID}"
        COMMAND_IDS+=("FAILED")
    }
done

echo ""
echo "等待命令执行..."
sleep 5

# --- 第二步：收集原始输出 ---
for i in $(seq 0 $((${#INSTANCES[@]} - 1))); do
    IFS='|' read -r name iid _ _ <<< "${INSTANCES[$i]}"
    CMD_ID="${COMMAND_IDS[$i]}"

    if [ "${CMD_ID}" = "FAILED" ]; then
        echo "✗ 跳过 ${name}（发送失败）"
        continue
    fi

    for _ in 1 2 3 4 5; do
        STATUS=$(aws ssm get-command-invocation \
            --command-id "${CMD_ID}" \
            --instance-id "${iid}" \
            --region "${REGION}" \
            --query 'Status' \
            --output text 2>/dev/null) || STATUS="Pending"
        if [ "${STATUS}" = "Success" ] || [ "${STATUS}" = "Failed" ]; then
            break
        fi
        sleep 5
    done

    if [ "${STATUS}" != "Success" ]; then
        echo "✗ ${name}: 状态 ${STATUS}"
        continue
    fi

    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "${CMD_ID}" \
        --instance-id "${iid}" \
        --region "${REGION}" \
        --query 'StandardOutputContent' \
        --output text)

    RAW_FILE="${OUTPUT_DIR}/raw-nslookup-${name}.txt"
    echo "=== Instance: ${name} (${iid}) ===" > "${RAW_FILE}"
    echo "${OUTPUT}" >> "${RAW_FILE}"
    echo "✓ ${name}: 已保存 ${RAW_FILE}"
done

# --- 第三步：用 Python 解析结果并生成报告 ---
echo ""
echo "========== 生成汇总报告 =========="

REPORT="${OUTPUT_DIR}/efs-dns-test-results.md"

python3 << PYEOF
import re, os, json
from datetime import datetime

output_dir = "${OUTPUT_DIR}"
region = "${REGION}"

instances = []
$(for entry in "${INSTANCES[@]}"; do
    IFS='|' read -r name iid vpc az <<< "${entry}"
    echo "instances.append(('${name}', '${iid}', '${vpc}', '${az}'))"
done)

queries = []
$(for entry in "${DNS_QUERIES[@]}"; do
    IFS='|' read -r efs_name dns_name qtype <<< "${entry}"
    echo "queries.append(('${dns_name}', '${efs_name}', '${qtype}'))"
done)

ip_az_map = {}
# Build from MT_IP_AZ_MAP shell variable
$(for entry in "${MT_IP_AZ_MAP[@]}"; do
    IFS='|' read -r map_ip map_az <<< "${entry}"
    echo "ip_az_map['${map_ip}'] = '${map_az}'"
done)

def parse_nslookup(raw_text, query_dns):
    pattern = rf"--- nslookup {re.escape(query_dns)} ---\n(.*?)(?=\n--- nslookup |\Z)"
    m = re.search(pattern, raw_text, re.DOTALL)
    if not m: return None
    block = m.group(1)
    name_match = re.search(r"Name:\s+\S+\nAddress:\s+(\d+\.\d+\.\d+\.\d+)", block)
    return name_match.group(1) if name_match else None

lines = []
lines.append("# EFS DNS 解析批量测试结果")
lines.append("")
lines.append(f"> 测试时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
lines.append(f"> Region: {region}")
lines.append("")
lines.append("---")
lines.append("")
lines.append("## 测试结果")
lines.append("")

scores = []
for idx, (name, iid, vpc, az) in enumerate(instances):
    raw_file = os.path.join(output_dir, f"raw-nslookup-{name}.txt")
    if not os.path.exists(raw_file):
        lines.append(f"### {idx+1}. {name}（{vpc}，{az}）— 未获取到结果")
        lines.append("")
        scores.append(None)
        continue

    with open(raw_file) as f:
        raw = f.read()

    pass_count = 0
    rows = []
    for dns, efs_name, qtype in queries:
        ip = parse_nslookup(raw, dns)
        if ip:
            pass_count += 1
            r_az = ip_az_map.get(ip, "unknown")
            cross = "否(同AZ)" if r_az == az else "是(跨AZ)"
            rows.append(f"| {efs_name} | {qtype} | PASS | {ip} | {r_az} | {cross} |")
        else:
            rows.append(f"| {efs_name} | {qtype} | **FAIL** | - | - | - |")

    total = len(queries)
    scores.append(pass_count)
    lines.append(f"### {idx+1}. {name}（{vpc}，{az}）— {pass_count}/{total} PASS")
    lines.append("")
    lines.append("| EFS 名称 | 查询类型 | 结果 | 解析 IP | 解析到AZ | 是否跨AZ |")
    lines.append("|----------|---------|------|---------|---------|---------|")
    lines.extend(rows)
    lines.append("")

# 汇总
total = len(queries)
lines.append("---")
lines.append("")
lines.append("## 汇总")
lines.append("")
lines.append("| 实例 | VPC | AZ | 通过/总数 |")
lines.append("|------|-----|----|----------|")
for idx, (name, iid, vpc, az) in enumerate(instances):
    s = scores[idx]
    lines.append(f"| {name} | {vpc} | {az} | **{s}/{total}** |" if s is not None else f"| {name} | {vpc} | {az} | N/A |")

lines.append("")
lines.append("---")
lines.append(f"\n*生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*")

report_path = os.path.join(output_dir, "efs-dns-test-results.md")
with open(report_path, "w") as f:
    f.write("\n".join(lines))

# Print summary
print("")
for idx, (name, iid, vpc, az) in enumerate(instances):
    s = scores[idx]
    print(f"  {name} ({vpc}, {az}): {s}/{total} PASS" if s is not None else f"  {name}: N/A")
print(f"\n报告: {report_path}")
PYEOF

echo ""
echo "========== 完成 =========="
echo "原始数据: ${OUTPUT_DIR}/raw-nslookup-*.txt"
