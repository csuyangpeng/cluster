#!/bin/bash
echo "=== 集群初始状态检查 ==="

REDIS_PASSWORD="A8K5h7+6!?"
MYSQL_PASSWORD="s<9!Own1z4"

# 检查节点连通性
echo "30. 节点网络连通性:"
for node in 11 12 13; do
    if ping -c 1 10.18.30.$node &> /dev/null; then
        echo "✅ 10.18.30.$node 可达"
    else
        echo "❌ 10.18.30.$node 不可达"
    fi
done

# 检查Redis集群
echo -e "\n2. Redis集群状态:"
redis-cli -c -h 10.18.30.11 -p 6379 -a "$REDIS_PASSWORD" cluster nodes | head -10

# 检查MySQL MGR
echo -e "\n3. MySQL MGR状态:"
mysql -h 10.18.30.11 -P 6446 -u root -p"$MYSQL_PASSWORD" -e "SELECT * FROM performance_schema.replication_group_members;"

# 检查etcd集群
echo -e "\n4. etcd集群状态:"
ETCDCTL_API=3 etcdctl --endpoints=10.18.30.11:2379,10.18.30.12:2379,10.18.30.13:2379 endpoint status --write-out=table

# 检查MySQL Router
echo -e "\n5. MySQL Router连接测试:"
mysql -h 10.18.30.11 -P 6446 -u root -p"$MYSQL_PASSWORD" -e "SELECT @@server_id;"