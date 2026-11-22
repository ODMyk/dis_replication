# Налаштування реплікації PostgreSQL — Покрокова інструкція

## Огляд

Цей документ описує налаштування двох конфігурацій реплікації PostgreSQL 16.4 для сервісу нотаток (`notes`), розгорнутих через Docker Compose.

| Параметр | Конфігурація A | Конфігурація B |
|----------|----------------|----------------|
| Топологія | Single-leader (1 лідер + 2 фоловери) | Multi-leader (2 лідери) |
| Механізм | Фізична потокова реплікація | Двостороння логічна реплікація |
| Таблиця | `notes` | `notes` |
| Контейнери | `pg-leader-a`, `pg-follower-a1`, `pg-follower-a2` | `pg-leader-b1`, `pg-leader-b2` |

---

## Конфігурація A: Фізична потокова реплікація (Single-Leader)

### 1. Параметри PostgreSQL на лідері

Файл `config/conf-a/leader/init-leader.sh` виконується при першому запуску і встановлює в `postgresql.conf`:

```ini
wal_level = replica          # Мінімальний рівень WAL для реплікації
max_wal_senders = 10         # Максимальна кількість одночасних потоків WAL
wal_keep_size = 256MB        # Мінімальний об'єм WAL, що зберігається для фоловерів без слоту
max_replication_slots = 10   # Максимальна кількість слотів реплікації
hot_standby = on             # Дозволяє читання на фоловерах
synchronous_standby_names = '' # Асинхронний режим за замовчуванням
```

**Роль параметрів:**
- `wal_level = replica` — PostgreSQL генерує достатньо WAL-даних для фізичного відтворення змін на фоловері. При `wal_level = minimal` реплікація неможлива.
- `max_wal_senders` — кожен фоловер займає один walsender-процес на лідері. Значення `10` достатньо для 2–3 фоловерів плюс резерв.
- `max_replication_slots` — слоти гарантують, що лідер не видаляє WAL, поки фоловер не застосував його (навіть при відключенні фоловера). Небезпека: необмежене накопичення WAL при тривалому відключенні.
- `hot_standby = on` — фоловери доступні для читання під час streaming replication (режим standby).

### 2. Автентифікація реплікації (pg_hba.conf)

Файл `config/conf-a/leader/pg_hba.conf`:

```
# Локальний доступ
local all all trust
host  all all 127.0.0.1/32 md5

# Реплікація: дозволяємо підключення з підмережі 172.28.1.0/24
host replication repl_admin 172.28.1.0/24 md5
host all         repl_admin 172.28.1.0/24 md5
```

**Роль `replication` у pg_hba.conf:** Запис виду `host replication <user> <network>` дозволяє саме реплікаційні підключення (на відміну від звичайних SQL-підключень). Без цього `pg_basebackup` та streaming replication недоступні.

### 3. Підготовка слотів реплікації на лідері

```sql
-- Два фізичні слоти — по одному на кожен фоловер
SELECT pg_create_physical_replication_slot('slot_follower_a1', true);
SELECT pg_create_physical_replication_slot('slot_follower_a2', true);
```

**Навіщо два слоти:** Кожен фоловер використовує свій слот. Якщо один фоловер відключений, лідер зберігає WAL для нього, не блокуючи інший.

### 4. Підключення фоловера — pg_basebackup

Скрипт `config/conf-a/follower/entrypoint-follower.sh`:

```bash
# Чекаємо, доки лідер не стане доступним
until pg_isready -h pg-leader-a -p 5432 -U repl_admin; do sleep 1; done

# Базова копія з лідера (точка входу для WAL-streaming)
pg_basebackup \
  -h pg-leader-a \           # хост лідера
  -p 5432 \                  # порт лідера
  -U repl_admin \            # користувач реплікації
  -D /var/lib/postgresql/data \ # куди зберегти базову копію
  -Fp \                      # формат: plain (директорія, не TAR)
  -Xs \                      # WAL mode: stream (потоковий, не fetch)
  -R \                       # генерує standby.signal та postgresql.auto.conf
  -c fast \                  # режим checkpoint: fast (не чекати планового checkpoint)
  -S "$SLOT_NAME"            # ім'я слоту реплікації на лідері
```

