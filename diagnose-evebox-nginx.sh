#!/bin/bash

echo "=========================================="
echo "Диагностика EveBox и nginx"
echo "=========================================="
echo ""

echo "=== 1. Статус службы EveBox ==="
sudo systemctl status evebox --no-pager -l | head -30
echo ""

echo "=== 2. Статус службы nginx ==="
sudo systemctl status nginx --no-pager -l | head -30
echo ""

echo "=== 3. Проверка процессов ==="
echo "EveBox:"
ps aux | grep evebox | grep -v grep || echo "Процесс EveBox не найден"
echo ""
echo "nginx:"
ps aux | grep nginx | grep -v grep || echo "Процесс nginx не найден"
echo ""

echo "=== 4. Проверка прослушивающих портов ==="
if command -v ss &> /dev/null; then
    echo "Порт 5636 (nginx):"
    sudo ss -tulpn | grep 5636 || echo "Порт 5636 не прослушивается"
    echo ""
    echo "Порт 5637 (EveBox):"
    sudo ss -tulpn | grep 5637 || echo "Порт 5637 не прослушивается"
else
    sudo netstat -tulpn 2>/dev/null | grep -E "5636|5637" || echo "Порты не найдены"
fi
echo ""

echo "=== 5. Конфигурация EveBox ==="
echo "Systemd override:"
cat /etc/systemd/system/evebox.service.d/override.conf 2>/dev/null || echo "Override конфигурация не найдена"
echo ""
echo "/etc/default/evebox:"
cat /etc/default/evebox 2>/dev/null || echo "Файл не найден"
echo ""

echo "=== 6. Конфигурация nginx ==="
echo "Конфигурация evebox:"
cat /etc/nginx/sites-available/evebox 2>/dev/null || echo "Конфигурация не найдена"
echo ""
echo "Проверка синтаксиса nginx:"
sudo nginx -t 2>&1
echo ""

echo "=== 7. Последние логи EveBox (30 строк) ==="
sudo journalctl -u evebox -n 30 --no-pager
echo ""

echo "=== 8. Последние логи nginx (30 строк) ==="
sudo journalctl -u nginx -n 30 --no-pager
echo ""
echo "Логи ошибок nginx:"
sudo tail -n 20 /var/log/nginx/error.log 2>/dev/null || echo "Лог ошибок не найден"
echo ""

echo "=== 9. Проверка доступности EveBox напрямую (localhost:5637) ==="
if command -v curl &> /dev/null; then
    echo "HTTP запрос к localhost:5637:"
    curl -v http://127.0.0.1:5637/ --max-time 5 2>&1 | head -30 || echo "Не удалось подключиться"
    echo ""
    echo "HTTPS запрос к localhost:5637:"
    curl -k -v https://127.0.0.1:5637/ --max-time 5 2>&1 | head -30 || echo "Не удалось подключиться"
else
    echo "curl не установлен"
fi
echo ""

echo "=== 10. Проверка доступности через nginx (localhost:5636) ==="
if command -v curl &> /dev/null; then
    echo "HTTP запрос к localhost:5636 (через nginx):"
    curl -v http://127.0.0.1:5636/ --max-time 10 2>&1 | head -40 || echo "Не удалось подключиться"
else
    echo "curl не установлен"
fi
echo ""

echo "=== 11. Проверка файла eve.json ==="
ls -lh /var/log/suricata/eve.json 2>/dev/null || echo "Файл не найден"
echo "Последние 2 строки (если файл существует):"
sudo tail -n 2 /var/log/suricata/eve.json 2>/dev/null | jq . 2>/dev/null || sudo tail -n 2 /var/log/suricata/eve.json 2>/dev/null || echo "Не удалось прочитать файл"
echo ""

echo "=== 12. Проверка файрвола ==="
if command -v ufw &> /dev/null; then
    echo "UFW статус для порта 5636:"
    sudo ufw status | grep 5636 || echo "Порт 5636 не открыт в UFW"
else
    echo "UFW не установлен"
fi
echo "Проверка iptables для порта 5636:"
sudo iptables -L INPUT -n -v | grep 5636 || echo "Правило для порта 5636 не найдено в iptables"
echo ""

echo "=== 13. Попытка ручного запуска EveBox (тест) ==="
echo "Команда, которая должна использоваться:"
cat /etc/systemd/system/evebox.service.d/override.conf 2>/dev/null | grep ExecStart || echo "Не найдено"
echo ""

echo "=========================================="
echo "Диагностика завершена"
echo "=========================================="
