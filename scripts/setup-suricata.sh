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
    # Добавляем правило-файл в конфигурацию
    sudo sed -i '/default-rule-path:/a\  - local.rules' /etc/suricata/suricata.yaml || \
    sudo sed -i '/rule-files:/a\  - local.rules' /etc/suricata/suricata.yaml || \
    echo "  - local.rules" | sudo tee -a /etc/suricata/suricata.yaml > /dev/null
  fi
  
  echo "✅ Custom rules loaded"
  echo "Rules file location: /etc/suricata/rules/local.rules"
  sudo cat /etc/suricata/rules/local.rules | head -5
else
  echo "⚠️  Warning: Custom rules file not found at ~/rules/suricata-rules.rules"
fi

# Находим Docker bridge интерфейс для информации
DOCKER_BRIDGE=$(docker network inspect vulnnet 2>/dev/null | grep -oP '"Name": "\K[^"]+' | head -1 || echo "")
if [ -z "$DOCKER_BRIDGE" ]; then
  DOCKER_BRIDGE=$(ip -br link show | grep -E '^br-' | awk '{print $1}' | head -1 || echo "docker0")
fi
echo "Docker bridge interface: $DOCKER_BRIDGE"

# Проверяем конфигурацию Suricata
echo "Testing Suricata configuration..."
sudo suricata -T -c /etc/suricata/suricata.yaml || echo "Config test completed"

# Перезапускаем Suricata после создания Docker сети
echo "Restarting Suricata..."
sudo systemctl stop suricata 2>/dev/null || true
sleep 2
sudo systemctl start suricata
sleep 3

# Проверяем статус
if sudo systemctl is-active --quiet suricata; then
  echo "✅ Suricata is running"
  sudo systemctl status suricata --no-pager -l || true
else
  echo "⚠️  Warning: Suricata service may not be running"
  sudo systemctl status suricata --no-pager -l || true
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
