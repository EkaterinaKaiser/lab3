#!/bin/bash
set -e

echo "=== Starting attacks on victim services ==="

# Используем IP адреса для надежности
POSTGRES_IP="172.20.0.20"
KAFKA_IP="172.20.0.31"
export PGPASSWORD="postgres"

# Атака на PostgreSQL
echo "--- Attacking PostgreSQL ($POSTGRES_IP:5432) ---"
echo "Attempting SQL injection with OR 1=1..."
timeout 3 psql -h $POSTGRES_IP -U postgres -d victimdb -c "SELECT * FROM (SELECT 1 as id, 'test' as name) t WHERE id=1 OR '1'='1';" 2>&1 | head -3 || echo "SQL injection attempt completed"

echo "Attempting SQL injection with UNION SELECT..."
timeout 3 psql -h $POSTGRES_IP -U postgres -d victimdb -c "SELECT 1 UNION SELECT 2;" 2>&1 | head -3 || echo "UNION SELECT injection attempt completed"

echo "Attempting SQL injection with DROP TABLE..."
timeout 3 psql -h $POSTGRES_IP -U postgres -d victimdb -c "DROP TABLE IF EXISTS test_table;" 2>&1 | head -3 || echo "DROP TABLE injection attempt completed"

echo "Attempting brute force connection..."
for i in {1..5}; do
  timeout 2 psql -h $POSTGRES_IP -U postgres -d victimdb -c "SELECT 1;" 2>&1 | head -1 && echo "Connection attempt $i succeeded" || echo "Connection attempt $i failed"
  sleep 0.5
done

echo "Attempting unauthorized access with wrong credentials..."
unset PGPASSWORD
timeout 2 psql -h $POSTGRES_IP -U admin -d victimdb -W wrongpassword -c "SELECT 1;" 2>&1 | head -1 || echo "Unauthorized access attempt blocked"
export PGPASSWORD="postgres"

# Атака на Kafka (используем IP и порт 29092 - внутренний порт Kafka)
echo "--- Attacking Kafka ($KAFKA_IP:29092) ---"
echo "Checking Kafka connectivity..."
timeout 2 bash -c "nc -zv $KAFKA_IP 29092" 2>&1 || echo "Kafka port check completed"

echo "Attempting unauthorized topic creation (malicious-topic)..."
timeout 3 bash -c "echo -e 'malicious-topic' | nc -w 2 $KAFKA_IP 29092" 2>&1 | head -2 || echo "Unauthorized topic creation attempt completed"

echo "Attempting protocol exploitation..."
timeout 3 bash -c "echo -ne '\x00\x00\x00\x01\x00' | nc -w 2 $KAFKA_IP 29092" 2>&1 | head -2 || echo "Protocol exploitation attempt completed"

echo "Attempting message injection..."
timeout 3 bash -c "echo -e 'malicious payload for test-topic' | nc -w 2 $KAFKA_IP 29092" 2>&1 | head -2 || echo "Message injection attempt completed"

echo "Attempting Kafka connection from attacker..."
timeout 3 bash -c "echo 'test connection' | nc -w 2 $KAFKA_IP 29092" 2>&1 | head -2 || echo "Kafka connection attempt completed"

echo "=== Attacks completed ==="
