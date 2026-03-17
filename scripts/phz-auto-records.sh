#!/bin/bash
set -euo pipefail

# ============================================================
# PHZ 自动创建 EFS DNS 记录脚本
#
# 功能：扫描源 VPC 中的所有 EFS，根据 Mount Target 数量自动创建
#       PHZ A 记录（单 MT = generic + per-AZ；多 MT = 仅 per-AZ）
#
# 用法：bash phz-auto-records.sh --phz-id <PHZ_ID> --source-vpc <VPC_ID> [--region <REGION>] [--dry-run]
# ============================================================

# ---------- 默认值 ----------
PHZ_ID=""
SOURCE_VPC_ID=""
REGION="us-east-1"
DRY_RUN=false
TTL=60

# ---------- 参数解析 ----------
usage() {
    echo "用法: bash $0 --phz-id <PHZ_ID> --source-vpc <VPC_ID> [--region <REGION>] [--dry-run]"
    echo ""
    echo "参数:"
    echo "  --phz-id       PHZ Hosted Zone ID（必填）"
    echo "  --source-vpc   EFS 所在的源 VPC ID（必填）"
    echo "  --region       AWS Region（默认: us-east-1）"
    echo "  --dry-run      仅预览，不实际创建记录"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --phz-id)     PHZ_ID="$2"; shift 2 ;;
        --source-vpc) SOURCE_VPC_ID="$2"; shift 2 ;;
        --region)     REGION="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        *)            echo "未知参数: $1"; usage ;;
    esac
done

if [ -z "${PHZ_ID}" ] || [ -z "${SOURCE_VPC_ID}" ]; then
    echo "错误: --phz-id 和 --source-vpc 为必填参数"
    echo ""
    usage
fi

# ---------- 辅助函数 ----------
log_info()  { echo "  ⓘ $*"; }
log_ok()    { echo "  ✓ $*"; }
log_skip()  { echo "  ⏭ $*"; }
log_fail()  { echo "  ✗ $*"; }
log_warn()  { echo "  ⚠ $*"; }
log_title() { echo ""; echo "--- $* ---"; }

# ---------- 预检查 ----------
echo "=========================================================="
echo "  PHZ 自动创建 EFS DNS 记录"
echo "=========================================================="
echo ""
echo "PHZ ID:     ${PHZ_ID}"
echo "源 VPC:     ${SOURCE_VPC_ID}"
echo "Region:     ${REGION}"
echo "模式:       $(${DRY_RUN} && echo 'DRY-RUN（仅预览）' || echo '正式执行')"
echo ""

# 验证 PHZ 存在
log_title "验证 PHZ"
PHZ_NAME=$(aws route53 get-hosted-zone \
    --id "${PHZ_ID}" \
    --query 'HostedZone.Name' \
    --output text 2>&1) || {
    log_fail "PHZ ${PHZ_ID} 不存在或无权限访问: ${PHZ_NAME}"
    exit 1
}
log_ok "PHZ 域名: ${PHZ_NAME}"

# 获取 PHZ 关联的 VPC 列表
PHZ_VPCS=$(aws route53 get-hosted-zone \
    --id "${PHZ_ID}" \
    --query 'VPCs[*].VPCId' \
    --output text)
log_info "PHZ 已关联的 VPC: ${PHZ_VPCS}"

# 检查源 VPC 是否在 PHZ 关联列表中（如果在，说明参数可能传错了）
if echo "${PHZ_VPCS}" | grep -qw "${SOURCE_VPC_ID}"; then
    log_warn "源 VPC ${SOURCE_VPC_ID} 已关联到此 PHZ"
    log_warn "通常 PHZ 关联的是消费者 VPC（VPC-B），而源 VPC（VPC-A）不应关联"
    log_warn "请确认 --source-vpc 是否为 EFS 所在的 VPC"
    echo ""
    read -p "是否继续？(y/N) " CONFIRM
    if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
        echo "已取消"
        exit 0
    fi
fi

# 获取已有的 PHZ 记录（用于判断是否跳过）
log_title "获取 PHZ 现有记录"
# 每条记录一行，方便精确匹配
EXISTING_RECORDS=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${PHZ_ID}" \
    --query 'ResourceRecordSets[?Type==`A`].Name' \
    --output text | tr '\t' '\n')
EXISTING_COUNT=$(echo "${EXISTING_RECORDS}" | grep -c '.' || echo 0)
log_info "现有 A 记录数量: ${EXISTING_COUNT}"
if [ "${EXISTING_COUNT}" -gt 0 ]; then
    for REC in ${EXISTING_RECORDS}; do
        log_info "  已有: ${REC}"
    done
