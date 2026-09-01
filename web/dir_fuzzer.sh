#!/bin/bash

# ============================================================
#       dirfuzzer.sh – Универсальный сканер директорий
#       Двухэтапный фаззинг с фильтрацией WAF-шума
# ============================================================
#  Спецификация ядра сканирования:
#  Компонент:         dirsearch (maurosoria/dirsearch)
#  Версия ядра:       v0.5.0
#  Ветка репозитория: master
#  Текущий коммит:     80a2996
#  Особенности:       Использует новый синтаксис аргументов (-O plain)
#                     и встроенный нативный rate-limiter утилиты
# ============================================================
#  Разработчик:  0xKernelPanicFF (ZORG)
#  Собрано при участии ИИ (Промпт-инжиниринг и отладка)
#  GitHub:       https://github.com/0xKernelPanicFF
# ============================================================
#
# Использование:
#   1. Подготовьте файл с целями (по одной на строку, с протоколом)
#   2. Укажите путь к словарю и к dirsearch.py
#   3. Запустите: ./dirfuzzer.sh
#
# Настройки – изменяйте под свои задачи.
# ============================================================

# ---------- ОСНОВНЫЕ НАСТРОЙКИ ----------
TARGETS_FILE="domains.txt"                       # Файл со списком целей (например, https://example.com)
WORDLIST="./wordlist.txt"                        # Путь к словарю (список путей для перебора)
DIRSEARCH_PATH="./dirsearch.py"                  # Путь к dirsearch.py
OUTPUT_DIR="./results"                           # Папка для результатов
DEBUG_MODE=0                                     # Режим отладки: 1 – показывать весь вывод dirsearch, 0 – только итоги

# ---------- ПАРАМЕТРЫ СКАНИРОВАНИЯ ----------
RATE_LIMIT=10                                    # Скорость (запросов в секунду)
THREADS=3                                        # Количество параллельных потоков
DELAY=0.1                                        # Задержка между запросами (сек)
TIMEOUT_HTTP=12                                  # Таймаут HTTP-запроса (сек)
DIRSEARCH_TIMEOUT=1800                           # Максимальное время работы dirsearch на одном этапе (сек)

# ---------- РАСШИРЕНИЯ И СУФФИКСЫ ----------
EXTENSIONS="php,html,bak,zip,old,sql,txt,log,ini,env"   # Расширения для поиска файлов (через запятую)
SUFFIXES=".bak,.old,.zip,~,.sql"                        # Суффиксы для поиска бэкапов (через запятую)
INCLUDE_STATUS="200,204,301,302,401,403"                # Какие HTTP-статусы нас интересуют

# ---------- ЗАЩИТА ОТ WAF ----------
WAF_THRESHOLD=50                                 # Порог для автоматической фильтрации WAF-шума (в %)

# ---------- ПРОКСИ (опционально) ----------
PROXY_LIST=""                                    # Путь к файлу с прокси (оставьте пустым, если не используются)

# ---------- ПРОЧЕЕ ----------
KEEP_EMPTY_REPORTS=0                             # Сохранять ли папки с пустыми результатами (1 – да, 0 – нет)

# ============================================================
#       НЕ МЕНЯЙТЕ НИЖЕ ЭТОЙ СТРОКИ, ЕСЛИ НЕ УВЕРЕНЫ
# ============================================================

# ---- Перехват сигналов ----
PAUSE_REQUESTED=0
CURRENT_PID=""
CURRENT_DOMAIN=""

pause_handler() {
    echo -e "\n\n⏸️  Получен сигнал Ctrl+C! Переходим в режим паузы..."
    if [ -n "$CURRENT_PID" ]; then
        echo "   Останавливаем текущий процесс timeout и все его дочерние..."
        pkill -P "$CURRENT_PID" 2>/dev/null
        kill -TERM "$CURRENT_PID" 2>/dev/null
        sleep 1
        if kill -0 "$CURRENT_PID" 2>/dev/null; then
            kill -KILL "$CURRENT_PID" 2>/dev/null
        fi
    fi
    PAUSE_REQUESTED=1
}

cleanup_and_exit() {
    if [ -n "$CURRENT_PID" ]; then
        pkill -P "$CURRENT_PID" 2>/dev/null
        kill -KILL "$CURRENT_PID" 2>/dev/null
    fi
    exit 1
}

