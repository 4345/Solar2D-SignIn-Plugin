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

timer.performWithDelay( 30000, function() finish( "общий таймаут теста" ) end )

-- Номер клиента OAuth — заведомо чужой: тест проверяет путь запроса и события,
-- а не вход. Настоящий вход возможен только в приложении, чей пакет и подпись
-- заведены у клиента OAuth (Google Cloud), — тестовое приложение не такое.
local CHUZHOY_KLIENT = "000000000000-test.apps.googleusercontent.com"

local estNativnaya = system.getInfo( "platform" ) == "android" and system.getInfo( "environment" ) == "device"

say( "=== Тест plugin.signin ===" )

-- [1] Загрузка
say( "[1] Загрузка" )
check( type( plagin ) == "table", "require вернул таблицу" )
check( type( plagin.version ) == "function" and plagin.version() == "1.0.0",
	"version() = " .. tostring( plagin.version and plagin.version() ) )
local dostupno = plagin.isAvailable()
check( type( dostupno ) == "table" and type( dostupno.google ) == "boolean" and type( dostupno.apple ) == "boolean",
	"isAvailable() — таблица с google и apple" )
check( dostupno.google == estNativnaya,
	"google доступен ровно там, где есть нативная часть (" .. tostring( dostupno.google ) .. ")" )
check( dostupno.apple == false, "apple на этой платформе недоступен" )

-- [2] Неверные аргументы: тип — ошибка Lua, значение — nil и сообщение
say( "[2] Неверные аргументы" )
check( not pcall( plagin.google, "клиент", function() end ), "options-строка отвергнуты ошибкой" )
check( not pcall( plagin.google, {}, 42 ), "слушатель-число отвергнут ошибкой" )
local net, netErr = plagin.google( {}, function() end )
check( net == nil and type( netErr ) == "string",
	"без serverClientId -> nil, " .. tostring( netErr ) )
local ap, apErr = plagin.apple( {}, function() end )
check( ap == nil and apErr == "unsupported", "apple() -> nil, " .. tostring( apErr ) )

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
