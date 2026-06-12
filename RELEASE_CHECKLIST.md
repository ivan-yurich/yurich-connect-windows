# Yurich Connect Windows Release Checklist

- [ ] Версия обновлена в `pubspec.yaml`.
- [ ] Версия обновлена в `lib/src/screens/home_screen.dart`.
- [ ] Версия обновлена в `windows/installer/setup/Program.cs`.
- [ ] Changelog заполнен в GitHub Release.
- [ ] `flutter analyze` прошёл.
- [ ] `flutter test` прошёл.
- [ ] Windows release build собран с `--release --split-debug-info`.
- [ ] По возможности включена obfuscation Dart-кода.
- [ ] Portable ZIP собран.
- [ ] Portable ZIP содержит корневую папку `Yurich Connect/`.
- [ ] Installer собран.
- [ ] SHA256 создан для `YurichConnect_Setup.exe`.
- [ ] SHA256 создан для `YurichConnect_Windows_Portable.zip`.
- [ ] `YurichConnect.exe` подписан.
- [ ] `YurichConnect_Setup.exe` подписан.
- [ ] Проверена установка поверх старой версии.
- [ ] Проверено удаление.
- [ ] Проверен запуск от администратора.
- [ ] Проверено подключение VLESS Reality.
- [ ] Проверено подключение VLESS TLS.
- [ ] Проверено подключение NaiveProxy.
- [ ] Проверено подключение Hysteria/Hysteria2.
- [ ] Проверено обновление через приложение.
- [ ] Проверена кнопка **Починить подключение**.
- [ ] Проверена диагностика и маскировка секретов.
- [ ] Проверен русский интерфейс.
- [ ] Проверено, что старый бренд Aurum VPN не виден пользователю.

## Подпись файлов

Подписывать нужно:

- `release\windows\YurichConnect_Windows_Portable\Yurich Connect\YurichConnect.exe`
- `release\windows\YurichConnect_Setup.exe`

Пример команды зависит от сертификата:

```powershell
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a YurichConnect_Setup.exe
```

