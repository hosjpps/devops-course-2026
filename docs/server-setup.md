# Конфигурация виртуальной машины devops-vm

Документ описывает сервер так, чтобы его можно было восстановить со снимка `01-clean-install`
только по этому тексту. Команды с пометкой **[VM]** выполняются на сервере, **[Хост]** — на MacBook.
Порядок разделов совпадает с порядком восстановления.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Средство виртуализации | VirtualBox 7.1 (macOS, Apple Silicon) |
| Имя ВМ | `devops-vm` |
| Гостевая ОС | Ubuntu Server 24.04 LTS (arm64), без minimized, без snaps |
| Оперативная память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ, динамически расширяемый |
| Имя узла / FQDN | `devops-vm` / `devops-vm.devops.local` |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс в ВМ | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | `enp0s8` | `10.0.2.15/24` (DHCP VirtualBox) | доступ в Интернет (apt), SSH с хоста через проброс порта |
| 2 | Host-only (`HostNetwork`, хост `192.168.56.1`) | `enp0s9` | `192.168.56.101/24` (DHCP) | прямой доступ с хоста: SSH, HTTP/HTTPS по имени `devops.local` |

Оба адаптера настраиваются до первого запуска. Адрес Host-only выдаётся по DHCP — после
восстановления сверить командой `ip -brief address` и при необходимости поправить `/etc/hosts` хоста.

## 3. Правило проброса портов

| Имя | Протокол | Адрес хоста | Порт хоста | Порт гостя |
|---|---|---|---|---|
| `ssh` | TCP | 127.0.0.1 | 2222 | 2222 (до hardening — 22) |

**[Хост]** изменение правила без GUI (ВМ запущена):

```bash
VBoxManage controlvm devops-vm natpf1 delete ssh
VBoxManage controlvm devops-vm natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Пользователь | Группы | Аутентификация |
|---|---|---|
| `student` | `student`, `sudo` (создан установщиком) | только консоль ВМ; по SSH вход запрещён (`AllowUsers devops`) |
| `devops` | `devops`, `sudo`, `users` | SSH только по ключу `~/.ssh/devops_vm` (ed25519); пароль — для `sudo` |
| `root` | — | вход по SSH запрещён (`PermitRootLogin no`) |

**[VM]** (через консоль или `ssh student@127.0.0.1 -p 2222` до hardening):

```bash
sudo adduser devops                 # пароль задать, остальные поля — Enter
sudo usermod -aG sudo devops
groups devops                       # devops : devops sudo users
```

**[Хост]** ключ и клиентская конфигурация:

```bash
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm     # если ключа ещё нет
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

`~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Права на сервере: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600 (иначе sshd молча отклоняет ключ,
в журнале — `bad ownership or modes`). Отпечаток ключа хоста при первом подключении сверять с
`sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` в консоли ВМ.

## 5. Служба SSH

Основной `/etc/ssh/sshd_config` не изменяется (копия — `/etc/ssh/sshd_config.backup`).
Настройки — в дополняющем файле `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

В `/etc/ssh/sshd_config.d/50-cloud-init.conf` строка `PasswordAuthentication yes` закомментирована:
файлы читаются по алфавиту, действует первое значение директивы, поэтому `50-` перекрывал бы `99-`.

**[VM]** порядок применения (текущую SSH-сессию не закрывать, проверять новым подключением):

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf          # содержимое выше
sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' \
     /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo sshd -t && echo "Конфигурация корректна"
sudo systemctl disable --now ssh.socket     # иначе сокет держит порт 22 и Port игнорируется
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd                   # 0.0.0.0:2222 и [::]:2222
```

Затем на хосте — правило проброса из раздела 3 (порт гостя 2222) и проверка `ssh devops`.
Действующие значения смотреть через `sudo sshd -T`, а не по файлам.

## 6. Правила межсетевого экрана

Политики: `deny (incoming)`, `allow (outgoing)`, `deny (routed)`. Журналирование — `medium`.

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp | LIMIT IN (v4, v6) | SSH rate-limited: ≥6 соединений за 30 с с одного адреса — блок |
| 80/tcp | ALLOW IN (v4, v6) | HTTP |
| 443/tcp | ALLOW IN (v4, v6) | HTTPS |

**[VM]** порядок важен — разрешающее правило для SSH создаётся **до** `ufw enable`:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable                              # y
sudo ufw logging medium
sudo ufw status verbose
```

`ufw allow ssh` не использовать: имя `ssh` берётся из `/etc/services` и даёт порт 22.

