#!/bin/bash
set -e

echo "=== Setting up Suricata ==="

# КРИТИЧНО: Удаляем директорию eve.json ДО любых операций с Suricata
# Это нужно сделать в самом начале, так как suricata-update запускает тест конфигурации
echo "Checking and fixing eve.json..."
if [ -d /var/log/suricata/eve.json ]; then
  echo "⚠️  WARNING: /var/log/suricata/eve.json is a directory! Removing it..."
  sudo rm -rf /var/log/suricata/eve.json
fi

# Создаем директорию для логов, если не существует
sudo mkdir -p /var/log/suricata
sudo chown suricata:suricata /var/log/suricata 2>/dev/null || true

# Создаем файл eve.json заранее
sudo touch /var/log/suricata/eve.json
sudo chown suricata:suricata /var/log/suricata/eve.json
sudo chmod 644 /var/log/suricata/eve.json

# Установка Suricata (если не установлен)
set +e  # Временно отключаем для suricata-update
if ! command -v suricata &> /dev/null; then
  echo "Installing Suricata..."
  sudo apt update
  sudo apt install -y suricata suricata-update
  sudo mkdir -p /var/log/suricata
  sudo chown suricata:suricata /var/log/suricata
  # Убеждаемся, что eve.json - файл, а не директория
  if [ -d /var/log/suricata/eve.json ]; then
    sudo rm -rf /var/log/suricata/eve.json
    sudo touch /var/log/suricata/eve.json
    sudo chown suricata:suricata /var/log/suricata/eve.json
  fi
  sudo suricata-update
  sudo systemctl enable suricata
  sudo systemctl restart suricata || true
else
  echo "Suricata already installed, updating rules..."
  # Убеждаемся, что eve.json - файл перед обновлением правил
  if [ -d /var/log/suricata/eve.json ]; then
    echo "Fixing eve.json before rule update..."
    sudo rm -rf /var/log/suricata/eve.json
    sudo touch /var/log/suricata/eve.json
    sudo chown suricata:suricata /var/log/suricata/eve.json
  fi
  sudo suricata-update || true
fi
set -e  # Включаем обратно

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
# (уже должно быть создано в начале скрипта, но проверяем еще раз)
if [ -d /var/log/suricata/eve.json ]; then
  echo "⚠️  WARNING: /var/log/suricata/eve.json is still a directory! Removing it..."
  sudo rm -rf /var/log/suricata/eve.json
fi

# Создаем файл eve.json, если его нет
if [ ! -f /var/log/suricata/eve.json ]; then
  sudo touch /var/log/suricata/eve.json
  sudo chown suricata:suricata /var/log/suricata/eve.json
  sudo chmod 644 /var/log/suricata/eve.json
fi

# Проверяем, что это действительно файл
if [ -f /var/log/suricata/eve.json ]; then
  echo "✅ eve.json file exists and is a file"
else
  echo "❌ ERROR: Failed to create eve.json file"
  ls -la /var/log/suricata/ | grep eve || true
fi

