// ----------------------------------------------------------------------------
//
// PluginSignIn.cpp — нативная часть plugin.signin, одна на Windows, Android, iOS и macOS
//
// ----------------------------------------------------------------------------

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "PluginSignIn.h"

#include <CoronaAssert.h>
#include <CoronaLibrary.h>

// Каркас асинхронного плагина. Что в нём уже решено:
// - рабочие потоки только кладут событие в потокобезопасную очередь; в Lua его передаёт
//   _pollEvents, который Lua-часть зовёт на каждом кадре (enterFrame). Из чужого потока
//   в Lua ходить нельзя;
// - экземпляр виден в Lua числом-хэндлом, и рабочий поток знает только хэндл: событие
//   остановленного экземпляра не находит хэндла в таблице и отбрасывается;
// - stop возвращается, когда поток экземпляра уже завершён: после stop событий нет;
// - при закрытии состояния Lua (перезапуск проекта в Simulator, os.exit) метка состояния
//   в реестре останавливает все его экземпляры: DLL и её потоки при этом живут дальше.
//
// Пример API — таймер в отдельном потоке: start(intervalMs, listener) -> handle,
// stop(handle), version(). Замените его своим, сохранив устройство.

namespace {

const char kVersion[] = "1.0.0";

struct Event {
	int handle;
	std::string name;   // имя события для слушателя (event.name)
	double count;
};

// Потокобезопасная очередь событий из рабочих потоков в главный поток Lua
class EventQueue {
public:
	void Push(Event&& ev) {
		std::lock_guard<std::mutex> lock(mutex_);
		queue_.push_back(std::move(ev));
	}

	// Забирает все накопленные события разом
	std::deque<Event> TakeAll() {
		std::lock_guard<std::mutex> lock(mutex_);
		std::deque<Event> taken;
		taken.swap(queue_);
		return taken;
	}

	// Возвращает в начало очереди события, которые должно обработать другое состояние Lua
	void PushFront(std::deque<Event>&& events) {
		std::lock_guard<std::mutex> lock(mutex_);
		queue_.insert(queue_.begin(), std::make_move_iterator(events.begin()), std::make_move_iterator(events.end()));
	}

private:
	std::mutex mutex_;
	std::deque<Event> queue_;
};

EventQueue g_EventQueue;

// Рабочий поток экземпляра. Stop ставит флаг и ждёт завершения потока: после возврата
// из Stop поток не положит в очередь ни одного события.
class Worker {
public:
	Worker(int handle, int intervalMs)
		: handle_(handle), intervalMs_(intervalMs), stopping_(false), thread_(&Worker::Run, this) {}

	~Worker() { Stop(); }

	void Stop() {
		{
			std::lock_guard<std::mutex> lock(mutex_);
			stopping_ = true;
		}
		wake_.notify_all();
		if (thread_.joinable()) {
			thread_.join();
		}
	}

private:
	void Run() {
		double count = 0;
		std::unique_lock<std::mutex> lock(mutex_);
		while (!wake_.wait_for(lock, std::chrono::milliseconds(intervalMs_), [this] { return stopping_; })) {
			count += 1;
			g_EventQueue.Push(Event{ handle_, "tick", count });
		}
	}

