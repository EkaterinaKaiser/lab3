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
docker exec attacker bash -c "cd /root && source venv/bin/activate && pip3 install boto3 requests"
echo "Зависимости установлены"

echo ""
echo "=== Шаг 3: Копирование файла minio_cve_exploit.py в контейнер attacker ==="
if [ ! -f minio_cve_exploit.py ]; then
    echo "Ошибка: файл minio_cve_exploit.py не найден в текущей директории"
    exit 1
fi
docker cp minio_cve_exploit.py attacker:/root/minio_cve_exploit.py
docker exec attacker chmod +x /root/minio_cve_exploit.py
# Проверка синтаксиса Python перед запуском
echo "Проверка синтаксиса Python файла..."
docker exec attacker bash -c "cd /root && python3 -m py_compile minio_cve_exploit.py" && echo "Синтаксис корректен" || echo "Ошибка синтаксиса!"
echo "Файл minio_cve_exploit.py скопирован и сделан исполняемым"

echo ""
echo "=== Шаг 4: Инициализация тестовых данных в MinIO ==="
echo "Создание тестового bucket в MinIO..."
# Используем Python для создания тестового bucket с известными credentials
docker exec attacker bash -c "cd /root && source venv/bin/activate && python3 << 'PYEOF'
import boto3
try:
    s3_client = boto3.client(
        's3',
        endpoint_url='http://172.20.0.103:9000',
        aws_access_key_id='minioadmin',
        aws_secret_access_key='minioadmin-vulhub',
        region_name='us-east-1'
    )
    # Создание тестового bucket
    test_bucket = 'cve-2023-28432-pwned'
    try:
        s3_client.create_bucket(Bucket=test_bucket)
        print(f'[+] Создан тестовый bucket: {test_bucket}')
    except Exception as e:
        if 'BucketAlreadyOwnedByYou' in str(e) or 'BucketAlreadyExists' in str(e):
            print(f'[+] Bucket {test_bucket} уже существует')
        else:
            print(f'[-] Ошибка создания bucket: {e}')
    print('Тестовые данные добавлены в MinIO')
except Exception as e:
    print(f'Ошибка при добавлении тестовых данных: {e}')
PYEOF
" || echo "Ошибка при добавлении тестовых данных"

echo ""
echo "=== Шаг 5: Запуск эксплуатации CVE-2023-28432 на MinIO ==="
docker exec attacker bash -c "cd /root && source venv/bin/activate && python3 minio_cve_exploit.py http://172.20.0.103:9000"
echo ""

echo "=== Шаг 6: Проверка результата эксплуатации ==="
echo "Проверка созданного bucket в MinIO:"
docker exec attacker bash -c "cd /root && source venv/bin/activate && python3 << 'PYEOF'
import boto3
try:
    s3_client = boto3.client(
        's3',
        endpoint_url='http://172.20.0.103:9000',
        aws_access_key_id='minioadmin',
        aws_secret_access_key='minioadmin-vulhub',
        region_name='us-east-1'
    )
    buckets = s3_client.list_buckets()
    test_bucket = 'cve-2023-28432-exploit'
    bucket_names = [b['Name'] for b in buckets['Buckets']]
    if test_bucket in bucket_names:
        print(f'[+] Bucket {test_bucket} найден!')
        # Проверка содержимого
        objects = s3_client.list_objects_v2(Bucket=test_bucket)
        if 'Contents' in objects:
            for obj in objects['Contents']:
                print(f'    - {obj[\"Key\"]} (размер: {obj[\"Size\"]} байт)')
                # Чтение файла
                if obj['Key'] == 'exploitation_proof.txt':
                    content = s3_client.get_object(Bucket=test_bucket, Key=obj['Key'])
                    print('    Содержимое файла:')
                    print(content['Body'].read().decode('utf-8'))
    else:
        print(f'[-] Bucket {test_bucket} не найден')
except Exception as e:
    print(f'Ошибка при проверке: {e}')
PYEOF
" || echo "Ошибка при проверке результата"

echo ""
echo "=== Шаг 7: Поиск алертов Suricata по правилам MinIO ==="
echo "Ожидание обработки событий Suricata..."
sleep 5

# Массив SID правил MinIO
MINIO_SIDS=(3000201 3000202 3000203 3000204 3000205 3000206 3000207 3000208)
# Массив имен правил
MINIO_RULE_NAMES=(
    "MinIO CVE-2023-28432 Bootstrap Verify Request"
    "MinIO CVE-2023-28432 Exploitation Blocked"
    "MinIO Admin API Request Detected"
    "MinIO S3 API Operation Detected"
    "MinIO Bucket Creation Detected"
    "MinIO Suspicious Bucket Name"
    "MinIO Console Access Detected"
    "MinIO Excessive S3 Operations Blocked"
)

# Проверка наличия eve.json
if sudo test -f /var/log/suricata/eve.json; then
    echo "Поиск алертов Suricata в /var/log/suricata/eve.json..."
    echo ""
    
    # Вывод всех алертов (последние записи)
    echo "Последние алерты Suricata (все типы):"
    sudo tail -n 100 /var/log/suricata/eve.json 2>/dev/null | jq -r 'select(.event_type=="alert") | "\(.timestamp) [SID:\(.alert.signature_id)] \(.alert.signature) | \(.src_ip):\(.src_port) -> \(.dest_ip):\(.dest_port)"' 2>/dev/null | tail -20 || echo "Не удалось прочитать алерты"
    
    echo ""
    echo "Поиск алертов по правилам MinIO (SID 3000201-3000208)..."
    echo ""
    
    # Поиск алертов по каждому правилу MinIO
    found_alerts=0
    for i in "${!MINIO_SIDS[@]}"; do
        sid=${MINIO_SIDS[$i]}
        rule_name=${MINIO_RULE_NAMES[$i]}
        
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
        echo "[!] Алерты по правилам MinIO не найдены"
        echo "    Проверьте, что Suricata обрабатывает трафик и правила активны"
    else
        echo "Всего найдено правил с алертами: ${found_alerts} из ${#MINIO_SIDS[@]}"
    fi
    
    # Общая статистика по MinIO алертам
    echo ""
    echo "Общая статистика по MinIO алертам:"
    total_minio_alerts=$(sudo tail -n 1000 /var/log/suricata/eve.json 2>/dev/null | jq -r "[select(.event_type==\"alert\" and (.alert.signature_id >= 3000201 and .alert.signature_id <= 3000208))] | length" 2>/dev/null || echo "0")
    echo "Всего алертов MinIO: ${total_minio_alerts}"
    
else
    echo "[!] Файл /var/log/suricata/eve.json не найден или недоступен"
    echo "    Проверьте статус Suricata: sudo systemctl status suricata"
fi

echo ""
echo "=== Тест завершен ==="
