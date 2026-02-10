#!/bin/bash
set -e

# Установка базовых утилит и Docker
sudo apt-get update -qq
sudo apt-get install -y docker.io curl jq iptables-persistent libnetfilter-queue1
sudo systemctl enable --now docker

# Bridge netfilter setup
sudo modprobe br_netfilter
echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf >/dev/null
cat <<'EOT' | sudo tee /etc/sysctl.d/99-bridge-nf.conf >/dev/null
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOT
sudo sysctl -p /etc/sysctl.d/99-bridge-nf.conf

# Установка Suricata
sudo add-apt-repository ppa:oisf/suricata-stable -y
sudo apt update
sudo apt install -y suricata

# Создание директории для правил
sudo mkdir -p /etc/suricata/rules
sudo mkdir -p /var/log/suricata

# Копирование suricata.yaml
SURICATA_CONFIG=""
if [ -f suricata/suricata.yaml ]; then
    SURICATA_CONFIG="suricata/suricata.yaml"
elif [ -f suricata.yaml ]; then
    SURICATA_CONFIG="suricata.yaml"
else
    echo "Ошибка: файл suricata.yaml не найден (проверены пути: suricata/suricata.yaml и suricata.yaml)"
    exit 1
fi
sudo cp "$SURICATA_CONFIG" /etc/suricata/suricata.yaml

# Создание правил Suricata
cat > /etc/suricata/rules/local.rules <<'EORULES'
# Обнаружение ActiveMQ подключений
alert tcp any any -> any 61616 (msg:"[IDS] Apache ActiveMQ Connection Detected"; flow:to_server,established; threshold: type limit, track by_src, count 1, seconds 300; classtype:policy-violation; sid:3000001; rev:1;)

# Обнаружение OpenWire протокола
alert tcp any any -> any 61616 (msg:"[IDS] ActiveMQ OpenWire Protocol Detected"; flow:to_server,established; content:"OpenWire"; nocase; classtype:policy-violation; sid:3000002; rev:1;)

# Обнаружение Java десериализации (ProcessBuilder)
alert tcp any any -> any 61616 (msg:"[IDS] ActiveMQ Java Deserialization CVE-2023-46604"; flow:to_server,established; content:"ProcessBuilder"; nocase; classtype:attempted-admin; sid:3000003; rev:1;)

# Блокировка подозрительных ActiveMQ запросов
drop tcp any any -> any 61616 (msg:"[IPS] ActiveMQ Exploit Attempt Blocked"; flow:to_server,established; content:"ClassPathXmlApplicationContext"; nocase; threshold: type limit, track by_src, count 1, seconds 60; classtype:attempted-admin; sid:3000004; rev:1;)

# Обнаружение Spring Beans в трафике
alert tcp any any -> any 61616 (msg:"[IDS] ActiveMQ Spring Beans Configuration Detected"; flow:to_server,established; content:"<beans"; nocase; classtype:attempted-admin; sid:3000005; rev:1;)

# Обнаружение Redis подключений
alert tcp any any -> any 6379 (msg:"[IDS] Redis Unauthorized Access Detected"; flow:to_server,established; threshold: type limit, track by_src, count 1, seconds 300; classtype:policy-violation; sid:3000101; rev:1;)

# Обнаружение config команд
alert tcp any any -> any 6379 (msg:"[IDS] Redis CONFIG Command Detected"; flow:to_server,established; content:"config"; nocase; classtype:attempted-admin; sid:3000102; rev:1;)

# Обнаружение команды SAVE
alert tcp any any -> any 6379 (msg:"[IDS] Redis SAVE Command Detected"; flow:to_server,established; content:"save"; nocase; classtype:attempted-admin; sid:3000103; rev:1;)

# Блокировка подозрительных Redis операций
drop tcp any any -> any 6379 (msg:"[IPS] Redis Dangerous Operation Blocked"; flow:to_server,established; content:"config set dir"; nocase; threshold: type limit, track by_src, count 1, seconds 60; classtype:attempted-admin; sid:3000104; rev:1;)