	int handle_;
	int intervalMs_;
	bool stopping_;
	std::mutex mutex_;
	std::condition_variable wake_;
	std::thread thread_;   // последним: поток стартует, когда остальные поля уже готовы
};

// Метка состояния Lua, в котором загружен плагин. Хранится в реестре этого состояния;
// её сборка мусора означает закрытие состояния.
struct PluginState {
	int unused;
};

// Экземпляр. Таблица экземпляров доступна только из потока Lua.
struct Instance {
	int handle;
	PluginState* owner;
	Worker* worker;
	CoronaLuaRef listener;
};

std::map<int, Instance*> g_Instances;
int g_NextHandle = 1;

const char kStateKey = 0;
const char kStateMetatable[] = "plugin.signin.state";

PluginState* GetState(lua_State* L) {
	lua_pushlightuserdata(L, (void*)&kStateKey);
	lua_rawget(L, LUA_REGISTRYINDEX);
	PluginState* state = (PluginState*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	return state;
}

Instance* FindInstance(int handle) {
	std::map<int, Instance*>::iterator it = g_Instances.find(handle);
	return it == g_Instances.end() ? NULL : it->second;
}

// Останавливает экземпляр и убирает его из таблицы; deleteRef = false при закрытии состояния Lua
void DestroyInstance(lua_State* L, Instance* inst, bool deleteRef) {
	delete inst->worker;   // ждёт завершения потока
	g_Instances.erase(inst->handle);
	if (deleteRef) {
		CoronaLuaDeleteRef(L, inst->listener);
	}
	delete inst;
}

// --- Lua API ---

// signin.version() -> строка версии нативной части
int l_version(lua_State* L) {
	lua_pushstring(L, kVersion);
	return 1;
}

// signin.start(intervalMs, listener) -> handle | nil, message
// Неверный ТИП аргумента — ошибка Lua (ошибка программиста); неверное ЗНАЧЕНИЕ или отказ
// среды — nil и сообщение, которое вызывающий может показать или записать в журнал.
int l_start(lua_State* L) {
	lua_Integer intervalMs = luaL_checkinteger(L, 1);
	int type = lua_type(L, 2);
	if (type != LUA_TFUNCTION && type != LUA_TTABLE) {
		return luaL_typerror(L, 2, "listener (function or table)");
	}
	if (intervalMs < 1 || intervalMs > 3600000) {
		lua_pushnil(L);
		lua_pushstring(L, "intervalMs must be in 1..3600000");
		return 2;
	}

	Instance* inst = new Instance();
	inst->handle = g_NextHandle++;
	inst->owner = GetState(L);
	inst->listener = CoronaLuaNewRef(L, 2);
	inst->worker = new Worker(inst->handle, (int)intervalMs);
	g_Instances[inst->handle] = inst;
	lua_pushinteger(L, inst->handle);
	return 1;
}

// signin.stop(handle). Повторная остановка и неизвестный хэндл — не ошибка.
int l_stop(lua_State* L) {
	Instance* inst = FindInstance((int)luaL_checkinteger(L, 1));
	if (inst != NULL) {
		DestroyInstance(L, inst, true);
	}
	return 0;
}

// Вызывается на каждом кадре из plugin_signin.lua: передаёт накопленные события слушателям
int l_poll_events(lua_State* L) {
	PluginState* state = GetState(L);
	std::deque<Event> events = g_EventQueue.TakeAll();
	std::deque<Event> foreign;

	for (std::deque<Event>::iterator ev = events.begin(); ev != events.end(); ++ev) {
		// Ищем экземпляр заново для каждого события: слушатель мог остановить любой экземпляр
		Instance* inst = FindInstance(ev->handle);
		if (inst == NULL) {
			continue;   // экземпляр остановлен, событие устарело
		}
		if (inst->owner != state) {
			foreign.push_back(*ev);
			continue;
		}
		CoronaLuaNewEvent(L, ev->name.c_str());
		lua_pushinteger(L, inst->handle);
		lua_setfield(L, -2, "handle");
		lua_pushnumber(L, ev->count);
		lua_setfield(L, -2, "count");
		CoronaLuaDispatchEvent(L, inst->listener, 0);
	}

	if (!foreign.empty()) {
		g_EventQueue.PushFront(std::move(foreign));
	}
	return 0;
}

// Сборка метки состояния: состояние Lua закрывается. Останавливаем все его экземпляры,
// иначе их потоки работали бы дальше, а слушатели ссылались бы на мёртвое состояние.
int l_state_gc(lua_State* L) {
	PluginState* state = (PluginState*)lua_touserdata(L, 1);
	std::vector<Instance*> mine;
	for (std::map<int, Instance*>::iterator it = g_Instances.begin(); it != g_Instances.end(); ++it) {
		if (it->second->owner == state) {
			mine.push_back(it->second);
		}
	}
	for (size_t i = 0; i < mine.size(); ++i) {
		DestroyInstance(L, mine[i], false);
	}
	return 0;
}

// Заводит метку состояния при первой загрузке плагина в этом состоянии Lua
void EnsureState(lua_State* L) {
	if (GetState(L) != NULL) {
		return;
	}
	lua_pushlightuserdata(L, (void*)&kStateKey);
	PluginState* state = (PluginState*)lua_newuserdata(L, sizeof(PluginState));
	state->unused = 0;
	if (luaL_newmetatable(L, kStateMetatable)) {
		lua_pushcfunction(L, l_state_gc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

} // namespace

// --- Регистрация плагина ---

// Загрузчик байт-кода Lua-части (CORONA_EXPORT уже включает extern "C")
CORONA_EXPORT int CoronaPluginLuaLoad_plugin_signin( lua_State * );

CORONA_EXPORT
int luaopen_plugin_signin( lua_State *L )
{
	using namespace Corona;

	EnsureState( L );

	// Таблица библиотеки строится из байт-кода Lua-части
	lua_CFunction factory = Corona::Lua::Open< CoronaPluginLuaLoad_plugin_signin >;
	int result = CoronaLibraryNewWithFactory( L, factory, NULL, NULL );

	// Нативные функции — в ту же таблицу
	static const luaL_Reg kFunctions[] = {
		{ "version", l_version },
		{ "start", l_start },
		{ "stop", l_stop },
		{ "_pollEvents", l_poll_events },
		{ NULL, NULL }
	};

	luaL_register( L, NULL, kFunctions );

	return result;
}

#ifdef __ANDROID__
#include <jni.h>

extern "C" {

// Вход из Java-класса plugin.signin.LuaLoader: он передаёт указатель на lua_State
JNIEXPORT jint JNICALL Java_plugin_signin_LuaLoader_nativeOpen(JNIEnv* env, jobject thiz, jlong lua_state_ptr) {
	lua_State* L = (lua_State*)lua_state_ptr;
	return luaopen_plugin_signin(L);
}

} // extern "C"
#endif

// Байт-код Lua-части (plugin_signin.c, делает tools/obnovit_baitkod_lua.py). Windows собирает его
// шагом LuaToCpp своего проекта, Android — отдельным файлом в CMake, а проекты Xcode собирают
// только этот файл. Подключается после объявления CoronaPluginLuaLoad_…: так определение
// получает компоновку C из объявления.
#ifdef __APPLE__
#include "plugin_signin.c"
#endif
