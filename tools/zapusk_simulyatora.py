"""Прогон тестового проекта Solar2D в Simulator и печать его отчёта.

Использование (из репозитория плагина):
    python tools/zapusk_simulyatora.py                     проект test/, отчёт test_report.txt
    python tools/zapusk_simulyatora.py путь/к/проекту --otchet my_report.txt --sekund 90
    python tools/zapusk_simulyatora.py --ostavit           не закрывать Simulator после прогона
    python3 tools/zapusk_simulyatora.py --arch x86_64      macOS: Simulator под Rosetta (срез x86_64 dylib)

Тестовый проект обязан сам записать отчёт в system.DocumentsDirectory и закрыться
(os.exit) — так устроен test/main.lua шаблона. Скрипт:
  1. закрывает запущенный Simulator (второй экземпляр отдал бы проект первому, со старой DLL);
  2. на Windows, если запущен из репозитория плагина, сбрасывает кэш плагина у Simulator
     (ochistit_kesh.py): с записью в catalog.json Simulator берёт ПЕРВУЮ распакованную
     сборку и свежую из Solar2DPlugins не видит — тест «проходит» на старой DLL
     (проверено мутантом 04.10.2026). --bez-ochistki — не трогать;
  3. запускает проект — на Windows БЕЗ прав администратора (__COMPAT_LAYER=RunAsInvoker):
     Simulator с повышением ждёт подтверждения UAC, а человека у монитора может не быть, и
     прогон встаёт; кроме того, окном процесса с повышенными правами обычный процесс не
     управляет вовсе (UIPI: ни кликов, ни клавиш, ни даже закрытия);
  4. ждёт отчёт, более свежий, чем запуск, в песочнице Simulator:
       Windows: %LOCALAPPDATA%\\Corona Labs\\Corona Simulator\\Sandbox\\<имя проекта>-<хэш>\\Documents\\
       macOS:   ~/Library/Application Support/Corona Simulator/<имя проекта>-<хэш>/Documents/
  5. сверяет по хешу библиотеку, которую взял Simulator, со свежей сборкой репозитория;
  6. печатает отчёт и считает строки «  ok» и «  FAIL»; код выхода 0 — только при ИТОГ без
     провалов и загруженной свежей сборке.

Если отчёта нет, а Simulator исчез — на Windows печатается событие 1000 журнала приложений:
Simulator, упавший на плагине, не пишет ничего (так нашлась старая MSVCP140 против std::mutex).
os.exit в Simulator закрывает проект, но не процесс: это нормально.
"""

import argparse
import hashlib
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ochistit_kesh import mesta, ochistit  # noqa: E402
from plagin_konfig import Plagin, najti_koren, nastroit_vyvod  # noqa: E402

WIN = platform.system() == "Windows"


def simulyator(arch: str | None = None) -> list[str]:
    if WIN:
        exe = Path(r"C:\Program Files (x86)\Corona Labs\Corona\Corona Simulator.exe")
        if not exe.exists():
            sys.exit(f"нет {exe}")
        return [str(exe)]
    apps = sorted(Path("/Applications").glob("Corona*/Corona Simulator.app")) + \
        sorted(Path("/Applications").glob("Solar2D*/Corona Simulator.app"))
    if not apps:
        sys.exit("не найден Corona Simulator.app в /Applications")
    # Simulator универсальный: без --arch на Apple Silicon он работает как arm64 и грузит срез
    # arm64 плагина. Срез x86_64 (Intel Mac) проверяется запуском под Rosetta: --arch x86_64
    return ["open", "-n", "-a", str(apps[-1]), *(["--arch", arch] if arch else []), "--args"]


def zakryt_simulyator() -> bool:
    """False — Simulator остался жив: на Windows это Simulator, запущенный с правами
    администратора, — обычный процесс его не закроет (taskkill: «Отказано в доступе»)."""
    if WIN:
        subprocess.run(["taskkill", "/F", "/IM", "Corona Simulator.exe"], capture_output=True)
    else:
        subprocess.run(["pkill", "-x", "Corona Simulator"], capture_output=True)
    time.sleep(1.0)
    return not zhiv()


def zapustit_bez_povysheniya(exe: str, main_lua: Path) -> None:
    """Windows: Simulator обычным процессом. У Corona Simulator.exe бывает флаг совместимости
    RUNASADMIN (HKCU\\...\\AppCompatFlags\\Layers): тогда CreateProcess отвечает WinError 740,
    а ShellExecute (os.startfile, Start-Process) поднимает окно UAC. __COMPAT_LAYER=RunAsInvoker
    в окружении снимает требование только для этого запуска — настройки системы не меняются.
    Права администратора Simulator для прогона тестов не нужны.

    HOME из окружения убирается: его задают Git Bash и MSYS, и Simulator с HOME ищет локальные
    плагины в %USERPROFILE%\\Solar2DPlugins вместо %APPDATA%\\Solar2DPlugins — «Unable to find
    plugin», хотя архив на месте (04.10.2026). Запуск с повышением прав этого не показывал:
    процесс получал свежее окружение от Windows, без HOME."""
    env = {k: v for k, v in os.environ.items() if k.upper() != "HOME"}
    env["__COMPAT_LAYER"] = "RunAsInvoker"
    subprocess.Popen([exe, str(main_lua)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def zhiv() -> bool:
    if WIN:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Corona Simulator.exe"], capture_output=True,
                             text=True, errors="replace").stdout
        return "Corona Simulator.exe" in out
    return subprocess.run(["pgrep", "-x", "Corona Simulator"], capture_output=True).returncode == 0


def pesochnica() -> Path:
    if WIN:
        return Path(os.environ["LOCALAPPDATA"]) / "Corona Labs" / "Corona Simulator" / "Sandbox"
    return Path.home() / "Library" / "Application Support" / "Corona Simulator"


def najti_otchet(proekt: Path, otchet: str, posle: float) -> Path | None:
    base = pesochnica()
    if not base.is_dir():
        return None
    imya = proekt.name.lower()
    for d in base.iterdir():
        if d.is_dir() and d.name.lower().startswith(imya + "-"):
            f = d / "Documents" / otchet
            if f.is_file() and f.stat().st_mtime > posle:
                return f
    return None


def sobytie_padeniya(posle: float) -> str:
    if not WIN:
        return ""
    t = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(posle - 2))
    q = f"*[System[(EventID=1000) and TimeCreated[@SystemTime>='{t}.000Z']]]"
    out = subprocess.run(["wevtutil", "qe", "Application", f"/q:{q}", "/f:text", "/c:3", "/rd:true"],
                         capture_output=True, text=True, errors="replace").stdout
    return out.strip()