**Имя узла.** **[VM]** `sudo hostnamectl set-hostname devops-vm`, в `/etc/hosts` ВМ строка
`127.0.1.1 devops-vm.devops.local devops-vm` (`hostname -f` → `devops-vm.devops.local`).
**[Хост]** в `/etc/hosts`: `192.168.56.101    devops.local`.

## 7. Снимки состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| `01-clean-install` | 27.10.2026 21:40 | чистая установка, `apt upgrade`, ВМ выключена |
| `02-keys-configured` | 28.10.2026 10:24 | пользователь `devops`, вход по ключу, `~/.ssh/config` |
| `03-ssh-hardened` | 28.10.2026 10:51 | `99-hardening.conf`, порт 2222, проброс 2222 → 2222 |
| `04-nginx-https` | 28.10.2026 13:52 | Nginx, ресурс `devops.local` по HTTPS, перенаправление с HTTP |
| `05-docker-compose` | 28.10.2026 15:12 | Docker Engine, проект `~/app` (app + db), том с данными |

**[Хост]** список снимков: `VBoxManage snapshot devops-vm list`.

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` из репозитория Ubuntu 24.04 (1.24.0), `sudo apt install -y nginx` |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `/etc/nginx/sites-enabled/`; ссылка `default` удалена (файл сохранён) |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталоги 755, файлы 644 |
| Содержимое | каталог `site/` репозитория, доставка `scripts/deploy.sh` (rsync `--delete --chmod=D755,F644`) |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, 644, самоподписанный, SAN `DNS:devops.local` |
| Ключ | `/etc/ssl/private/devops.key`, `root:root`, 600, RSA 2048 |
| Срок действия | 365 дней с 28.10.2026 (до 28.10.2027) |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` |

**[VM]** установка, каталог, сертификат:

```bash
sudo apt update && sudo apt install -y nginx rsync
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

**[VM]** `/etc/nginx/sites-available/devops-site`:

```nginx
# Блок 1: перенаправление HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}

# Блок 2: ресурс по HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;
    access_log /var/log/nginx/devops-site.access.log;
    error_log /var/log/nginx/devops-site.error.log;
}
```

```bash
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx     # только reload, не restart
```

HSTS не включать: браузер запомнит требование доверенного сертификата и перестанет пускать на
ресурс с самоподписанным.

**[Хост]** доверие к сертификату и доставка:

```bash
scp devops:/etc/ssl/certs/devops.crt ~/devops.crt
brew install rsync          # штатный rsync macOS 26 — openrsync, не понимает --chmod=D755,F644
scripts/deploy.sh --dry-run && scripts/deploy.sh
```

Снимок после настройки: `04-nginx-https` (28.10.2026 13:52).

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Docker Engine | 28.5.2, пакеты `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` из `download.docker.com` (не `docker.io`) |
| Docker Compose | плагин v2.40.3 (`docker compose`) |
| Группа `docker` | только `devops` (у него и так есть `sudo`: участник `docker` фактически равен root) |
| Проект на сервере | `/home/devops/app` (`~/app`), доставка из каталога `app/` репозитория через rsync |
| Файл `.env` | `/home/devops/app/.env`, владелец `devops`, права 600, только на сервере, в git не попадает |
| Сервисы | `app` (образ `devops-app:1.0`, процесс от пользователя `app`), `db` (`postgres:16-alpine`) |
| Публикуемые порты | `127.0.0.1:5000 → app:5000`; порт СУБД 5432 не публикуется |
| Сеть | `app_backend` (bridge), приложение обращается к СУБД по имени `db` |
| Том | `app_db_data` → `/var/lib/postgresql/data`; `docker compose down -v` его удаляет |
| Обратный прокси | `https://devops.local/app/` → `http://127.0.0.1:5000/` |

**[VM]** установка Docker Engine (официальная инструкция):

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops      # затем переподключиться по SSH
docker run --rm hello-world
```

**[Хост]** доставка проекта (`.env` исключается, иначе `--delete` удалит его на сервере):

```bash
rsync -avz --delete --exclude=.env app/ devops:app/
```

**[VM]** секреты и запуск:

```bash
cd ~/app
cp .env.example .env && chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
docker compose ps                   # db — (healthy)
```

**[VM]** в блок `server { listen 443 ssl; ... }` файла `/etc/nginx/sites-available/devops-site`:

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Публиковать порты только на `127.0.0.1`: Docker добавляет DNAT-правила в свои цепочки iptables,
и порт на `0.0.0.0` доступен из сети в обход UFW.