# Обнаружение попыток записи веб-шелла
alert tcp any any -> any 6379 (msg:"[IDS] Redis Web Shell Upload Attempt"; flow:to_server,established; content:"<?php"; nocase; classtype:trojan-activity; sid:3000105; rev:1;)

# Обнаружение манипуляций с dbfilename
alert tcp any any -> any 6379 (msg:"[IDS] Redis DBFilename Manipulation"; flow:to_server,established; content:"dbfilename"; nocase; classtype:attempted-admin; sid:3000106; rev:1;)

# Обнаружение команды FLUSHALL
alert tcp any any -> any 6379 (msg:"[IDS] Redis FLUSHALL Command Detected"; flow:to_server,established; content:"flushall"; nocase; classtype:attempted-admin; sid:3000107; rev:1;)

# Обнаружение множественных операций (brute-force/scan)
alert tcp any any -> any 6379 (msg:"[IDS] Redis Multiple Operations Detected"; flow:to_server,established; threshold: type threshold, track by_src, count 20, seconds 60; classtype:attempted-recon; sid:3000108; rev:1;)

# Обнаружение CVE-2023-28432 Bootstrap Verify запроса
alert http any any -> any 9000 (msg:"[IDS] MinIO CVE-2023-28432 Bootstrap Verify Request"; flow:to_server,established; http_uri; content:"/minio/bootstrap/v1/verify"; http_method; content:"POST"; classtype:attempted-admin; sid:3000201; rev:1;)

# Блокировка CVE-2023-28432 эксплуатации
drop http any any -> any 9000 (msg:"[IPS] MinIO CVE-2023-28432 Exploitation Blocked"; flow:to_server,established; http_uri; content:"/minio/bootstrap/v1/verify"; http_method; content:"POST"; threshold: type limit, track by_src, count 1, seconds 3600; classtype:attempted-admin; sid:3000202; rev:1;)

# Обнаружение MinIO admin API запросов
alert http any any -> any 9000 (msg:"[IDS] MinIO Admin API Request Detected"; flow:to_server,established; http_uri; content:"/minio/admin"; classtype:attempted-admin; sid:3000203; rev:1;)

# Обнаружение S3 API операций
alert http any any -> any 9000 (msg:"[IDS] MinIO S3 API Operation Detected"; flow:to_server,established; http_header; content:"aws4_request"; classtype:policy-violation; sid:3000204; rev:1;)

# Обнаружение создания bucket'ов
alert http any any -> any 9000 (msg:"[IDS] MinIO Bucket Creation Detected"; flow:to_server,established; http_method; content:"PUT"; classtype:policy-violation; sid:3000205; rev:1;)

# Обнаружение подозрительных имен bucket'ов
alert http any any -> any 9000 (msg:"[IDS] MinIO Suspicious Bucket Name"; flow:to_server,established; http_uri; pcre:"/\/(hack|exploit|malware|backdoor|pwned|compromised|cve)/i"; classtype:trojan-activity; sid:3000206; rev:1;)

# Обнаружение консольного доступа
alert http any any -> any 9001 (msg:"[IDS] MinIO Console Access Detected"; flow:to_server,established; threshold: type limit, track by_src, count 1, seconds 300; classtype:policy-violation; sid:3000207; rev:1;)

# Блокировка множественных S3 операций
drop http any any -> any 9000 (msg:"[IPS] MinIO Excessive S3 Operations Blocked"; flow:to_server,established; threshold: type both, track by_src, count 50, seconds 60; classtype:attempted-dos; sid:3000208; rev:1;)

# SMB соединения
alert tcp any any -> any 445 (msg:"[IDS] SMB Connection Detected"; flow:to_server,established; threshold: type limit, track by_src, count 1, seconds 300; classtype:policy-violation; sid:3000301; rev:1;)

# Загрузка .so через SMB (попытка записи библиотек)
alert tcp any any -> any 445 (msg:"[IDS] SMB Shared Library Upload"; flow:to_server,established; content:".so"; classtype:trojan-activity; sid:3000302; rev:1;)

# Блокировка известных артефактов SambaCry (имя библиотеки по умолчанию)
drop tcp any any -> any 445 (msg:"[IPS] SambaCry Library Upload Blocked"; flow:to_server,established; content:"libbindshell-samba.so"; threshold: type limit, track by_src, count 1, seconds 3600; classtype:attempted-admin; sid:3000303; rev:1;)