trap pause_handler SIGINT
trap cleanup_and_exit SIGHUP SIGTERM

# ---- Проверка окружения ----
command -v python3 >/dev/null 2>&1 || { echo "❌ Нужен python3"; exit 1; }
[ ! -f "$DIRSEARCH_PATH" ] && { echo "❌ dirsearch.py не найден по пути $DIRSEARCH_PATH"; exit 1; }
[ ! -f "$WORDLIST" ] && { echo "❌ Словарь не найден по пути $WORDLIST"; exit 1; }
mkdir -p "$OUTPUT_DIR"

# Определяем формат вывода dirsearch (для новых версий)
FORMAT_FLAGS="-O plain"

# Автоматическое определение антибан-флагов
ANTI_BAN_FLAGS=""
DIRSEARCH_HELP=$(python3 "$DIRSEARCH_PATH" -h 2>/dev/null)
if [[ "$DIRSEARCH_HELP" == *"--skip-on-status"* ]]; then
    ANTI_BAN_FLAGS="$ANTI_BAN_FLAGS --skip-on-status 429,502,503"
fi
if [[ "$DIRSEARCH_HELP" == *"--random-agent"* ]]; then
    ANTI_BAN_FLAGS="$ANTI_BAN_FLAGS --random-agent"
fi

# Прокси (если указаны)
PROXY_OPT=""
if [ -n "$PROXY_LIST" ] && [ -f "$PROXY_LIST" ]; then
    PROXY_OPT="--proxy-list $PROXY_LIST"
fi

# ---- История прогресса ----
PROCESSED_HISTORY="$OUTPUT_DIR/processed_domains.txt"
touch "$PROCESSED_HISTORY"
ALL_PATHS="$OUTPUT_DIR/all_found_paths.txt"
touch "$ALL_PATHS"

if [ ! -f "$TARGETS_FILE" ]; then
    echo "❌ Файл $TARGETS_FILE не найден!"; exit 1
fi

TOTAL=$(wc -l < "$TARGETS_FILE" | tr -d ' ')
PROCESSED=0

echo "🚀 Запуск сканирования"
echo "📋 Режим: скорость <= $RATE_LIMIT RPS | потоков: $THREADS | отладка: $DEBUG_MODE"
echo "--------------------------------------------------------"

