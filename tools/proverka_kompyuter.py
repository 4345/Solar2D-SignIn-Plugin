"""Проверка входа Google на компьютере (desktop/plugin_signin.lua) без Simulator.
    python tools/proverka_kompyuter.py

Гоняет НАСТОЯЩИЙ desktop/plugin_signin.lua через lupa. Сокеты — настоящие
(Python), «браузер» — поток Python, который шлёт ответ на локальный порт; обмен
кода идёт к настоящему Google (заведомо чужой клиент и неверный код — ждём
отказ). Заглушки — только у того, что даёт Solar2D: CoronaLibrary, timer,
system, network (через urllib), crypto, mime, json. Окончательная проверка —
тестовый проект test/ в Simulator (tools/zapusk_simulyatora.py) и вход руками.
"""
import base64
import hashlib
import json
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from lupa import lua51

KOREN = Path(__file__).resolve().parent.parent
CHUZHOY = "000000000000-test.apps.googleusercontent.com"
provalov = 0


def proverit(imya, uslovie, podrobno=""):
    global provalov
    print(("  ok   " + imya) if uslovie else ("  FAIL %s -- %s" % (imya, podrobno)))
    if not uslovie:
        provalov += 1


L = lua51.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
G = L.globals()


def b(s):  # строка Lua (latin-1) -> байты
    return s.encode("latin-1") if isinstance(s, str) else s


# --- сокеты: Python, обёртка с методами — в Lua ниже ---
SOKETY, N = {}, [0]


def py_bind(host, port):
    s = socket.socket()
    s.bind((host, int(port)))
    s.listen(4)
    N[0] += 1
    SOKETY[N[0]] = s
    return N[0]


def py_settimeout(i, t):
    SOKETY[i].settimeout(None if t is None else float(t))


def py_getsockname(i):
    h, p = SOKETY[i].getsockname()
    return h, p


def py_accept(i):
    try:
        c, _ = SOKETY[i].accept()
    except (BlockingIOError, socket.timeout):
        return None
    N[0] += 1
    SOKETY[N[0]] = c
    c.settimeout(2)
    BUFERY[N[0]] = b""
    return N[0]


BUFERY = {}  # недочитанное после строки — у каждого сокета своё


def py_receive_line(i):
    s = SOKETY[i]
    buf = BUFERY.get(i, b"")
    while b"\n" not in buf:
        try:
            d = s.recv(4096)
        except socket.timeout:
            d = b""
        if not d:
            break
        buf += d
    if b"\n" not in buf:
        BUFERY[i] = b""
        return None
    stroka, buf = buf.split(b"\n", 1)
    BUFERY[i] = buf
    return stroka.rstrip(b"\r").decode("latin-1")


def py_send(i, data):
    SOKETY[i].sendall(b(data))


def py_close(i):
    try:
        SOKETY[i].close()
    except OSError:
        pass


ZAPROSY = []


def py_network(url, metod, telo, zagolovki_json):
    req = urllib.request.Request(url, data=b(telo), method=metod, headers=json.loads(zagolovki_json))
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return False, r.status, r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return False, e.code, e.read().decode("utf-8")
    except OSError as e:
        return True, 0, str(e)


G.py_bind, G.py_settimeout, G.py_getsockname, G.py_accept = py_bind, py_settimeout, py_getsockname, py_accept
G.py_receive_line, G.py_send, G.py_close, G.py_network = py_receive_line, py_send, py_close, py_network
G.py_sha256 = lambda data: hashlib.sha256(b(data)).digest().decode("latin-1")
G.py_b64 = lambda data: base64.b64encode(b(data)).decode("ascii")
G.py_unb64 = lambda data: base64.b64decode(b(data)).decode("latin-1")
G.py_json_decode = lambda s: json.loads(b(s).decode("utf-8"))
G.py_json_encode = lambda s: json.dumps(s)
G.py_time = time.time
NACHALO = time.time()
G.py_timer_ms = lambda: (time.time() - NACHALO) * 1000

