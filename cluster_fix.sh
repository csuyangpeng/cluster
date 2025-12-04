#!/bin/bash
# auto_fix_redis_cluster_remote.sh
# 从控制节点远程修复其他Redis节点

set -e  # 遇到错误退出

PASSWORD='A8K5h7+6!?'
CONTROL_NODE="10.18.30.12"  # 控制节点IP
CONTROL_PORT=6379

# 所有Redis节点列表
REDIS_NODES=(
    "10.18.30.11:6379"
    "10.18.30.11:6380"
    "10.18.30.12:6379"
    "10.18.30.12:6380"
    "10.18.30.13:6379"
    "10.18.30.13:6380"
)

echo "=== Redis集群远程修复脚本 ==="
echo "控制节点: $CONTROL_NODE:$CONTROL_PORT"
echo "时间: $(date)"
echo ""

# 函数：执行Redis命令（带重试）
redis_cmd() {
    local host=$1
    local port=$2
    local cmd=$3
    local retries=3
    local timeout=5
    
    for i in $(seq 1 $retries); do
        if timeout $timeout redis-cli -c -h $host -p $port -a "$PASSWORD" $cmd 2>/dev/null; then
            return 0
        fi
        echo "  重试 $i/$retries..."
        sleep 1
    done
    echo "错误: 无法连接 $host:$port"
    return 1
}

# 函数：检查节点连通性
check_node_connectivity() {
    local host=$1
    local port=$2
    
    if ping -c 1 -W 1 $host >/dev/null 2>&1; then
        if redis_cmd $host $port "ping" >/dev/null; then
            echo "✅ $host:$port 可达"
            return 0
        else
            echo "❌ $host:$port Redis不可用"
            return 1
        fi
    else
        echo "❌ $host:$port 主机不可达"
        return 2
    fi
}

# 函数：获取完整的集群视图
get_cluster_view() {
    echo "获取集群完整视图..."
    redis_cmd $CONTROL_NODE $CONTROL_PORT "cluster nodes" > /tmp/cluster_nodes.txt
    cat /tmp/cluster_nodes.txt
    echo ""
}

# 函数：分析集群问题
analyze_cluster_issues() {
    echo "=== 集群问题分析 ==="
    
    # 1. 统计主从关系
    echo "1. 主从关系统计:"
    grep -E "(master|slave)" /tmp/cluster_nodes.txt | awk '{print $3}' | sort | uniq -c
    
    # 2. 检查每个物理节点的主节点数量
    echo -e "\n2. 物理节点主节点分布:"
    grep "master" /tmp/cluster_nodes.txt | grep -v "fail" | awk '{print $2}' | cut -d':' -f1 | sort | uniq -c | while read count ip; do
        echo "  $ip: $count 个主节点"
        if [ $count -gt 1 ]; then
            echo "    ⚠️ 警告: 有多个主节点"
        fi
    done
    
    # 3. 检查槽位覆盖
    echo -e "\n3. 槽位覆盖检查:"
    total_slots=$(redis_cmd $CONTROL_NODE $CONTROL_PORT "cluster slots" | wc -l)
    echo "  总槽位段数: $total_slots"
    
    # 4. 检查孤儿节点（主节点但没有槽位）
    echo -e "\n4. 孤儿节点检查:"
    grep "master" /tmp/cluster_nodes.txt | grep -v "fail" | while read line; do
        node_id=$(echo $line | awk '{print $1}')
        node_addr=$(echo $line | awk '{print $2}' | cut -d'@' -f1)
        slots_count=$(echo $line | awk '{for(i=9;i<=NF;i++) print $i}' | grep -c "-")
        if [ $slots_count -eq 0 ]; then
            echo "  ⚠️ 孤儿节点: $node_addr (ID: ${node_id:0:8}...)"
        fi
    done
    
    # 5. 检查从节点数量
    echo -e "\n5. 主节点从节点数量:"
    grep "master" /tmp/cluster_nodes.txt | grep -v "fail" | while read line; do
        master_id=$(echo $line | awk '{print $1}')
        master_addr=$(echo $line | awk '{print $2}' | cut -d'@' -f1)
        slave_count=$(grep "slave $master_id" /tmp/cluster_nodes.txt | wc -l)
        echo "  $master_addr: $slave_count 个从节点"
        if [ $slave_count -eq 0 ]; then
            echo "    ⚠️ 警告: 没有从节点"
        fi
    done
}

