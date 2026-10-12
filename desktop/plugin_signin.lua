-- ----------------------------------------------------------------------------
--
-- desktop/plugin_signin.lua — plugin.signin на компьютере: Solar2D Simulator
-- (Windows, macOS) и настольные приложения (win32, macOS). Архивы win32,
-- win32-sim, macOS и mac-sim собираются из этого файла; shared/plugin_signin.lua
-- (без входа) — основа таблицы на iOS и архив lua.
--
-- С 1.3.0 здесь есть вход через Google: OAuth 2.0 для настольных приложений —
-- системный браузер, ответ на локальный адрес http://127.0.0.1:<свободный порт>,
-- PKCE (S256). Нужен клиент OAuth типа «Desktop app» из того же проекта Google
-- Cloud, что и клиенты Android и iOS: учётная запись (sub) у них одна, и
-- сервер найдёт тот же аккаунт, что с телефона. Входа с Apple на компьютере нет.
--
-- Код из браузера меняется на ID-токен у Google одним из двух способов:
--   * сервером приложения (options.serverAuthCode = true) — плагин отдаёт код,
--     PKCE-ключ и адрес возврата. Так и надо: Google требует у клиента
--     «Desktop app» секрет (client_secret), а в приложении ему не место;
--   * самим плагином — с options.desktopClientSecret (Google без секрета
--     отвечает «client_secret is missing»).
--
-- Lua API на компьютере:
--   signin.version()                 -> "1.3.0"
--   signin.isAvailable()             -> { google = true, apple = false }
--       google = false, если нет LuaSocket, mime или crypto
--   signin.google(options, listener) -> true | nil, сообщение
--       options.desktopClientId (строка, обязательно) — клиент «Desktop app»;
--           ID-токен выдаётся с aud, равным ему, — его сервер и сверяет.
--           serverClientId и iosClientId здесь не нужны.
--       options.button = true       — выбор аккаунта каждый раз
--           (prompt=select_account)
--       options.doneText (строка)   — текст страницы в браузере после входа
--       options.serverAuthCode = true — не менять код, а отдать его (ниже)
--       options.desktopClientSecret — секрет клиента, если меняет плагин
--   options.silent = true            -> nil, "unsupported": без окна браузера
--       входа нет — как на iOS.
--   signin.apple(options, listener)  -> nil, "unsupported"
--   signin.signOut([listener])       -> true; событие isSignOut = true.
--       Забывать нечего: сессия Google — у браузера.
--
-- Событие слушателя — как у Android и iOS: name = "signin", provider =
-- "google", isError; при успехе idToken (JWT), displayName и
-- profilePictureUri (из самого ID-токена), а с serverAuthCode — вместо них
-- serverAuthCode, codeVerifier и redirectUri (их сервер шлёт в
-- https://oauth2.googleapis.com/token); при ошибке errorType
-- ("cancelled", "failed") и errorMessage. Одновременно идёт один вход: второй,
-- пока первый в полёте, -> nil, "busy". Ответа из браузера нет 5 минут —
-- "cancelled" (закрытую вкладку отличить не от чего).
--
-- ----------------------------------------------------------------------------

local Library = require "CoronaLibrary"

local lib = Library:new{ name = 'plugin.signin', publisherId = 'ovh.azi' }

local VERSION = "1.3.0"

local AVTORIZACIYA = "https://accounts.google.com/o/oauth2/v2/auth"
local TOKEN = "https://oauth2.googleapis.com/token"
local KONEC_KLIENTA = ".apps.googleusercontent.com"
local OZHIDANIE_MS = 5 * 60 * 1000
local OPROS_MS = 100

local okSocket, socket = pcall( require, "socket" )
local okMime, mime = pcall( require, "mime" )
local okCrypto, crypto = pcall( require, "crypto" )
local json = require "json"

local function etoSlushatel( listener )
	local t = type( listener )
	return t == "function" or ( t == "table" and type( listener.signin ) == "function" )
end

local function proverit( imya, options, listener )
	if type( options ) ~= "table" then
		error( "signin." .. imya .. ": options must be a table", 3 )
	end
	if not etoSlushatel( listener ) then
		error( "signin." .. imya .. ": listener must be a function or a table", 3 )
	end
end

-- Как CoronaLuaDispatchEvent: функция — вызов, таблица — её метод signin.
local function otdat( listener, event )
	event.name = "signin"
	if type( listener ) == "function" then
		listener( event )
	else
		listener:signin( event )
	end
end

local function dostupen()
	return okSocket and okMime and okCrypto and type( socket ) == "table" and type( socket.bind ) == "function"
		and type( crypto ) == "table" and crypto.sha256 ~= nil
end

-- Случайная строка из алфавита PKCE (RFC 7636, unreserved). Источник —
-- /dev/urandom (macOS); где его нет (Windows), байты — SHA-256 от часов,
-- адресов таблиц и счётчика: не криптостойко, но вход идёт на своём же
-- компьютере, а перехватить код можно, только уже сидя на нём.
local ALFAVIT = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
local schetchik = 0
local function sluchaynyeBayty( n )
	local f = io.open( "/dev/urandom", "rb" )
	if f then
		local b = f:read( n )
		f:close()
		if b and #b == n then return b end
	end
	schetchik = schetchik + 1
	local zatravka = table.concat( { tostring( socket.gettime() ), tostring( os.clock() ), tostring( {} ),
		tostring( os.time() ), tostring( schetchik ), tostring( math.random() ) }, "|" )
	local bayty = ""
	while #bayty < n do
		bayty = bayty .. crypto.digest( crypto.sha256, zatravka .. "|" .. #bayty, true )
	end
	return bayty:sub( 1, n )
end

local function sluchaynaya( n )
	local b = sluchaynyeBayty( n )
	local out = {}
	for i = 1, n do
		local j = b:byte( i ) % #ALFAVIT + 1
		out[ i ] = ALFAVIT:sub( j, j )
	end
	return table.concat( out )
end

local function base64url( raw )
	return ( mime.b64( raw ):gsub( "%+", "-" ):gsub( "/", "_" ):gsub( "=", "" ) )
end

local function kodirovat( s )
	return ( tostring( s ):gsub( "[^%w%-%._~]", function( c ) return string.format( "%%%02X", c:byte() ) end ) )
end

local function raskodirovat( s )
	return ( s:gsub( "%+", " " ):gsub( "%%(%x%x)", function( h ) return string.char( tonumber( h, 16 ) ) end ) )
end

local function razobratZapros( s )
	local t = {}
	for k, v in s:gmatch( "([^&=]+)=([^&]*)" ) do
		t[ raskodirovat( k ) ] = raskodirovat( v )
	end
	return t
end

local function sobratZapros( p )
	local klyuchi = {}
	for k in pairs( p ) do klyuchi[ #klyuchi + 1 ] = k end
	table.sort( klyuchi )
	local chasti = {}
	for _, k in ipairs( klyuchi ) do chasti[ #chasti + 1 ] = k .. "=" .. kodirovat( p[ k ] ) end
	return table.concat( chasti, "&" )
end

-- Полезная нагрузка ID-токена: только имя и картинка для события — подпись
-- проверяет сервер, ему токен и уходит.
local function poleznayaNagruzka( token )
	local chast = token:match( "^[^.]+%.([^.]+)%." )
	if not chast then return {} end
	chast = chast:gsub( "%-", "+" ):gsub( "_", "/" )
	chast = chast .. string.rep( "=", ( 4 - #chast % 4 ) % 4 )
	local ok, t = pcall( json.decode, mime.unb64( chast ) )
	return ( ok and type( t ) == "table" ) and t or {}
end

local function html( tekst )
	return ( tostring( tekst ):gsub( "&", "&amp;" ):gsub( "<", "&lt;" ):gsub( ">", "&gt;" ) )
end

local idyot = nil -- вход в полёте

function lib.version()
	return VERSION
end

function lib.isAvailable()
	return { google = dostupen() and true or false, apple = false }
end

function lib.google( options, listener )
	proverit( "google", options, listener )
	local klient = options.desktopClientId
	if type( klient ) ~= "string" or #klient <= #KONEC_KLIENTA or klient:sub( -#KONEC_KLIENTA ) ~= KONEC_KLIENTA then
		return nil, "desktopClientId is required"
	end
	if options.silent then
		return nil, "unsupported"
	end
	if not dostupen() then
		return nil, "unsupported"
	end
	if idyot then
		return nil, "busy"
	end

	local server, oshibkaPorta = socket.bind( "127.0.0.1", 0 )
	if not server then
		return nil, "loopback listener: " .. tostring( oshibkaPorta )
	end
	server:settimeout( 0 )
	local _, port = server:getsockname()
	local vozvrat = "http://127.0.0.1:" .. tostring( port )
	local verifikator = sluchaynaya( 64 )
	local sostoyanie = sluchaynaya( 24 )
	local p = {
		client_id = klient,
		redirect_uri = vozvrat,
		response_type = "code",
		scope = "openid email profile",
		code_challenge = base64url( crypto.digest( crypto.sha256, verifikator, true ) ),
		code_challenge_method = "S256",
		state = sostoyanie,
	}
	if options.button then
		p.prompt = "select_account"
	end

	local vhod = {}
	idyot = vhod
	local function zakryt()
		if vhod.taimer then
			timer.cancel( vhod.taimer )
			vhod.taimer = nil
		end
		pcall( server.close, server )
	end
	local function zavershit( event )
		if idyot ~= vhod then return end
		idyot = nil
		zakryt()
		event.provider = "google"
		otdat( listener, event )
	end
	local function oshibka( tip, tekst )
		zavershit( { isError = true, errorType = tip, errorMessage = tekst } )
	end

	local function obmenyat( kod )
		local telo = {
			code = kod,
			client_id = klient,
			code_verifier = verifikator,
			grant_type = "authorization_code",
			redirect_uri = vozvrat,
		}
		if type( options.desktopClientSecret ) == "string" and options.desktopClientSecret ~= "" then
			telo.client_secret = options.desktopClientSecret
		end
		network.request( TOKEN, "POST", function( e )
			if idyot ~= vhod then return end
			if e.isError then
				return oshibka( "failed", "token request: " .. tostring( e.response ) )
			end
			local ok, t = pcall( json.decode, e.response or "" )
			t = ( ok and type( t ) == "table" ) and t or {}
			if tonumber( e.status ) ~= 200 or type( t.id_token ) ~= "string" then
				return oshibka( "failed", "token request " .. tostring( e.status ) .. ": "
					.. tostring( t.error_description or t.error or "no id_token" ) )
			end
			local n = poleznayaNagruzka( t.id_token )
			zavershit( { isError = false, idToken = t.id_token, displayName = n.name, profilePictureUri = n.picture } )
		end, { headers = { [ "Content-Type" ] = "application/x-www-form-urlencoded" }, body = sobratZapros( telo ) } )
	end

	local nachalo = system.getTimer()
	vhod.taimer = timer.performWithDelay( OPROS_MS, function()
		if idyot ~= vhod then return end
		if system.getTimer() - nachalo > OZHIDANIE_MS then
			return oshibka( "cancelled", "no answer from the browser" )
		end
		local s = server:accept()
		if not s then return end
		s:settimeout( 2 )
		local stroka = s:receive( "*l" )
		repeat
			local zagolovok = s:receive( "*l" )
		until not zagolovok or zagolovok == ""
		local zapros = razobratZapros( ( stroka or "" ):match( "^GET [^%s?]*%?(%S*)" ) or "" )
		if not ( zapros.code or zapros.error ) then
			-- Не ответ входа (значок сайта и т. п.) — ждём дальше
			s:send( "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" )
			s:close()
			return
		end
		local tekst = options.doneText or "Done. You can close this tab and return to the app."
		s:send( "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
			.. "<!doctype html><meta charset=utf-8><title>Sign-in</title>"
			.. "<p style='font:20px sans-serif;margin:3em'>" .. html( tekst ) .. "</p>" )
		s:close()
		if zapros.state ~= sostoyanie then
			return oshibka( "failed", "state mismatch" )
		end
		if zapros.error then
			return oshibka( zapros.error == "access_denied" and "cancelled" or "failed", zapros.error )
		end
		-- Ответ получен: слушать больше нечего, дальше — обмен кода
		zakryt()
		if options.serverAuthCode then
			return zavershit( { isError = false, serverAuthCode = zapros.code, codeVerifier = verifikator,
				redirectUri = vozvrat } )
		end
		obmenyat( zapros.code )
	end, 0 )

	if system.openURL( AVTORIZACIYA .. "?" .. sobratZapros( p ) ) == false then
		idyot = nil
		zakryt()
		return nil, "browser did not open"
	end
	return true
end

function lib.apple( options, listener )
	proverit( "apple", options, listener )
	return nil, "unsupported"
end

function lib.signOut( listener )
	if listener ~= nil and not etoSlushatel( listener ) then
		error( "signin.signOut: listener must be a function or a table", 2 )
	end
	if listener then
		timer.performWithDelay( 1, function()
			otdat( listener, { provider = "google", isError = false, isSignOut = true } )
		end )
	end
	return true
end

return lib
