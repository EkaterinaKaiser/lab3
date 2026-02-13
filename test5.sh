#!/bin/bash
set -e

# Функция для обработки ошибок
handle_error() {
    echo "Ошибка на строке $1"
    exit 1
}
trap 'handle_error $LINENO' ERR

echo "=== Шаг 1: Подготовка окружения в контейнере attacker ==="
echo "Проверка наличия Java и jenkins-cli.jar..."

# Проверяем наличие Java
if ! docker exec attacker bash -c "command -v java > /dev/null 2>&1"; then
    echo "Java не установлена, устанавливаем..."
    docker exec attacker bash -c "apt update -qq && apt install -y openjdk-11-jre"
fi

# Скачиваем jenkins-cli.jar в /tmp (где будет запускаться скрипт)
if ! docker exec attacker bash -c "test -f /tmp/jenkins-cli.jar"; then
    echo "Скачивание jenkins-cli.jar в /tmp..."
    docker exec attacker bash -c "cd /tmp && wget -q http://172.20.0.105:8080/jnlpJars/jenkins-cli.jar -O jenkins-cli.jar" || echo "Не удалось скачать jenkins-cli.jar"
    if docker exec attacker bash -c "test -f /tmp/jenkins-cli.jar"; then
        echo "jenkins-cli.jar успешно скачан"
    else
        echo "Ошибка: не удалось скачать jenkins-cli.jar"
        exit 1
    fi
else
    echo "jenkins-cli.jar уже существует в /tmp"
fi

echo "Окружение подготовлено"

echo ""
echo "=== Шаг 2: Копирование jenkins_exploit.py в контейнер ==="
# Копируем jenkins_exploit.py в контейнер (файл должен быть на хосте)
if [ -f jenkins_exploit.py ]; then
    docker cp jenkins_exploit.py attacker:/tmp/jenkins_exploit.py
    docker exec attacker bash -c "chmod +x /tmp/jenkins_exploit.py"
    echo "jenkins_exploit.py скопирован в контейнер"
else
    echo "Ошибка: файл jenkins_exploit.py не найден на хосте"
    exit 1
fi

echo ""
echo "=== Шаг 3: Запуск эксплуатации CVE-2024-23897 ==="
echo "Эксплуатация Jenkins Arbitrary File Read на 172.20.0.105:8080..."
echo ""

# Запускаем эксплойт и выводим результат
docker exec attacker bash -c "cd /tmp && python3 jenkins_exploit.py http://172.20.0.105:8080/"

echo ""
echo "=== Шаг 4: Проверка результата эксплуатации ==="
echo "Проверка созданных файлов в контейнере attacker..."
docker exec attacker bash -c "ls -lh /tmp/*.txt 2>/dev/null | head -10" || echo "Файлы не найдены"

echo ""
echo "=== Шаг 5: Поиск алертов Suricata по правилам Jenkins ==="
echo "Ожидание обработки событий Suricata..."
sleep 5

# Массив SID правил Jenkins
JENKINS_SIDS=(3000501 3000502)
# Массив имен правил
JENKINS_RULE_NAMES=(
    "Jenkins Web Interface Access"
    "Jenkins CLI JAR Download"
)

# Проверка наличия eve.json
if sudo test -f /var/log/suricata/eve.json; then
    echo "Поиск алертов Suricata в /var/log/suricata/eve.json..."
    echo ""
    
    # Вывод всех алертов (последние записи)
    echo "Последние алерты Suricata (Jenkins правила):"
    sudo tail -n 200 /var/log/suricata/eve.json 2>/dev/null | jq -r 'select(.event_type=="alert" and (.alert.signature_id >= 3000501 and .alert.signature_id <= 3000502)) | "\(.timestamp) [SID:\(.alert.signature_id)] \(.alert.signature) | \(.src_ip):\(.src_port) -> \(.dest_ip):\(.dest_port)"' 2>/dev/null | tail -20 || echo "Не удалось прочитать алерты"
    
    echo ""
    echo "Поиск алертов по правилам Jenkins (SID 3000501-3000502)..."
    echo ""
    
    # Поиск алертов по каждому правилу Jenkins
    found_alerts=0
    for i in "${!JENKINS_SIDS[@]}"; do
        sid=${JENKINS_SIDS[$i]}
        rule_name=${JENKINS_RULE_NAMES[$i]}
        
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
        echo "[!] Алерты по правилам Jenkins не найдены"
        echo "    Проверьте, что Suricata обрабатывает трафик и правила активны"
    else
        echo "Всего найдено правил с алертами: ${found_alerts} из ${#JENKINS_SIDS[@]}"
    fi
    
    # Общая статистика по Jenkins алертам
    echo ""
    echo "Общая статистика по Jenkins алертам:"
    total_jenkins_alerts=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -s "[.[] | select(.event_type==\"alert\" and (.alert.signature_id >= 3000501 and .alert.signature_id <= 3000502))] | length" 2>/dev/null || echo "0")
    total_jenkins_alerts=$(echo "$total_jenkins_alerts" | tr -d '\n\r ' | head -1)
    echo "Всего алертов Jenkins: ${total_jenkins_alerts}"
    
else
    echo "[!] Файл /var/log/suricata/eve.json не найден или недоступен"
    echo "    Проверьте статус Suricata: sudo systemctl status suricata"
fi

echo ""
echo "=== Тест завершен ==="
