#!/bin/bash
set -e

echo "=== Setting up Suricata ==="

# Установка Suricata (если не установлен)
if ! command -v suricata &> /dev/null; then
  echo "Installing Suricata..."
  sudo apt update
  sudo apt install -y suricata suricata-update
  sudo mkdir -p /var/log/suricata
  sudo chown suricata:suricata /var/log/suricata
  sudo suricata-update
  sudo systemctl enable suricata
  sudo systemctl restart suricata || true
else
  echo "Suricata already installed, updating rules..."
  sudo suricata-update || true
fi

# Настройка конфигурации Suricata
echo "Configuring Suricata..."

# Создаем резервную копию конфигурации
sudo cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak 2>/dev/null || true

# Включаем eve.json логирование
# Раскомментируем и настраиваем eve-log секцию
sudo sed -i 's|^\([[:space:]]*\)# eve-log:|\1eve-log:|' /etc/suricata/suricata.yaml || true
sudo sed -i '/eve-log:/,/^[^[:space:]]/ {
  s|enabled: no|enabled: yes|g
  s|filename: eve.json|filename: /var/log/suricata/eve.json|g
}' /etc/suricata/suricata.yaml || true

# Альтернативный способ: прямая замена через sed
if ! grep -q "filename: /var/log/suricata/eve.json" /etc/suricata/suricata.yaml 2>/dev/null; then
  sudo sed -i 's|filename:.*eve.json|filename: /var/log/suricata/eve.json|g' /etc/suricata/suricata.yaml || true
fi

# Убеждаемся, что enabled: yes установлен для eve-log
sudo sed -i '/eve-log:/,/^[^[:space:]#]/ {
  /enabled:/ s/enabled:.*/enabled: yes/
}' /etc/suricata/suricata.yaml || true

# Убеждаемся, что eve.json файл существует и имеет правильные права
sudo touch /var/log/suricata/eve.json
sudo chown suricata:suricata /var/log/suricata/eve.json
sudo chmod 644 /var/log/suricata/eve.json

# Загружаем кастомные правила защиты
echo "Loading custom Suricata rules..."
if [ -f ~/rules/suricata-rules.rules ]; then
  sudo mkdir -p /etc/suricata/rules
  sudo cp ~/rules/suricata-rules.rules /etc/suricata/rules/local.rules
  sudo chown suricata:suricata /etc/suricata/rules/local.rules
  sudo chmod 644 /etc/suricata/rules/local.rules
  
  # Убеждаемся, что локальные правила включены в конфигурации
  if ! grep -q "local.rules" /etc/suricata/suricata.yaml 2>/dev/null; then
    echo "Adding local.rules to suricata.yaml configuration..."
    # Ищем секцию rule-files и добавляем туда
    if grep -q "rule-files:" /etc/suricata/suricata.yaml; then
      # Добавляем после rule-files:
      sudo sed -i '/rule-files:/a\  - local.rules' /etc/suricata/suricata.yaml
    elif grep -q "default-rule-path:" /etc/suricata/suricata.yaml; then
      # Добавляем после default-rule-path
      sudo sed -i '/default-rule-path:/a\\nrule-files:\n  - local.rules' /etc/suricata/suricata.yaml
    else
      # Добавляем в конец файла
      echo "" | sudo tee -a /etc/suricata/suricata.yaml
      echo "rule-files:" | sudo tee -a /etc/suricata/suricata.yaml
      echo "  - local.rules" | sudo tee -a /etc/suricata/suricata.yaml
    fi
    echo "✅ Added local.rules to configuration"
  else
    echo "✅ local.rules already in configuration"
  fi
  
  echo "✅ Custom rules loaded"
  echo "Rules file location: /etc/suricata/rules/local.rules"
  sudo cat /etc/suricata/rules/local.rules | head -5
else
  echo "⚠️  Warning: Custom rules file not found at ~/rules/suricata-rules.rules"
fi

# Находим Docker bridge интерфейс для мониторинга
DOCKER_BRIDGE=$(docker network inspect vulnnet 2>/dev/null | jq -r '.[0].Options."com.docker.network.bridge.name" // empty' 2>/dev/null || echo "")
if [ -z "$DOCKER_BRIDGE" ]; then
  DOCKER_BRIDGE=$(docker network inspect vulnnet 2>/dev/null | grep -oP '"Name": "\K[^"]+' | head -1 || echo "")
