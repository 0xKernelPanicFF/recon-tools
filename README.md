# recon-tools

Набор скриптов для автоматизации задач разведки и веб-фаззинга, написанных с помощью ИИ в ходе практики на баг-баунти и пентестах.
Скрипты протестированы и исправлены под полным контролем автора. 

---

## Структура

- `recon/dns_recon.sh` – многоуровневый DNS-брутфорс + пассивный сбор
- `web/dir_fuzzer.sh` – интенсивный фаззинг директорий с поддержкой прокси

---

## Зависимости

Обязательные утилиты:
- bash (≥4.0)
- subfinder – пассивный сбор поддоменов
- assetfinder – альтернативный пассивный сбор
- dnsx – быстрый DNS-разрешитель с поддержкой брутфорса
- httpx – веб-зондирование живых хостов
- python3 (для dirsearch)
- curl – для скачивания словарей и прокси

Опционально:
- dirsearch – установите из репозитория maurosoria/dirsearch
- Словари: SecLists, commonspeak2

---

## Установка и настройка

1. Клонирование:
   git clone https://github.com/0xKernelPanicFF/recon-tools.git
   cd recon-tools

2. Установка зависимостей (пример для Debian/Ubuntu):
   go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
   go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest
   go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
   go install -v github.com/tomnomnom/assetfinder@latest
   git clone https://github.com/maurosoria/dirsearch.git ~/tools/dirsearch

3. Скачивание словарей:
   git clone https://github.com/danielmiessler/SecLists.git ~/SecLists
   curl -o ~/SecLists/Discovery/DNS/subdomains_deep.txt \

---

## Использование

### DNS-рекон (recon/dns_recon.sh)

Назначение: полный сбор поддоменов целевого домена: пассивный поиск, брутфорс 2-го уровня, рекурсивный генеративный брутфорс до 5-го уровня, фильтрация wildcard, веб-зондирование живых хостов.

Запуск:
   cd recon
   ./dns_recon.sh

По умолчанию сканируется домен magnit.ru. Чтобы изменить домен, отредактируйте переменную DOMAIN в начале файла.

Результаты:
- recon_<domain>/alive_subdomains.txt – список рабочих HTTP/HTTPS-хостов
- recon_<domain>/resolved.txt – все разрешённые поддомены
- Промежуточные файлы: passive.txt, brute_base.txt, recursive.txt

Управление:
- Ctrl+C – временно останавливает выполнение и запрашивает подтверждение на полное прерывание (с очисткой временных файлов).

---

### Фаззинг директорий (web/dir_fuzzer.sh)

Назначение: массовое сканирование путей на всех живых хостах с использованием dirsearch. Поддерживает работу через прокси, автоматическое обновление списка прокси, подбор флагов под версию dirsearch.

Запуск:
   cd web
   ./dir_fuzzer.sh

Скрипт читает цели из файла alive_subdomains.txt (по умолчанию).

Настройки в файле:
- DOMAINS_FILE – путь к списку целей
- WORDLIST – словарь для фаззинга
- OUTPUT_DIR – папка для результатов
- RATE_LIMIT, THREADS, TIMEOUT_HTTP – регулировка производительности
- PROXIES_FILE – файл со списком прокси (обновляется при AUTO_UPDATE_PROXIES=1)
- KEEP_EMPTY_REPORTS – оставлять ли папки с пустыми отчётами

Результаты:
- Для каждого домена: full_scan_results/<домен>/
   - raw_report.txt – полный вывод dirsearch
   - found_paths.txt – найденные пути с HTTP-кодами
- Общий файл all_found_paths.txt со всеми путями по всем целям.

Управление:
- Ctrl+C – прерывает текущий процесс dirsearch и предлагает продолжить или выйти.
- При повторном запуске пропускает уже обработанные домены (список в processed_domains.txt).

---

## Важные замечания

1. Скорость и нагрузка – скрипты генерируют высокую нагрузку. Используйте разумные значения RATE_LIMIT и THREADS.
2. Прокси – при использовании публичных прокси увеличьте TIMEOUT_HTTP до 12–15 секунд.
3. Словари – убедитесь, что все пути к словарям существуют.
4. Права на выполнение – перед запуском дайте права: chmod +x recon/*.sh web/*.sh

---

## Лицензия

MIT. Вы можете свободно использовать, модифицировать и распространять код.

---

## Автор

0xKernelPanicFF
- GitHub: https://github.com/0xKernelPanicFF
- Standoff 365: https://standoff365.com/profile/ZORG/

---

## Вклад и обратная связь

Предложения и замечания приветствуются через Issues и Pull Requests.
   
     https://raw.githubusercontent.com/assetnote/commonspeak2-wordlists/master/subdomains/subdomains.txt
   curl -o ~/resolvers/resolvers.txt \
     https://raw.githubusercontent.com/projectdiscovery/public-resolvers/master/resolvers.txt
