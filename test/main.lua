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
-- Android-часть с 1.1.0 не менялась; iOS и Lua-заглушка — 1.2.0
local VERSIYA = estAndroid and "1.1.0" or "1.2.0"
check( type( plagin.version ) == "function" and plagin.version() == VERSIYA,
	"version() = " .. tostring( plagin.version and plagin.version() ) .. ", ждали " .. VERSIYA )
local dostupno = plagin.isAvailable()
check( type( dostupno ) == "table" and type( dostupno.google ) == "boolean" and type( dostupno.apple ) == "boolean",
	"isAvailable() — таблица с google и apple" )
check( dostupno.google == estNativnaya,
	"google доступен ровно там, где есть нативная часть (" .. tostring( dostupno.google ) .. ")" )
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
	-- Lua-заглушка (Simulator, настольные приложения): вход недоступен, и это
	-- честно сказано, а не изображено.
	say( "[3] Без нативной части" )
	local r, e = plagin.google( { serverClientId = CHUZHOY_KLIENT }, function() end )
	check( r == nil and e == "unsupported", "google() -> nil, " .. tostring( e ) )
	finish()
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
