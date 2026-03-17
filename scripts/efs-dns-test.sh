#!/bin/bash
set -euo pipefail

# ============================================================
# EFS DNS 解析连通性测试脚本
#
# 在 EC2 上运行，自动获取实例元数据，测试各 EFS 的 DNS 解析情况。
# 用法: bash efs-dns-test.sh
#
# 使用前请修改下方【配置区】中的 EFS 信息。
# ============================================================

REGION="us-east-1"

# ============================================================
# 【配置区】 — 请根据您的环境修改
# ============================================================

# --- DNS 查询列表: "EFS名称|DNS名称|查询类型说明" ---
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

# ============================================================
# 以下内容无需修改
# ============================================================

# 检查是否还是占位符
if echo "${DNS_QUERIES[0]}" | grep -q "REPLACE_ME"; then
    echo "错误: 请先修改脚本【配置区】中的 EFS 信息"
    echo "  1. 替换 DNS_QUERIES 中的 EFS 文件系统 ID"
    echo "  2. 替换 MT_IP_AZ_MAP 中的 Mount Target IP 和 AZ"
    echo ""
    echo "可通过以下命令查询您的 EFS 信息:"
    echo "  aws efs describe-file-systems --region ${REGION} --query 'FileSystems[*].[FileSystemId,Name]' --output table"
    echo "  aws efs describe-mount-targets --file-system-id <EFS-ID> --region ${REGION} --query 'MountTargets[*].[AvailabilityZoneName,IpAddress]' --output table"
    exit 1
fi

# 构建 IP→AZ 查找函数
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
# 获取当前 EC2 实例信息
# ============================================================
echo "=========================================="
echo " EFS DNS 解析连通性测试"
echo "=========================================="

# 通过 IMDS v2 获取实例元数据
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true

if [[ -n "${TOKEN}" ]]; then
    INSTANCE_AZ=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null) || INSTANCE_AZ="unknown"
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
        http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null) || INSTANCE_ID="unknown"
    LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
        http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null) || LOCAL_IP="unknown"
    MAC=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
        http://169.254.169.254/latest/meta-data/network/interfaces/macs/ 2>/dev/null | head -1 | tr -d '/')
    INSTANCE_VPC=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
        "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/vpc-id" 2>/dev/null) || INSTANCE_VPC="unknown"
else
    INSTANCE_AZ="unknown"
    INSTANCE_ID="unknown"
    LOCAL_IP="unknown"
    INSTANCE_VPC="unknown"
fi

echo ""
echo "实例信息:"
echo "  Instance ID : ${INSTANCE_ID}"
echo "  VPC         : ${INSTANCE_VPC}"
echo "  AZ          : ${INSTANCE_AZ}"
echo "  Private IP  : ${LOCAL_IP}"
echo ""

# ============================================================
# 执行 DNS 解析测试
# ============================================================

# 表头
SEP="+-----------------------+------------------+------------------------------------------------------------------+---------+---------------+------------+-----------+"
printf "%s\n" "${SEP}"
printf "| %-21s | %-16s | %-64s | %-7s | %-13s | %-10s | %-9s |\n" \
    "EFS 名称" "查询类型" "DNS 名称" "结果" "解析 IP" "解析到AZ" "是否跨AZ"
printf "%s\n" "${SEP}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

for entry in "${DNS_QUERIES[@]}"; do
    IFS='|' read -r efs_name dns_name query_type <<< "${entry}"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    # 执行 nslookup
    nslookup_output=$(timeout 3 nslookup "${dns_name}" 2>&1) || true
    resolved_ip=$(echo "${nslookup_output}" | awk '/^Name:/{found=1} found && /^Address:/{print $2}' | tail -1)

    if [[ -z "${resolved_ip}" ]]; then
        resolved_ip=$(echo "${nslookup_output}" | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | tail -1 || true)
    fi

    if [[ -n "${resolved_ip}" ]]; then
        result="PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
        resolved_az=$(ip_to_az "${resolved_ip}")
        if [[ "${resolved_az}" == "${INSTANCE_AZ}" ]]; then
            cross_az="否(同AZ)"
        elif [[ "${resolved_az}" == "unknown" ]]; then
            cross_az="未知"
        else
            cross_az="是(跨AZ)"
        fi
    else
        result="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        resolved_ip="-"
        resolved_az="-"
        cross_az="-"
    fi

    printf "| %-21s | %-16s | %-64s | %-7s | %-13s | %-10s | %-9s |\n" \
        "${efs_name}" "${query_type}" "${dns_name}" "${result}" "${resolved_ip}" "${resolved_az}" "${cross_az}"
done

printf "%s\n" "${SEP}"

# ============================================================
# 汇总
# ============================================================
echo ""
echo "=========================================="
echo " 汇总"
echo "=========================================="
echo "  总查询数 : ${TOTAL_COUNT}"
echo "  成功     : ${PASS_COUNT}"
echo "  失败     : ${FAIL_COUNT}"
echo "=========================================="
