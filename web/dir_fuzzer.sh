#!/bin/bash

# ============================================================
# DIR FUZZER — МАССОВЫЙ ФАЗЗИНГ ДИРЕКТОРИЙ
# ============================================================
# !!! ВНИМАНИЕ !!!
# Перед запуском обязательно отредактируйте переменные ниже:
#   - DOMAINS_FILE     – путь к списку целей (каждая строка – URL)
#   - WORDLIST         – путь к словарю для фаззинга
#   - DIRSEARCH_PATH   – путь к скрипту dirsearch.py
#   - OUTPUT_DIR       – папка для результатов (можно оставить)
#   - PROXIES_FILE     – путь к файлу с прокси (если используете)
#   - AUTO_UPDATE_PROXIES – автоматическая загрузка свежих прокси
#   - RATE_LIMIT, THREADS, TIMEOUT – параметры скорости
# ============================================================
# https://github.com/0xKernelPanicFF 
# ------------------------------------------------------------
#  НАСТРОЙКИ (ИЗМЕНИТЕ ПЕРЕД ЗАПУСКОМ)
# ------------------------------------------------------------
DOMAINS_FILE="alive_subdomains.txt"          # Файл со списком целей – ЗАМЕНИТЕ НА ВАШ
WORDLIST="$HOME/wordlists/ultimate_dir_http.txt"   # ЗАМЕНИТЕ НА ВАШ СЛОВАРЬ
DIRSEARCH_PATH="$HOME/tools/dirsearch/dirsearch.py" # ЗАМЕНИТЕ НА ВАШ ПУТЬ К dirsearch
OUTPUT_DIR="./full_scan_results"              # Можно оставить

# Параметры производительности
RATE_LIMIT=25
THREADS=5
DELAY=0.1
TIMEOUT_HTTP=5          # При использовании прокси увеличьте до 12–15

# Параметры dirsearch
EXTENSIONS="php,html,js,json,bak,zip,old,sql,txt,log,ini,env"
SUFFIXES=".bak,.old,.zip,~,.sql"
INCLUDE_STATUS="200,204,301,302,403,401"
DIRSEARCH_TIMEOUT=600

# Прокси
PROXIES_FILE="$HOME/proxies.txt"            # ЗАМЕНИТЕ НА ВАШ ФАЙЛ (если используете)
AUTO_UPDATE_PROXIES=1          # 1 – загружать свежие прокси, 0 – не загружать
KEEP_EMPTY_REPORTS=0           # 1 – сохранять пустые папки для отладки

# ------------------------------------------------------------
#  ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И TRAP
# ------------------------------------------------------------
PAUSE_REQUESTED=0
CURRENT_PID=""

pause_handler() {
    echo -e "\n⏸️  Получен сигнал Ctrl+C!"
    if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        echo "   Принудительно завершаем dirsearch (PID: $CURRENT_PID)..."
        pkill -9 -P "$CURRENT_PID" 2>/dev/null
        kill -9 "$CURRENT_PID" 2>/dev/null
    fi
    PAUSE_REQUESTED=1
    if [ ! -t 0 ]; then
        echo "   (Нет интерактивного терминала, завершаем работу)"
        exit 1
    fi
}

cleanup_and_exit() {
    if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        pkill -9 -P "$CURRENT_PID" 2>/dev/null
        kill -9 "$CURRENT_PID" 2>/dev/null
    fi
}

trap pause_handler SIGINT
trap cleanup_and_exit SIGHUP SIGTERM

# ------------------------------------------------------------
#  ПРОВЕРКИ И ДИАГНОСТИКА
# ------------------------------------------------------------
check_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "❌ Установи $1"; exit 1; }
}
check_cmd "python3"
check_cmd "awk"
check_cmd "curl"

[ ! -f "$DIRSEARCH_PATH" ] && { echo "❌ dirsearch.py не найден по пути: $DIRSEARCH_PATH"; exit 1; }
[ ! -f "$WORDLIST" ] && { echo "❌ Словарь не найден: $WORDLIST"; exit 1; }
mkdir -p "$OUTPUT_DIR"

# --- Автоматическая загрузка прокси ---
if [ "$AUTO_UPDATE_PROXIES" -eq 1 ]; then
    echo "📡 Загружаем свежий список прокси..."
    curl -s https://raw.githubusercontent.com/theriturajps/proxy-list/main/proxies.txt -o "$PROXIES_FILE" 2>/dev/null
    if [ ! -s "$PROXIES_FILE" ]; then
        curl -s https://raw.githubusercontent.com/Bes-js/public-proxy-list/main/proxies.txt -o "$PROXIES_FILE" 2>/dev/null
    fi
    if [ -s "$PROXIES_FILE" ]; then
        echo "   ✅ Загружено $(wc -l < "$PROXIES_FILE" | tr -d ' ') прокси."
    else
        echo "   ⚠️ Не удалось загрузить прокси, продолжаем без них."
        PROXIES_FILE=""
    fi