L.execute("""
    ADRES, OTKRYVAT = nil, true
    package.preload["CoronaLibrary"] = function() return { new = function(self, t) return {} end } end
    local function obyekt(id)
        local o = { id = id }
        function o:settimeout(t) py_settimeout(self.id, t) end
        function o:getsockname() return py_getsockname(self.id) end
        function o:accept() local c = py_accept(self.id); if c then return obyekt(c) end return nil, "timeout" end
        function o:receive(f) return py_receive_line(self.id) end
        function o:send(d) py_send(self.id, d); return #d end
        function o:close() py_close(self.id) end
        return o
    end
    package.preload["socket"] = function()
        return { bind = function(h, p) return obyekt(py_bind(h, p)) end, gettime = py_time }
    end
    package.preload["mime"] = function() return { b64 = py_b64, unb64 = py_unb64 } end
    package.preload["crypto"] = function()
        return { sha256 = "sha256", digest = function(alg, d, raw) return py_sha256(d) end }
    end
    -- json.decode отдаёт таблицу Lua: из словаря Python — только нужные поля
    package.preload["json"] = function()
        return { decode = function(s)
            local d = py_json_decode(s)
            local t = {}
            for _, k in ipairs({ "id_token", "error", "error_description", "name", "picture" }) do
                local ok, v = pcall(function() return d[k] end)
                if ok and v ~= nil then t[k] = v end
            end
            return t
        end }
    end
    TAIMERY = {}
    timer = {
        performWithDelay = function(ms, f, n) local t = { f = f, n = n or 1, ms = ms }; TAIMERY[#TAIMERY + 1] = t; return t end,
        cancel = function(t) if t then t.otmenen = true end end,
    }
    function tik()
        local spisok = TAIMERY
        TAIMERY = {}
        for _, t in ipairs(spisok) do
            if not t.otmenen then
                t.f()
                if t.n == 0 and not t.otmenen then TAIMERY[#TAIMERY + 1] = t end
            end
        end
    end
    system = { getTimer = py_timer_ms, openURL = function(u) ADRES = u; return OTKRYVAT end }
    network = { request = function(url, metod, slushatel, p)
        local zag = "{"
        local pervyy = true
        for k, v in pairs(p.headers or {}) do
            zag = zag .. (pervyy and "" or ",") .. string.format("%q:%q", k, v); pervyy = false
        end
        zag = zag .. "}"
        local oshibka, status, otvet = py_network(url, metod, p.body, zag)
        local t = { f = function() slushatel({ isError = oshibka, status = status, response = otvet }) end, n = 1 }
        TAIMERY[#TAIMERY + 1] = t
    end }
    SOBYTIYA = {}
    function slushatel(ev) SOBYTIYA[#SOBYTIYA + 1] = ev end
    function vyhod(ev) VYHOD = ev end
""".encode("utf-8"))
plagin = L.execute((KOREN / "desktop" / "plugin_signin.lua").read_bytes())


def tikat(poka, sekund=25):
    konec = time.time() + sekund
    while time.time() < konec and not poka():
        G.tik()
        time.sleep(0.02)


def nachat(**dop):
    opts = {"desktopClientId": CHUZHOY, "doneText": "Вход выполнен <проверка>"}
    opts.update(dop)
    G.ADRES = None
    ok = plagin.google(L.table_from({k: (v.encode("utf-8").decode("latin-1") if isinstance(v, str) else v)
                                      for k, v in opts.items()}), G.slushatel)
    adres = G.ADRES or ""
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(adres).query))
    port = int(urllib.parse.urlsplit(q.get("redirect_uri", "http://x:0")).port or 0)
    return ok, adres, q, port


def brauzer(port, put):
    """Ответ «браузера» в отдельном потоке: вход опрашивает порт таймером."""
    itog = {}

    def rabota():
        with socket.create_connection(("127.0.0.1", port), timeout=5) as c:
            c.sendall(("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" % put).encode())
            d = b""
            while True:
                try:
                    k = c.recv(4096)
                except socket.timeout:
                    break
                if not k:
                    break
                d += k
            itog["otvet"] = d.decode("utf-8", "replace")

    t = threading.Thread(target=rabota)
    t.start()
    tikat(lambda: not t.is_alive(), 10)
    t.join(1)
    return itog.get("otvet", "")


def sobytiya():
    return [G.SOBYTIYA[i] for i in range(1, len(G.SOBYTIYA) + 1)]


print("[1] Версия и доступность")
proverit("version() = 1.3.0", plagin.version() == "1.3.0", plagin.version())
d = plagin.isAvailable()
proverit("isAvailable: google = true, apple = false", d.google is True and d.apple is False)

print("[2] Аргументы")
r = plagin.google(L.table_from({"serverClientId": CHUZHOY}), G.slushatel)
proverit("без desktopClientId -> nil, desktopClientId is required", r == (None, "desktopClientId is required"), r)
r = plagin.google(L.table_from({"desktopClientId": CHUZHOY, "silent": True}), G.slushatel)
proverit("silent -> nil, unsupported", r == (None, "unsupported"), r)
r = plagin.apple(L.table_from({}), G.slushatel)
proverit("apple -> nil, unsupported", r == (None, "unsupported"), r)

