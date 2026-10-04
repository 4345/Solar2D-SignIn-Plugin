"""Сброс кэша плагина у Solar2D Simulator (Windows и macOS).

Использование:
    python tools/ochistit_kesh.py                          плагин из plagin.json репозитория
    python tools/ochistit_kesh.py --plagin plugin.x --izdatel ovh.azi
    python tools/ochistit_kesh.py --spisok                 только показать, ничего не трогая
    python tools/ochistit_kesh.py --i-lokalnoe             убрать и локальную копию Solar2DPlugins

Кэш Simulator — в ТРЁХ местах, и удалять надо все:
  1. <кэш>/<плагин>/ — скачанный или взятый из Solar2DPlugins data.tgz;
  2. там же рядом — распакованные файлы (plugin_x.dll / .dylib / .lua);
  3. запись «<издатель>/<плагин>» в <кэш>/catalog.json. Пока она есть, Simulator берёт
     распакованную копию и НЕ перечитывает ни ссылку, ни свежий архив в Solar2DPlugins:
     проверено 04.10.2026 — новая сборка лежала в Solar2DPlugins, а загрузилась первая.
     Убирается только своя запись, остальные плагины перекачивать незачем. Файл пишется
     без BOM: его читает движок.
Где кэш: Windows — %APPDATA%\\Corona Labs\\Corona Simulator\\Plugins;
         macOS   — ~/Library/Application Support/Corona/Simulator/Plugins.

Локальное хранилище Solar2DPlugins/<издатель>/<плагин>/ — не кэш, а источник: его
выкладывает сборка (VS после сборки, deployToLocalSolar2DRepo, deployLocal.sh). Удаляется
только с --i-lokalnoe. Ссылки supportedPlatforms в build.settings важнее него.

НА МАКЕ: Simulator сам не распаковывает архив из ~/Solar2DPlugins. Плагин, разложенный
mac/deploy_local.py, после очистки не найдётся, пока его не выложить снова.
Чужие файлы рядом (зависимости, положенные вручную, вроде msquic.dll) не трогаются:
удаляются только файлы с именем plugin_<имя>*.
"""

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plagin_konfig import Plagin, nastroit_vyvod  # noqa: E402


def mesta() -> tuple[Path, Path]:
    """(кэш Simulator, корень локального хранилища)."""
    if sys.platform == "darwin":
        doma = Path.home()
        return doma / "Library" / "Application Support" / "Corona" / "Simulator" / "Plugins", doma / "Solar2DPlugins"
    appdata = Path(os.environ["APPDATA"])
    return appdata / "Corona Labs" / "Corona Simulator" / "Plugins", appdata / "Solar2DPlugins"


def razmer(put: Path) -> int:
    if put.is_dir():
        return sum(f.stat().st_size for f in put.rglob("*") if f.is_file())
    return put.stat().st_size


def ochistit(modul: str, izdatel: str, i_lokalnoe: bool = False, spisok: bool = False, pechat=print) -> int:
    """Удаляет кэш плагина modul (plugin.x) издателя izdatel. Возвращает число удалённого."""
    kesh, hranilishe_koren = mesta()
    hranilishe = hranilishe_koren / izdatel / modul
    katalog = kesh / "catalog.json"
    osnova = modul.replace(".", "_")

    celi = [c for c in [kesh / modul] if c.exists()]
    if kesh.is_dir():
        celi += sorted(f for f in kesh.glob(osnova + "*") if f.is_file())
    if i_lokalnoe and hranilishe.exists():
        celi.append(hranilishe)
    for c in celi:
        pechat(f"  {c}  ({razmer(c)} байт)")

    klyuch = f"{izdatel}/{modul}"
    dannye = None
    if katalog.is_file():
        try:
            dannye = json.loads(katalog.read_text(encoding="utf-8-sig"))
        except ValueError as e:
            sys.exit(f"catalog.json не разобрать ({e}) — не трогаю")
    est_zapis = isinstance(dannye, dict) and klyuch in dannye
    if est_zapis:
        pechat(f"  catalog.json: запись {klyuch}")
    if spisok or (not celi and not est_zapis):
        return 0

    for c in celi:
        shutil.rmtree(c) if c.is_dir() else c.unlink()
    if est_zapis:
        del dannye[klyuch]
        katalog.write_text(json.dumps(dannye, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    return len(celi) + int(est_zapis)


def main() -> int:
    nastroit_vyvod()
    p = argparse.ArgumentParser(description="Сброс кэша плагина Solar2D Simulator")
    p.add_argument("--plagin", help="имя плагина, например plugin.primer")
    p.add_argument("--izdatel", help="publisherId")
    p.add_argument("--spisok", action="store_true")
    p.add_argument("--i-lokalnoe", action="store_true", help="удалить и Solar2DPlugins/<издатель>/<плагин>")
    a = p.parse_args()

    if not (a.plagin and a.izdatel):
        koren = next((d for d in [Path.cwd(), *Path.cwd().parents] if (d / "plagin.json").is_file()), None)
        if not koren:
            sys.exit("укажите --plagin и --izdatel или запускайте из репозитория плагина")
        pl = Plagin(koren)
        a.plagin = a.plagin or pl.modul
        a.izdatel = a.izdatel or pl.izdatel

    print(f"Плагин: {a.izdatel}/{a.plagin}")
    n = ochistit(a.plagin, a.izdatel, a.i_lokalnoe, a.spisok)
    if a.spisok:
        print("Только показ (--spisok) — ничего не удалено.")
    elif n:
        print("Готово. Следующий запуск возьмёт плагин заново (по ссылке или из Solar2DPlugins).")
    else:
        print("  кэша нет — чистить нечего")
    return 0


if __name__ == "__main__":
    sys.exit(main())