fi
if [ -z "$DOCKER_BRIDGE" ]; then
  DOCKER_BRIDGE=$(ip -br link show | grep -E '^br-' | awk '{print $1}' | head -1 || echo "any")
fi
echo "Docker bridge interface: $DOCKER_BRIDGE"

# Настраиваем Suricata для мониторинга всех интерфейсов или Docker bridge
# Suricata по умолчанию мониторит все интерфейсы через AF_PACKET
# Но нужно убедиться, что он видит Docker трафик
if [ "$DOCKER_BRIDGE" != "any" ] && ip link show "$DOCKER_BRIDGE" &>/dev/null; then
  echo "Docker bridge $DOCKER_BRIDGE found, Suricata should monitor it automatically"
else
  echo "Using default interface monitoring (Suricata will monitor all interfaces)"
fi

# Проверяем конфигурацию Suricata
echo "Testing Suricata configuration..."
if ! sudo suricata -T -c /etc/suricata/suricata.yaml 2>&1; then
  echo "⚠️  Suricata configuration test failed. Checking errors..."
  sudo suricata -T -c /etc/suricata/suricata.yaml 2>&1 | tail -20
  echo "Attempting to fix common issues..."
  
  # Убеждаемся, что default-rule-path существует
  if ! grep -q "default-rule-path:" /etc/suricata/suricata.yaml; then
    echo "Adding default-rule-path..."
    sudo sed -i '/rule-files:/i\default-rule-path: /etc/suricata/rules' /etc/suricata/suricata.yaml || true
  fi
fi

# Перезапускаем Suricata после создания Docker сети и загрузки правил
echo "Restarting Suricata..."
sudo systemctl stop suricata 2>/dev/null || true
sleep 2

# Проверяем, что правила загружены
if [ -f /etc/suricata/rules/local.rules ]; then
  RULE_COUNT=$(grep -c "^alert" /etc/suricata/rules/local.rules 2>/dev/null || echo "0")
  echo "Loaded $RULE_COUNT custom rules"
fi

# Запускаем Suricata
echo "Starting Suricata service..."
sudo systemctl start suricata || {
  echo "Systemd start failed, checking why..."
  sudo journalctl -u suricata -n 20 --no-pager
  echo "Trying to start manually to see errors..."
  sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D -v 2>&1 | head -30 || true
}

sleep 5

# Проверяем, запущен ли Suricata
if ! sudo systemctl is-active --quiet suricata && ! pgrep -x suricata > /dev/null; then
  echo "⚠️  Suricata is not running. Attempting alternative start method..."
  # Пробуем запустить в фоне без systemd
  sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D || {
    echo "Manual start also failed. Last attempt with minimal config..."
    # Пробуем запустить только на одном интерфейсе
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$INTERFACE" ]; then
      sudo suricata -c /etc/suricata/suricata.yaml -i "$INTERFACE" -D || echo "Failed to start on $INTERFACE"
    fi
  }
  sleep 3
fi

# Перезагружаем правила Suricata (если сервис уже запущен)
if sudo systemctl is-active --quiet suricata || pgrep -x suricata > /dev/null; then
  echo "Reloading Suricata rules..."
  sudo suricatasc -c "reload-rules" 2>/dev/null || echo "Could not reload rules via suricatasc (this is OK if Suricata was just started)"
fi

# Проверяем статус
if sudo systemctl is-active --quiet suricata; then
  echo "✅ Suricata is running"
  sudo systemctl status suricata --no-pager -l | head -15 || true
else
  echo "⚠️  ERROR: Suricata service failed to start!"
  echo "Checking error logs:"
  sudo journalctl -u suricata -n 30 --no-pager || true
  echo ""
  echo "Attempting to start Suricata manually to see errors:"
  sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D 2>&1 | head -20 || true
  sleep 2
  if pgrep -x suricata > /dev/null; then
    echo "✅ Suricata started manually"
    sudo pkill suricata || true
    sleep 1
    sudo systemctl start suricata || true
  fi
fi

# Проверяем, что eve.json создается
sleep 2
if [ -f /var/log/suricata/eve.json ]; then
  echo "✅ Suricata eve.json file exists"
  ls -lh /var/log/suricata/eve.json
else
  echo "⚠️  Warning: eve.json file not found yet (will be created when Suricata processes traffic)"
fi

echo "=== Suricata setup completed ==="