print("[3] Адрес входа и PKCE")
ok, adres, q, port = nachat(button=True)
proverit("запрос принят", ok is True, ok)
proverit("адрес входа Google", adres.startswith("https://accounts.google.com/o/oauth2/v2/auth?"), adres[:60])
proverit("client_id — клиент ПК, возврат на 127.0.0.1:<порт>",
         q.get("client_id") == CHUZHOY and q.get("redirect_uri", "").startswith("http://127.0.0.1:") and port > 0, q)
proverit("PKCE S256, вызов 43 знака; state 24; prompt=select_account; scope openid email profile",
         q.get("code_challenge_method") == "S256" and len(q.get("code_challenge", "")) == 43
         and len(q.get("state", "")) == 24 and q.get("prompt") == "select_account"
         and q.get("scope") == "openid email profile", q)
proverit("второй, пока первый в полёте -> busy",
         plagin.google(L.table_from({"desktopClientId": CHUZHOY}), G.slushatel) == (None, "busy"))

print("[4] Ответы на локальный порт")
o = brauzer(port, "/favicon.ico")
proverit("не ответ входа -> 404, вход ждёт дальше", o.startswith("HTTP/1.1 404") and len(sobytiya()) == 0, o[:40])
o = brauzer(port, "/?state=chuzhoy&code=x")
proverit("страница с doneText, текст экранирован",
         o.startswith("HTTP/1.1 200") and "&lt;проверка&gt;" in o, o[:120])
tikat(lambda: len(sobytiya()) >= 1, 3)
ev = sobytiya()[0] if sobytiya() else None
proverit("чужой state -> failed, state mismatch",
         ev is not None and ev.name == "signin" and ev.provider == "google" and ev.isError is True
         and ev.errorType == "failed" and ev.errorMessage == "state mismatch",
         ev and (ev.errorType, ev.errorMessage))
try:
    socket.create_connection(("127.0.0.1", port), timeout=1).close()
    zakryt = False
except OSError:
    zakryt = True
proverit("после итога порт закрыт", zakryt)

ok, adres, q, port = nachat()
brauzer(port, "/?error=access_denied&state=" + q["state"])
tikat(lambda: len(sobytiya()) >= 2, 3)
proverit("отказ в браузере -> cancelled", len(sobytiya()) >= 2 and sobytiya()[1].errorType == "cancelled")

print("[5] Обмен кода у настоящего Google (заведомо неверный)")
ok, adres, q, port = nachat()
brauzer(port, "/?code=nevernyy&scope=openid&state=" + q["state"])
tikat(lambda: len(sobytiya()) >= 3, 25)
ev = sobytiya()[2] if len(sobytiya()) >= 3 else None
print("     событие:", ev and (ev.errorType, ev.errorMessage))
proverit("Google отказал -> failed, «token request <код>: …»",
         ev is not None and ev.isError is True and ev.idToken is None and ev.errorType == "failed"
         and str(ev.errorMessage).startswith("token request 4"), ev and ev.errorMessage)

print("[5а] serverAuthCode: код меняет сервер приложения")
ok, adres, q, port = nachat(serverAuthCode=True)
brauzer(port, "/?code=4%2Fkod-dlya-servera&scope=openid&state=" + q["state"])
tikat(lambda: len(sobytiya()) >= 4, 3)
ev = sobytiya()[3] if len(sobytiya()) >= 4 else None
proverit("событие без idToken: serverAuthCode (раскодирован), codeVerifier 64 знака, redirectUri — локальный",
         ev is not None and ev.isError is False and ev.idToken is None and ev.serverAuthCode == "4/kod-dlya-servera"
         and len(ev.codeVerifier or "") == 64 and ev.redirectUri == q["redirect_uri"],
         ev and (ev.serverAuthCode, ev.redirectUri))
proverit("  и вызов PKCE — SHA-256 от этого ключа",
         ev is not None and base64.urlsafe_b64encode(hashlib.sha256(ev.codeVerifier.encode()).digest()).rstrip(b"=").decode()
         == q["code_challenge"])

print("[6] Браузер не открылся")
G.OTKRYVAT = False
r = plagin.google(L.table_from({"desktopClientId": CHUZHOY}), G.slushatel)
G.OTKRYVAT = True
proverit("-> nil, browser did not open; очередь свободна",
         r == (None, "browser did not open") and nachat()[0] is True, r)

print("[7] Выход")
G.VYHOD = None
r = plagin.signOut(G.vyhod)
proverit("signOut -> true, событие не синхронное", r is True and G.VYHOD is None)
tikat(lambda: G.VYHOD is not None, 2)
proverit("событие выхода: isSignOut, без ошибки", G.VYHOD is not None and G.VYHOD.isSignOut is True and G.VYHOD.isError is False)

print("\nПРОВАЛОВ: %d" % provalov)
sys.exit(1 if provalov else 0)
