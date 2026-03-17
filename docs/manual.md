# 跨 VPC 访问 EFS 操作手册 — Route 53 Private Hosted Zone (PHZ) 方案

> **适用场景**：VPC-B（消费者）中的 EC2/EKS 需要挂载 VPC-A（EFS 源）中的 EFS 文件系统。VPC-B 自身**没有** EFS Mount Target。
>
> **前提**：两个 VPC 通过 VPC Peering 互联（Transit Gateway 场景路由配置不同，但 PHZ 部分相同）。
>
> **Region**：本手册以 `us-east-1` 为例，适用于所有商业 Region。

---

## 0. 变量替换表

操作前请将以下占位符替换为您环境中的实际值：

| 占位符             | 含义                                       | 示例                      |
| ------------------ | ------------------------------------------ | ------------------------- |
| `<REGION>`       | AWS Region                                 | `us-east-1`             |
| `<VPC-A-ID>`     | EFS 所在 VPC（源 VPC）                     | `vpc-03bd24a1b42bff74b` |
| `<VPC-A-CIDR>`   | VPC-A 的 CIDR                              | `10.0.0.0/16`           |
| `<VPC-B-ID>`     | 消费者 VPC                                 | `vpc-07623cfc6ce8f1d32` |
| `<VPC-B-CIDR>`   | VPC-B 的 CIDR                              | `10.1.0.0/16`           |
| `<EFS-ID>`       | EFS 文件系统 ID                            | `fs-0b080eff7f87fcfb0`  |
| `<EFS-SG-ID>`    | EFS Mount Target 安全组 ID                 | `sg-03bd9cb3dc43f80c0`  |
| `<MT-AZ>`        | Mount Target 所在 AZ                       | `us-east-1a`            |
| `<MT-IP>`        | Mount Target 的私有 IP                     | `10.0.1.17`             |
| `<MT-SUBNET-ID>` | Mount Target 所在子网 ID                   | `subnet-0abc123def456`  |
| `<PEERING-ID>`   | VPC Peering Connection ID                  | `pcx-0da640fcd956c2f43` |
| `<PHZ-ID>`       | Private Hosted Zone ID（步骤五创建后获得） | `Z022263636MIQ488I6458` |
| `<VPC-A-RT-ID>`  | VPC-A 侧路由表 ID                          | `rtb-0abc123`           |
| `<VPC-B-RT-ID>`  | VPC-B 侧路由表 ID                          | `rtb-0def456`           |

---

## 1. 方案概述

### 1.1 问题

EFS 的 DNS 名（`fs-xxx.efs.<REGION>.amazonaws.com`）**仅在拥有 Mount Target 的 VPC 内部解析**。VPC Peering 的 `AllowDnsResolutionFromRemoteVpc` 选项仅对 EC2 私有 DNS 主机名（如 `ip-x-x-x.ec2.internal`）生效，不覆盖 EFS 的服务 DNS。

因此，VPC-B 中的实例无法通过 DNS 名直接挂载 VPC-A 的 EFS — `mount -t nfs4 fs-xxx.efs...:/ /mnt` 会因 DNS 解析失败而报错。

### 1.2 PHZ 方案原理

创建一个 Route 53 Private Hosted Zone（域名 `efs.<REGION>.amazonaws.com`），关联到 VPC-B，在其中手动添加 A 记录将 EFS DNS 名指向 Mount Target IP。VPC-B 的 DNS Resolver 会优先查询 PHZ，从而获得正确的 IP。

```
VPC-A (EFS 源, <VPC-A-CIDR>)                    VPC-B (消费者, <VPC-B-CIDR>)
┌──────────────────────────────┐                ┌──────────────────────────────┐
│                              │  VPC Peering   │                              │
│  EFS: <EFS-ID>               │◄──── active ──►│  EC2 / EKS Pod               │
│  Mount Target(s)             │                │  mount -t nfs4 ... :/ /mnt   │
│  ├─ <MT-AZ-1>: <MT-IP-1>    │                │                              │
│  └─ <MT-AZ-2>: <MT-IP-2>    │◄── NFS 2049 ──│                              │
│                              │                │  DNS Resolver (VPC CIDR+2)   │
│  ⚠ 不能关联 PHZ              │                │  ├─ 查询 PHZ → 命中 A 记录    │
│  (ConflictingDomainExists)   │                │  └─ 返回 Mount Target IP     │
│                              │                │                              │
└──────────────────────────────┘                │  Route 53 PHZ (已关联)        │
                                                │  efs.<REGION>.amazonaws.com   │
                                                │  ├─ <AZ>.fs-xxx.efs... → IP  │
                                                │  └─ (可选) fs-xxx.efs... → IP│
                                                └──────────────────────────────┘
```

### 1.3 两种场景

本手册覆盖两种常见场景，根据 EFS 的 Mount Target 数量选择：