fi

# --- Динамическая диагностика флагов dirsearch ---
DIRSEARCH_HELP=$(python3 "$DIRSEARCH_PATH" -h 2>&1 | tr -d '\r')

CALIBRATE_FLAG=""
if echo "$DIRSEARCH_HELP" | grep -q -- "--cal"; then
    CALIBRATE_FLAG="--cal"
fi

FORMAT_FLAG=""
if echo "$DIRSEARCH_HELP" | grep -q -- "--format"; then
    FORMAT_FLAG="--format=plain"
fi

SUFFIXES_FLAG=""
if echo "$DIRSEARCH_HELP" | grep -q -- "--suffixes"; then
    SUFFIXES_FLAG="--suffixes $SUFFIXES"
fi

DELAY_FLAG=""
if echo "$DIRSEARCH_HELP" | grep -q -- "--delay"; then
    DELAY_FLAG="--delay=$DELAY"
fi

EXIT_ON_ERROR_FLAG=""
if echo "$DIRSEARCH_HELP" | grep -q -- "--exit-on-error"; then
    EXIT_ON_ERROR_FLAG="--exit-on-error"
fi

SKIP_ON_STATUS_FLAG=""
if echo "$DIRSEARCH_HELP" | grep -q -- "--skip-on-status"; then
    SKIP_ON_STATUS_FLAG="--skip-on-status 429"
fi

RETRIES_FLAG=""
if echo "$DIRSEARCH_HELP" | grep -q -- "--retries"; then
    RETRIES_FLAG="--retries 2"
fi

FOLLOW_FLAG=""
# Отключаем follow-redirects, чтобы избежать бесконечных циклов
# Если нужно, раскомментируйте соответствующие строки ниже
# if echo "$DIRSEARCH_HELP" | grep -q -- "--follow-redirects"; then
#     FOLLOW_FLAG="--follow-redirects"
# fi

echo "📋 Диагностика флагов:"
echo "   CALIBRATE_FLAG: $CALIBRATE_FLAG"
echo "   FORMAT_FLAG: $FORMAT_FLAG"
echo "   SUFFIXES_FLAG: $SUFFIXES_FLAG"
echo "   FOLLOW_FLAG: отключено (для избежания бесконечных редиректов)"
echo "   DELAY_FLAG: $DELAY_FLAG"
echo "   EXIT_ON_ERROR_FLAG: $EXIT_ON_ERROR_FLAG"
echo "   SKIP_ON_STATUS_FLAG: $SKIP_ON_STATUS_FLAG"
echo "   RETRIES_FLAG: $RETRIES_FLAG"
echo "   INCLUDE_STATUS: $INCLUDE_STATUS"
if [ -n "$PROXIES_FILE" ] && [ -s "$PROXIES_FILE" ]; then
    echo "   Прокси: включены ($PROXIES_FILE)"
else
    echo "   Прокси: не используются"
fi
echo ""

# ------------------------------------------------------------
#  ИНИЦИАЛИЗАЦИЯ ИСТОРИИ И ОТЧЕТОВ
# ------------------------------------------------------------
PROCESSED_HISTORY="$OUTPUT_DIR/processed_domains.txt"
touch "$PROCESSED_HISTORY"

if [ ! -f "$DOMAINS_FILE" ]; then
    echo "❌ Файл $DOMAINS_FILE не найден!"; exit 1
fi

TOTAL=$(wc -l < "$DOMAINS_FILE" | tr -d ' ')
PROCESSED=0
ALL_PATHS="$OUTPUT_DIR/all_found_paths.txt"
cat /dev/null > "$ALL_PATHS"

echo "🚀 Начинаем сканирование $TOTAL целей..."
echo "--------------------------------------------------------"

