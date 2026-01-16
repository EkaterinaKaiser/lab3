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
# Проверяем, не является ли eve.json директорией (ошибка из предыдущих установок)
if [ -d /var/log/suricata/eve.json ]; then
  echo "⚠️  WARNING: /var/log/suricata/eve.json is a directory! Removing it..."
  sudo rm -rf /var/log/suricata/eve.json
fi

# Создаем файл eve.json
sudo touch /var/log/suricata/eve.json
sudo chown suricata:suricata /var/log/suricata/eve.json
sudo chmod 644 /var/log/suricata/eve.json

# Проверяем, что это действительно файл
if [ -f /var/log/suricata/eve.json ]; then
  echo "✅ eve.json file created successfully"
else
  echo "❌ ERROR: Failed to create eve.json file"
  ls -la /var/log/suricata/ | grep eve
fi

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
  DOCKER_BRIDGE=$(ip -br link show | grep -E '^br-' | awk '{print $1}' | head -1 || echo "")
fi

# Находим активный сетевой интерфейс
ACTIVE_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1 || echo "")
if [ -z "$ACTIVE_INTERFACE" ]; then
  ACTIVE_INTERFACE=$(ip -br link show | grep -v "lo" | grep "UP" | awk '{print $1}' | head -1 || echo "")
fi

# Если интерфейс не найден, используем первый доступный (кроме lo)
if [ -z "$ACTIVE_INTERFACE" ] || [ "$ACTIVE_INTERFACE" = "any" ]; then
  ACTIVE_INTERFACE=$(ip -br link show | grep -v "lo" | awk '{print $1}' | head -1 || echo "eth0")
fi

# Проверяем, что интерфейс существует
if ! ip link show "$ACTIVE_INTERFACE" &>/dev/null 2>&1; then
  echo "⚠️  Interface $ACTIVE_INTERFACE not found, trying to find available interface..."
  ACTIVE_INTERFACE=$(ip -br link show | grep -E "^[a-z]" | grep -v "lo" | awk '{print $1}' | head -1 || echo "any")
fi

echo "Docker bridge interface: $DOCKER_BRIDGE"
echo "Active network interface: $ACTIVE_INTERFACE"

# Настраиваем af-packet интерфейсы в конфигурации Suricata
echo "Configuring af-packet interfaces in Suricata..."

# Проверяем текущую конфигурацию af-packet
if grep -q "^af-packet:" /etc/suricata/suricata.yaml; then
  echo "af-packet section exists, checking interfaces..."
  # Проверяем, есть ли активный интерфейс в конфигурации
  if ! grep -A 10 "^af-packet:" /etc/suricata/suricata.yaml | grep -q "interface: $ACTIVE_INTERFACE"; then
    echo "Active interface $ACTIVE_INTERFACE not found in af-packet config"
  fi
else
  echo "Adding af-packet configuration..."
  # Находим место для вставки (перед rule-files или в конец)
  if grep -q "^rule-files:" /etc/suricata/suricata.yaml; then
    # Вставляем перед rule-files
    sudo sed -i '/^rule-files:/i\
af-packet:\
  - interface: '"$ACTIVE_INTERFACE"'\
    cluster-id: 99\
    cluster-type: cluster_flow\
    defrag: yes\
    use-mmap: yes\
    tpacket-v3: yes' /etc/suricata/suricata.yaml
  else
    # Добавляем в конец файла
    echo "" | sudo tee -a /etc/suricata/suricata.yaml
    echo "af-packet:" | sudo tee -a /etc/suricata/suricata.yaml
    echo "  - interface: $ACTIVE_INTERFACE" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    cluster-id: 99" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    cluster-type: cluster_flow" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    defrag: yes" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    use-mmap: yes" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    tpacket-v3: yes" | sudo tee -a /etc/suricata/suricata.yaml
  fi
fi

# Если Docker bridge найден и отличается от основного интерфейса, добавляем его
if [ -n "$DOCKER_BRIDGE" ] && [ "$DOCKER_BRIDGE" != "$ACTIVE_INTERFACE" ] && ip link show "$DOCKER_BRIDGE" &>/dev/null; then
  echo "Adding Docker bridge $DOCKER_BRIDGE to af-packet configuration..."
  if ! grep -A 20 "^af-packet:" /etc/suricata/suricata.yaml | grep -q "interface: $DOCKER_BRIDGE"; then
    # Добавляем Docker bridge в секцию af-packet
    sudo sed -i '/^af-packet:/a\
  - interface: '"$DOCKER_BRIDGE"'\
    cluster-id: 98\
    cluster-type: cluster_flow\
    defrag: yes\
    use-mmap: yes\
    tpacket-v3: yes' /etc/suricata/suricata.yaml
  fi
fi

