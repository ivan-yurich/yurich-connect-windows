# Yurich Connect для Windows

**Yurich Connect** - Windows-клиент Yurich Desktop для подключения через Yurich Core, sing-box, NaiveProxy и Wintun.

## Возможности

- VLESS Reality и VLESS TLS.
- NaiveProxy через sing-box или bundled `naive.exe`.
- Hysteria и Hysteria2.
- Импорт профилей по ссылке, подписке, QR, буферу обмена и вручную.
- Windows TUN/Wintun режим.
- Split tunneling по `.exe` файлам.
- Постоянный VPN для выбранных приложений.
- Автостарт с Windows и автоподключение выбранного профиля.
- Проверка обновлений через GitHub Releases.
- Диагностика, логи и отчёт с маскировкой секретов.
- Installer и portable-сборка.

## Установка

1. Скачайте `YurichConnect_Setup.exe` из GitHub Releases.
2. Запустите установщик.
3. Разрешите Windows UAC.
4. После установки запустите Yurich Connect.

Portable-версия: распакуйте `YurichConnect_Windows_Portable.zip`, откройте папку `Yurich Connect` и запустите `YurichConnect.exe` или `START_YURICH_CONNECT.cmd`.

## Почему нужны права администратора

Yurich Connect использует Windows TUN/Wintun. Для создания сетевого интерфейса и маршрутов Windows нужны права администратора. Если приложение запущено без прав, оно покажет окно с кнопкой **Перезапустить от имени администратора**.

## Логи и диагностика

Логи находятся в:

- `%APPDATA%\Yurich Connect\logs\yurich.log`
- `%APPDATA%\Yurich Connect\logs\sing-box.log`
- `%APPDATA%\Yurich Connect\logs\naive.log`

Диагностический отчёт сохраняется в:

- `%APPDATA%\Yurich Connect\diagnostics\report.zip`

UUID, пароли, токены, ссылки подписок и ключи маскируются автоматически.

## Если пропал интернет

Откройте Yurich Connect и нажмите **Починить подключение**. Приложение остановит свои процессы, очистит временные конфиги и выполнит flush DNS. Профили и подписки не удаляются.

