// ----------------------------------------------------------------------------
//
// PluginSignIn.h
//
// ----------------------------------------------------------------------------

#ifndef _PluginSignIn_H__
#define _PluginSignIn_H__

#include <CoronaLua.h>
#include <CoronaMacros.h>

// Экспортируемая функция инициализации библиотеки Lua для Corona/Solar2D.
// Имя соответствует вызову require "plugin.signin"
CORONA_EXPORT int luaopen_plugin_signin( lua_State *L );

#endif // _PluginSignIn_H__