# Проверяем, что интерфейсы существуют
echo "Verifying interfaces exist..."
if [ "$ACTIVE_INTERFACE" != "any" ]; then
  if ip link show "$ACTIVE_INTERFACE" &>/dev/null; then
    echo "✅ Interface $ACTIVE_INTERFACE exists"
  else
    echo "⚠️  Interface $ACTIVE_INTERFACE not found, Suricata may fail to start"
  fi
fi

# Проверяем конфигурацию Suricata
echo "Testing Suricata configuration..."
CONFIG_TEST=$(sudo suricata -T -c /etc/suricata/suricata.yaml 2>&1)
if echo "$CONFIG_TEST" | grep -q "Configuration test was successful"; then
  echo "✅ Suricata configuration is valid"
else
  echo "⚠️  Suricata configuration test issues:"
  echo "$CONFIG_TEST" | tail -30
  
  # Убеждаемся, что default-rule-path существует
  if ! grep -q "default-rule-path:" /etc/suricata/suricata.yaml; then
    echo "Adding default-rule-path..."
    sudo sed -i '/rule-files:/i\default-rule-path: /etc/suricata/rules' /etc/suricata/suricata.yaml || true
  fi
  
  # Проверяем, что af-packet настроен правильно
  if ! grep -A 5 "^af-packet:" /etc/suricata/suricata.yaml | grep -q "interface:"; then
    echo "⚠️  No interfaces configured in af-packet section"
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
# Сначала останавливаем, если запущен
sudo systemctl stop suricata 2>/dev/null || true
sudo pkill -9 suricata 2>/dev/null || true
sleep 2

# Пробуем запустить через systemd
if sudo systemctl start suricata 2>&1; then
  echo "Suricata started via systemd"
else
  echo "Systemd start failed, checking errors..."
  sudo journalctl -u suricata -n 30 --no-pager | grep -i "error\|fail" | tail -10 || true
  
  echo "Trying to start manually to see detailed errors..."
  # Пробуем запустить вручную с выводом ошибок
  sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D -v 2>&1 | head -50 || {
    echo "Manual start also failed. Trying with specific interface..."
    if [ -n "$ACTIVE_INTERFACE" ] && [ "$ACTIVE_INTERFACE" != "any" ]; then
      sudo suricata -c /etc/suricata/suricata.yaml -i "$ACTIVE_INTERFACE" -D -v 2>&1 | head -30 || echo "Failed to start on $ACTIVE_INTERFACE"
    fi
  }
fi

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
if sudo systemctl is-active --quiet suricata || pgrep -x suricata > /dev/null; then
  echo "✅ Suricata is running"
  if sudo systemctl is-active --quiet suricata; then
    sudo systemctl status suricata --no-pager -l | head -15 || true
  else
    echo "Suricata running as process (not via systemd)"
    ps aux | grep suricata | grep -v grep | head -2
  fi
else
  echo "⚠️  ERROR: Suricata service failed to start!"
  echo "Checking error logs:"
  sudo journalctl -u suricata -n 30 --no-pager | grep -i "error\|fail\|interface" | tail -15 || true
  echo ""
  echo "Available network interfaces:"
  ip -br link show | grep -v "lo" | head -5
  echo ""
  echo "Attempting to start Suricata manually to see errors:"
  sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D -v 2>&1 | head -30 || true
  sleep 3
  if pgrep -x suricata > /dev/null; then
    echo "✅ Suricata started manually"
    # Останавливаем ручной процесс и запускаем через systemd
    sudo pkill suricata || true
    sleep 2
    sudo systemctl start suricata || true
  else
    echo "❌ Could not start Suricata. Please check configuration manually."
  fi
fi

# Проверяем, что eve.json создается и является файлом (не директорией)
sleep 2
if [ -f /var/log/suricata/eve.json ]; then
  echo "✅ Suricata eve.json file exists and is a file"
  ls -lh /var/log/suricata/eve.json
elif [ -d /var/log/suricata/eve.json ]; then
  echo "❌ ERROR: eve.json is still a directory! Removing and recreating..."
  sudo rm -rf /var/log/suricata/eve.json
  sudo touch /var/log/suricata/eve.json
  sudo chown suricata:suricata /var/log/suricata/eve.json
  sudo chmod 644 /var/log/suricata/eve.json
  echo "✅ eve.json recreated as file"
else
  echo "⚠️  Warning: eve.json file not found yet (will be created when Suricata processes traffic)"
  # Создаем файл заранее
  sudo touch /var/log/suricata/eve.json
  sudo chown suricata:suricata /var/log/suricata/eve.json
  sudo chmod 644 /var/log/suricata/eve.json
  echo "✅ Created eve.json file"
fi

echo "=== Suricata setup completed ==="
