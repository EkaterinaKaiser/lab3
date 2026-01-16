#!/bin/bash
set -e

echo "=== Setting up iptables for Docker traffic redirection to Suricata ==="

# Устанавливаем iptables если не установлен
if ! command -v iptables &> /dev/null; then
  echo "Installing iptables..."
  sudo apt update
  sudo apt install -y iptables iptables-persistent || true
fi

# Находим Docker bridge интерфейс
DOCKER_BRIDGE=$(docker network inspect vulnnet 2>/dev/null | jq -r '.[0].Options."com.docker.network.bridge.name" // empty' 2>/dev/null || echo "")
if [ -z "$DOCKER_BRIDGE" ]; then
  DOCKER_BRIDGE=$(ip -br link show | grep -E '^br-' | awk '{print $1}' | head -1 || echo "")
fi

if [ -z "$DOCKER_BRIDGE" ]; then
  echo "⚠️  Docker bridge not found, cannot setup iptables rules"
  exit 1
fi

echo "Found Docker bridge: $DOCKER_BRIDGE"

# Получаем сеть Docker (обычно 172.20.0.0/16 из docker-compose.yml)
DOCKER_NETWORK=$(docker network inspect vulnnet 2>/dev/null | jq -r '.[0].IPAM.Config[0].Subnet // "172.20.0.0/16"' 2>/dev/null || echo "172.20.0.0/16")
echo "Docker network: $DOCKER_NETWORK"

# NFQUEUE номер для Suricata (можно использовать 0-65535, используем 0)
NFQUEUE_NUM=0

echo ""
echo "=== Clearing existing iptables rules for Docker network ==="
# Удаляем старые правила, если они есть
sudo iptables -t mangle -D FORWARD -s $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM 2>/dev/null || true
sudo iptables -t mangle -D FORWARD -d $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM 2>/dev/null || true
sudo iptables -t mangle -D OUTPUT -s $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM 2>/dev/null || true
sudo iptables -t mangle -D INPUT -d $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM 2>/dev/null || true

echo ""
echo "=== Adding iptables rules to redirect Docker traffic to NFQUEUE ==="

# Перенаправляем трафик Docker сети через NFQUEUE для Suricata
# FORWARD - трафик между контейнерами в Docker сети
sudo iptables -t mangle -I FORWARD 1 -s $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM || true
sudo iptables -t mangle -I FORWARD 1 -d $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM || true

# OUTPUT - трафик из хоста в Docker сеть
sudo iptables -t mangle -I OUTPUT 1 -s $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM || true

# INPUT - трафик в Docker сеть с хоста
sudo iptables -t mangle -I INPUT 1 -d $DOCKER_NETWORK -j NFQUEUE --queue-num $NFQUEUE_NUM || true

echo "✅ iptables rules added"

echo ""
echo "=== Verifying iptables rules ==="
echo "FORWARD rules:"
sudo iptables -t mangle -L FORWARD -n -v | grep -E "NFQUEUE|172.20" || echo "No FORWARD rules found"
echo ""
echo "OUTPUT rules:"
sudo iptables -t mangle -L OUTPUT -n -v | grep -E "NFQUEUE|172.20" || echo "No OUTPUT rules found"
echo ""
echo "INPUT rules:"
sudo iptables -t mangle -L INPUT -n -v | grep -E "NFQUEUE|172.20" || echo "No INPUT rules found"

echo ""
echo "=== Saving iptables rules (if iptables-persistent is available) ==="
# Сохраняем правила, если iptables-persistent установлен
if command -v netfilter-persistent &> /dev/null; then
  sudo netfilter-persistent save || true
elif [ -f /etc/iptables/rules.v4 ]; then
  sudo iptables-save > /tmp/iptables-rules-v4.txt 2>/dev/null || true
  echo "Rules saved to /tmp/iptables-rules-v4.txt"
fi

echo ""
echo "=== iptables setup completed ==="
echo "NFQUEUE number: $NFQUEUE_NUM"
echo "Docker network: $DOCKER_NETWORK"
echo "Docker bridge: $DOCKER_BRIDGE"
