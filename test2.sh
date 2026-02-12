#!/bin/bash
set -e

# Функция для обработки ошибок
handle_error() {
    echo "Ошибка на строке $1"
    exit 1
}
trap 'handle_error $LINENO' ERR

echo "=== Шаг 1: Создание виртуального окружения Python в контейнере attacker ==="
docker exec attacker bash -c "cd /root && python3 -m venv venv"
echo "Виртуальное окружение создано"

echo ""
echo "=== Шаг 2: Активация виртуального окружения и установка зависимостей ==="
docker exec attacker bash -c "cd /root && source venv/bin/activate && pip3 install redis"
echo "Зависимости установлены"

echo ""
echo "=== Шаг 3: Копирование файла redis_attack.py в контейнер attacker ==="
if [ ! -f redis_attack.py ]; then
    echo "Ошибка: файл redis_attack.py не найден в текущей директории"
    exit 1
fi
docker cp redis_attack.py attacker:/root/redis_attack.py
docker exec attacker chmod +x /root/redis_attack.py
# Проверка синтаксиса Python перед запуском
echo "Проверка синтаксиса Python файла..."
docker exec attacker bash -c "cd /root && python3 -m py_compile redis_attack.py" && echo "Синтаксис корректен" || echo "Ошибка синтаксиса!"
echo "Файл redis_attack.py скопирован и сделан исполняемым"

echo ""
echo "=== Шаг 4: Инициализация тестовых данных в Redis ==="
echo "Добавление тестовых данных (конфиденциальная информация) в Redis..."
# Используем Python для добавления данных, так как redis-cli может быть недоступен
docker exec attacker bash -c "cd /root && source venv/bin/activate && python3 << 'PYEOF'
import redis
r = redis.Redis(host='172.20.0.102', port=6379, decode_responses=True)
r.set('api_key', 'secret_api_key_12345')
r.set('user:admin:password', 'admin123')
r.set('user:guest:password', 'guest456')
r.set('credit_card', '4111-1111-1111-1111')
print('Тестовые данные добавлены в Redis')
PYEOF
" || echo "Ошибка при добавлении тестовых данных"

echo ""
echo "=== Шаг 5: Запуск атаки на Redis ==="
docker exec attacker bash -c "cd /root && source venv/bin/activate && python3 redis_attack.py 172.20.0.102 6379"
echo ""

echo "=== Шаг 6: Проверка результата атаки ==="
echo "Проверка файла /tmp/redis_test.txt в контейнере victim-redis:"
if docker exec victim-redis test -f /tmp/redis_test.txt 2>/dev/null; then
    echo "Файл найден!"
    docker exec victim-redis ls -la /tmp/redis_test.txt 2>/dev/null || true
    echo "Содержимое файла (первые 100 байт):"
    docker exec victim-redis head -c 100 /tmp/redis_test.txt 2>/dev/null || echo "Не удалось прочитать файл"
else
    echo "Файл не найден (это нормально, если Redis не сохранил данные)"
fi

echo ""
echo "=== Шаг 7: Поиск алертов Suricata по правилам Redis ==="
echo "Ожидание обработки событий Suricata..."
sleep 5

# Массив SID правил Redis
REDIS_SIDS=(3000101 3000102 3000103 3000104 3000105 3000106 3000107 3000108)
# Массив имен правил
REDIS_RULE_NAMES=(
    "Redis Unauthorized Access Detected"
    "Redis CONFIG Command Detected"
    "Redis SAVE Command Detected"
    "Redis Dangerous Operation Blocked"
    "Redis Web Shell Upload Attempt"
    "Redis DBFilename Manipulation"
    "Redis FLUSHALL Command Detected"
    "Redis Multiple Operations Detected"
)

# Проверка наличия eve.json
if sudo test -f /var/log/suricata/eve.json; then
    echo "Поиск алертов Suricata в /var/log/suricata/eve.json..."
    echo ""
    
    # Поиск алертов по каждому правилу
    found_alerts=0
    for i in "${!REDIS_SIDS[@]}"; do
        sid=${REDIS_SIDS[$i]}
        rule_name=${REDIS_RULE_NAMES[$i]}
        
        # Поиск алертов с данным SID
        alert_count=$(sudo jq -r "[select(.event_type==\"alert\" and .alert.signature_id==${sid})] | length" /var/log/suricata/eve.json 2>/dev/null || echo "0")
        
        if [ "$alert_count" != "0" ] && [ "$alert_count" != "null" ]; then
            found_alerts=$((found_alerts + 1))
            echo "[✓] Найдено алертов для правила SID ${sid}: ${alert_count}"
            echo "    Правило: ${rule_name}"
            
            # Вывод деталей последнего алерта
            last_alert=$(sudo jq -r "select(.event_type==\"alert\" and .alert.signature_id==${sid}) | ." /var/log/suricata/eve.json 2>/dev/null | tail -n 1)
            if [ -n "$last_alert" ] && [ "$last_alert" != "null" ]; then
                timestamp=$(echo "$last_alert" | jq -r '.timestamp // "N/A"' 2>/dev/null)
                src_ip=$(echo "$last_alert" | jq -r '.src_ip // "N/A"' 2>/dev/null)
                dest_ip=$(echo "$last_alert" | jq -r '.dest_ip // "N/A"' 2>/dev/null)
                echo "    Последний алерт: ${timestamp}"
                echo "    Источник: ${src_ip} -> ${dest_ip}"
            fi
            echo ""
        fi
    done
    
    if [ $found_alerts -eq 0 ]; then
        echo "[!] Алерты по правилам Redis не найдены"
        echo "    Проверьте, что Suricata обрабатывает трафик и правила активны"
    else
        echo "Всего найдено правил с алертами: ${found_alerts} из ${#REDIS_SIDS[@]}"
    fi
    
    # Общая статистика по Redis алертам
    echo ""
    echo "Общая статистика по Redis алертам:"
    total_redis_alerts=$(sudo jq -r "[select(.event_type==\"alert\" and (.alert.signature_id >= 3000101 and .alert.signature_id <= 3000108))] | length" /var/log/suricata/eve.json 2>/dev/null || echo "0")
    echo "Всего алертов Redis: ${total_redis_alerts}"
    
else
    echo "[!] Файл /var/log/suricata/eve.json не найден или недоступен"
    echo "    Проверьте статус Suricata: sudo systemctl status suricata"
fi

echo ""
echo "=== Тест завершен ==="