**Пояснення прапорів:**
- `-Xs` (WAL mode stream): під час копіювання WAL одночасно стрімиться до фоловера, що гарантує отримання всіх змін, що відбулися під час бекапу.
- `-R`: автоматично створює `standby.signal` та записує `primary_conninfo` в `postgresql.auto.conf` — фоловер знатиме, де лідер і як підключитись після рестарту.
- `-S SLOT_NAME`: фоловер використовує свій dedicated слот. Так лідер знає, що WAL для цього слоту потрібно зберігати.
- `-c fast`: примушує checkpoint перед початком бекапу замість очікування планового. Пришвидшує старт фоловера.

**Звідки фоловер знає, з якого місця продовжувати:**
`pg_basebackup -R` записує в `postgresql.auto.conf`:
```ini
primary_conninfo = 'host=pg-leader-a port=5432 user=repl_admin ...'
primary_slot_name = 'slot_follower_a1'
```
Після старту фоловер зчитує ці параметри, підключається до лідера та повідомляє `restart_lsn` зі свого слоту — саме з цієї позиції WAL продовжує стрімитись.

### 5. Динамічне підключення pg-follower-a2 під навантаженням

В процесі роботи лідера (120 req/s, 100 000+ рядків) підключили другий фоловер:

```bash
docker compose --profile follower-a2 up -d pg-follower-a2
```

Результат: `pg_basebackup -c fast -S slot_follower_a2` виконав consistent snapshot під навантаженням (~0.87s на 100k рядків). Після старту фоловер-a2 автоматично наздогнав лідера через WAL-streaming.

### 6. Перевірка стану реплікації

```sql
-- На лідері
SELECT
  client_addr,
  application_name,
  state,          -- streaming / startup / catchup
  sync_state,     -- async / sync / potential
  write_lag,      -- затримка до підтвердження запису
  flush_lag,      -- затримка до підтвердження flush
  replay_lag,     -- затримка до підтвердження apply
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;

-- На фоловері
SELECT status, sender_host, receive_start_lsn, written_lsn, flushed_lsn, replayed_lsn
FROM pg_stat_wal_receiver;
```

---

## Конфігурація B: Двостороння логічна реплікація (Multi-Leader)

### 1. Параметри PostgreSQL на обох лідерах

```ini
wal_level = logical          # Обов'язковий для логічної реплікації
max_wal_senders = 10
max_replication_slots = 10
max_logical_replication_workers = 10
```

**Різниця між `replica` та `logical`:** `wal_level = logical` додає до WAL інформацію про старі значення рядків (`REPLICA IDENTITY`) та назви таблиць/стовпців, що дозволяє декодувати зміни у вигляді SQL-операцій (INSERT/UPDATE/DELETE), а не байтових блоків.

### 2. Схема та публікації

Файли `config/conf-b/init-b1.sql`, `init-b2.sql`:

```sql
-- Схема (однакова на обох вузлах)
CREATE TABLE notes (
  id         BIGSERIAL PRIMARY KEY,
  author_id  VARCHAR(64)   NOT NULL,
  title      VARCHAR(255)  NOT NULL,
  body       TEXT          NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Публікація: надсилати всі зміни таблиці notes
CREATE PUBLICATION pub_notes_b1 FOR TABLE notes;  -- на B1
CREATE PUBLICATION pub_notes_b2 FOR TABLE notes;  -- на B2
```

### 3. Підписки та запобігання циклам

Скрипт `scripts/setup_conf_b_replication.sh` створює перехресні підписки:

```sql
-- На B1: підписуємось на зміни від B2
CREATE SUBSCRIPTION sub_b1_from_b2
  CONNECTION 'host=172.29.1.11 port=5432 user=repl_admin dbname=notes_b password=repl_password_b'
  PUBLICATION pub_notes_b2
  WITH (copy_data = false, origin = 'none');

-- На B2: підписуємось на зміни від B1
CREATE SUBSCRIPTION sub_b2_from_b1
  CONNECTION 'host=172.29.1.10 port=5432 user=repl_admin dbname=notes_b password=repl_password_b'
  PUBLICATION pub_notes_b1
  WITH (copy_data = false, origin = 'none');
```