# Загружаем кастомные правила защиты
echo "Loading custom Suricata rules..."
if [ -f ~/rules/suricata-rules.rules ]; then
  sudo mkdir -p /etc/suricata/rules
  sudo cp ~/rules/suricata-rules.rules /etc/suricata/rules/local.rules
  sudo chown suricata:suricata /etc/suricata/rules/local.rules
  sudo chmod 644 /etc/suricata/rules/local.rules
  
  # Убеждаемся, что локальные правила включены в конфигурации
  if ! grep -q "^[[:space:]]*-[[:space:]]*local.rules" /etc/suricata/suricata.yaml 2>/dev/null; then
    echo "Adding local.rules to suricata.yaml configuration..."
    # Проверяем, нет ли неправильного паттерна с дефисом
    if grep -q "local.rules/custom_ioc.rules" /etc/suricata/suricata.yaml 2>/dev/null; then
      echo "⚠️  Found incorrect rule pattern, fixing..."
      sudo sed -i 's|local.rules/custom_ioc.rules|local.rules|g' /etc/suricata/suricata.yaml
    fi
    
    # Ищем секцию rule-files и добавляем туда
    if grep -q "^rule-files:" /etc/suricata/suricata.yaml; then
      # Проверяем, нет ли уже local.rules (может быть с другим форматированием)
      if ! grep -A 20 "^rule-files:" /etc/suricata/suricata.yaml | grep -q "local.rules"; then
        # Добавляем после rule-files: с правильным отступом
        sudo sed -i '/^rule-files:/a\  - local.rules' /etc/suricata/suricata.yaml
      fi
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
  
  # Убеждаемся, что default-rule-path настроен правильно
  if ! grep -q "^default-rule-path:" /etc/suricata/suricata.yaml; then
    echo "Adding default-rule-path..."
    if grep -q "^rule-files:" /etc/suricata/suricata.yaml; then
      sudo sed -i '/^rule-files:/i\default-rule-path: /etc/suricata/rules' /etc/suricata/suricata.yaml
    else
      echo "default-rule-path: /etc/suricata/rules" | sudo tee -a /etc/suricata/suricata.yaml
    fi
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
# Используем af-packet для Docker bridge
DOCKER_BRIDGE_ADDED=false
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
    tpacket-v3: yes\
    buffer-size: 32768' /etc/suricata/suricata.yaml
    DOCKER_BRIDGE_ADDED=true
    echo "✅ Docker bridge $DOCKER_BRIDGE added to configuration"
  else
    echo "✅ Docker bridge $DOCKER_BRIDGE already in configuration"
  fi
elif [ -n "$DOCKER_BRIDGE" ]; then
  echo "⚠️  Docker bridge $DOCKER_BRIDGE found but interface does not exist yet (will be added when Docker network is created)"
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

# Настраиваем Suricata для работы с NFQUEUE (для iptables перенаправления)
echo "Configuring Suricata for NFQUEUE mode..."
NFQUEUE_NUM=0

# Проверяем, есть ли секция nfq в конфигурации
if ! grep -q "^nfq:" /etc/suricata/suricata.yaml; then
  echo "Adding NFQUEUE configuration..."
  # Добавляем секцию nfq после af-packet или перед rule-files
  if grep -q "^af-packet:" /etc/suricata/suricata.yaml; then
    sudo sed -i '/^af-packet:/a\
nfq:\
  - mode: accept\
    repeat-mark: 1\
    repeat-mask: 1\
    queue-num: '"$NFQUEUE_NUM"'
' /etc/suricata/suricata.yaml
  elif grep -q "^rule-files:" /etc/suricata/suricata.yaml; then
    sudo sed -i '/^rule-files:/i\
nfq:\
  - mode: accept\
    repeat-mark: 1\
    repeat-mask: 1\
    queue-num: '"$NFQUEUE_NUM"'
' /etc/suricata/suricata.yaml
  else
    echo "" | sudo tee -a /etc/suricata/suricata.yaml
    echo "nfq:" | sudo tee -a /etc/suricata/suricata.yaml
    echo "  - mode: accept" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    repeat-mark: 1" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    repeat-mask: 1" | sudo tee -a /etc/suricata/suricata.yaml
    echo "    queue-num: $NFQUEUE_NUM" | sudo tee -a /etc/suricata/suricata.yaml
  fi
  echo "✅ NFQUEUE configuration added (queue-num: $NFQUEUE_NUM)"
else
  echo "✅ NFQUEUE configuration already exists"
fi

# Проверяем конфигурацию Suricata
echo "Testing Suricata configuration..."
set +e  # Временно отключаем set -e для обработки ошибок теста
CONFIG_TEST=$(sudo suricata -T -c /etc/suricata/suricata.yaml 2>&1)
CONFIG_EXIT_CODE=$?
set -e  # Включаем обратно