# Подключение к bind shell на 6699
alert tcp any any -> any 6699 (msg:"[IDS] SambaCry Bind Shell Connection"; flow:to_server; threshold: type limit, track by_src, count 1, seconds 60; classtype:trojan-activity; sid:3000304; rev:1;)

# Множественные SMB операции (возможная эксплуатация/брут/скан)
alert tcp any any -> any 445 (msg:"[IDS] SMB Multiple File Operations"; flow:to_server,established; threshold: type threshold, track by_src, count 15, seconds 30; classtype:attempted-recon; sid:3000305; rev:1;)

# Запись в конкретную шару myshare
alert tcp any any -> any 445 (msg:"[IDS] SMB Write to myshare"; flow:to_server,established; content:"myshare"; nocase; classtype:policy-violation; sid:3000306; rev:1;)

# Обнаружение доступа к Jenkins
alert http any any -> any 8080 (msg:"[IDS] Jenkins Web Interface Access"; flow:to_server,established; http_uri; content:"/"; threshold: type limit, track by_src, count 1, seconds 300; classtype:policy-violation; sid:3000501; rev:1;)

# Обнаружение загрузки jenkins-cli.jar
alert http any any -> any 8080 (msg:"[IDS] Jenkins CLI JAR Download"; flow:to_server,established; http_uri; content:"jenkins-cli.jar"; classtype:attempted-recon; sid:3000502; rev:1;)

# Обнаружение Jenkins CLI операций (по User-Agent)
alert http any any -> any 8080 (msg:"[IDS] Jenkins CLI Command Execution"; flow:to_server,established; http_user_agent; content:"Jenkins CLI"; classtype:attempted-admin; sid:3000503; rev:1;)

# Блокировка CVE-2024-23897 эксплуатации (символ @ в запросах)
drop http any any -> any 8080 (msg:"[IPS] Jenkins CVE-2024-23897 File Read Blocked"; flow:to_server,established; http_request_body; content:"@/"; threshold: type limit, track by_src, count 1, seconds 3600; classtype:attempted-admin; sid:3000504; rev:1;)

# Обнаружение попыток чтения системных файлов
alert http any any -> any 8080 (msg:"[IDS] Jenkins System File Access"; flow:to_server,established; http_request_body; pcre:"/@\/(etc|proc|var)/"; classtype:attempted-admin; sid:3000505; rev:1;)

# Обнаружение попыток чтения секретов Jenkins
alert http any any -> any 8080 (msg:"[IDS] Jenkins Secret File Access"; flow:to_server,established; http_request_body; content:"@/var/jenkins_home/secret"; classtype:attempted-admin; sid:3000506; rev:1;)

# Обнаружение множественных Jenkins CLI операций
alert http any any -> any 8080 (msg:"[IDS] Jenkins CLI Multiple Operations"; flow:to_server,established; http_uri; content:"/cli"; threshold: type threshold, track by_src, count 10, seconds 60; classtype:attempted-recon; sid:3000507; rev:1;)

# Обнаружение доступа к JNLP порту (50000)
alert tcp any any -> any 50000 (msg:"[IDS] Jenkins JNLP Port Access"; flow:to_server,established; threshold: type limit, track by_src, count 1, seconds 300; classtype:policy-violation; sid:3000508; rev:1;)

# Обнаружение доступа к debug порту (5005)
alert tcp any any -> any 5005 (msg:"[IDS] Jenkins Debug Port Access"; flow:to_server,established; threshold: type limit, track by_src, count 1, seconds 300; classtype:attempted-admin; sid:3000509; rev:1;)

# Обнаружение HTTP POST к CLI endpoint
alert http any any -> any 8080 (msg:"[IDS] Jenkins CLI HTTP POST"; flow:to_server,established; http_method; content:"POST"; http_uri; content:"/cli"; classtype:attempted-admin; sid:3000510; rev:1;)

# Блокировка агрессивного сканирования Jenkins
drop http any any -> any 8080 (msg:"[IPS] Jenkins Aggressive Scanning Blocked"; flow:to_server,established; threshold: type both, track by_src, count 50, seconds 120; classtype:attempted-dos; sid:3000511; rev:1;)

