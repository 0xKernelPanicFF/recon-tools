#!/bin/bash

# ============================================================
# DNS RECON — МНОГОУРОВНЕВЫЙ СБОР ПОДДОМЕНОВ
# ============================================================
# !!! ВНИМАНИЕ !!!
# Перед запуском обязательно отредактируйте переменные ниже:
#   - DOMAIN          – целевой домен (замените example.com на свой)
#   - WORDLIST        – путь к основному словарю поддоменов
#   - WORDLIST_DEEP   – путь к глубокому словарю (для рекурсии)
#   - RESOLVERS       – путь к файлу с DNS-резолверами
#   - OUTPUT_DIR      – папка для результатов (можно оставить)
#   - RATE_LIMIT и др. – параметры скорости (по желанию)
# ============================================================
# https://github.com/0xKernelPanicFF
# ------------------------------------------------------------
#  НАСТРОЙКИ (ИЗМЕНИТЕ ПЕРЕД ЗАПУСКОМ)
# ------------------------------------------------------------
DOMAIN="example.com"                     # ЗАМЕНИТЕ НА ВАШ ДОМЕН
OUTPUT_DIR="./recon_${DOMAIN}"           # Можно оставить

# Пути к словарям – ЗАМЕНИТЕ НА ВАШИ
WORDLIST="$HOME/SecLists/Discovery/DNS/subdomains-top1million-5000.txt"
WORDLIST_DEEP="$HOME/SecLists/Discovery/DNS/subdomains_deep.txt"
RESOLVERS="$HOME/resolvers/resolvers.txt"

# Параметры производительности (можно менять)
RATE_LIMIT=400
THREADS_DNS=150
THREADS_HTTP=80
TIMEOUT_HTTP=3

# Глубина рекурсивного брутфорса (3–5 уровней)
MAX_DEPTH=5
LEVEL_LIMIT=300
WORDLIST_LIMIT=1500

# Включить/выключить этапы (1 – да, 0 – нет)
RUN_PASSIVE=1
RUN_BRUTE_BASE=1
RUN_RECURSIVE=1
RUN_FINAL_RESOLVE=1
RUN_HTTPX=1

# ------------------------------------------------------------
#  ИНТАКТИВНАЯ ЛОВУШКА CTRL+C (ЗАЩИТА ОТ СЛУЧАЙНОГО НАЖАТИЯ)
# ------------------------------------------------------------
cleanup_and_exit() {
    pkill -STOP -P $$ 2>/dev/null
    kill -STOP $(jobs -p) 2>/dev/null 2>&1
    echo -e "\n\n⚠️  \033[1;31m[ВНИМАНИЕ] Нажата комбинация Ctrl+C!\033[0m"
    echo -n "❓ Вы действительно хотите прервать рекон и УДАЛИТЬ промежуточные результаты брутфорса? (y/n): "
    read -n 1 -r user_response
    echo ""
    if [[ "$user_response" =~ ^[YyДд]$ ]]; then
        echo -e "\n🛑 Экстренное завершение работы по требованию пользователя..."
        pkill -KILL -P $$ 2>/dev/null
        kill -9 $(jobs -p) 2>/dev/null 2>&1
        rm -f "$OUTPUT_DIR/combinations_tmp.txt" \
              "$OUTPUT_DIR/level_input.txt" \
              "$OUTPUT_DIR/level_found_tmp.txt" \
              "$OUTPUT_DIR/level_found_raw.txt" \
              "$OUTPUT_DIR/level_found_clean.txt" \
              "$OUTPUT_DIR/wordlist_head.txt" \
              "$OUTPUT_DIR/passive_tmp1.txt" \
              "$OUTPUT_DIR/passive_tmp2.txt" 2>/dev/null
        trap - SIGINT SIGTERM
        exit 1
    else
        echo -e "\n✅ \033[1;32mФух, продолжаем работу! Снятие процессов с паузы...\033[0m\n"
        pkill -CONT -P $$ 2>/dev/null
        kill -CONT $(jobs -p) 2>/dev/null 2>&1
    fi
}
trap cleanup_and_exit SIGINT SIGTERM

# ------------------------------------------------------------
#  ПРОВЕРКА ЗАВИСИМОСТЕЙ И ФЛАГОВ
# ------------------------------------------------------------
check_cmd() {
    command -v "$1" >/dev/null 2>&1 || \
    { echo "❌ Установи $1"; exit 1; }
}
check_cmd "subfinder"
check_cmd "assetfinder"
check_cmd "dnsx"
check_cmd "httpx"

mkdir -p "$OUTPUT_DIR"

echo "🔍 Диагностика флагов утилит..."
DNSX_HELP=$(dnsx -h 2>&1)
HTTPX_HELP=$(httpx -h 2>&1)