if echo "$CONFIG_TEST" | grep -q "Configuration test was successful"; then
  echo "✅ Suricata configuration is valid"
elif [ $CONFIG_EXIT_CODE -ne 0 ]; then
  echo "⚠️  Suricata configuration test failed with exit code $CONFIG_EXIT_CODE"
  echo "Full error output:"
  echo "$CONFIG_TEST" | tail -50
  
  # Ищем конкретные ошибки
  if echo "$CONFIG_TEST" | grep -q "eve.json.*Is a directory"; then
    echo "Fixing eve.json directory issue..."
    sudo rm -rf /var/log/suricata/eve.json
    sudo touch /var/log/suricata/eve.json
    sudo chown suricata:suricata /var/log/suricata/eve.json
    sudo chmod 644 /var/log/suricata/eve.json
    echo "Retesting configuration..."
    sudo suricata -T -c /etc/suricata/suricata.yaml 2>&1 | tail -20 || true
  fi
  
  if echo "$CONFIG_TEST" | grep -q "No interface found"; then
    echo "⚠️  Interface configuration issue detected"
    echo "Current af-packet configuration:"
    grep -A 10 "^af-packet:" /etc/suricata/suricata.yaml || echo "No af-packet section found"
  fi
  
  # Убеждаемся, что default-rule-path существует
  if ! grep -q "default-rule-path:" /etc/suricata/suricata.yaml; then
    echo "Adding default-rule-path..."
    sudo sed -i '/rule-files:/i\default-rule-path: /etc/suricata/rules' /etc/suricata/suricata.yaml || true
  fi
  
  # Проверяем, что af-packet настроен правильно
  if ! grep -A 5 "^af-packet:" /etc/suricata/suricata.yaml | grep -q "interface:"; then
    echo "⚠️  No interfaces configured in af-packet section"
  fi
  
  echo "⚠️  Continuing despite configuration test failure - will attempt to start Suricata anyway"
else
  echo "⚠️  Configuration test completed with warnings"
  echo "$CONFIG_TEST" | grep -i "warning\|error" | tail -20 || echo "No critical errors found"
fi

# Убеждаемся, что после теста конфигурации мы продолжаем работу
echo "Configuration test completed, continuing with setup..."

# Если Docker bridge был добавлен, нужно перезапустить Suricata
if [ "$DOCKER_BRIDGE_ADDED" = "true" ] && [ -n "$DOCKER_BRIDGE" ]; then
  echo "Docker bridge was added, Suricata will need to be restarted after Docker network is created"
fi

# Перезапускаем Suricata после создания Docker сети и загрузки правил
echo "Preparing to start Suricata..."
set +e  # Отключаем строгую проверку ошибок для операций, которые могут завершиться с ошибкой
sudo systemctl stop suricata 2>/dev/null || true
sudo pkill -9 suricata 2>/dev/null || true
sleep 2
set -e  # Включаем обратно

# Проверяем, что правила загружены
if [ -f /etc/suricata/rules/local.rules ]; then
  RULE_COUNT=$(grep -c "^alert" /etc/suricata/rules/local.rules 2>/dev/null || echo "0")
  echo "Loaded $RULE_COUNT custom rules"
fi

# Запускаем Suricata
echo "Starting Suricata service..."
set +e  # Отключаем строгую проверку для операций запуска

# Пробуем запустить через systemd
if sudo systemctl start suricata 2>&1; then
  echo "✅ Suricata started via systemd"
  sleep 3
