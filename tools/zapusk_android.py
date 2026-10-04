"""Сборка тестового приложения Android с плагином, установка на устройство и печать отчёта теста.

Использование (из репозитория плагина, телефон подключён по adb):
    python tools/zapusk_android.py                       собрать AAR и APK, поставить, запустить
    python tools/zapusk_android.py --bez-sborki          только поставить готовый APK и запустить
    python tools/zapusk_android.py --proekt ../../другой  другой проект Solar2D (путь от android/app)
    python tools/zapusk_android.py --po-ssylke           приложение берёт плагин по ссылкам из
                                                         build.settings проекта, а не модулем :plugin

Шаблон Corona Native (android/app) собирает приложение прямо с модулем :plugin, без Simulator.
Gradle запускается на JDK 17 из Solar2D: Gradle 8.13 шаблона не работает на JDK 25.
Печать Lua читается из logcat (тег Corona); отчёт — строки «  ok» / «  FAIL» и «ИТОГ: …»,
которые печатает test/main.lua. Отказ загрузки плагина виден по «error loading class» и
UnsatisfiedLinkError — они печатаются отдельно.

--po-ssylke передаёт Gradle -PconfigureCoronaPlugins=YES: без него шаблон плагины по ссылкам
НЕ скачивает (это свойство Solar2D передаёт сам, когда собирает Android). Для проверки
архивов до публикации: python -m http.server --directory plugins и ссылки на 127.0.0.1 в
build.settings проекта (tools/proverit_ssylki.py --lokalno <порт>). Архивы скачивает сборка
на этой машине, а не телефон, поэтому adb reverse не нужен.
"""

import argparse
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plagin_konfig import android_sdk, java_home_17, najti_koren, nastroit_vyvod  # noqa: E402

PAKET = "com.mycompany.app"   # applicationId шаблона Corona Native


def adb() -> str:
    exe = android_sdk() / "platform-tools" / ("adb.exe" if platform.system() == "Windows" else "adb")
    if not exe.exists():
        sys.exit(f"нет {exe}")
    return str(exe)


def run(args, **kw):
    # adb и Gradle пишут UTF-8; кодировка консоли Windows (cp1251/cp866) превращает кириллицу
    # отчёта в кашу, и строка «ИТОГ» не находится
    return subprocess.run(args, capture_output=True, encoding="utf-8", errors="replace", **kw)


def main() -> int:
    nastroit_vyvod()
    p = argparse.ArgumentParser(description="Прогон тестового проекта плагина на Android-устройстве")
    p.add_argument("--bez-sborki", action="store_true")
    p.add_argument("--proekt", help="coronaSrcDir: проект Solar2D, путь относительно android/app")
    p.add_argument("--po-ssylke", action="store_true", help="плагин по ссылкам build.settings (-PconfigureCoronaPlugins=YES)")
    p.add_argument("--sekund", type=int, default=30)
    a = p.parse_args()

    koren = najti_koren()
    android = koren / "android"
    apk = android / "app" / "build" / "outputs" / "apk" / "debug" / "app-debug.apk"

    ustr = [s.split()[0] for s in run([adb(), "devices"]).stdout.splitlines()[1:] if s.strip().endswith("device")]
    if not ustr:
        sys.exit("нет устройства: adb devices пуст (включите отладку по USB и подтвердите ключ на телефоне)")
    print(f"устройство: {ustr[0]}")

    if not a.bez_sborki:
        env = dict(os.environ)
        jh = java_home_17()
        if jh:
            env["JAVA_HOME"] = jh
        env.setdefault("ANDROID_HOME", str(android_sdk()))
        gradlew = android / ("gradlew.bat" if platform.system() == "Windows" else "gradlew")
        zadachi = [":app:assembleDebug"] if a.po_ssylke else [":plugin:assembleRelease", ":app:assembleDebug"]
        args = [str(gradlew), "-p", str(android), *zadachi, "--console=plain"]
        if a.proekt:
            args.append(f"-PcoronaSrcDir={a.proekt}")
        if a.po_ssylke:
            args.append("-PconfigureCoronaPlugins=YES")
        print("сборка:", " ".join(args[2:]), flush=True)
        r = run(args, env=env, cwd=android)
        hvost = [s for s in (r.stdout + r.stderr).splitlines()
                 if any(k in s for k in ("BUILD", "error", "FAIL", "What went wrong", "Unable to find plugin"))]
        print("\n".join(hvost[-15:]))
        if r.returncode != 0:
            return 1

    if not apk.exists():
        sys.exit(f"нет {apk}")
    run([adb(), "shell", "am", "force-stop", PAKET])
    r = run([adb(), "install", "-r", "-d", str(apk)])
    print("установка:", (r.stdout + r.stderr).strip().splitlines()[-1:])
    run([adb(), "logcat", "-c"])
    run([adb(), "shell", "monkey", "-p", PAKET, "-c", "android.intent.category.LAUNCHER", "1"])

    start = time.time()
    lines: list[str] = []
    while time.time() - start < a.sekund:
        time.sleep(1.0)
        log = run([adb(), "logcat", "-d", "-v", "brief", "-s", "Corona:*"]).stdout
        lines = [s.split(":", 1)[1][1:] if ":" in s else s for s in log.splitlines()]
        if any("ИТОГ" in s for s in lines):
            break

    vse = run([adb(), "logcat", "-d", "-v", "time"]).stdout
    otkazy = [s for s in vse.splitlines() if any(k in s for k in (
        "error loading class", "UnsatisfiedLinkError", "cannot locate symbol", "module 'plugin.", "FATAL EXCEPTION"))]
    if otkazy:
        print("ОТКАЗЫ ЗАГРУЗКИ:\n" + "\n".join(otkazy[:10]))
    zagruzka = [s for s in lines if "Loading via reflection" in s]
    if zagruzka:
        print("\n".join(zagruzka))

    otchet = [s for s in lines if s.startswith(("  ok", "  FAIL", "ИТОГ", "===", "["))]
    print("\n".join(otchet))
    ok = sum(1 for s in otchet if s.startswith("  ok"))
    fail = sum(1 for s in otchet if s.startswith("  FAIL"))
    itog = next((s for s in reversed(otchet) if s.startswith("ИТОГ")), "")
    print(f"\n== ok: {ok}, FAIL: {fail}" + ("" if itog else f"; ИТОГА нет за {a.sekund} с"))
    return 0 if itog and fail == 0 and "провалов: 0" in itog else 1


if __name__ == "__main__":
    sys.exit(main())