if echo "$DNSX_HELP" | grep -q -- "-auto-wildcard"; then
    DNSX_WC_FLAG="-auto-wildcard"
elif echo "$DNSX_HELP" | grep -q -- "-wd"; then
    DNSX_WC_FLAG="-wd"
else
    DNSX_WC_FLAG=""
fi

if echo "$HTTPX_HELP" | grep -q -- "-fc"; then
    HTTPX_CODE_FLAG="-fc"
elif echo "$HTTPX_HELP" | grep -q -- "-filter-code"; then
    HTTPX_CODE_FLAG="-filter-code"
else
    HTTPX_CODE_FLAG="-code"
fi

if echo "$DNSX_HELP" | grep -q -- "-stats-interval"; then
    DNSX_STATS_FLAG="-stats -stats-interval 10"
    echo "   ✅ dnsx поддерживает живой прогресс с интервалом"
elif echo "$DNSX_HELP" | grep -q -- "-stats"; then
    DNSX_STATS_FLAG="-stats"
    echo "   ✅ dnsx поддерживает базовый живой прогресс (-stats)"
else
    DNSX_STATS_FLAG=""
    echo "   ⚠️ dnsx НЕ поддерживает -stats"
fi

if echo "$DNSX_HELP" | grep -q -- "-l"; then
    DNSX_LIST_FLAG="-l"
elif echo "$DNSX_HELP" | grep -q -- "-list"; then
    DNSX_LIST_FLAG="-list"
else
    DNSX_LIST_FLAG=""
    echo "❌ dnsx не поддерживает списки целей! Рекурсия невозможна."
    exit 1
fi

if [ ! -f "$WORDLIST" ]; then
    echo "❌ Нет основного словаря: $WORDLIST"; exit 1
fi

if [ ! -f "$WORDLIST_DEEP" ]; then
    echo "⚠️ Скачиваю глубокий словарь (assetnote/commonspeak2)..."
    curl -s -o "$WORDLIST_DEEP" \
        "https://raw.githubusercontent.com/assetnote/commonspeak2-wordlists/master/subdomains/subdomains.txt"
    if [ $? -ne 0 ] || [ ! -s "$WORDLIST_DEEP" ]; then
        echo "⚠️ Не удалось скачать словарь. Использую основной для всех уровней."
        WORDLIST_DEEP="$WORDLIST"
    else
        echo "   Словарь успешно загружен: $WORDLIST_DEEP"
    fi
fi

DNS_FLAGS=""
if [ -f "$RESOLVERS" ] && [ -s "$RESOLVERS" ]; then
    DNS_FLAGS="-r $RESOLVERS"
fi

echo "🚀 Старт рекона для $DOMAIN"
echo "📁 Папка: $OUTPUT_DIR"
echo ""

# ------------------------------------------------------------
#  1. ПАССИВНЫЙ СБОР
# ------------------------------------------------------------
if [ "$RUN_PASSIVE" -eq 1 ]; then
    echo "[1/5] Пассивный сбор..."
    > "$OUTPUT_DIR/passive_tmp1.txt"
    > "$OUTPUT_DIR/passive_tmp2.txt"
    subfinder -d "$DOMAIN" -all -silent > "$OUTPUT_DIR/passive_tmp1.txt" &
    assetfinder --subs-only "$DOMAIN" > "$OUTPUT_DIR/passive_tmp2.txt" &
    wait
    cat "$OUTPUT_DIR/passive_tmp1.txt" "$OUTPUT_DIR/passive_tmp2.txt" \
        2>/dev/null | tr -d '\r' | sort -u > "$OUTPUT_DIR/passive.txt"
    rm -f "$OUTPUT_DIR/passive_tmp1.txt" "$OUTPUT_DIR/passive_tmp2.txt"
    COUNT=$(wc -l < "$OUTPUT_DIR/passive.txt" | tr -d ' ')
    echo "   Найдено пассивно: $COUNT"
else
    touch "$OUTPUT_DIR/passive.txt"
fi

# ------------------------------------------------------------
#  ВЫЧИСЛЕНИЕ IP WILDCARD-ЗАГЛУШКИ
# ------------------------------------------------------------
echo "🔍 Поиск глобального Wildcard IP..."
WILDCARD_IP=$(dnsx -d "$DOMAIN" -w <(echo "detectwildcard123xyz") \
    $DNS_FLAGS -resp-only -silent | tr -d '\r')

if [ -n "$WILDCARD_IP" ]; then
    echo "   ⚠️ Wildcard IP: $WILDCARD_IP (будет вырезаться)"
else
    echo "   ✅ Чистый DNS"
fi