# Обнаружение reverse shell паттернов
alert tcp any any -> any any (msg:"[IDS] Reverse Shell Pattern /bin/sh Detected"; flow:established; content:"/bin/sh"; nocase; classtype:trojan-activity; sid:3000601; rev:1;)

alert tcp any any -> any any (msg:"[IDS] Reverse Shell Pattern /bin/bash Detected"; flow:established; content:"/bin/bash"; nocase; classtype:trojan-activity; sid:3000602; rev:1;)

alert tcp any any -> any any (msg:"[IDS] Netcat Reverse Shell Detected"; flow:established; content:"nc -e"; nocase; classtype:trojan-activity; sid:3000603; rev:1;)

# Обнаружение Meterpreter трафика
alert tcp any any -> any any (msg:"[IDS] Meterpreter Session Detected"; flow:established; content:"meterpreter"; nocase; classtype:trojan-activity; sid:3000604; rev:1;)

alert tcp any any -> any 4444 (msg:"[IDS] Connection to Metasploit Port 4444"; flow:to_server; threshold: type limit, track by_dst, count 1, seconds 60; classtype:trojan-activity; sid:3000605; rev:1;)

alert tcp any any -> any 4445 (msg:"[IDS] Connection to Metasploit Port 4445"; flow:to_server; threshold: type limit, track by_dst, count 1, seconds 60; classtype:trojan-activity; sid:3000606; rev:1;)

# Обнаружение base64 encoded payload
alert tcp any any -> any any (msg:"[IDS] Base64 Encoded Command Execution"; flow:established; content:"base64"; nocase; content:"exec"; nocase; classtype:trojan-activity; sid:3000607; rev:1;)

# Обнаружение Python reverse shell
alert tcp any any -> any any (msg:"[IDS] Python Reverse Shell Detected"; flow:established; content:"python"; nocase; content:"socket"; nocase; classtype:trojan-activity; sid:3000608; rev:1;)

# Обнаружение cron-based persistence
alert tcp any any -> any any (msg:"[IDS] Cron-based Persistence Attempt"; flow:established; content:"crontab"; nocase; classtype:trojan-activity; sid:3000609; rev:1;)

EORULES

# NFQUEUE for Docker traffic
sudo iptables -D DOCKER-USER -j NFQUEUE --queue-num 1 --queue-bypass 2>/dev/null || true
sudo iptables -I DOCKER-USER -j NFQUEUE --queue-num 1 --queue-bypass
sudo netfilter-persistent save

# Настройка Suricata
setcap cap_net_admin,cap_net_raw+ep /usr/bin/suricata
mkdir -p /etc/systemd/system/suricata.service.d
cat > /etc/systemd/system/suricata.service.d/override.conf <<'EOSERVICE'
[Service]
ExecStart=
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml -q 1 --pidfile /run/suricata.pid
EOSERVICE

# Запуск Suricata
systemctl daemon-reload
systemctl enable suricata
systemctl restart suricata
systemctl status suricata --no-pager

sudo apt-get install curl
curl -fsSL https://evebox.org/files/GPG-KEY-evebox -o /etc/apt/keyrings/evebox.asc
echo "deb [signed-by=/etc/apt/keyrings/evebox.asc] https://evebox.org/files/debian stable main" | sudo tee /etc/apt/sources.list.d/evebox.list
sudo apt-get update
sudo apt-get install evebox

sudo usermod -a -G suricata evebox

# EveBox: читать события напрямую из eve.json (SQLite + файл логов Suricata)
sudo tee /etc/default/evebox > /dev/null <<'EOEVEBOX'
EVEBOX_OPTS="--database sqlite /var/log/suricata/eve.json"
EOEVEBOX

# Права на чтение логов Suricata для пользователя evebox
sudo chown -R root:suricata /var/log/suricata
sudo chmod 750 /var/log/suricata
sudo touch /var/log/suricata/eve.json
sudo chmod 640 /var/log/suricata/eve.json

sudo systemctl daemon-reload
sudo systemctl restart evebox
sudo systemctl enable evebox
