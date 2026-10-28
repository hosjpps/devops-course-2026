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
| 2 | Host-only (`vboxnet0`, хост `192.168.56.1`) | `enp0s9` | `192.168.56.101/24` (DHCP) | прямой доступ с хоста: SSH, HTTP/HTTPS по имени `devops.local` |

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
| `devops` | `devops`, `sudo` | SSH только по ключу `~/.ssh/devops_vm` (ed25519); пароль — для `sudo` |
| `root` | — | вход по SSH запрещён (`PermitRootLogin no`) |

**[VM]** (через консоль или `ssh student@127.0.0.1 -p 2222` до hardening):

```bash
sudo adduser devops                 # пароль задать, остальные поля — Enter
sudo usermod -aG sudo devops
groups devops                       # devops : devops sudo
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

**[Хост]** список снимков: `VBoxManage snapshot devops-vm list`.