def sha(put: Path) -> str | None:
    return hashlib.sha256(put.read_bytes()).hexdigest() if put.is_file() else None


def svezhaya_li(pl: Plagin) -> tuple[bool, str]:
    """Та ли библиотека у Simulator, что собрана в репозитории."""
    kesh, _ = mesta()
    sobrana = pl.dll if WIN else pl.dylib
    vzyata = kesh / sobrana.name
    hs, hv = sha(sobrana), sha(vzyata)
    if hs is None:
        return True, f"сборки {sobrana.name} в репозитории нет — сверять не с чем"
    if hv is None:
        return False, f"у Simulator нет {vzyata} — плагин взят не из локальной сборки (ссылка в build.settings?)"
    if hs != hv:
        return False, f"Simulator взял НЕ свежую сборку: {vzyata} ({hv[:12]}) ≠ {sobrana} ({hs[:12]})"
    return True, f"Simulator взял свежую сборку {sobrana.name} ({hs[:12]})"


def main() -> int:
    nastroit_vyvod()
    p = argparse.ArgumentParser(description="Прогон тестового проекта в Solar2D Simulator")
    p.add_argument("proekt", nargs="?", help="каталог проекта Solar2D (по умолчанию test/ репозитория)")
    p.add_argument("--otchet", default="test_report.txt")
    p.add_argument("--sekund", type=int, default=60)
    p.add_argument("--ostavit", action="store_true", help="не закрывать Simulator после прогона")
    p.add_argument("--bez-ochistki", action="store_true", help="не сбрасывать кэш плагина перед запуском")
    p.add_argument("--arch", choices=["arm64", "x86_64"], help="macOS: архитектура Simulator (x86_64 — под Rosetta)")
    a = p.parse_args()
    if a.arch and WIN:
        sys.exit("--arch — только для macOS")

    proekt = Path(a.proekt).resolve() if a.proekt else najti_koren() / "test"
    main_lua = proekt / "main.lua"
    if not main_lua.is_file():
        sys.exit(f"нет {main_lua}")
    koren = next((d for d in [proekt, *proekt.parents] if (d / "plagin.json").is_file()), None)
    pl = Plagin(koren) if koren else None

    if not zakryt_simulyator():
        sys.exit("Simulator не закрывается: он запущен с правами администратора, а обычный процесс такой "
                 "закрыть не может. Закройте его вручную — скрипт запустит новый без повышения прав.")
    if pl and WIN and not a.bez_ochistki:
        if ochistit(pl.modul, pl.izdatel, pechat=lambda s: None):
            print(f"кэш {pl.modul} у Simulator сброшен: возьмёт свежую копию из Solar2DPlugins или по ссылке")
    start = time.time()
    if WIN:
        zapustit_bez_povysheniya(simulyator()[0], main_lua)
    else:
        subprocess.Popen(simulyator(a.arch) + [str(main_lua)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"Simulator{f' ({a.arch})' if a.arch else ''}: {main_lua}")

    otchet = None
    propal = False
    while time.time() - start < a.sekund:
        time.sleep(0.5)
        otchet = najti_otchet(proekt, a.otchet, start)
        if otchet:
            time.sleep(0.5)  # дописывается одним вызовом, но дадим закрыться файлу
            break
        if time.time() - start > 8 and not zhiv():
            propal = True
            break

    kod = 1
    if otchet:
        text = otchet.read_text(encoding="utf-8", errors="replace")
        print(text)
        lines = text.splitlines()
        ok = sum(1 for s in lines if s.startswith("  ok"))
        fail = sum(1 for s in lines if s.startswith("  FAIL"))
        itog = next((s for s in reversed(lines) if s.startswith("ИТОГ")), "")
        print(f"\n== ok: {ok}, FAIL: {fail}; отчёт: {otchet}")
        kod = 0 if fail == 0 and itog and "провалов: 0" in itog else 1
        if pl:
            svezh, poyasnenie = svezhaya_li(pl)
            print(("== " if svezh else "== ВНИМАНИЕ: ") + poyasnenie)
            if not svezh:
                kod = 1
    else:
        print("НЕТ ОТЧЁТА" + (": Simulator закрылся" if propal else f" за {a.sekund} с"))
        padenie = sobytie_padeniya(start)
        if padenie:
            print("Журнал Windows, событие 1000 (падение приложения):\n" + padenie)
        print("Проверьте консоль Simulator: «Unable to find plugin», «module not found», ошибки Lua.")

    if not a.ostavit:
        zakryt_simulyator()
    return kod


if __name__ == "__main__":
    sys.exit(main())