while IFS= read -r target; do
    target=$(echo "$target" | tr -d '\r' | xargs)
    [ -z "$target" ] && continue

    PROCESSED=$((PROCESSED + 1))

    # Обработка паузы (если был Ctrl+C)
    if [ "$PAUSE_REQUESTED" -eq 1 ]; then
        if [ -t 0 ]; then
            echo -e "\n⏸️  Сканирование приостановлено."
            while true; do
                read -p "   Продолжить (c) или выйти (q)? " choice </dev/tty
                case "$choice" in
                    c|C) PAUSE_REQUESTED=0
                         echo "   ▶️ Продолжаем работу..."
                         break ;;
                    q|Q) echo "   🛑 Выход по запросу пользователя."
                         exit 0 ;;
                    *) echo "   ❌ Введите 'c' для продолжения или 'q' для выхода." ;;
                esac
            done
        else
            echo -e "\n⏸️  Получен Ctrl+C в фоновом режиме (no TTY). Завершаем работу."
            exit 1
        fi
    fi

    target_clean=$(echo "$target" | sed 's|/*$||')
    domain_folder=$(echo "$target_clean" | sed -e 's|^[^:]*://||' -e 's|:[0-9]*$||' -e 's|/|_|g')

    if grep -qx "$domain_folder" "$PROCESSED_HISTORY" 2>/dev/null; then
        echo "[$PROCESSED/$TOTAL] ⏭️  Домен $domain_folder уже обработан, пропускаем."
        continue
    fi

    echo "[$PROCESSED/$TOTAL] Сканируем: $target"

    DOMAIN_DIR="$OUTPUT_DIR/$domain_folder"
    mkdir -p "$DOMAIN_DIR"
    RAW_REPORT="$DOMAIN_DIR/raw_report.txt"
    FOUND_PATHS="$DOMAIN_DIR/found_paths.txt"
    > "$FOUND_PATHS"

    echo "   🕵️ Запуск dirsearch (RPS: $RATE_LIMIT, потоки: $THREADS)..."

    PROXY_OPT=""
    if [ -n "$PROXIES_FILE" ] && [ -s "$PROXIES_FILE" ]; then
        PROXY_OPT="--proxy-list $PROXIES_FILE"
    fi

    # Запуск в фоне с полным подавлением вывода
    {
        timeout -k 30s "$DIRSEARCH_TIMEOUT" python3 "$DIRSEARCH_PATH" \
            -u "$target" \
            -w "$WORDLIST" \
            --max-rate="$RATE_LIMIT" \
            -t "$THREADS" \
            --random-agent \
            $DELAY_FLAG \
            --timeout="$TIMEOUT_HTTP" \
            $CALIBRATE_FLAG \
            -e "$EXTENSIONS" \
            $SUFFIXES_FLAG \
            -i "$INCLUDE_STATUS" \
            $EXIT_ON_ERROR_FLAG \
            $SKIP_ON_STATUS_FLAG \
            $RETRIES_FLAG \
            $PROXY_OPT \
            $FORMAT_FLAG \
            -o "$RAW_REPORT" \
            < /dev/null > /dev/null 2>&1
    } &

    CURRENT_PID=$!
    wait $CURRENT_PID
    CURRENT_PID=""

    # --- Быстрый парсинг (один awk) ---
    HAS_FINDINGS=0
    if [ -f "$RAW_REPORT" ] && [ -s "$RAW_REPORT" ]; then
        awk '/^[^#]/ && NF {
            code = $1
            url = ""
            for(i=1;i<=NF;i++) {
                if($i ~ /^http/ || $i ~ /^\//) { url = $i; break }
            }
            if(code && url) {
                print url " [" code "]" >> "'"$FOUND_PATHS"'"
                print url " [" code "]" >> "'"$ALL_PATHS"'"
            }
        }' "$RAW_REPORT" 2>/dev/null

        [ -s "$FOUND_PATHS" ] && HAS_FINDINGS=1
    fi

    if [ "$HAS_FINDINGS" -eq 1 ]; then
        FOUND_COUNT=$(wc -l < "$FOUND_PATHS" | tr -d ' ')
        echo "   ✅ Найдено путей: $FOUND_COUNT (сохранены в папку $domain_folder)"
        sed -i '/^#/d; /^$/d' "$RAW_REPORT" 2>/dev/null
    else
        echo "   ❌ Путей не найдено."
        if [ "$KEEP_EMPTY_REPORTS" -eq 0 ]; then
            rm -rf "$DOMAIN_DIR"
        else
            echo "   (Пустой отчёт сохранён для отладки в $DOMAIN_DIR)"
        fi
    fi

    echo "$domain_folder" >> "$PROCESSED_HISTORY"
    echo "   ⏱️  Прогресс: $PROCESSED / $TOTAL"
    echo "--------------------------------------------------------"

done < "$DOMAINS_FILE"

echo -e "\n🎉 Полное сканирование завершено!"
echo "📊 Результаты в папке: $OUTPUT_DIR"
echo "📄 Общий список всех путей (с кодами): $ALL_PATHS"