| 场景                                   | 适用条件                                | PHZ 记录类型                                 | AZ 亲和                         | 步骤                                                      |
| -------------------------------------- | --------------------------------------- | -------------------------------------------- | ------------------------------- | --------------------------------------------------------- |
| **场景一：单 MT + Generic 记录** | EFS 仅有**1 个** Mount Target     | 1 条 generic A 记录 + 1 条 per-AZ A 记录     | 不适用（只有 1 个 IP）          | [步骤六（场景一）](#8-步骤六场景一单-mt-efs--generic-a-记录) |
| **场景二：多 MT + Per-AZ 记录**  | EFS 有**2 个或以上** Mount Target | 仅 per-AZ A 记录（**不创建 generic**） | 客户端显式指定 AZ，DNS 精确匹配 | [步骤六（场景二）](#9-步骤六场景二多-mt-efs--per-az-a-记录)  |

**为什么多 MT 场景不创建 generic 记录？**

- PHZ 的 A 记录是静态值，无法像原生 EFS DNS 一样根据查询者的 AZ 返回不同 IP
- Generic 记录固定指向某个 AZ 的 IP → 其他 AZ 的实例访问时产生跨 AZ 流量（$0.01/GB）
- Route 53 PHZ 不支持 AZ 级别的路由策略（Latency 策略仅 Region 级别），多值记录（Multivalue）会随机返回 IP，无法实现 AZ 亲和
- 使用 per-AZ 记录时，客户端通过 per-AZ DNS 名（`<AZ>.fs-xxx.efs...`）显式指定目标 AZ，确保访问同 AZ 的 Mount Target

> 📌 **单 MT 场景创建 generic 记录是安全的**：只有 1 个 IP，不存在跨 AZ 问题。同时创建 generic 记录可以让 `nslookup` 和 `mount -t nfs4 fs-xxx.efs...:/ /mnt` 等标准工具直接工作，便于调试。

---

## 2. 前置条件检查

开始操作前，请确认以下条件：

### 2.1 VPC-A 已有 EFS 和 Mount Target

```bash
# CLI: 查询 EFS 的 Mount Target
aws efs describe-mount-targets \
    --file-system-id <EFS-ID> \
    --region <REGION> \
    --query 'MountTargets[*].[MountTargetId,AvailabilityZoneName,SubnetId,IpAddress,LifeCycleState]' \
    --output table
```

> **Console**: EFS 控制台 → 文件系统 → 选择 `<EFS-ID>` → **网络** 标签 → 查看 Mount Target 列表

确认至少有 1 个 Mount Target 且状态为 `available`。记录每个 MT 的 AZ 和 IP 地址。

### 2.2 CIDR 不重叠

```bash
# CLI: 查询两个 VPC 的 CIDR
aws ec2 describe-vpcs \
    --vpc-ids <VPC-A-ID> <VPC-B-ID> \
    --region <REGION> \
    --query 'Vpcs[*].[VpcId,CidrBlock]' \
    --output table
```

> **Console**: VPC 控制台 → 您的 VPC → 确认两个 VPC 的 IPv4 CIDR 不重叠

VPC Peering 要求两端 CIDR 不重叠。如果有辅助 CIDR，也需确认无重叠。

### 2.3 DNS 设置

两个 VPC 都必须启用 DNS 支持和 DNS 主机名：

```bash
# CLI: 检查 DNS 设置
for VPC_ID in <VPC-A-ID> <VPC-B-ID>; do
    echo "=== $VPC_ID ==="
    aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport --region <REGION> \
        --query 'EnableDnsSupport.Value' --output text
    aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames --region <REGION> \
        --query 'EnableDnsHostnames.Value' --output text
done
# 两项都应输出 True
```

> **Console**: VPC 控制台 → 选择 VPC → **详细信息** 标签 → 确认 "DNS 解析" 和 "DNS 主机名" 均为 "已启用"

如未启用，修改 VPC 属性：

```bash
aws ec2 modify-vpc-attribute --vpc-id <VPC-ID> --enable-dns-support '{"Value":true}' --region <REGION>
aws ec2 modify-vpc-attribute --vpc-id <VPC-ID> --enable-dns-hostnames '{"Value":true}' --region <REGION>
```

### 2.4 IAM 权限要求

执行操作的 IAM 身份需要以下权限：

| 服务     | 权限                                                                                                                                                                                  | 用途                      |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| EC2      | `ec2:CreateVpcPeeringConnection`, `ec2:AcceptVpcPeeringConnection`, `ec2:CreateRoute`, `ec2:DescribeRouteTables`, `ec2:DescribeVpcs`, `ec2:AuthorizeSecurityGroupIngress` | VPC Peering、路由、安全组 |
| EFS      | `elasticfilesystem:DescribeMountTargets`, `elasticfilesystem:DescribeMountTargetSecurityGroups`                                                                                   | 查询 EFS 信息             |
| Route 53 | `route53:CreateHostedZone`, `route53:ChangeResourceRecordSets`, `route53:AssociateVPCWithHostedZone`, `route53:ListResourceRecordSets`                                        | PHZ 管理                  |

---

## 3. 步骤一：创建 VPC Peering

> 如果 VPC Peering 已存在且状态为 `active`，可跳过此步骤。

### 3.1 创建 Peering Connection

```bash
# CLI: 创建 VPC Peering
aws ec2 create-vpc-peering-connection \
    --vpc-id <VPC-A-ID> \
    --peer-vpc-id <VPC-B-ID> \
    --region <REGION> \
    --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
    --output text
# 记下返回的 pcx-xxx ID
```

> **Console**: VPC 控制台 → 对等连接 → **创建对等连接** → 请求方 VPC 选 `<VPC-A-ID>`，接受方选 `<VPC-B-ID>` → 创建

### 3.2 接受 Peering

```bash
# CLI: 接受 Peering（同账号同 Region 也需显式接受）
aws ec2 accept-vpc-peering-connection \
    --vpc-peering-connection-id <PEERING-ID> \
    --region <REGION>
```

> **Console**: VPC 控制台 → 对等连接 → 选择新建的 Peering → **操作** → **接受请求**

### 3.3 验证状态

```bash
# CLI: 确认状态为 active
aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids <PEERING-ID> \
    --region <REGION> \
    --query 'VpcPeeringConnections[0].Status' \
    --output json
# 期望输出：{ "Code": "active", "Message": "Active" }
```

> **Console**: 对等连接列表中确认状态列显示 **活跃**

---

## 4. 步骤二：配置双向路由

VPC Peering 建立后，还需在两端的路由表中添加路由，数据包才知道如何到达对方 VPC。

### 4.1 VPC-A 侧：所有 MT 子网路由表添加到 VPC-B 的路由

> ⚠️ **关键陷阱**：子网可能有**显式关联的路由表**，此时该子网**完全忽略主路由表**。如果只在主路由表中添加了 Peering 路由，但 Mount Target 所在子网使用的是另一个路由表，EFS 的回包将无法路由回 VPC-B，导致 `mount` 命令超时。
>
> **必须确认每个 Mount Target 子网实际使用的路由表，并逐一添加路由。**

#### 4.1.1 查询 MT 子网实际路由表

```bash
# CLI: 查询 EFS 所有 Mount Target 的子网
aws efs describe-mount-targets \
    --file-system-id <EFS-ID> \
    --region <REGION> \
    --query 'MountTargets[*].[MountTargetId,AvailabilityZoneName,SubnetId,IpAddress]' \
    --output table

# CLI: 查询某个子网显式关联的路由表
# 如返回 null → 该子网使用主路由表
# 如返回路由表 ID → 必须在该路由表中添加路由
aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=<MT-SUBNET-ID>" \
    --region <REGION> \
    --query 'RouteTables[0].RouteTableId' \
    --output text

# CLI: 查询 VPC-A 的主路由表（兜底，覆盖无显式关联的子网）
aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=<VPC-A-ID>" "Name=association.main,Values=true" \
    --region <REGION> \
    --query 'RouteTables[0].RouteTableId' \
    --output text
```

> **Console**: VPC 控制台 → 子网 → 选择 MT 所在子网 → **路由表** 标签 → 查看关联的路由表 ID

#### 4.1.2 添加路由

```bash
# CLI: 在 MT 子网的路由表中添加到 VPC-B 的路由
aws ec2 create-route \
    --route-table-id <VPC-A-RT-ID> \
    --destination-cidr-block <VPC-B-CIDR> \
    --vpc-peering-connection-id <PEERING-ID> \
    --region <REGION>

# 如果有多个路由表（不同子网使用不同路由表），逐一添加
# 主路由表也建议添加（兜底覆盖无显式关联的子网）
```

> **Console**: VPC 控制台 → 路由表 → 选择路由表 → **路由** 标签 → **编辑路由** → 添加路由 → 目标 `<VPC-B-CIDR>`，目标选择 Peering Connection `<PEERING-ID>` → 保存

### 4.2 VPC-B 侧：EC2 子网路由表添加到 VPC-A 的路由

> ⚠️ **不需要在所有路由表中都添加路由**，只需在 EC2/EKS 节点所在子网**实际使用的路由表**中添加。但多加路由不会有副作用，如果不确定未来哪些子网的实例会访问 EFS，全部添加也是安全的。

#### 4.2.1 理解路由表与子网的关系

- 子网**显式关联**了某个路由表（`Main=False`）→ **只用那个路由表**，完全忽略主路由表
- 子网**没有显式关联**任何路由表 → **自动使用主路由表**（`Main=True`）

#### 4.2.2 查询 VPC-B 的路由表

```bash
# CLI: 查询 VPC-B 的所有路由表及其子网关联
aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=<VPC-B-ID>" \
    --region <REGION> \
    --query 'RouteTables[*].[RouteTableId,Associations[0].SubnetId,Associations[0].Main]' \
    --output table

# 示例输出：
# +------------------------+----------------------------+--------+
# |  rtb-aaa111            |  subnet-111                |  False |  ← 显式绑了 subnet-111
# |  rtb-bbb222            |  subnet-222                |  False |  ← 显式绑了 subnet-222
# |  rtb-ccc333            |  None                      |  True  |  ← 主路由表（兜底）
# |  rtb-ddd444            |  subnet-444                |  False |  ← 显式绑了 subnet-444
# +------------------------+----------------------------+--------+
#
# 判断逻辑：
# - EC2/EKS 节点在 subnet-111 → 在 rtb-aaa111 中添加路由
# - EC2/EKS 节点在 subnet-222 → 在 rtb-bbb222 中添加路由
# - EC2/EKS 节点在某个不在列表中的子网 → 在主路由表 rtb-ccc333 中添加路由
```

> **Console**: VPC 控制台 → 子网 → 选择 EC2/EKS 节点所在子网 → **路由表** 标签 → 查看关联的路由表 ID

如果使用 EKS，可通过以下方式查询节点所在子网：

```bash
# CLI: 查询 EKS 节点的子网
aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=<CLUSTER-NAME>" \
    --region <REGION> \
    --query 'Reservations[*].Instances[*].[InstanceId,SubnetId,Placement.AvailabilityZone]' \
    --output table
```

#### 4.2.3 添加路由

```bash
# CLI: 在目标路由表中添加到 VPC-A 的路由
aws ec2 create-route \
    --route-table-id <VPC-B-RT-ID> \
    --destination-cidr-block <VPC-A-CIDR> \
    --vpc-peering-connection-id <PEERING-ID> \
    --region <REGION>

# 如果需要在多个路由表中添加，逐一执行（替换 <VPC-B-RT-ID>）
# 主路由表也建议添加（兜底覆盖无显式关联的子网）
```

> **Console**: 同 4.1.2，在 VPC-B 的路由表中添加 → 目标 `<VPC-A-CIDR>`，目标选择 Peering Connection `<PEERING-ID>`

### 4.3 验证路由

```bash
# CLI: 验证 VPC-A 侧路由（应包含到 VPC-B CIDR 的 Peering 路由）
aws ec2 describe-route-tables \
    --route-table-ids <VPC-A-RT-ID> \
    --region <REGION> \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`<VPC-B-CIDR>`]' \
    --output json

# CLI: 验证 VPC-B 侧路由（应包含到 VPC-A CIDR 的 Peering 路由）
aws ec2 describe-route-tables \
    --route-table-ids <VPC-B-RT-ID> \
    --region <REGION> \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`<VPC-A-CIDR>`]' \
    --output json
```

---

## 5. 步骤三：配置安全组

> ⚠️ **多 EFS 场景注意**：安全组绑定在 **Mount Target** 上，不是 EFS 文件系统上。不同 EFS 的 Mount Target 可能使用不同的安全组。必须确保**所有需要跨 VPC 访问的 EFS 的 Mount Target 安全组**都添加了入站规则，遗漏任何一个都会导致对应 EFS 的 `mount` 超时。

### 5.1 查询所有 EFS 的 Mount Target 安全组

> 现有安全组仅放行了 VPC-A 内部的 NFS 流量。要让 VPC-B 的实例访问 EFS，需要在相关安全组中**新增** VPC-B CIDR 的入站规则。此步骤用于获取需要修改的安全组 ID。

```bash
# CLI: 查询单个 EFS 的 Mount Target 安全组
MT_ID=$(aws efs describe-mount-targets \
    --file-system-id <EFS-ID> \
    --region <REGION> \
    --query 'MountTargets[0].MountTargetId' \
    --output text)

aws efs describe-mount-target-security-groups \
    --mount-target-id $MT_ID \
    --region <REGION>
# 记下 SecurityGroups 中的 SG ID，用于下一步添加入站规则
```

如果 VPC-A 有**多个 EFS** 需要跨 VPC 访问，使用以下脚本一次性查询所有 EFS 的安全组，确认哪些 SG 需要添加规则：

```bash
# CLI: 批量查询多个 EFS 的 Mount Target 安全组（去重汇总）
# 将 EFS_IDS 替换为实际的 EFS ID 列表
EFS_IDS="fs-aaa111 fs-bbb222 fs-ccc333"

echo "========== EFS Mount Target 安全组汇总 =========="
ALL_SGS=""
for EFS_ID in $EFS_IDS; do
    MT_IDS=$(aws efs describe-mount-targets \
        --file-system-id $EFS_ID --region <REGION> \
        --query 'MountTargets[*].MountTargetId' --output text)
    for MT_ID in $MT_IDS; do
        SGS=$(aws efs describe-mount-target-security-groups \
            --mount-target-id $MT_ID --region <REGION> \
            --query 'SecurityGroups[]' --output text)
        AZ=$(aws efs describe-mount-targets \
            --file-system-id $EFS_ID --region <REGION> \
            --query "MountTargets[?MountTargetId=='$MT_ID'].AvailabilityZoneName" --output text)
        echo "  $EFS_ID | $MT_ID ($AZ) | SG: $SGS"
        ALL_SGS="$ALL_SGS $SGS"
    done
done

echo ""
echo "========== 需要添加入站规则的安全组（去重） =========="
echo "$ALL_SGS" | tr ' ' '\n' | sort -u | grep -v '^$'
# 对输出的每个 SG ID 执行 5.2 的入站规则添加
```

> **Console**: EFS 控制台 → 逐个点击每个文件系统 → **网络** 标签 → 查看 Mount Target 的安全组列

### 5.2 添加入站规则

> ⚠️ **最小权限原则**：以下示例使用 VPC-B 的整个 CIDR 作为源，操作简单但授权范围较大。生产环境建议根据实际需求收窄源范围，参见下方对比表。

| 授权方式   | 源                         | 适用场景                                                            | 安全性 |
| ---------- | -------------------------- | ------------------------------------------------------------------- | ------ |
| VPC CIDR   | `--cidr <VPC-B-CIDR>`    | 快速验证、VPC-B 内所有实例都需要访问 EFS                            | 最宽松 |
| 子网 CIDR  | `--cidr <SUBNET-CIDR>`   | 仅特定子网（如 EKS 节点子网）需要访问                               | 较严格 |
| 安全组引用 | `--source-group <SG-ID>` | 仅特定安全组的实例需要访问（⚠️ 仅同 VPC 内可引用，跨 VPC 不支持） | 最严格 |

📌 **跨 VPC 场景不支持安全组引用**：VPC Peering 下无法在 VPC-A 的安全组中引用 VPC-B 的安全组 ID 作为源。因此跨 VPC 只能使用 CIDR 方式。建议至少收窄到 VPC-B 中**实际需要挂载 EFS 的子网 CIDR**。

```bash
# 方式一（简单）：允许 VPC-B 整个 CIDR 的 NFS 流量
# 对 5.1 汇总出的每个 SG ID 执行
aws ec2 authorize-security-group-ingress \
    --group-id <EFS-SG-ID> \
    --protocol tcp \
    --port 2049 \
    --cidr <VPC-B-CIDR> \
    --region <REGION>

# 方式二（推荐）：仅允许 VPC-B 中特定子网的 NFS 流量
# 查询 EKS 节点所在子网的 CIDR
aws ec2 describe-subnets \
    --subnet-ids <NODE-SUBNET-ID> \
    --region <REGION> \
    --query 'Subnets[0].CidrBlock' \
    --output text

aws ec2 authorize-security-group-ingress \
    --group-id <EFS-SG-ID> \
    --protocol tcp \
    --port 2049 \
    --cidr <NODE-SUBNET-CIDR> \
    --region <REGION>
# 如果有多个节点子网，逐个添加
```

> **Console**: EC2 控制台 → 安全组 → 选择 `<EFS-SG-ID>` → **入站规则** → **编辑入站规则** → 添加规则 → 类型 "NFS"，源填 CIDR → 保存

📌 **重复添加是安全的**：如果某个 SG 已经有相同的入站规则，`authorize-security-group-ingress` 会返回 `InvalidPermission.Duplicate` 错误但不会产生任何影响。

📌 如果 5.1 汇总结果显示所有 EFS 共用同一个 SG，只需添加一次入站规则即可。

### 5.3 （可选）添加 ICMP 规则

```bash
# CLI: 添加 ICMP（用于网络调试）
aws ec2 authorize-security-group-ingress \
    --group-id <EFS-SG-ID> \
    --protocol icmp \
    --port -1 \
    --cidr <VPC-B-CIDR> \
    --region <REGION>
```

> ⚠️ **注意**：EFS Mount Target **不响应 ICMP**。即使安全组已允许，ping 也会超时。这是 EFS 服务层的行为（类似 RDS），与安全组和路由无关。**Ping 不能作为 EFS 连通性测试手段。**

---

## 6. 步骤四：验证网络连通性（PHZ 之前）

在配置 PHZ 之前，先确认 VPC-B 到 VPC-A Mount Target 的网络是通的。从 VPC-B 的 EC2 实例执行：

```bash
# 测试 TCP 2049 端口连通性（替换 <MT-IP> 为实际 Mount Target IP）
timeout 5 bash -c "echo > /dev/tcp/<MT-IP>/2049" && echo "OK: TCP 2049 可达" || echo "FAIL: TCP 2049 不可达"
```

> 如需测试所有 Mount Target：

```bash
# 替换为实际 IP 列表
for IP in <MT-IP-1> <MT-IP-2> <MT-IP-3>; do
    timeout 5 bash -c "echo > /dev/tcp/$IP/2049" 2>/dev/null && echo "OK: $IP:2049" || echo "FAIL: $IP:2049"
done
```

**必须全部显示 OK 才能继续。** 如果 FAIL，请检查：

1. VPC-B EC2 子网的路由表是否有到 `<VPC-A-CIDR>` 的 Peering 路由
2. VPC-A MT 子网的路由表是否有到 `<VPC-B-CIDR>` 的 Peering 路由（注意显式路由表陷阱）
3. EFS 安全组是否允许 `<VPC-B-CIDR>` 的 TCP 2049 入站

---

## 7. 步骤五：创建 PHZ 并关联 VPC-B

### 7.1 创建 PHZ

```bash
# CLI: 创建 Private Hosted Zone，直接关联到 VPC-B
aws route53 create-hosted-zone \
    --name "efs.<REGION>.amazonaws.com" \
    --vpc VPCRegion=<REGION>,VPCId=<VPC-B-ID> \
    --caller-reference "efs-cross-vpc-$(date +%s)" \
    --hosted-zone-config Comment="EFS cross-VPC DNS for <VPC-B-ID>",PrivateZone=true \
    --region <REGION>
# 记下返回的 HostedZone.Id（格式如 /hostedzone/Z022263636MIQ488I6458）
# 后续步骤中使用纯 ID 部分，如 Z022263636MIQ488I6458
```

> **Console**: Route 53 控制台 → 托管区域 → **创建托管区域** → 域名填 `efs.<REGION>.amazonaws.com` → 类型选 **私有托管区域** → 关联的 VPC 选择 `<VPC-B-ID>` → 创建

### 7.2 关联额外的消费者 VPC（可选）

如果有多个消费者 VPC 需要访问同一 EFS：

```bash
# CLI: 将 PHZ 关联到额外的消费者 VPC
aws route53 associate-vpc-with-hosted-zone \
    --hosted-zone-id <PHZ-ID> \
    --vpc VPCRegion=<REGION>,VPCId=<其他消费者-VPC-ID> \
    --region <REGION>
```

> **Console**: Route 53 控制台 → 托管区域 → 选择 PHZ → **编辑托管区域** → 添加 VPC

### 7.3 关于 VPC-A 的关联限制

> ⚠️ **不能将此 PHZ 关联到 VPC-A**（EFS 源 VPC）。
>
> 原因：AWS 在 VPC 内创建第一个 Mount Target 时，会自动在后台关联一个 EFS 服务拥有的内部 PHZ（域名同为 `efs.<REGION>.amazonaws.com`，对用户不可见）。Route 53 禁止同一 VPC 关联两个同域名的 PHZ，因此会报错 `ConflictingDomainExists`。
>
> 这也意味着：**VPC-B 自身也不能有 EFS Mount Target**。如果 VPC-B 也有自己的 EFS，则无法关联此 PHZ，只能使用 IP 直接挂载方式。
>
> **VPC-A 不需要关联 PHZ** — VPC-A 有原生 EFS DNS，自身的 EFS 挂载正常工作。

### 7.4 验证 PHZ 状态

```bash
# CLI: 确认 PHZ 已创建且关联了 VPC-B
aws route53 get-hosted-zone \
    --id <PHZ-ID> \
    --region <REGION> \
    --query '{Name:HostedZone.Name,RecordCount:HostedZone.ResourceRecordSetCount,VPCs:VPCs}'
```

> **Console**: Route 53 控制台 → 托管区域 → 选择 PHZ → 确认 "关联的 VPC" 中包含 `<VPC-B-ID>`

---

## 8. 步骤六（场景一）：单 MT EFS — Generic A 记录

> **适用条件**：EFS 仅有 **1 个** Mount Target。
>
> 单 MT 时 generic 记录是安全的 — 只有一个 IP，不存在跨 AZ 问题。

### 8.1 查询 Mount Target IP

```bash
# CLI: 查询该 EFS 的 Mount Target
aws efs describe-mount-targets \
    --file-system-id <EFS-ID> \
    --region <REGION> \
    --query 'MountTargets[*].[AvailabilityZoneName,IpAddress,LifeCycleState]' \
    --output table

# 示例输出（仅 1 个 MT）：
# +-------------+------------+-----------+
# |  us-east-1a |  10.0.1.17 | available |
# +-------------+------------+-----------+
```

记下 `<MT-AZ>`（如 `us-east-1a`）和 `<MT-IP>`（如 `10.0.1.17`）。

### 8.2 创建 DNS 记录

创建 **2 条** A 记录：1 条 generic + 1 条 per-AZ。

```bash
# CLI: 添加 A 记录
aws route53 change-resource-record-sets \
    --hosted-zone-id <PHZ-ID> \
    --change-batch '{
        "Changes": [
            {
                "Action": "CREATE",
                "ResourceRecordSet": {
                    "Name": "<EFS-ID>.efs.<REGION>.amazonaws.com",
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": "<MT-IP>"}]
                }
            },
            {
                "Action": "CREATE",
                "ResourceRecordSet": {
                    "Name": "<MT-AZ>.<EFS-ID>.efs.<REGION>.amazonaws.com",
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": "<MT-IP>"}]
                }
            }
        ]
    }'
```

> **Console**: Route 53 控制台 → 托管区域 → 选择 PHZ → **创建记录** → 记录名填 `<EFS-ID>.efs.<REGION>.amazonaws.com`，类型 A，值 `<MT-IP>`，TTL 60 → 创建。重复创建 per-AZ 记录。

### 8.3 自动化脚本：一键创建所有 EFS 的 PHZ 记录（DEMO 示例）

手动逐个 EFS 添加 A 记录容易遗漏。本目录提供了自动化脚本 [`phz-auto-records.sh`](phz-auto-records.sh)，可一键扫描源 VPC 中所有 EFS 并自动创建 PHZ 记录。

**脚本功能**：

1. 扫描源 VPC 中所有 EFS 及其 Mount Target
2. 自动判断场景：单 MT → 创建 generic + per-AZ 记录；多 MT → 仅创建 per-AZ 记录
3. 已存在的记录自动跳过，支持 `--dry-run` 预览模式

> ⚠️ **关于 `--source-vpc` 参数**：必须指定 **EFS 所在的源 VPC（VPC-A）**，而非 PHZ 关联的消费者 VPC（VPC-B）。因为 PHZ 关联的 VPC-B 中没有 EFS Mount Target，VPC-A 又无法关联 PHZ（`ConflictingDomainExists`），所以脚本无法从 PHZ 关联关系自动推断出 EFS 所在的 VPC。

```bash
# 第一步：预览（不实际创建）
bash phz-auto-records.sh \
    --phz-id <PHZ-ID> \
    --source-vpc <VPC-A-ID> \
    --region <REGION> \
    --dry-run

# 第二步：确认无误后正式执行
bash phz-auto-records.sh \
    --phz-id <PHZ-ID> \
    --source-vpc <VPC-A-ID> \
    --region <REGION>
```

**脚本输出示例**：

```
--- 处理 EFS: fs-03521789fcc9f93b7 (A-Regional-EFS-1-MT) ---
  ⓘ Mount Target 数量: 1
  ⓘ   us-east-1a → 10.1.136.55
  ⓘ 场景一：单 MT → 创建 generic + per-AZ 记录
  ✓ 已创建: fs-03521789fcc9f93b7.efs.us-east-1.amazonaws.com → 10.1.136.55
  ✓ 已创建: us-east-1a.fs-03521789fcc9f93b7.efs.us-east-1.amazonaws.com → 10.1.136.55

--- 处理 EFS: fs-0828744b4f4ea703b (A-Regional-EFS-2-MT) ---
  ⓘ Mount Target 数量: 2
  ⓘ   us-east-1a → 10.1.129.247
  ⓘ   us-east-1b → 10.1.158.113
  ⓘ 场景二：多 MT → 仅创建 per-AZ 记录（不创建 generic）
  ✓ 已创建: us-east-1a.fs-0828744b4f4ea703b.efs.us-east-1.amazonaws.com → 10.1.129.247
  ✓ 已创建: us-east-1b.fs-0828744b4f4ea703b.efs.us-east-1.amazonaws.com → 10.1.158.113
```

📌 脚本使用 `UPSERT` 操作，重复执行不报错；如果 Mount Target IP 发生变化，重新执行会自动更新记录。

### 8.4 验证 DNS

从 VPC-B 的 EC2 实例执行：

```bash
# Generic DNS 应返回 MT IP
nslookup <EFS-ID>.efs.<REGION>.amazonaws.com
# 期望: Address: <MT-IP>

# Per-AZ DNS 也应返回 MT IP
nslookup <MT-AZ>.<EFS-ID>.efs.<REGION>.amazonaws.com
# 期望: Address: <MT-IP>
```

> 📌 **DNS 负缓存问题**：如果之前已尝试过 DNS 解析并失败（产生了 NXDOMAIN 负缓存），创建 PHZ 记录后可能需要等待最多 **15 分钟**（负缓存 TTL = 900 秒）才会生效。可用 `dig` 查看 TTL 倒计时。

### 8.5 挂载测试

```bash
sudo mkdir -p /mnt/efs

# 方式一：使用 generic DNS 名（推荐，与同 VPC 挂载体验一致）
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
    <EFS-ID>.efs.<REGION>.amazonaws.com:/ /mnt/efs

# 方式二：使用 Mount Target IP
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
    <MT-IP>:/ /mnt/efs
```

---

## 9. 步骤六（场景二）：多 MT EFS — Per-AZ A 记录

> 📌 **自动化替代**：[`phz-auto-records.sh`](phz-auto-records.sh) 同时支持场景一和场景二，会自动识别 MT 数量并创建正确的记录。如已使用该脚本，可跳过本节的手动步骤。

> **适用条件**：EFS 有 **2 个或以上** Mount Target（跨多个 AZ）。
>
> **不创建 generic 记录**，避免跨 AZ 流量。客户端通过 per-AZ DNS 名显式指定目标 AZ，确保访问同 AZ 的 Mount Target。

### 9.1 查询所有 Mount Target

```bash
# CLI: 查询该 EFS 的所有 Mount Target
aws efs describe-mount-targets \
    --file-system-id <EFS-ID> \
    --region <REGION> \
    --query 'MountTargets[*].[AvailabilityZoneName,IpAddress,LifeCycleState]' \
    --output table

# 示例输出（3 个 MT）：
# +-------------+------------+-----------+
# |  us-east-1a |  10.0.1.17 | available |
# |  us-east-1b |  10.0.2.51 | available |
# |  us-east-1c |  10.0.3.51 | available |
# +-------------+------------+-----------+
```

### 9.2 创建 Per-AZ DNS 记录

**仅**创建 per-AZ A 记录，每个 Mount Target 一条：

```bash
# CLI: 添加 per-AZ A 记录（根据实际 MT 数量调整 Changes 数组）
aws route53 change-resource-record-sets \
    --hosted-zone-id <PHZ-ID> \
    --change-batch '{
        "Changes": [
            {
                "Action": "CREATE",
                "ResourceRecordSet": {
                    "Name": "us-east-1a.<EFS-ID>.efs.<REGION>.amazonaws.com",
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": "10.0.1.17"}]
                }
            },
            {
                "Action": "CREATE",
                "ResourceRecordSet": {
                    "Name": "us-east-1b.<EFS-ID>.efs.<REGION>.amazonaws.com",
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": "10.0.2.51"}]
                }
            },
            {
                "Action": "CREATE",
                "ResourceRecordSet": {
                    "Name": "us-east-1c.<EFS-ID>.efs.<REGION>.amazonaws.com",
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": "10.0.3.51"}]
                }
            }
        ]
    }'
```

> **Console**: Route 53 控制台 → 托管区域 → 选择 PHZ → 为每个 AZ 创建一条 A 记录，记录名格式为 `<AZ>.<EFS-ID>.efs.<REGION>.amazonaws.com`

📌 根据实际 Mount Target 数量调整记录条数。每个 AZ 的 MT IP 对应一条 per-AZ 记录。

### 9.3 验证 DNS

从 VPC-B 的 EC2 实例执行：

```bash
# Generic DNS 应无结果（预期行为，未创建 generic 记录）
nslookup <EFS-ID>.efs.<REGION>.amazonaws.com
# 期望: ** server can't find ... NXDOMAIN 或 No answer

# Per-AZ DNS 应返回对应 AZ 的 MT IP
nslookup us-east-1a.<EFS-ID>.efs.<REGION>.amazonaws.com
# 期望: Address: 10.0.1.17

nslookup us-east-1b.<EFS-ID>.efs.<REGION>.amazonaws.com
# 期望: Address: 10.0.2.51

nslookup us-east-1c.<EFS-ID>.efs.<REGION>.amazonaws.com
# 期望: Address: 10.0.3.51
```

### 9.4 挂载测试

挂载时需使用 per-AZ DNS 名，将 `<AZ>` 替换为实例所在的 AZ：

```bash
sudo mkdir -p /mnt/efs

# 查询本机 AZ（在 EC2 上执行）
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
MY_AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
echo "本机 AZ: $MY_AZ"

# 使用 per-AZ DNS 名挂载（替换 <AZ> 为上面查到的 AZ）
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
    <AZ>.<EFS-ID>.efs.<REGION>.amazonaws.com:/ /mnt/efs

# 示例：本机在 us-east-1a
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
    us-east-1a.<EFS-ID>.efs.<REGION>.amazonaws.com:/ /mnt/efs
```

> 📌 **必须使用与本机相同 AZ 的 per-AZ DNS 名**。如果使用其他 AZ 的 DNS 名，虽然挂载可以成功，但会产生跨 AZ 数据传输费（$0.01/GB）。
>
> ⚠️ 如果该 EFS 在本机 AZ 没有 Mount Target，per-AZ DNS 将无结果，挂载会失败。此时需要先在 VPC-A 的该 AZ 中创建 Mount Target，然后在 PHZ 中添加对应的 per-AZ 记录。

---

## 10. 验证清单

完成所有步骤后，从 VPC-B 的 EC2 实例执行以下验证。

> 📌 **自动化测试脚本**：本目录提供了两个测试脚本，可替代以下手动验证步骤：
>
> | 脚本                                        | 运行位置              | 用途                                     |
> | ------------------------------------------- | --------------------- | ---------------------------------------- |
> | [`efs-dns-test.sh`](efs-dns-test.sh)         | 在 EC2 上直接执行     | 单实例 DNS 测试，输出格式化表格          |
> | [`efs-dns-ssm-test.sh`](efs-dns-ssm-test.sh) | 本地通过 SSM 远程执行 | 批量测试多台 EC2，生成 Markdown 对比报告 |
>
> ```bash
> # 方式一：SSH 到 EC2 后运行
> bash efs-dns-test.sh
>
> # 方式二：本地通过 SSM 批量测试（需修改脚本中的实例 ID 配置）
> bash efs-dns-ssm-test.sh --region us-east-1
> ```

### 10.1 DNS 验证

```bash
# 场景一（有 generic 记录）：应返回 MT IP
nslookup <EFS-ID>.efs.<REGION>.amazonaws.com

# 场景二（无 generic 记录）：应无结果（预期行为）
# nslookup <EFS-ID>.efs.<REGION>.amazonaws.com  → NXDOMAIN

# 两种场景都适用：per-AZ DNS 应返回对应 AZ 的 IP
nslookup <MT-AZ>.<EFS-ID>.efs.<REGION>.amazonaws.com
```

### 10.2 NFS 连通性验证

```bash
# TCP 2049 端口测试（使用 MT IP）
timeout 5 bash -c "echo > /dev/tcp/<MT-IP>/2049" && echo "OK" || echo "FAIL"
```

### 10.3 实际挂载验证

```bash
sudo mkdir -p /mnt/efs-test

# 场景一（有 generic 记录）：
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
    <EFS-ID>.efs.<REGION>.amazonaws.com:/ /mnt/efs-test

# 场景二（仅 per-AZ 记录）：替换 <AZ> 为本机 AZ
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
    <AZ>.<EFS-ID>.efs.<REGION>.amazonaws.com:/ /mnt/efs-test

# 确认挂载成功
df -h /mnt/efs-test
mount | grep nfs4
```

### 10.4 读写测试

```bash
# 写入
sudo sh -c 'echo "cross-vpc-test from VPC-B at $(date)" > /mnt/efs-test/cross-vpc-test.txt'

# 读取
cat /mnt/efs-test/cross-vpc-test.txt

# 清理
sudo umount /mnt/efs-test
```

---

## 11. 故障排查

| 现象                                     | 可能原因                                       | 排查方法                                                                                                                                                                                              |
| ---------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nslookup` 返回 NXDOMAIN               | PHZ 未创建记录 / PHZ 未关联 VPC-B / DNS 负缓存 | 确认 PHZ 记录存在（`aws route53 list-resource-record-sets --hosted-zone-id <PHZ-ID>`）；确认 VPC-B 已关联；等待 15 分钟负缓存过期                                                                   |
| PHZ 关联失败 `ConflictingDomainExists` | VPC-B 自身有 EFS Mount Target                  | 该 VPC 无法使用 PHZ 方案，改用 IP 直接挂载（方案 A）                                                                                                                                                  |
| `mount.nfs4: Connection timed out`     | 路由未配置                                     | 检查 VPC-B EC2 子网路由表是否有到 `<VPC-A-CIDR>` 的 Peering 路由                                                                                                                                    |
| `mount.nfs4: Connection timed out`     | MT 子网回程路由缺失                            | 检查 MT 子网**实际关联的路由表**（非主路由表）是否有到 `<VPC-B-CIDR>` 的 Peering 路由。用 `aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=<MT-SUBNET-ID>"` 查看 |
| `mount.nfs4: Connection timed out`     | 安全组未放行                                   | 检查 EFS SG 是否允许 `<VPC-B-CIDR>` 的 TCP 2049 入站                                                                                                                                                |
| `mount.nfs4: access denied`            | EFS 文件系统策略/POSIX 权限                    | 检查 EFS 的资源策略（`aws efs describe-file-system-policy`）和目录 POSIX 权限                                                                                                                       |
| Per-AZ DNS 无结果                        | 该 EFS 在查询的 AZ 没有 Mount Target           | 确认 EFS 在目标 AZ 有 MT（`aws efs describe-mount-targets --file-system-id <EFS-ID>`）；如无，需先在该 AZ 创建 MT 并添加 PHZ 记录                                                                   |
| VPC Peering 状态 `pending-acceptance`  | 未接受                                         | 执行 `aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id <PEERING-ID>`                                                                                                               |
| `ping <MT-IP>` 超时                    | EFS 不响应 ICMP                                | **正常行为** — EFS Mount Target 在服务层不响应 ICMP，即使安全组已允许。改用 `bash /dev/tcp/<MT-IP>/2049` 测试                                                                                |

---

## 12. 清理步骤（可选）

如需移除 PHZ 方案，按以下顺序操作：

### 12.1 删除 PHZ 记录

```bash
# CLI: 列出 PHZ 中的所有记录
aws route53 list-resource-record-sets \
    --hosted-zone-id <PHZ-ID> \
    --region <REGION>

# CLI: 删除 A 记录（将 CREATE 改为 DELETE，使用与创建时相同的记录内容）
aws route53 change-resource-record-sets \
    --hosted-zone-id <PHZ-ID> \
    --change-batch '{
        "Changes": [
            {
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": "<EFS-ID>.efs.<REGION>.amazonaws.com",
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": "<MT-IP>"}]
                }
            }
        ]
    }'
# 对每条 A 记录重复操作
```

> **Console**: Route 53 控制台 → 托管区域 → 选择 PHZ → 选中 A 记录 → **删除记录**

### 12.2 取消 VPC 关联并删除 PHZ

```bash
# CLI: 取消 VPC-B 关联（PHZ 至少需要关联 1 个 VPC，取消最后一个时会自动删除）
# 如果 PHZ 只关联了 1 个 VPC，直接删除 PHZ 即可
aws route53 delete-hosted-zone \
    --id <PHZ-ID> \
    --region <REGION>

# 如果关联了多个 VPC，先取消非最后一个的关联
aws route53 disassociate-vpc-from-hosted-zone \
    --hosted-zone-id <PHZ-ID> \
    --vpc VPCRegion=<REGION>,VPCId=<VPC-ID> \
    --region <REGION>
```

> **Console**: Route 53 控制台 → 托管区域 → 选择 PHZ → **删除托管区域**（需先删除所有非 NS/SOA 记录）

### 12.3 删除路由和 Peering（可选）

```bash
# CLI: 删除路由
aws ec2 delete-route \
    --route-table-id <VPC-A-RT-ID> \
    --destination-cidr-block <VPC-B-CIDR> \
    --region <REGION>

aws ec2 delete-route \
    --route-table-id <VPC-B-RT-ID> \
    --destination-cidr-block <VPC-A-CIDR> \
    --region <REGION>

# CLI: 删除 Peering
aws ec2 delete-vpc-peering-connection \
    --vpc-peering-connection-id <PEERING-ID> \
    --region <REGION>
```

### 12.4 删除安全组规则（可选）

```bash
# CLI: 撤销入站规则
aws ec2 revoke-security-group-ingress \
    --group-id <EFS-SG-ID> \
    --protocol tcp \
    --port 2049 \
    --cidr <VPC-B-CIDR> \
    --region <REGION>
```

---

*文档版本：v1.0 | 日期：2026-03-12*