fi

# ---------- 扫描源 VPC 中的 EFS ----------
log_title "扫描源 VPC (${SOURCE_VPC_ID}) 中的 EFS"

# 获取源 VPC 的所有子网
VPC_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${SOURCE_VPC_ID}" \
    --region "${REGION}" \
    --query 'Subnets[*].SubnetId' \
    --output text)

# 列出 region 内所有 EFS，然后过滤出在源 VPC 中有 Mount Target 的
ALL_EFS=$(aws efs describe-file-systems \
    --region "${REGION}" \
    --query 'FileSystems[*].[FileSystemId,Name,NumberOfMountTargets]' \
    --output json)

EFS_COUNT=$(echo "${ALL_EFS}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
log_info "Region 中共有 ${EFS_COUNT} 个 EFS，正在过滤源 VPC 的..."

# 找出在源 VPC 中有 Mount Target 的 EFS
VPC_EFS_IDS=()
VPC_EFS_NAMES=()

for idx in $(seq 0 $((EFS_COUNT - 1))); do
    FS_ID=$(echo "${ALL_EFS}" | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx][0])")
    FS_NAME=$(echo "${ALL_EFS}" | python3 -c "import sys,json; v=json.load(sys.stdin)[$idx][1]; print(v if v else '(unnamed)')")

    # 查询该 EFS 的 Mount Target，检查是否有在源 VPC 子网中的
    MT_JSON=$(aws efs describe-mount-targets \
        --file-system-id "${FS_ID}" \
        --region "${REGION}" \
        --query 'MountTargets[*].[SubnetId,AvailabilityZoneName,IpAddress,LifeCycleState]' \
        --output json 2>/dev/null) || continue

    # 检查是否有 MT 的子网在源 VPC 中
    IN_VPC=$(echo "${MT_JSON}" | python3 -c "
import sys, json
mts = json.load(sys.stdin)
vpc_subnets = '${VPC_SUBNETS}'.split()
found = [m for m in mts if m[0] in vpc_subnets]
print(len(found))
")

    if [ "${IN_VPC}" -gt 0 ]; then
        VPC_EFS_IDS+=("${FS_ID}")
        VPC_EFS_NAMES+=("${FS_NAME}")
    fi
done

if [ ${#VPC_EFS_IDS[@]} -eq 0 ]; then
    log_warn "源 VPC ${SOURCE_VPC_ID} 中未找到任何 EFS Mount Target"
    exit 0
fi

log_ok "找到 ${#VPC_EFS_IDS[@]} 个 EFS:"
for k in $(seq 0 $((${#VPC_EFS_IDS[@]} - 1))); do
    log_info "  ${VPC_EFS_IDS[$k]} (${VPC_EFS_NAMES[$k]})"
done

# ---------- 逐个 EFS 创建记录 ----------
TOTAL_CREATED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

for k in $(seq 0 $((${#VPC_EFS_IDS[@]} - 1))); do
    FS_ID="${VPC_EFS_IDS[$k]}"
    FS_NAME="${VPC_EFS_NAMES[$k]}"

    log_title "处理 EFS: ${FS_ID} (${FS_NAME})"

    # 查询该 EFS 在源 VPC 中的 Mount Target
    MT_JSON=$(aws efs describe-mount-targets \
        --file-system-id "${FS_ID}" \
        --region "${REGION}" \
        --query 'MountTargets[*].[AvailabilityZoneName,IpAddress,LifeCycleState,SubnetId]' \
        --output json)

    # 过滤出源 VPC 中的、状态为 available 的 MT
    MT_LIST=$(echo "${MT_JSON}" | python3 -c "
import sys, json
mts = json.load(sys.stdin)
vpc_subnets = '${VPC_SUBNETS}'.split()
available = [m for m in mts if m[0] and m[2] == 'available' and m[3] in vpc_subnets]
for m in available:
    print(f'{m[0]} {m[1]}')
")

    MT_COUNT=$(echo "${MT_LIST}" | grep -c '.' || echo 0)

    if [ "${MT_COUNT}" -eq 0 ]; then
        log_fail "无 available 状态的 Mount Target，跳过"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi

    log_info "Mount Target 数量: ${MT_COUNT}"
    echo "${MT_LIST}" | while read -r AZ IP; do
        log_info "  ${AZ} → ${IP}"
    done

    # 确定场景
    if [ "${MT_COUNT}" -eq 1 ]; then
        log_info "场景一：单 MT → 创建 generic + per-AZ 记录"
    else
        log_info "场景二：多 MT → 仅创建 per-AZ 记录（不创建 generic）"
    fi

    # 构建 Changes 数组
    CHANGES=""
    RECORDS_TO_CREATE=()

    # 场景一：单 MT，额外创建 generic 记录
    if [ "${MT_COUNT}" -eq 1 ]; then
        SINGLE_IP=$(echo "${MT_LIST}" | awk '{print $2}')
        GENERIC_NAME="${FS_ID}.efs.${REGION}.amazonaws.com"

        # 检查是否已存在（精确行匹配，Route 53 返回的记录名末尾有 "."）
        if echo "${EXISTING_RECORDS}" | grep -qxF "${GENERIC_NAME}."; then
            log_skip "已存在: ${GENERIC_NAME} → 跳过"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        else
            log_info "将创建: ${GENERIC_NAME} → ${SINGLE_IP}"
            CHANGES="${CHANGES}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${GENERIC_NAME}\",\"Type\":\"A\",\"TTL\":${TTL},\"ResourceRecords\":[{\"Value\":\"${SINGLE_IP}\"}]}},"
            RECORDS_TO_CREATE+=("${GENERIC_NAME} → ${SINGLE_IP}")
        fi
    fi

    # 所有场景：创建 per-AZ 记录
    while read -r AZ IP; do
        [ -z "${AZ}" ] && continue
        PERAZ_NAME="${AZ}.${FS_ID}.efs.${REGION}.amazonaws.com"

        if echo "${EXISTING_RECORDS}" | grep -qxF "${PERAZ_NAME}."; then
            log_skip "已存在: ${PERAZ_NAME} → 跳过"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        else
            log_info "将创建: ${PERAZ_NAME} → ${IP}"
            CHANGES="${CHANGES}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${PERAZ_NAME}\",\"Type\":\"A\",\"TTL\":${TTL},\"ResourceRecords\":[{\"Value\":\"${IP}\"}]}},"
            RECORDS_TO_CREATE+=("${PERAZ_NAME} → ${IP}")
        fi
    done <<< "${MT_LIST}"

    # 提交记录
    if [ -z "${CHANGES}" ]; then
        log_info "所有记录已存在，无需操作"
        continue
    fi

    # 去掉末尾逗号
    CHANGES="${CHANGES%,}"
    CHANGE_BATCH="{\"Changes\":[${CHANGES}]}"

    if ${DRY_RUN}; then
        log_info "[DRY-RUN] 将创建 ${#RECORDS_TO_CREATE[@]} 条记录（未实际执行）"
    else
        RESULT=$(aws route53 change-resource-record-sets \
            --hosted-zone-id "${PHZ_ID}" \
            --change-batch "${CHANGE_BATCH}" \
            --query 'ChangeInfo.Status' \
            --output text 2>&1) && {
            for REC in "${RECORDS_TO_CREATE[@]}"; do
                log_ok "已创建: ${REC}"
            done
            TOTAL_CREATED=$((TOTAL_CREATED + ${#RECORDS_TO_CREATE[@]}))
        } || {
            log_fail "Route 53 API 失败: ${RESULT}"
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
        }
    fi
done

# ---------- 汇总 ----------
echo ""
echo "=========================================================="
echo "  执行完成"
echo "=========================================================="
echo ""
echo "  EFS 数量:    ${#VPC_EFS_IDS[@]}"
echo "  ✓ 新建记录:  ${TOTAL_CREATED}"
echo "  ⏭ 已存在跳过: ${TOTAL_SKIPPED}"
echo "  ✗ 失败:      ${TOTAL_FAILED}"
if ${DRY_RUN}; then
    echo ""
    echo "  ⓘ 以上为 DRY-RUN 预览，未实际创建记录"
    echo "  ⓘ 去掉 --dry-run 参数重新执行以正式创建"
fi
echo ""

# 显示 PHZ 当前所有 A 记录
if ! ${DRY_RUN} && [ "${TOTAL_CREATED}" -gt 0 ]; then
    echo "--- PHZ 当前所有 A 记录 ---"
    aws route53 list-resource-record-sets \
        --hosted-zone-id "${PHZ_ID}" \
        --query 'ResourceRecordSets[?Type==`A`].[Name,ResourceRecords[0].Value]' \
        --output table
fi