# 函数：修复孤儿节点
fix_orphan_nodes() {
    echo -e "\n=== 修复孤儿节点 ==="
    
    grep "master" /tmp/cluster_nodes.txt | grep -v "fail" | while read line; do
        node_id=$(echo $line | awk '{print $1}')
        node_addr=$(echo $line | awk '{print $2}' | cut -d'@' -f1)
        node_host=${node_addr%:*}
        node_port=${node_addr##:*}
        slots_count=$(echo $line | awk '{for(i=9;i<=NF;i++) print $i}' | grep -c "-")
        
        if [ $slots_count -eq 0 ]; then
            echo "发现孤儿节点: $node_addr"
            
            # 检查节点是否可达
            if ! check_node_connectivity $node_host $node_port; then
                echo "  节点不可达，跳过修复"
                continue
            fi
            
            # 找到合适的主节点作为目标
            echo "  寻找合适的主节点..."
            target_master=$(grep "master" /tmp/cluster_nodes.txt | grep -v "fail" | grep -v $node_id | head -1)
            if [ -z "$target_master" ]; then
                echo "  错误: 没有可用的主节点"
                continue
            fi
            
            target_id=$(echo $target_master | awk '{print $1}')
            target_addr=$(echo $target_master | awk '{print $2}' | cut -d'@' -f1)
            target_host=${target_addr%:*}
            target_port=${target_addr##:*}
            
            echo "  目标主节点: $target_addr (ID: ${target_id:0:8}...)"
            
            # 执行修复步骤
            echo "  步骤1: 重置孤儿节点..."
            if redis_cmd $node_host $node_port "cluster reset soft"; then
                echo "    重置成功"
            else
                echo "    重置失败，尝试hard reset"
                redis_cmd $node_host $node_port "cluster reset hard"
            fi
            
            sleep 2
            
            echo "  步骤2: 加入集群..."
            if redis_cmd $node_host $node_port "cluster meet $target_host $target_port"; then
                echo "    加入成功"
            fi
            
            sleep 2
            
            echo "  步骤3: 配置为从节点..."
            if redis_cmd $node_host $node_port "cluster replicate $target_id"; then
                echo "    配置成功"
                echo "  ✅ $node_addr 修复完成，现为 $target_addr 的从节点"
            else
                echo "  ⚠️ 配置失败，可能需要手动处理"
            fi
            
            echo ""
        fi
    done
}

# 函数：重新平衡主节点分布
rebalance_masters() {
    echo -e "\n=== 重新平衡主节点分布 ==="
    
    # 统计每个物理节点的主节点数量
    declare -A node_master_count
    # 先用文件收集所有IP
    grep "master" /tmp/cluster_nodes.txt | awk '{print $2}' | cut -d':' -f1 > /tmp/ip_list.txt

    # 在同一个shell进程中处理
    while read ip; do
        ((node_master_count[$ip]++))
    done < /tmp/ip_list.txt

    # 验证结果
    for ip in "${!node_master_count[@]}"; do
        echo "$ip: ${node_master_count[$ip]} 个主节点"
    done

    # 找出主节点过多的节点
    for ip in "${!node_master_count[@]}"; do
        if [ ${node_master_count[$ip]} -gt 1 ]; then
            echo "发现 $ip 有 ${node_master_count[$ip]} 个主节点"
            
            # 获取该节点上的主节点列表（除了第一个）
            grep "master" /tmp/cluster_nodes.txt | grep -v "fail" | grep "$ip:" | tail -n +2 | while read line; do
                master_id=$(echo $line | awk '{print $1}')
                master_addr=$(echo $line | awk '{print $2}' | cut -d'@' -f1)
                
                # 找到该主节点的从节点
                slave_node=$(grep "slave $master_id" /tmp/cluster_nodes.txt | head -1)
                if [ -n "$slave_node" ]; then
                    slave_id=$(echo $slave_node | awk '{print $1}')
                    slave_addr=$(echo $slave_node | awk '{print $2}' | cut -d'@' -f1)
                    slave_host=${slave_addr%:*}
                    slave_port=${slave_addr##:*}
                    
                    echo "  尝试让从节点 $slave_addr 接管主节点 $master_addr"
                    
                    # 在从节点上执行故障转移
                    if redis_cmd $slave_host $slave_port "cluster failover --force"; then
                        echo "  ✅ 故障转移启动成功"
                        sleep 3
                    else
                        echo "  ⚠️ 故障转移失败"
                    fi
                else
                    echo "  ⚠️ 主节点 $master_addr 没有从节点，无法转移"
                fi
            done
        fi
    done
}

# 函数：验证集群状态
verify_cluster() {
    echo -e "\n=== 集群状态验证 ==="
    
    # 1. 检查集群状态
    echo "1. 集群整体状态:"
    if cluster_state=$(redis_cmd $CONTROL_NODE $CONTROL_PORT "cluster info" | grep "cluster_state:"); then
        echo "  $cluster_state"
    fi
    
    # 2. 检查槽位覆盖
    echo "2. 槽位覆盖:"
    if slots_info=$(redis_cmd $CONTROL_NODE $CONTROL_PORT "cluster info" | grep -E "(cluster_slots_ok|cluster_slots_fail|cluster_slots_assigned)"); then
        echo "$slots_info" | while read line; do
            echo "  $line"
        done
    fi
    
    # 3. 简单读写测试
    echo "3. 简单读写测试:"
    if redis_cmd $CONTROL_NODE $CONTROL_PORT "set auto_test_key $(date +%s)" >/dev/null; then
        echo "  ✅ 写入测试成功"
        if redis_cmd $CONTROL_NODE $CONTROL_PORT "get auto_test_key" >/dev/null; then
            echo "  ✅ 读取测试成功"
            redis_cmd $CONTROL_NODE $CONTROL_PORT "del auto_test_key" >/dev/null
        fi
    else
        echo "  ❌ 读写测试失败"
    fi
}

# 主执行流程
main() {
    echo "开始集群健康检查..."
    echo ""
    
    # 检查控制节点连通性
    if ! check_node_connectivity $CONTROL_NODE $CONTROL_PORT; then
        echo "错误: 控制节点不可用"
        exit 1
    fi
    
    # 获取集群视图
    get_cluster_view
    
    # 分析问题
    analyze_cluster_issues
    
    # 修复孤儿节点
    fix_orphan_nodes
    
    # 重新平衡主节点分布
    rebalance_masters
    
    # 验证修复结果
    sleep 5  # 等待修复操作完成
    get_cluster_view  # 重新获取状态
    verify_cluster
    
    echo -e "\n=== 修复完成 ==="
    echo "时间: $(date)"
    echo "注意: 某些修复可能需要时间生效，建议等待1分钟后再次检查"
}

# 执行主函数
main 2>&1 | tee redis-cluster-fix-$(date +%Y%m%d-%H%M%S).log

# 发送通知（可选）
# curl -X POST -d "集群修复完成" http://notification-server/alert