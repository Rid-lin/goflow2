# Улучшенный скрипт установки goflow2

Этот скрипт (`install-goflow2-alpine-enhanced.sh`) расширяет базовую установку goflow2, добавляя:

## Новые возможности

1. **Логирование и ротация логов**
   - Автоматическая настройка каталога логов `/var/log/goflow2`
   - Конфигурация logrotate для ротации логов (ежедневно, хранение 30 дней)
   - Раздельные логи вывода и ошибок

2. **Установка Docker и Docker Compose**
   - Автоматическая установка Docker и Docker Compose, если они не установлены
   - Настройка Docker для запуска при загрузке системы

3. **Развертывание TimescaleDB в контейнере**
   - Автоматическое развертывание TimescaleDB с помощью docker-compose
   - Настройка производительности и health checks
   - Создание сети Docker для изоляции

4. **Интеграция с Grafana**
   - Подробное руководство по подключению Grafana к TimescaleDB
   - Примеры SQL-запросов для визуализации данных потоков
   - Рекомендации по созданию пользователей только для чтения

5. **Улучшенная конфигурация**
   - Автоматическое создание файла `.env` с настройками по умолчанию
   - Скрипт-обертка для загрузки переменных окружения
   - Настройка сервиса OpenRC с перенаправлением логов

## Использование

```bash
# Скачайте скрипт
wget https://raw.githubusercontent.com/Rid-lin/goflow2/refs/heads/timescaledb-sourcecraft/scripts/install-goflow2-alpine-enhanced.sh

# Сделайте исполняемым
chmod +x install-goflow2-alpine-enhanced.sh

# Запустите с правами root
sudo ./install-goflow2-alpine-enhanced.sh
```

## Структура после установки

```
/opt/goflow2/
├── goflow2                    # Бинарный файл
├── goflow2-wrapper.sh         # Скрипт-обертка
├── .env                       # Конфигурация окружения
├── .env.example               # Пример конфигурации
├── docker-compose.timescaledb.yml # Конфигурация TimescaleDB
├── GRAFANA-CONNECTION.md      # Руководство по Grafana
└── timescaledb-data/          # Данные TimescaleDB (том Docker)

/var/log/goflow2/
├── output.log                 # Лог вывода
└── error.log                  # Лог ошибок
```

## Управление

### Сервис goflow2
```bash
# Статус
rc-service goflow2 status

# Перезапуск
rc-service goflow2 restart

# Логи
tail -f /var/log/goflow2/output.log
```

### TimescaleDB
```bash
# Перейти в каталог установки
cd /opt/goflow2

# Просмотр состояния
docker-compose -f docker-compose.timescaledb.yml ps

# Просмотр логов
docker-compose -f docker-compose.timescaledb.yml logs -f

# Остановка
docker-compose -f docker-compose.timescaledb.yml down

# Запуск
docker-compose -f docker-compose.timescaledb.yml up -d
```

## Настройка

1. **Редактирование конфигурации**:
   ```bash
   nano /opt/goflow2/.env
   ```

2. **Основные параметры**:
   - `DB_ADMIN_PASSWORD`: Пароль администратора PostgreSQL
   - `APP_USER` и `APP_PASSWORD`: Учетные данные для приложения goflow2
   - `DB_PORT`: Порт TimescaleDB (по умолчанию 5432)

3. **После изменения конфигурации**:
   ```bash
   rc-service goflow2 restart
   docker-compose -f /opt/goflow2/docker-compose.timescaledb.yml restart
   ```

## Подключение Grafana с отдельного хоста

Если Grafana установлена на отдельном сервере, необходимо настроить сетевой доступ и аутентификацию:

1. **Настройте брандмауэр** для разрешения порта 5432 на сервере с TimescaleDB

2. **Настройте аутентификацию PostgreSQL**:
   - Добавьте запись в `pg_hba.conf` для вашей подсети
   - Создайте отдельного пользователя для Grafana с правами только на чтение

3. **В Grafana укажите**:
   - Host: IP-адрес сервера с TimescaleDB
   - Port: 5432 (или указанный в DB_PORT)
   - Database: goflow2
   - User/Password: созданные учетные данные

**Важно**: TimescaleDB по умолчанию слушает на всех интерфейсах (0.0.0.0:5432), но PostgreSQL ограничивает доступ через pg_hba.conf. Основная задача - настроить pg_hba.conf и брандмауэр.

Подробные инструкции смотрите в `/opt/goflow2/GRAFANA-CONNECTION.md`

## Безопасность

- Скрипт создает отдельного пользователя `goflow2` для запуска сервиса
- Пароли по умолчанию должны быть изменены в production-среде
- Рекомендуется настроить брандмауэр для ограничения доступа к порту TimescaleDB
- Для Grafana рекомендуется создать пользователя только для чтения

## Устранение неполадок

### TimescaleDB не запускается
```bash
# Проверьте логи Docker
docker-compose -f /opt/goflow2/docker-compose.timescaledb.yml logs

# Проверьте, запущен ли Docker
rc-service docker status
```

### Нет подключения к базе данных
```bash
# Проверьте, слушает ли порт
netstat -tlnp | grep 5432

# Проверьте подключение из контейнера
docker exec goflow2-timescaledb pg_isready -U postgres
```

### Проблемы с логированием
```bash
# Проверьте права доступа
ls -la /var/log/goflow2/

# Проверьте конфигурацию logrotate
logrotate -d /etc/logrotate.d/goflow2
```

## Обновление

Для обновления goflow2 до новой версии:
1. Остановите сервис: `rc-service goflow2 stop`
2. Удалите старый бинарный файл: `rm /opt/goflow2/goflow2`
3. Запустите скрипт установки снова (он скачает последнюю версию)

## Лицензия

Скрипт распространяется под той же лицензией, что и основной проект goflow2.