**Ключовий параметр `origin = 'none'`:** Без цього параметра зміна, що прийшла від B2 до B1, потрапила б у публікацію `pub_notes_b1` і повернулась назад на B2 — нескінченний цикл. З `origin = 'none'` підписка B1 ігнорує рядки, що вже були реплікованими (мають непорожній origin), — тільки локальні зміни B2 передаються на B1.

---

## Вирішення інженерних проблем та підводні камені

Під час налаштування середовища виникли та були подолані такі специфічні проблеми:

1. **Синтаксис порожнього `synchronous_standby_names` у CLI-аргументах Docker Compose:**
   - *Проблема:* Використання `-c synchronous_standby_names=''` у списку `command` Docker Compose викликало помилку парсингу: `invalid value at or near "'"`.
   - *Вирішення:* Передавати значення без лапок: `-c synchronous_standby_names=`.

2. **Пріоритет CLI-прапорів над `ALTER SYSTEM`:**
   - *Проблема:* Команда `ALTER SYSTEM SET synchronous_standby_names = ...` записує параметр у `postgresql.auto.conf`, але якщо у `docker-compose.yml` вказано прапорець `-c synchronous_standby_names`, аргумент командного рядка має вищий пріоритет, і `pg_reload_conf()` не застосовує зміни.
   - *Вирішення:* Видалити прапорець із командного рядка Docker Compose, перезапустити контейнер без нього, після чого конфігурація динамічно керується через `ALTER SYSTEM` та `SELECT pg_reload_conf()`.

3. **Обмеження транзакцій у `CREATE SUBSCRIPTION`:**
   - *Проблема:* Спроба виконати `CREATE SUBSCRIPTION ... WITH (create_slot = true)` всередині анонімного блоку `DO $$ ... $$` або у мультикомандному рядку `psql -c "DROP ...; CREATE ...;"` викликає помилку: `ERROR: CREATE SUBSCRIPTION ... cannot run inside a transaction block`.
   - *Вирішення:* Розділити команди на окремі виклики `psql -c "DROP SUBSCRIPTION ..."` та `psql -c "CREATE SUBSCRIPTION ..."`, щоб кожна з них виконувалася як окрема самостійна транзакція.

4. **Втрата статичної IP-адреси при повторному підключенні до мережі Docker:**
   - *Проблема:* При виклику `docker network disconnect` та наступному `docker network connect` Docker динамічно виділяє першу вільну IP-адресу (наприклад, `172.29.1.2` замість `172.29.1.11`), через що логічна підписка втрачає зв'язок (`Host is unreachable`).
   - *Вирішення:* Завжди явно вказувати прапорець `--ip`: `docker network connect --ip 172.29.1.11 pg-replication-lab_net_conf_b pg-leader-b2`.

5. **Відсутність `psql` на хості:**
   - *Проблема:* На хост-машині не встановлено клієнт `psql` або `pg_isready`.
   - *Вирішення:* Усі системні операції автоматизовано через `docker exec -i <container> psql -U repl_admin -d <dbname> ...`.

---

## Загальні кроки відтворення

```bash
# 1. Запуск Конф. A
docker compose up -d pg-leader-a pg-follower-a1
docker compose --profile follower-a2 up -d pg-follower-a2

# 2. Засів початкових даних (100k записів, seed=42)
uv run --with "psycopg[binary]" scripts/seed_notes.py \
  --host 127.0.0.1 --port 5432 --count 100000 --seed 42

# 3. Перевірка консистентності
uv run --with "psycopg[binary]" scripts/verify_consistency.py \
  --nodes "127.0.0.1:5432:notes_a:repl_admin:repl_password_a:leader" \
         "127.0.0.1:5433:notes_a:repl_admin:repl_password_a:follower-a1" \
         "127.0.0.1:5434:notes_a:repl_admin:repl_password_a:follower-a2"

# 4. Запуск Конф. B
docker compose --profile conf-b up -d pg-leader-b1 pg-leader-b2
bash scripts/setup_conf_b_replication.sh
```