else
  echo "⚠️  Systemd start failed, checking errors..."
  sudo journalctl -u suricata -n 30 --no-pager | grep -i "error\|fail" | tail -10 || true
  
  echo "Trying to start manually to see detailed errors..."
  # Пробуем запустить вручную с выводом ошибок
  MANUAL_START_OUTPUT=$(sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D -v 2>&1)
  if echo "$MANUAL_START_OUTPUT" | grep -q "started"; then
    echo "✅ Suricata started manually"
  else
    echo "Manual start output:"
    echo "$MANUAL_START_OUTPUT" | head -50
    echo ""
    echo "Trying with specific interface..."
    if [ -n "$ACTIVE_INTERFACE" ] && [ "$ACTIVE_INTERFACE" != "any" ]; then
      INTERFACE_START_OUTPUT=$(sudo suricata -c /etc/suricata/suricata.yaml -i "$ACTIVE_INTERFACE" -D -v 2>&1)
      if echo "$INTERFACE_START_OUTPUT" | grep -q "started"; then
        echo "✅ Suricata started on interface $ACTIVE_INTERFACE"
      else
        echo "⚠️  Failed to start on $ACTIVE_INTERFACE"
        echo "$INTERFACE_START_OUTPUT" | head -30
      fi
    fi
  fi
fi
set -e  # Включаем обратно

sleep 5

# Проверяем, запущен ли Suricata
set +e
if ! sudo systemctl is-active --quiet suricata && ! pgrep -x suricata > /dev/null; then
  echo "⚠️  Suricata is not running. Attempting alternative start method..."
  # Пробуем запустить в фоне без systemd
  ALT_START_OUTPUT=$(sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D 2>&1)
  if echo "$ALT_START_OUTPUT" | grep -q "started\|error"; then
    echo "$ALT_START_OUTPUT" | head -20
  else
    echo "Manual start also failed. Last attempt with minimal config..."
    # Пробуем запустить только на одном интерфейсе
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$INTERFACE" ]; then
      INTERFACE_START=$(sudo suricata -c /etc/suricata/suricata.yaml -i "$INTERFACE" -D 2>&1)
      echo "$INTERFACE_START" | head -20 || echo "Failed to start on $INTERFACE"
    fi
  fi
  sleep 3
fi
set -e

# Перезагружаем правила Suricata (если сервис уже запущен)
if sudo systemctl is-active --quiet suricata || pgrep -x suricata > /dev/null; then
  echo "Reloading Suricata rules..."
  sudo suricatasc -c "reload-rules" 2>/dev/null || echo "Could not reload rules via suricatasc (this is OK if Suricata was just started)"
fi

# Проверяем статус
set +e
if sudo systemctl is-active --quiet suricata || pgrep -x suricata > /dev/null; then
  echo "✅ Suricata is running"
  if sudo systemctl is-active --quiet suricata; then
    sudo systemctl status suricata --no-pager -l | head -15 || true
  else
    echo "Suricata running as process (not via systemd)"
    ps aux | grep suricata | grep -v grep | head -2
  fi
else
  echo "⚠️  WARNING: Suricata service is not running!"
  echo "Checking error logs:"
  sudo journalctl -u suricata -n 30 --no-pager 2>/dev/null | grep -i "error\|fail\|interface" | tail -15 || echo "No recent errors in journal"
  echo ""
  echo "Available network interfaces:"
  ip -br link show | grep -v "lo" | head -5
  echo ""
  echo "Attempting final start attempt:"
  FINAL_START=$(sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D -v 2>&1)
  echo "$FINAL_START" | head -30
  sleep 3
  if pgrep -x suricata > /dev/null; then
    echo "✅ Suricata started manually"
    # Останавливаем ручной процесс и запускаем через systemd
    sudo pkill suricata || true
    sleep 2
    sudo systemctl start suricata || true
  else
    echo "⚠️  Could not start Suricata automatically. Manual intervention may be required."
    echo "You can try starting manually with: sudo suricata -c /etc/suricata/suricata.yaml --af-packet -D"
  fi
fi
set -e

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

# Финальная проверка статуса
set +e
if sudo systemctl is-active --quiet suricata || pgrep -x suricata > /dev/null; then
  echo "✅ Suricata is running"
else
  echo "⚠️  Suricata is not running, but setup completed"
fi
set -e

echo "=== Suricata setup completed ==="
