-- ----------------------------------------------------------------------------
--
-- plugin_signin.lua — plugin.signin там, где нативной части нет: Solar2D
-- Simulator (Windows, macOS) и настольные приложения. Входа через Google и
-- Apple на этих платформах нет, и заглушка честно говорит об этом:
-- isAvailable() отвечает false, google() и apple() — nil, "unsupported".
-- Аргументы проверяются так же, как в нативной части, — ошибка программиста
-- видна уже в Simulator, а не только на телефоне.
--
-- ----------------------------------------------------------------------------

local Library = require "CoronaLibrary"

local lib = Library:new{ name = 'plugin.signin', publisherId = 'ovh.azi' }

local VERSION = "1.0.0"

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

function lib.version()
	return VERSION
end

function lib.isAvailable()
	return { google = false, apple = false }
end

function lib.google( options, listener )
	proverit( "google", options, listener )
	if type( options.serverClientId ) ~= "string" or options.serverClientId == "" then
		return nil, "serverClientId is required"
	end
	return nil, "unsupported"
end

function lib.apple( options, listener )
	proverit( "apple", options, listener )
	return nil, "unsupported"
end

function lib.signOut( listener )
	return false
end

return lib