# ------------------------------------------------------------
#  2. БРУТФОРС БАЗОВОГО УРОВНЯ (2-Й УРОВЕНЬ)
# ------------------------------------------------------------
if [ "$RUN_BRUTE_BASE" -eq 1 ]; then
    echo "[2/5] Брутфорс 2-го уровня..."
    if [ -n "$WILDCARD_IP" ]; then
        head -n "$WORDLIST_LIMIT" "$WORDLIST" | \
        dnsx -d "$DOMAIN" -w - $DNS_FLAGS -rl "$RATE_LIMIT" \
        -t "$THREADS_DNS" -a -silent | grep -v "\[$WILDCARD_IP\]" | \
        awk '{print $1}' | tr -d '\r' > "$OUTPUT_DIR/brute_base.txt"
    else
        head -n "$WORDLIST_LIMIT" "$WORDLIST" | \
        dnsx -d "$DOMAIN" -w - $DNS_FLAGS -rl "$RATE_LIMIT" \
        -t "$THREADS_DNS" -silent | tr -d '\r' > "$OUTPUT_DIR/brute_base.txt"
    fi
    COUNT=$(wc -l < "$OUTPUT_DIR/brute_base.txt" | tr -d ' ')
    echo "   Найдено на 2 уровне: $COUNT"
else
    touch "$OUTPUT_DIR/brute_base.txt"
fi

# ------------------------------------------------------------
#  3. ГЕНЕРАТИВНЫЙ РЕКУРСИВНЫЙ БРУТФОРС (3-5 УРОВНИ)
# ------------------------------------------------------------
if [ "$RUN_RECURSIVE" -eq 1 ] && [ "$MAX_DEPTH" -gt 2 ]; then
    echo "[3/5] Запуск генеративного рекурсивного брутфорса..."
    
    grep -v '^#' "$WORDLIST_DEEP" | grep -v '^$' | tr -d ' ' | \
        head -n "$WORDLIST_LIMIT" > "$OUTPUT_DIR/wordlist_head.txt"
        
    cat "$OUTPUT_DIR/passive.txt" "$OUTPUT_DIR/brute_base.txt" \
        2>/dev/null | sort -u > "$OUTPUT_DIR/all_known_hosts.txt"
    > "$OUTPUT_DIR/all_recursive.txt"

    BASE_DOTS=$(echo -n "$DOMAIN" | tr -cd '.' | wc -c)

    for ((level=3; level<=MAX_DEPTH; level++)); do
        base_level=$((level - 1))
        echo "   Ищем хосты Уровня $level (на базе Уровня $base_level)..."
        
        expected_dots=$(( BASE_DOTS + base_level - 1 ))
        
        awk -v dots="$expected_dots" '{
            split($0, arr, ".");
            if (length(arr) - 1 == dots) print $0
        }' "$OUTPUT_DIR/all_known_hosts.txt" | head -n "$LEVEL_LIMIT" > "$OUTPUT_DIR/level_input.txt"
            
        COUNT_IN=$(wc -l < "$OUTPUT_DIR/level_input.txt" | tr -d ' ')
        if [ "$COUNT_IN" -eq 0 ]; then
            echo "      Нет базовых хостов уровня $base_level. Пропускаю."
            rm -f "$OUTPUT_DIR/level_input.txt"; continue
        fi
        
        echo "      Генерация строк для $COUNT_IN хостов..."
        awk -v wl="$OUTPUT_DIR/wordlist_head.txt" '
            BEGIN { while(getline < wl) { words[++i] = $0 } }
            { for(j=1; j<=i; j++) print words[j]"."$0 }
        ' "$OUTPUT_DIR/level_input.txt" > "$OUTPUT_DIR/combinations_tmp.txt"
        
        COMB_COUNT=$(wc -l < "$OUTPUT_DIR/combinations_tmp.txt" | tr -d ' ')
        echo "      Сгенерировано комбинаций: $COMB_COUNT"

        TOTAL_SECONDS=$(( COMB_COUNT / RATE_LIMIT ))
        [ "$TOTAL_SECONDS" -lt 1 ] && TOTAL_SECONDS=1
        MINUTES=$(( TOTAL_SECONDS / 60 ))
        SECONDS=$(( TOTAL_SECONDS % 60 ))
        echo "      ⏱️  Время шага: $MINUTES мин. $SECONDS сек."
        echo "      🚀 DNS проверка запущена (прогресс в консоли)..."
        
        if [ -n "$WILDCARD_IP" ]; then
            dnsx $DNSX_LIST_FLAG "$OUTPUT_DIR/combinations_tmp.txt" \
                 $DNS_FLAGS -rl "$RATE_LIMIT" -t "$THREADS_DNS" -a -silent \
                 $DNSX_STATS_FLAG -o "$OUTPUT_DIR/level_found_raw.txt"
                 
            if [ -s "$OUTPUT_DIR/level_found_raw.txt" ]; then
                grep -v "\[$WILDCARD_IP\]" "$OUTPUT_DIR/level_found_raw.txt" | \
                    awk '{print $1}' | tr -d '\r' > "$OUTPUT_DIR/level_found_clean.txt"
                mv "$OUTPUT_DIR/level_found_clean.txt" "$OUTPUT_DIR/level_found_raw.txt"
            fi
        else
            dnsx $DNSX_LIST_FLAG "$OUTPUT_DIR/combinations_tmp.txt" \
                 $DNS_FLAGS -rl "$RATE_LIMIT" -t "$THREADS_DNS" -silent \
                 $DNSX_STATS_FLAG -o "$OUTPUT_DIR/level_found_raw.txt"
                 
            if [ -s "$OUTPUT_DIR/level_found_raw.txt" ]; then
                tr -d '\r' < "$OUTPUT_DIR/level_found_raw.txt" > "$OUTPUT_DIR/level_found_clean.txt"
                mv "$OUTPUT_DIR/level_found_clean.txt" "$OUTPUT_DIR/level_found_raw.txt"
            fi
        fi
        
        if [ -s "$OUTPUT_DIR/level_found_raw.txt" ]; then
            sort -u "$OUTPUT_DIR/level_found_raw.txt" | \
                grep -F -v -f "$OUTPUT_DIR/level_input.txt" > "$OUTPUT_DIR/level_found_tmp.txt"
        else
            > "$OUTPUT_DIR/level_found_tmp.txt"
        fi
        rm -f "$OUTPUT_DIR/level_found_raw.txt"

        COUNT_FOUND=$(wc -l < "$OUTPUT_DIR/level_found_tmp.txt" | tr -d ' ')
        echo "      Найдено на уровне $level: $COUNT_FOUND"
        
        if [ "$COUNT_FOUND" -gt 0 ]; then
            cat "$OUTPUT_DIR/level_found_tmp.txt" >> "$OUTPUT_DIR/all_recursive.txt"
            cat "$OUTPUT_DIR/level_found_tmp.txt" >> "$OUTPUT_DIR/all_known_hosts.txt"
            sort -u "$OUTPUT_DIR/all_known_hosts.txt" -o "$OUTPUT_DIR/all_known_hosts.txt"
        fi
        rm -f "$OUTPUT_DIR/level_input.txt" "$OUTPUT_DIR/level_found_tmp.txt" \
              "$OUTPUT_DIR/combinations_tmp.txt"
    done
    sort -u "$OUTPUT_DIR/all_recursive.txt" > "$OUTPUT_DIR/recursive.txt"
    rm -f "$OUTPUT_DIR/wordlist_head.txt" "$OUTPUT_DIR/all_known_hosts.txt" \
          "$OUTPUT_DIR/all_recursive.txt"
