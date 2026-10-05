# Плагин Solar2D `plugin.signin`

Плагин для игрового движка **Solar2D**: вход через **Google** средствами системы. Приложение
получает **ID-токен Google** (JWT, подписанный Google) и проверяет его на своём сервере — так
сервер узнаёт учётную запись игрока, и тот возвращается к своему аккаунту после
переустановки, очистки данных приложения и на новом телефоне.

| Платформа | Что работает |
| :--- | :--- |
| **Android** | вход через Google ([Credential Manager](https://developer.android.com/identity/sign-in/credential-manager-siwg)): окно выбора аккаунта, тихий повторный вход, выход |
| **iOS** | в работе: вход через Google и «Вход с Apple» |
| Simulator (Windows, macOS), настольные приложения | заглушка на Lua: вход недоступен, и это сказано явно (`isAvailable()` — `false`) |

---

## 🚀 Возможности

- **Вход в одно касание.** Шторка Credential Manager со всеми Google-аккаунтами устройства:
  согласие на передачу имени, почты и фото Google показывает строкой в ней же, отдельной
  страницы нет. Шторке нечего показать (на устройстве нет Google-аккаунта или все требуют
  повторного входа) — вход сам переходит на полноэкранный выбор аккаунта, который умеет и
  добавить аккаунт. Совсем без согласия первого входа нельзя: его показывает Google.
- **Полноэкранный выбор** (`button = true`): сразу окно выбора любого аккаунта, согласие —
  отдельной страницей после выбора.
- **Тихий повторный вход** (`silent = true`): без окна, только аккаунты, которые пользователь
  уже разрешал этому приложению; если такой один — выбирается сам. Нужен, когда у приложения
  кончился свой токен сессии, а беспокоить пользователя не хочется.
- **Выход** (`signOut`): сбрасывает запомненный выбор аккаунта, следующий тихий вход вернёт
  `noCredential`.
- **Итог — событием в потоке Lua**, слушатель — функция или таблица, как везде в Solar2D.
  Одновременно идёт один вход: второй, пока первый в полёте, получает `nil, "busy"`.

---

## 🛠 Подключение к проекту Solar2D

### Способ 1 — прямые ссылки

```lua
settings =
{
	plugins =
	{
		["plugin.signin"] =
		{
			publisherId = "ovh.azi",
			supportedPlatforms =
			{
				android = { url = "https://raw.githubusercontent.com/4345/Solar2D-SignIn-Plugin/main/plugins/android/data.tgz" },
				-- Заглушка: Simulator и настольные приложения
				["win32-sim"] = { url = "https://raw.githubusercontent.com/4345/Solar2D-SignIn-Plugin/main/plugins/win32-sim/data.tgz" },
				["mac-sim"] = { url = "https://raw.githubusercontent.com/4345/Solar2D-SignIn-Plugin/main/plugins/mac-sim/data.tgz" },
				win32 = { url = "https://raw.githubusercontent.com/4345/Solar2D-SignIn-Plugin/main/plugins/win32/data.tgz" },
				macOS = { url = "https://raw.githubusercontent.com/4345/Solar2D-SignIn-Plugin/main/plugins/macOS/data.tgz" },
			},
		},
	},
}
```

**Ссылка важнее локальной копии**: если она задана, Solar2D берёт плагин по ней.

### Способ 2 — локально

```lua
plugins = { ["plugin.signin"] = { publisherId = "ovh.azi" } },
```

Архивы кладутся в `Solar2DPlugins/ovh.azi/plugin.signin/<платформа>/data.tgz`
(`%APPDATA%\Solar2DPlugins` на Windows, `~/Solar2DPlugins` на macOS). Android-архив туда
кладёт `gradlew :plugin:deployToLocalSolar2DRepo`.

### Зависимости Android

Архив `android` несёт `corona.gradle` — сборщик Solar2D применяет его сам и подключает
`androidx.credentials`, `credentials-play-services-auth`, `googleid` и **`androidx.core`**.
Последний — явно: `credentials-play-services-auth` исключает его из-под сервисов Google,
рассчитывая, что в приложении он и так есть (обычно приходит с appcompat). В приложении Solar2D
его нет, и без него первый же вход падает: `NoClassDefFoundError
androidx.core.app.ComponentActivity` в `GoogleApiAvailability.getInstance`.

---

## ⚙️ Настройка Google Cloud

Вход вернёт токен только приложению, которое заведено в проекте Google Cloud (или Firebase)
вашего сервера:

1. **Веб-клиент OAuth** (тип «Web application»). Его номер передаётся в `serverClientId`, и
   ID-токен выдаётся с `aud`, равным этому номеру, — по нему сервер отличает токены своего
   приложения от чужих.
2. **Android-клиент OAuth**: имя пакета приложения и SHA-1 сертификата, которым подписан APK.
   Если подписывает Google Play (Play App Signing) — SHA-1 ключа подписи из Play Console;
   для тестовых сборок — ещё и SHA-1 ключа, которым подписаны они. Не совпали пакет или
   подпись — окно входа заканчивается ошибкой, токена нет.
3. **Экран согласия OAuth** — опубликован (In production). Достаточно `openid`.

---

## 💻 Lua API

```lua
local signin = require( "plugin.signin" )

if signin.isAvailable().google then
	signin.google( { serverClientId = "123-abc.apps.googleusercontent.com" }, function( event )
		if event.isError then
			print( "вход не удался:", event.errorType, event.errorMessage )
		else
			-- отправить event.idToken на свой сервер и проверить там
		end
	end )
end
```

| функция | результат |
| :--- | :--- |
| `signin.version()` | строка версии |
| `signin.isAvailable()` | `{ google = логическое, apple = логическое }` |
| `signin.google( options, listener )` | `true` — запрос принят; `nil, сообщение` — нет |
| `signin.apple( options, listener )` | на Android и заглушке — `nil, "unsupported"` |
| `signin.signOut( [listener] )` | `true` — сброс принят |

`options` для `google`:

| поле | что |
| :--- | :--- |
| `serverClientId` | строка, обязательно — номер веб-клиента OAuth |
| `silent` | `true` — тихий вход (см. «Возможности») |
| `button` | `true` — сразу полноэкранный выбор аккаунта, минуя шторку |
| `nonce` | строка — попадёт в ID-токен; защита сервера от повторного использования токена |

Неверный тип аргумента (`options` не таблица, слушатель не функция и не таблица) — ошибка Lua.
Неверное значение или отказ среды — `nil, сообщение`: `"serverClientId is required"`,
`"busy"`, `"unsupported"`, `"no activity"`.

**Событие** слушателя: `name = "signin"`, `provider = "google"`, `isError`.

| при | поля |
| :--- | :--- |
| успехе | `idToken`; `displayName` и `profilePictureUri`, если Google их передал (они же есть в самом ID-токене — `name`, `picture`) |
| ошибке | `errorType`, `errorMessage` |
| выходе (`signOut`) | `isSignOut = true` |

| `errorType` | что случилось |
| :--- | :--- |
| `cancelled` | пользователь закрыл окно |
| `noCredential` | подходящего аккаунта нет (тихий вход без разрешённых аккаунтов; клиент OAuth не заведён) |
| `interrupted` | системный запрос прервался — можно повторить |
| `failed` | прочее, подробности — в `errorMessage` |

---

## 🔐 Проверка токена на сервере

ID-токену без проверки верить нельзя. Сервер проверяет:

- подпись RS256 по открытым ключам Google `https://www.googleapis.com/oauth2/v3/certs`
  (кэшировать по `Cache-Control`);
- `iss` — `accounts.google.com` или `https://accounts.google.com`;
- `aud` — номер **вашего** веб-клиента (и iOS-клиента, когда появится iOS);
- `exp` — не истёк; `nonce` — если передавали.

`sub` — постоянный номер учётной записи Google: по нему и заводится аккаунт. Почта может
смениться, `sub` — нет.

---

## 🏗 Сборка

Android — Windows или macOS: JDK 17 (подойдёт `…\Corona Labs\Corona\jre`), Android SDK,
`CORONA_ROOT` → `…\Corona Labs\Corona\Native`.

```bash
cd android && gradlew :plugin:assembleRelease && cd ..
python tools/sobrat_arhivy.py               # plugins/<платформа>/data.tgz
python tools/sobrat_arhivy.py --proverit    # архивы совпадают со сборкой
```

Заглушка для Simulator и настольных платформ — `shared/plugin_signin.lua`, упаковывается тем же
`sobrat_arhivy.py`.

---

## 🧪 Проверка

| что | как | проверок |
| :--- | :--- | :--- |
| Android на устройстве | `python tools/zapusk_android.py` (телефон по adb) | 20: загрузка, аргументы, тихий вход до ответа Google и событие в Lua, `busy`, повторный вход, слушатель-таблица, выход |
| заглушка в Simulator | `python tools/zapusk_simulyatora.py` | 10 |

Тестовое приложение не заведено ни у одного клиента OAuth, поэтому тихий вход в нём законно
кончается `noCredential`: проверяется путь запроса и события, а не выдача токена. Настоящий
токен — только в приложении с пакетом и подписью, заведёнными у Android-клиента.

---

## 📁 Структура

```
android/plugin/      Java-часть: plugin/signin/LuaLoader.java, build.gradle
android/corona.gradle  зависимости для приложения (уходит в архив android)
android/app/         тестовое приложение (шаблон Corona Native)
shared/plugin_signin.lua  заглушка для платформ без нативной части
test/                тестовый проект Solar2D
plugins/<платформа>/ готовые data.tgz
tools/               сборка архивов, прогон тестов
ios/                 в работе
```

---

## 📄 Лицензия

MIT, см. [LICENSE](LICENSE).
