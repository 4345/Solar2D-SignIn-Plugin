-- ----------------------------------------------------------------------------
--
-- main.lua — тестовый проект plugin.signin.
-- Итог пишется в консоль и в файл test_report.txt в DocumentsDirectory, затем проект
-- закрывается сам (os.exit). Строки «  ok   …» / «  FAIL …» и последняя «ИТОГ: …» —
-- их ищут tools/zapusk_simulyatora.py и tools/zapusk_android.py.
--
-- Проверки устроены «с обратной стороной»: если плагин не делает обещанного, проверка
-- обязана упасть. Добавляя свои, сохраняйте это свойство.
--
-- ----------------------------------------------------------------------------

local plagin = require( "plugin.signin" )

local REPORT = "test_report.txt"

local lines = {}
local failures = 0
local finished = false

local function say( text )
	lines[ #lines + 1 ] = text
	print( text )
end

local function check( cond, text )
	if cond then
		say( "  ok   " .. text )
	else
		failures = failures + 1
		say( "  FAIL " .. text )
	end
end

local function finish( why )
	if finished then return end
	finished = true
	if why then
		failures = failures + 1
		say( "  FAIL " .. why )
	end
	say( string.format( "ИТОГ: %s (провалов: %d)", failures == 0 and "все проверки пройдены" or "ЕСТЬ ПРОВАЛЫ", failures ) )
	local f = io.open( system.pathForFile( REPORT, system.DocumentsDirectory ), "w" )
	if f then
		f:write( table.concat( lines, "\n" ) )
		f:close()
	end
	timer.performWithDelay( 300, function() os.exit() end )
end

-- Ждёт выполнения условия, затем вызывает nextStep; по таймауту фиксирует провал и завершает тест
local function waitFor( what, cond, timeoutMs, nextStep )
	local started = system.getTimer()
	local t
	t = timer.performWithDelay( 20, function()
		if finished then timer.cancel( t ) return end
		if cond() then
			timer.cancel( t )
			nextStep()
		elseif system.getTimer() - started > timeoutMs then
			timer.cancel( t )
			finish( "таймаут: " .. what )
		end
	end, 0 )
end

-- Нативная часть: Android (вход через Google) и iOS (вход с Apple). На iOS
-- «device» — и телефон, и симулятор iOS из Xcode: библиотека плагина
-- слинкована в обоих.
local estAndroid = system.getInfo( "platform" ) == "android" and system.getInfo( "environment" ) == "device"
local estIOS = system.getInfo( "platform" ) == "ios" and system.getInfo( "environment" ) == "device"
local estNativnaya = estAndroid or estIOS

-- На iOS шторку Apple может понадобиться закрыть рукой (приложение с правом
-- «Вход с Apple»), отсюда запас времени.
timer.performWithDelay( estIOS and 120000 or 30000, function() finish( "общий таймаут теста" ) end )

-- Номер клиента OAuth — заведомо чужой: тест проверяет путь запроса и события,
-- а не вход. Настоящий вход возможен только в приложении, чей пакет и подпись
-- заведены у клиента OAuth (Google Cloud), — тестовое приложение не такое.
local CHUZHOY_KLIENT = "000000000000-test.apps.googleusercontent.com"

say( "=== Тест plugin.signin ===" )

-- [1] Загрузка
say( "[1] Загрузка" )
check( type( plagin ) == "table", "require вернул таблицу" )
-- Android-часть с 1.1.0 не менялась; iOS — 1.2.0; компьютер (вход Google через
-- браузер, desktop/plugin_signin.lua) — 1.3.0
local VERSIYA = estAndroid and "1.1.0" or estIOS and "1.2.0" or "1.3.0"
check( type( plagin.version ) == "function" and plagin.version() == VERSIYA,
	"version() = " .. tostring( plagin.version and plagin.version() ) .. ", ждали " .. VERSIYA )
local dostupno = plagin.isAvailable()
check( type( dostupno ) == "table" and type( dostupno.google ) == "boolean" and type( dostupno.apple ) == "boolean",
	"isAvailable() — таблица с google и apple" )
-- Google есть везде, где тест запускается: на телефоне — нативная часть, на
-- компьютере (Simulator) — вход через браузер (с 1.3.0)
check( dostupno.google == true, "google доступен (" .. tostring( dostupno.google ) .. ")" )
check( dostupno.apple == estIOS,
	"apple доступен ровно на iOS (" .. tostring( dostupno.apple ) .. ")" )

-- [2] Неверные аргументы: тип — ошибка Lua, значение — nil и сообщение
say( "[2] Неверные аргументы" )
check( not pcall( plagin.google, "клиент", function() end ), "options-строка отвергнуты ошибкой" )
check( not pcall( plagin.google, {}, 42 ), "слушатель-число отвергнут ошибкой" )
local net, netErr = plagin.google( {}, function() end )
check( net == nil and type( netErr ) == "string",
	"без serverClientId -> nil, " .. tostring( netErr ) )
if not estAndroid then
	-- На Android apple() — честный отказ без разбора аргументов
	check( not pcall( plagin.apple, "опции", function() end ), "apple: options-строка отвергнуты ошибкой" )
	check( not pcall( plagin.apple, {}, 42 ), "apple: слушатель-число отвергнут ошибкой" )
end
local ap, apErr = plagin.apple( { silent = true }, function() end )
check( ap == nil and apErr == "unsupported", "apple { silent } -> nil, " .. tostring( apErr ) )
if not estIOS then
	-- Без нативной части iOS вызов apple() ничего не открывает
	local ap2, apErr2 = plagin.apple( {}, function() end )
	check( ap2 == nil and apErr2 == "unsupported", "apple() -> nil, " .. tostring( apErr2 ) )
end

if estIOS then
	-- google() на iOS — системное окно входа Google. Его тест не открывает
	-- (окно и вопрос системы «использовать google.com для входа» ждут руки):
	-- только аргументы и общая с Apple очередь — ниже, пока Apple в полёте.
	say( "[2а] Google на iOS: аргументы" )
	local g, gErr = plagin.google( { serverClientId = CHUZHOY_KLIENT }, function() end )
	check( g == nil and gErr == "iosClientId is required", "без iosClientId -> nil, " .. tostring( gErr ) )
	local g2, gErr2 = plagin.google( { iosClientId = "не-номер-клиента" }, function() end )
	check( g2 == nil and gErr2 == "iosClientId is required", "чужой вид iosClientId -> nil, " .. tostring( gErr2 ) )
	local g3, gErr3 = plagin.google( { iosClientId = CHUZHOY_KLIENT, silent = true }, function() end )
	check( g3 == nil and gErr3 == "unsupported", "google { silent } -> nil, " .. tostring( gErr3 ) )
	check( not pcall( plagin.google, {}, 42 ), "google: слушатель-число отвергнут ошибкой" )

	-- [3] Вход с Apple: запрос уходит в AuthenticationServices, итог — событием.
	-- У тестового приложения без права «Вход с Apple» итог — сразу ошибка
	-- (1000, failed); с правом показывается шторка — её можно закрыть
	-- (cancelled) или войти (тогда проверяются токен и код).
	say( "[3] Вход с Apple" )
	local sobytiya = {}
	local pervyy = plagin.apple( { email = true, fullName = true }, function( event )
		sobytiya[ #sobytiya + 1 ] = event
	end )
	check( pervyy == true, "запрос принят" )
	local vtoroy, vtoroyErr = plagin.apple( {}, function() end )
	check( vtoroy == nil and vtoroyErr == "busy", "второй, пока первый в полёте, -> nil, " .. tostring( vtoroyErr ) )
	local tikhiy, tikhiyErr = plagin.apple( { silent = true }, function() end )
	check( tikhiy == nil and tikhiyErr == "busy", "и тихий, пока первый в полёте, -> nil, " .. tostring( tikhiyErr ) )
	-- Очередь общая: Google, пока Apple в полёте, окна не откроет
	local gz, gzErr = plagin.google( { iosClientId = CHUZHOY_KLIENT, button = true }, function() end )
	check( gz == nil and gzErr == "busy", "google, пока Apple в полёте, -> nil, " .. tostring( gzErr ) )

	waitFor( "событие входа с Apple", function() return #sobytiya > 0 end, 100000, function()
		local ev = sobytiya[ 1 ]
		say( "     событие: isError=" .. tostring( ev.isError ) .. " errorType=" .. tostring( ev.errorType )
			.. " errorMessage=" .. tostring( ev.errorMessage ) )
		check( ev.name == "signin" and ev.provider == "apple", "имя события signin, провайдер apple" )
		if ev.isError then
			check( ev.idToken == nil, "ошибка — без idToken" )
			check( ev.errorType == "failed" or ev.errorType == "cancelled",
				"тип ошибки — failed или cancelled (" .. tostring( ev.errorType ) .. ")" )
			check( type( ev.errorMessage ) == "string" and #ev.errorMessage > 0, "есть текст ошибки" )
		else
			-- Вход состоялся: identity token — JWT из трёх частей, код и номер есть
			local _, tochek = string.gsub( ev.idToken or "", "%.", "" )
			check( tochek == 2, "idToken — JWT из трёх частей" )
			check( type( ev.authorizationCode ) == "string" and #ev.authorizationCode > 0, "есть authorizationCode" )
			check( type( ev.user ) == "string" and #ev.user > 0, "есть user" )
		end

		timer.performWithDelay( 100, function()
			check( #sobytiya == 1, "событие пришло ровно одно (" .. #sobytiya .. ")" )

			-- [4] После итога очередь свободна: «busy» больше нет. Новый вход не
			-- открываем (шторка снова потребовала бы руки) — проверяем тихим:
			-- в полёте он получал «busy», свободная очередь отвечает «unsupported».
			say( "[4] Очередь после итога" )
			local t, tErr = plagin.apple( { silent = true }, function() end )
			check( t == nil and tErr == "unsupported", "после итога — снова «unsupported», не «busy» (" .. tostring( tErr ) .. ")" )

			-- [5] Выход: на iOS забывать нечего, но событие приходит, как на Android
			say( "[5] Выход" )
			local vyhod = {}
			check( plagin.signOut( { signin = function( self, event ) vyhod[ #vyhod + 1 ] = event end } ) == true,
				"signOut принят (слушатель-таблица)" )
			check( #vyhod == 0, "событие выхода не синхронное" )
			waitFor( "событие выхода", function() return #vyhod > 0 end, 10000, function()
				check( vyhod[ 1 ].name == "signin" and vyhod[ 1 ].isSignOut == true and vyhod[ 1 ].isError == false,
					"выход: событие signin, isSignOut, без ошибки" )
				finish()
			end )
		end )
	end )
	return
end

if not estNativnaya then
	-- Компьютер (Simulator, настольные приложения): вход Google через браузер и
	-- ответ на локальный адрес. Браузер тест не открывает — system.openURL
	-- подменён, адрес входа перехвачен; «ответ браузера» тест шлёт на локальный
	-- порт сам. Настоящий вход (аккаунт Google в браузере) — только руками.
	say( "[3] Компьютер: аргументы" )
	local r, e = plagin.google( { serverClientId = CHUZHOY_KLIENT }, function() end )
	check( r == nil and e == "desktopClientId is required", "без desktopClientId -> nil, " .. tostring( e ) )
	local r2, e2 = plagin.google( { desktopClientId = "не-номер-клиента" }, function() end )
	check( r2 == nil and e2 == "desktopClientId is required", "чужой вид desktopClientId -> nil, " .. tostring( e2 ) )
	local r3, e3 = plagin.google( { desktopClientId = CHUZHOY_KLIENT, silent = true }, function() end )
	check( r3 == nil and e3 == "unsupported", "google { silent } -> nil, " .. tostring( e3 ) )
	check( not pcall( plagin.google, { desktopClientId = CHUZHOY_KLIENT }, 42 ), "google: слушатель-число отвергнут ошибкой" )

	local socket = require( "socket" )
	local sobytiya = {}
	local adres

	-- Вход с перехваченным браузером; вернёт порт и state из адреса входа
	local function nachat( dop )
		adres = nil
		local opts = { desktopClientId = CHUZHOY_KLIENT, doneText = "Вход выполнен <проверка>" }
		for k, v in pairs( dop or {} ) do opts[ k ] = v end
		local nastoyashchiy = system.openURL
		system.openURL = function( u ) adres = u; return true end
		local ok = plagin.google( opts, function( ev ) sobytiya[ #sobytiya + 1 ] = ev end )
		system.openURL = nastoyashchiy
		local p = {}
		for k, v in ( adres or "" ):gmatch( "([%w_]+)=([^&]*)" ) do p[ k ] = v end
		local port = tonumber( ( p.redirect_uri or "" ):match( "127%.0%.0%.1%%3A(%d+)$" ) )
		return ok, p, port
	end

	-- «Браузер»: один запрос на локальный порт, ответ читается без блокировки
	-- (вход опрашивает порт таймером — блокирующее чтение здесь его бы остановило)
	local function brauzer( port, put, gotovo )
		local c = socket.tcp()
		c:settimeout( 2 )
		local ok = c:connect( "127.0.0.1", port )
		if not ok then return gotovo( nil ) end
		c:send( "GET " .. put .. " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" )
		c:settimeout( 0 )
		local kuski = {}
		local nachalo = system.getTimer()
		local t
		t = timer.performWithDelay( 20, function()
			local dannye, err, chast = c:receive( "*a" )
			local kusok = dannye or chast
			if kusok and #kusok > 0 then kuski[ #kuski + 1 ] = kusok end
			if err == "closed" or dannye or system.getTimer() - nachalo > 5000 then
				timer.cancel( t )
				c:close()
				gotovo( table.concat( kuski ) )
			end
		end, 0 )
	end

	say( "[4] Компьютер: адрес входа" )
	local ok, p, port = nachat( { button = true } )
	check( ok == true, "запрос принят" )
	check( adres and adres:find( "^https://accounts%.google%.com/o/oauth2/v2/auth%?" ) ~= nil, "открыт адрес входа Google" )
	check( p.client_id == CHUZHOY_KLIENT:gsub( "%-", "%%2D" ) or p.client_id == CHUZHOY_KLIENT, "client_id — клиент «Desktop app»" )
	check( port ~= nil, "возврат — http://127.0.0.1:<порт> (" .. tostring( port ) .. ")" )
	check( p.code_challenge_method == "S256" and #( p.code_challenge or "" ) == 43, "PKCE S256, вызов 43 знака" )
	check( #( p.state or "" ) == 24 and p.prompt == "select_account" and p.response_type == "code", "state, prompt, response_type" )
	local b, bErr = plagin.google( { desktopClientId = CHUZHOY_KLIENT }, function() end )
	check( b == nil and bErr == "busy", "второй, пока первый в полёте, -> nil, " .. tostring( bErr ) )

	brauzer( port, "/favicon.ico", function( otvet1 )
		check( otvet1 and otvet1:find( "^HTTP/1%.1 404" ) ~= nil, "не ответ входа (значок сайта) -> 404, вход ждёт дальше" )
		brauzer( port, "/?state=chuzhoy&code=x", function( otvet2 )
			check( otvet2 and otvet2:find( "^HTTP/1%.1 200" ) ~= nil and otvet2:find( "&lt;проверка&gt;", 1, true ) ~= nil,
				"браузер получает страницу с doneText (текст экранирован)" )
			waitFor( "событие при чужом state", function() return #sobytiya >= 1 end, 3000, function()
				local ev = sobytiya[ 1 ]
				check( ev.name == "signin" and ev.provider == "google" and ev.isError == true and ev.errorType == "failed"
					and ev.errorMessage == "state mismatch", "чужой state -> failed, state mismatch (" .. tostring( ev.errorMessage ) .. ")" )

				say( "[5] Компьютер: отказ в браузере" )
				local ok2, p2, port2 = nachat()
				check( ok2 == true and port2 ~= nil, "после итога вход снова принимается" )
				brauzer( port2, "/?error=access_denied&state=" .. tostring( p2.state ), function()
					waitFor( "событие отказа", function() return #sobytiya >= 2 end, 3000, function()
						check( sobytiya[ 2 ].isError and sobytiya[ 2 ].errorType == "cancelled", "access_denied -> cancelled" )

						say( "[6] Компьютер: обмен кода у Google" )
						local ok3, p3, port3 = nachat()
						check( ok3 == true and port3 ~= nil, "вход принят" )
						brauzer( port3, "/?code=nevernyy-kod&scope=openid&state=" .. tostring( p3.state ), function()
							waitFor( "ответ Google на обмен кода", function() return #sobytiya >= 3 end, 20000, function()
								local ev3 = sobytiya[ 3 ]
								say( "     событие: errorType=" .. tostring( ev3.errorType ) .. " errorMessage=" .. tostring( ev3.errorMessage ) )
								check( ev3.isError == true and ev3.idToken == nil and ev3.errorType == "failed"
									and tostring( ev3.errorMessage ):find( "^token request %d%d%d" ) ~= nil,
									"неверный код у настоящего Google -> failed с ответом token request" )

								say( "[6а] Компьютер: код для сервера (serverAuthCode)" )
								local ok4, p4, port4 = nachat( { serverAuthCode = true } )
								check( ok4 == true and port4 ~= nil, "вход принят" )
								brauzer( port4, "/?code=4%2Fkod&state=" .. tostring( p4.state ), function()
								waitFor( "событие с кодом", function() return #sobytiya >= 4 end, 3000, function()
								local ev4 = sobytiya[ 4 ]
								check( ev4.isError == false and ev4.idToken == nil and ev4.serverAuthCode == "4/kod"
									and #( ev4.codeVerifier or "" ) == 64 and ( ev4.redirectUri or "" ):find( "^http://127%.0%.0%.1:%d+$" ) ~= nil,
									"код, PKCE-ключ и адрес возврата — серверу, без обмена (" .. tostring( ev4.serverAuthCode ) .. ")" )

								say( "[7] Выход" )
								local vyhod = {}
								check( plagin.signOut( { signin = function( self, event ) vyhod[ #vyhod + 1 ] = event end } ) == true,
									"signOut принят (слушатель-таблица)" )
								check( #vyhod == 0, "событие выхода не синхронное" )
								waitFor( "событие выхода", function() return #vyhod > 0 end, 5000, function()
									check( vyhod[ 1 ].name == "signin" and vyhod[ 1 ].isSignOut == true and vyhod[ 1 ].isError == false,
										"выход: событие signin, isSignOut, без ошибки" )
									timer.performWithDelay( 200, function()
										check( #sobytiya == 4, "событий входа ровно четыре (" .. #sobytiya .. ")" )
										finish()
									end )
								end )
								end )
								end )
							end )
						end )
					end )
				end )
			end )
		end )
	end )
	return
end

-- [3] Тихий вход: запрос уходит в Credential Manager, итог — событием в Lua
say( "[3] Тихий вход" )
local sobytiya = {}
local pervyy = plagin.google( { serverClientId = CHUZHOY_KLIENT, silent = true }, function( event )
	sobytiya[ #sobytiya + 1 ] = event
end )
check( pervyy == true, "запрос принят" )
local vtoroy, vtoroyErr = plagin.google( { serverClientId = CHUZHOY_KLIENT, silent = true }, function() end )
check( vtoroy == nil and vtoroyErr == "busy", "второй, пока первый в полёте, -> nil, " .. tostring( vtoroyErr ) )

waitFor( "событие тихого входа", function() return #sobytiya > 0 end, 20000, function()
	local ev = sobytiya[ 1 ]
	say( "     событие: errorType=" .. tostring( ev.errorType ) .. " errorMessage=" .. tostring( ev.errorMessage ) )
	check( ev.name == "signin" and ev.provider == "google", "имя события signin, провайдер google" )
	check( ev.isError == true and ev.idToken == nil,
		"чужой клиент токена не даёт: ошибка без idToken" )
	check( ev.errorType == "noCredential" or ev.errorType == "failed",
		"тип ошибки — noCredential или failed (" .. tostring( ev.errorType ) .. ")" )
	check( type( ev.errorMessage ) == "string" and #ev.errorMessage > 0, "есть текст ошибки" )

	timer.performWithDelay( 100, function()
		check( #sobytiya == 1, "событие пришло ровно одно (" .. #sobytiya .. ")" )

		-- [4] После итога очередь свободна — новый вход принимается
		say( "[4] Новый вход после итога" )
		local esche = {}
		local tretiy = plagin.google( { serverClientId = CHUZHOY_KLIENT, silent = true },
			{ signin = function( self, event ) esche[ #esche + 1 ] = event end } )
		check( tretiy == true, "после итога вход снова принимается" )
		waitFor( "событие второго входа (слушатель-таблица)", function() return #esche > 0 end, 20000, function()
			check( esche[ 1 ].name == "signin" and esche[ 1 ].isError == true, "слушатель-таблица получает событие" )

			-- [5] Выход: сброс выбора аккаунта
			say( "[5] Выход" )
			local vyhod = {}
			check( plagin.signOut( function( event ) vyhod[ #vyhod + 1 ] = event end ) == true, "signOut принят" )
			waitFor( "событие выхода", function() return #vyhod > 0 end, 10000, function()
				check( vyhod[ 1 ].isSignOut == true and vyhod[ 1 ].isError == false,
					"выход: isSignOut, без ошибки (" .. tostring( vyhod[ 1 ].errorMessage ) .. ")" )
				finish()
			end )
		end )
	end )
end )
