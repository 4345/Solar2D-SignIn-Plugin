# Плагин Solar2D `plugin.signin`

Плагин для игрового движка **Solar2D**: вход через **Google** и **«Вход с Apple»** средствами
системы. Приложение получает **ID-токен** провайдера (JWT, подписанный Google или Apple) и
проверяет его на своём сервере — так сервер узнаёт учётную запись игрока, и тот возвращается к
своему аккаунту после переустановки, очистки данных приложения и на новом телефоне.

| Платформа | Что работает |
| :--- | :--- |
| **Android** | вход через Google ([Credential Manager](https://developer.android.com/identity/sign-in/credential-manager-siwg)): окно выбора аккаунта, тихий повторный вход, выход |
| **iOS** (с 1.2.0) | «Вход с Apple» ([AuthenticationServices](https://developer.apple.com/documentation/authenticationservices)) и вход через Google (OAuth 2.0 с PKCE в системном окне `ASWebAuthenticationSession`, без SDK Google) |
| Simulator (Windows, macOS), настольные приложения (с 1.3.0) | вход через Google в браузере компьютера: OAuth 2.0 для настольных приложений, ответ на `http://127.0.0.1:<порт>`, PKCE (S256). Нужен клиент OAuth типа «Desktop app»; код на токен меняет ваш сервер (`serverAuthCode`) — у такого клиента Google требует секрет, и в приложении ему не место. Вход с Apple — нет |

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
- **iOS: «Вход с Apple»** — системная шторка «Продолжить с Apple ID»; событие несёт ещё и
  `authorizationCode` — сервер меняет его на refresh token Apple и отзывает при удалении
  аккаунта (этого требует App Store).
- **iOS: вход через Google** — страница входа Google в системном окне Safari (его cookie
  общие: вошедшему в Google в Safari хватает касания аккаунта). Перед окном iOS спрашивает
  «Приложение хочет использовать google.com для входа» — это вопрос системы, его не убрать.
- **iOS: тихого входа нет** ни у одного: `silent = true` отвечает `nil, "unsupported"` —
  повторный вход всегда показывает окно провайдера.

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
				iphone = { url = "https://raw.githubusercontent.com/4345/Solar2D-SignIn-Plugin/main/plugins/iphone/data.tgz" },
				["iphone-sim"] = { url = "https://raw.githubusercontent.com/4345/Solar2D-SignIn-Plugin/main/plugins/iphone-sim/data.tgz" },
				-- Компьютер: Simulator и настольные приложения (вход Google через браузер, с 1.3.0)
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

### iOS: право «Вход с Apple»

Без права приложения шторка Apple сразу кончается ошибкой 1000 (`failed`). В `build.settings`:

```lua
iphone =
{
	entitlements =
	{
		["com.apple.developer.applesignin"] = { "Default" },
	},
},
```

и у идентификатора приложения (App ID) в Apple Developer — возможность **Sign in with Apple**
(профиль подписи после этого выпустить заново). Входу через Google на iOS ничего этого не
нужно: схему возврата окно ловит само, в `Info.plist` её регистрировать не надо.

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
3. **iOS-клиент OAuth** (для iOS): bundle ID приложения. Его номер передаётся в `iosClientId`,
   и ID-токен выдаётся с `aud`, равным ЕМУ (не веб-клиенту), — добавьте его в список аудиторий
   сервера. Адрес возврата — обратный номер клиента
   (`com.googleusercontent.apps.<номер>:/oauth2redirect`), Google принимает его у iOS-клиента сам.
4. **Экран согласия OAuth** — опубликован (In production). Достаточно `openid`.

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
| `signin.apple( options, listener )` | iOS — как `google`; на Android и компьютере — `nil, "unsupported"` |
| `signin.signOut( [listener] )` | `true` — сброс принят (на iOS забывать нечего — только событие) |

`options` для `google` на компьютере (Simulator, настольные приложения, с 1.3.0):

| поле | что |
| :--- | :--- |
| `desktopClientId` | строка, обязательно — клиент OAuth типа «Desktop app» того же проекта Google Cloud: учётная запись (`sub`) та же, что с телефона |
| `serverAuthCode = true` | не менять код, а отдать его: событие несёт `serverAuthCode`, `codeVerifier` и `redirectUri` вместо `idToken` — сервер шлёт их с секретом клиента в `https://oauth2.googleapis.com/token` (`grant_type=authorization_code`) и получает ID-токен |
| `desktopClientSecret` | секрет клиента — если код меняет сам плагин (без `serverAuthCode`); Google без него отвечает `client_secret is missing` |
| `button = true` | выбор аккаунта каждый раз (`prompt=select_account`) |
| `doneText` | текст страницы в браузере после входа |
| `silent = true` | `nil, "unsupported"`: без окна браузера входа нет |

Браузер открывается системный (`system.openURL`); ответа нет 5 минут — событие `cancelled`.

`options` для `google` на телефоне:

| поле | что |
| :--- | :--- |
| `serverClientId` | строка, обязательно на Android — номер веб-клиента OAuth |
| `iosClientId` | строка, обязательно на iOS — номер iOS-клиента OAuth |
| `silent` | `true` — тихий вход (см. «Возможности»); на iOS — `nil, "unsupported"` |
| `button` | `true` — сразу полноэкранный выбор аккаунта, минуя шторку; на iOS — выбор аккаунта каждый раз (`prompt=select_account`) |
| `nonce` | строка — попадёт в ID-токен; защита сервера от повторного использования токена (Android) |

`options` для `apple` (iOS):

| поле | что |
| :--- | :--- |
| `email`, `fullName` | `true` — попросить почту и имя. Apple отдаёт их **только при первом входе** в приложение |
| `nonce` | строка — попадёт в identity token как есть |
| `silent` | `nil, "unsupported"` |

Неверный тип аргумента (`options` не таблица, слушатель не функция и не таблица) — ошибка Lua.
Неверное значение или отказ среды — `nil, сообщение`: `"serverClientId is required"`,
`"iosClientId is required"`, `"busy"`, `"unsupported"`, `"no activity"`.

**Событие** слушателя: `name = "signin"`, `provider` (`"google"` / `"apple"`), `isError`.

| при | поля |
| :--- | :--- |
| успехе, Google | `idToken`; `displayName` и `profilePictureUri`, если Google их передал (они же есть в самом ID-токене — `name`, `picture`) |
| успехе, Apple | `idToken` (identity token), `authorizationCode`, `user`; `email`, `displayName` — если просили и это первый вход |
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
- `aud` — номер **вашего** веб-клиента (Android) и iOS-клиента (iOS);
- `exp` — не истёк; `nonce` — если передавали.

`sub` — постоянный номер учётной записи Google: по нему и заводится аккаунт. Почта может
смениться, `sub` — нет.

**Apple** — то же: ключи `https://appleid.apple.com/auth/keys`, `iss` —
`https://appleid.apple.com`, `aud` — bundle ID приложения, `sub` — постоянный номер
пользователя у вашей команды разработчиков (он же `user` в событии).

**Удаление аккаунта и Apple.** App Store требует при удалении аккаунта отозвать доступ «Входа
с Apple» через REST API: сервер при входе меняет `authorizationCode` на refresh token
(`POST https://appleid.apple.com/auth/token`, `grant_type=authorization_code`; код живёт 5
минут и годен один раз), хранит его, а при удалении зовёт
`POST https://appleid.apple.com/auth/revoke`. Обоим запросам нужен `client_secret` — JWT ES256,
подписанный ключом «Sign in with Apple» (`.p8`, Apple Developer → Keys): `iss` — Team ID,
`sub` — bundle ID, `aud` — `https://appleid.apple.com`, в заголовке `kid` — Key ID.

---

## 🏗 Сборка

Android — Windows или macOS: JDK 17 (подойдёт `…\Corona Labs\Corona\jre`), Android SDK,
`CORONA_ROOT` → `…\Corona Labs\Corona\Native`.

```bash
cd android && gradlew :plugin:assembleRelease && cd ..
python tools/sobrat_arhivy.py               # plugins/<платформа>/data.tgz
python tools/sobrat_arhivy.py --proverit    # архивы совпадают со сборкой
```

Компьютер (win32, win32-sim, macOS, mac-sim) — `desktop/plugin_signin.lua`, упаковывается тем же
`sobrat_arhivy.py`. Заглушка `shared/plugin_signin.lua` (архив lua) — основа таблицы на iOS: она
вшита в библиотеку байт-кодом (`shared/plugin_signin.c`); правили её —
`python tools/obnovit_baitkod_lua.py`.

iOS — только на macOS (Xcode, Corona Native):

```bash
cd ios && ./deployLocal.sh && cd ..         # BuiltPlugin/iphone, iphone-sim (+ ~/Solar2DPlugins)
python3 tools/sobrat_arhivy.py iphone iphone-sim
```

---

## 🧪 Проверка

| что | как | проверок |
| :--- | :--- | :--- |
| Android на устройстве | `python tools/zapusk_android.py` (телефон по adb) | 20: загрузка, аргументы, тихий вход до ответа Google и событие в Lua, `busy`, повторный вход, слушатель-таблица, выход |
| компьютер без Simulator | `python tools/proverka_kompyuter.py` (lupa: настоящий `desktop/plugin_signin.lua`, настоящие сокеты, обмен кода у настоящего Google) | 24 |
| компьютер в Simulator | `python tools/zapusk_simulyatora.py` (закрывает открытый Simulator) | адрес входа и PKCE, ответы на локальный порт (чужой запрос, чужой `state`, отказ), обмен у Google, `serverAuthCode`, `busy`, выход |
| iOS (симулятор iOS, iPhone) | `ios/App.xcodeproj` | загрузка, аргументы обоих входов, вход с Apple до события в Lua, общая очередь `busy`, выход. Окно Google тест не открывает — его проверяют в приложении руками |

Тестовое приложение не заведено ни у одного клиента OAuth, поэтому тихий вход в нём законно
кончается `noCredential`: проверяется путь запроса и события, а не выдача токена. Настоящий
токен — только в приложении с пакетом и подписью, заведёнными у Android-клиента.

---

## 📁 Структура

```
android/plugin/      Java-часть: plugin/signin/LuaLoader.java, build.gradle
android/corona.gradle  зависимости для приложения (уходит в архив android)
android/app/         тестовое приложение (шаблон Corona Native)
desktop/plugin_signin.lua компьютер: вход Google через браузер (архивы win32, win32-sim, macOS, mac-sim)
shared/plugin_signin.lua  заглушка (архив lua) и основа таблицы на iOS
shared/PluginSignIn.mm    iOS: вход с Apple и через Google
shared/plugin_signin.c    байт-код заглушки для iOS (tools/obnovit_baitkod_lua.py)
test/                тестовый проект Solar2D
plugins/<платформа>/ готовые data.tgz
tools/               сборка архивов, прогон тестов
ios/                 Xcode: библиотека (Plugin.xcodeproj), тестовое приложение (App.xcodeproj)
```

---

## 📄 Лицензия

MIT, см. [LICENSE](LICENSE).