else
    touch "$OUTPUT_DIR/recursive.txt"
fi

# ------------------------------------------------------------
#  4. ФИНАЛЬНОЕ ОБЪЕДИНЕНИЕ И СРЕЗ WILDCARD
# ------------------------------------------------------------
if [ "$RUN_FINAL_RESOLVE" -eq 1 ]; then
    echo "[4/5] Финальная склейка и срез Wildcard..."
    cat "$OUTPUT_DIR/passive.txt" "$OUTPUT_DIR/brute_base.txt" \
        "$OUTPUT_DIR/recursive.txt" 2>/dev/null | tr -d '\r' | sort -u | \
        dnsx -silent $DNS_FLAGS -rl "$RATE_LIMIT" -t "$THREADS_DNS" \
        $DNSX_WC_FLAG > "$OUTPUT_DIR/resolved.txt"
    COUNT=$(wc -l < "$OUTPUT_DIR/resolved.txt" | tr -d ' ')
    echo "   Итого живых хостов в DNS: $COUNT"
else
    cat "$OUTPUT_DIR/passive.txt" "$OUTPUT_DIR/brute_base.txt" \
        "$OUTPUT_DIR/recursive.txt" 2>/dev/null | tr -d '\r' \
        | sort -u > "$OUTPUT_DIR/resolved.txt"
fi

# ------------------------------------------------------------
#  5. ВЕБ-ЗОНДИРОВАНИЕ (HTTPX)
# ------------------------------------------------------------
if [ "$RUN_HTTPX" -eq 1 ]; then
    echo "[5/5] Зондирование через httpx..."
    httpx -l "$OUTPUT_DIR/resolved.txt" $HTTPX_CODE_FLAG 404 \
        -follow-redirects -t "$THREADS_HTTP" -timeout "$TIMEOUT_HTTP" \
        -silent -o "$OUTPUT_DIR/alive_subdomains.txt"
    COUNT=$(wc -l < "$OUTPUT_DIR/alive_subdomains.txt" | tr -d ' ')
    echo "   Найдено рабочих сайтов: $COUNT"
fi

echo ""
echo "🎉 Рекон завершен! Результаты в $OUTPUT_DIR/alive_subdomains.txt"