# ---- Основной цикл по целям ----
while IFS= read -r target; do
    target=$(echo "$target" | tr -d '\r' | xargs)
    [ -z "$target" ] && continue

    CURRENT_DOMAIN="$target"
    PROCESSED=$((PROCESSED + 1))

    # Обработка паузы
    if [ "$PAUSE_REQUESTED" -eq 1 ]; then
        echo -e "\n⏸️  Сканирование приостановлено пользователем."
        read -p "   Продолжить (c) или выйти (q)? " choice </dev/tty
        if [[ "$choice" =~ ^[Qq]$ ]]; then
            echo "   🛑 Выход из программы."
            exit 0
        else
            PAUSE_REQUESTED=0
            echo "   ▶️ Продолжаем работу..."
        fi
    fi

    target_clean=$(echo "$target" | sed 's|/*$||')
    domain_folder=$(echo "$target_clean" | sed -e 's|^[^:]*://||' -e 's|:[0-9]*$||' -e 's|/|_|g')

    if grep -qx "$domain_folder" "$PROCESSED_HISTORY" 2>/dev/null; then
        echo "[$PROCESSED/$TOTAL] ⏭️  $domain_folder уже обработан. Пропуск."
        continue
    fi

    echo "[$PROCESSED/$TOTAL] 🎯 Цель: $target"
    DOMAIN_DIR="$OUTPUT_DIR/$domain_folder"
    mkdir -p "$DOMAIN_DIR"
    FOUND_PATHS="$DOMAIN_DIR/found_paths.txt"
    > "$FOUND_PATHS"

    # Проверка доступности (опционально)
    if ! curl -Is --connect-timeout 5 --max-time 10 "$target" > /dev/null 2>&1; then
        echo "   ⚠️  Внимание: Цель не отвечает на обычный curl! Возможно, WAF или проблемы с сетью."
    fi

    # --------------------------------------------
    # ЭТАП 1: Поиск структуры (директории)
    # --------------------------------------------
    echo "   🔍 Этап 1: Поиск директорий и файлов..."
    STEP1_REPORT="$DOMAIN_DIR/step1_raw.txt"

    if [ "$DEBUG_MODE" -eq 1 ]; then
        timeout -k 30s "$DIRSEARCH_TIMEOUT" python3 "$DIRSEARCH_PATH" \
            -u "$target" \
            -w "$WORDLIST" \
            --max-rate="$RATE_LIMIT" \
            -t "$THREADS" \
            --delay="$DELAY" \
            --timeout="$TIMEOUT_HTTP" \
            -i "$INCLUDE_STATUS" \
            $PROXY_OPT \
            $FORMAT_FLAGS \
            $ANTI_BAN_FLAGS \
            -o "$STEP1_REPORT" &
    else
        timeout -k 30s "$DIRSEARCH_TIMEOUT" python3 "$DIRSEARCH_PATH" \
            -u "$target" \
            -w "$WORDLIST" \
            --max-rate="$RATE_LIMIT" \
            -t "$THREADS" \
            --delay="$DELAY" \
            --timeout="$TIMEOUT_HTTP" \
            -i "$INCLUDE_STATUS" \
            $PROXY_OPT \
            $FORMAT_FLAGS \
            $ANTI_BAN_FLAGS \
            -o "$STEP1_REPORT" >/dev/null 2>&1 &
    fi

    CURRENT_PID=$!
    wait $CURRENT_PID
    CURRENT_PID=""

    # Извлечение найденных путей (относительные)
    STEP1_PATHS="$DOMAIN_DIR/step1_paths.txt"
    > "$STEP1_PATHS"
    if [ -f "$STEP1_REPORT" ] && [ -s "$STEP1_REPORT" ]; then
        awk '!/^#/ && NF>=3 {
            url = $3
            gsub(/^https?:\/\/[^/]+\//, "", url)
            gsub(/^\//, "", url)
            if (url != "") print url
        }' "$STEP1_REPORT" | sort -u > "$STEP1_PATHS"
    fi

    if [ ! -s "$STEP1_PATHS" ]; then
        echo "   ❌ На первом этапе ничего не найдено."
        [ "$KEEP_EMPTY_REPORTS" -eq 0 ] && rm -rf "$DOMAIN_DIR"
        echo "$domain_folder" >> "$PROCESSED_HISTORY"
        continue
    fi

    # Краткий вывод найденных директорий
    if [ "$DEBUG_MODE" -eq 0 ]; then
        echo "   📈 Найденные директории на Этапе 1:"
        while read -r found_dir; do
            status_code=$(awk -v d="$found_dir" '$3 ~ "/" d "(/|$)" {print $1; exit}' "$STEP1_REPORT" 2>/dev/null)
            [ -z "$status_code" ] && status_code="???"
            echo "      [+] /$found_dir [Код: $status_code]"
        done < "$STEP1_PATHS"
    fi

    # --------------------------------------------
    # ЭТАП 2: Проверка расширений и суффиксов
    # --------------------------------------------
    echo "   🔍 Этап 2: Проверка расширений и суффиксов in-place..."
    STEP2_REPORT="$DOMAIN_DIR/step2_raw.txt"

    if [ "$DEBUG_MODE" -eq 1 ]; then
        timeout -k 30s "$DIRSEARCH_TIMEOUT" python3 "$DIRSEARCH_PATH" \
            -u "$target" \
            -w "$STEP1_PATHS" \
            -e "$EXTENSIONS" \
            --suffixes "$SUFFIXES" \
            -i "$INCLUDE_STATUS" \
            --max-rate="$RATE_LIMIT" \
            -t "$THREADS" \
            --delay="$DELAY" \
            --timeout="$TIMEOUT_HTTP" \
            $PROXY_OPT \
            $FORMAT_FLAGS \
            $ANTI_BAN_FLAGS \
            -o "$STEP2_REPORT" &
    else
        timeout -k 30s "$DIRSEARCH_TIMEOUT" python3 "$DIRSEARCH_PATH" \
            -u "$target" \
            -w "$STEP1_PATHS" \
            -e "$EXTENSIONS" \
            --suffixes "$SUFFIXES" \
            -i "$INCLUDE_STATUS" \
            --max-rate="$RATE_LIMIT" \
            -t "$THREADS" \
            --delay="$DELAY" \
            --timeout="$TIMEOUT_HTTP" \
            $PROXY_OPT \
            $FORMAT_FLAGS \
            $ANTI_BAN_FLAGS \
            -o "$STEP2_REPORT" >/dev/null 2>&1 &
    fi

    CURRENT_PID=$!
    wait $CURRENT_PID
    CURRENT_PID=""

    # --------------------------------------------
    # ФИЛЬТРАЦИЯ WAF-ШУМА (по размеру 403-ответов)
    # --------------------------------------------
    echo "   🧹 Фильтрация WAF-заглушек (403 с одинаковым размером)..."
    TEMP_ALL="$DOMAIN_DIR/temp_all.txt"
    touch "$TEMP_ALL"

    [ -s "$STEP1_REPORT" ] && cat "$STEP1_REPORT" | grep -v '^#' | grep -v '^$' >> "$TEMP_ALL"
    [ -s "$STEP2_REPORT" ] && cat "$STEP2_REPORT" | grep -v '^#' | grep -v '^$' >> "$TEMP_ALL"

    # Анализируем ответы 403
    if grep -q ' 403 ' "$TEMP_ALL"; then
        # Определяем наиболее частый размер
        MOST_COMMON_SIZE=$(grep ' 403 ' "$TEMP_ALL" | awk -F ' - ' '{print $2}' | awk '{print $1}' | sort | uniq -c | sort -nr | head -1 | awk '{print $2}')
        if [ -n "$MOST_COMMON_SIZE" ]; then
            TOTAL_403=$(grep -c ' 403 ' "$TEMP_ALL")
            SIZE_COUNT=$(grep ' 403 ' "$TEMP_ALL" | awk -F ' - ' '{print $2}' | awk '{print $1}' | grep -c "^$MOST_COMMON_SIZE$")
            if [ "$TOTAL_403" -gt 0 ]; then
                PERCENT=$((SIZE_COUNT * 100 / TOTAL_403))
                if [ "$PERCENT" -ge "$WAF_THRESHOLD" ]; then
                    echo "   ⚠️  Обнаружен WAF: $PERCENT% ответов 403 имеют одинаковый размер ($MOST_COMMON_SIZE). Отсекаем шум."
                    grep -v " $MOST_COMMON_SIZE " "$TEMP_ALL" > "$TEMP_ALL.filtered"
                    mv "$TEMP_ALL.filtered" "$TEMP_ALL"
                fi
            fi
        fi
    fi

    # --------------------------------------------
    # СБОРКА ФИНАЛЬНОГО ОТЧЕТА
    # --------------------------------------------
    if [ -s "$TEMP_ALL" ]; then
        awk -v tgt="$target_clean" '!/^#/ && NF>=3 {
            path = $3
            gsub(/^https?:\/\/[^/]+\//, "", path)
            gsub(/^\//, "", path)
            if (path != "") print tgt "/" path " [" $1 "]"
        }' "$TEMP_ALL" >> "$FOUND_PATHS"
    fi

    # Уникализация и запись в общий лог
    if [ -s "$FOUND_PATHS" ]; then
        sort -u "$FOUND_PATHS" -o "$FOUND_PATHS"
        cat "$FOUND_PATHS" >> "$ALL_PATHS"
        echo "   ✅ Успешно. Итоговый отчет сохранен в: $FOUND_PATHS"

        if [ "$DEBUG_MODE" -eq 0 ]; then
            echo "   🔥 Результаты сканирования (без учета WAF-заглушек):"
            awk '{print "      [+] " $0}' "$FOUND_PATHS" | head -20
            if [ $(wc -l < "$FOUND_PATHS") -gt 20 ]; then
                echo "      ... и ещё $(($(wc -l < "$FOUND_PATHS") - 20)) записей (см. файл)"
            fi
        fi
    else
        echo "   ❌ Новых скрытых файлов не найдено."
        [ "$KEEP_EMPTY_REPORTS" -eq 0 ] && rm -rf "$DOMAIN_DIR"
    fi

    rm -f "$TEMP_ALL"
    echo "$domain_folder" >> "$PROCESSED_HISTORY"
    echo "--------------------------------------------------------"
done < "$TARGETS_FILE"

echo -e "\n🎉 Все цели успешно обработаны!"
