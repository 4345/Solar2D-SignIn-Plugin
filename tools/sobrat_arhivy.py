"""Архивы plugins/<платформа>/data.tgz для подключения плагина по прямым ссылкам.

Использование (из репозитория плагина):
    python tools/sobrat_arhivy.py                  упаковать все платформы
    python tools/sobrat_arhivy.py iphone mac-sim   только перечисленные (на Mac — Apple-платформы)
    python tools/sobrat_arhivy.py --proverit       только сверить готовые архивы с библиотеками

Архивы собираются из уже собранных библиотек (пути — plagin_konfig.py). Apple-библиотеки
собираются только на Mac, остальные — на Windows: архивы платформ обновляются там, где
собраны их библиотеки, а этот скрипт работает на обеих машинах.

Перед упаковкой каждая библиотека (в AAR — каждая .so) проверяется:
- есть ли в ней строки-маркеры из plagin.json («markery») — например ALPN протокола: сборка
  без него несовместима с остальными, и её выкладка сломала бы соединение молча;
- нет ли в ней путей сборочной машины (C:\\Users\\…, /Users/<имя>/, /home/<имя>/): они раскрывают
  имя пользователя и устройство папок. Ищется по сырым байтам — strings таблицу символов
  не просматривает и пропускает, например, записи OSO в dylib.
Архивы плоские и детерминированные: те же файлы дают тот же архив байт в байт, и git не
видит лишних изменений.
"""

import gzip
import hashlib
import io
import re
import sys
import tarfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plagin_konfig import PLATFORMY, Plagin, najti_koren, nastroit_vyvod  # noqa: E402

BUILD_PATH = re.compile(rb"[A-Za-z]:[\\/]+Users[\\/]+|/Users/[^/\0]+/|/home/[^/\0]+/")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def binaries(name: str, data: bytes, java: bool = False) -> list[tuple[str, bytes]]:
    """Двоичные части файла: у AAR — его .so (у Java-плагина — classes.jar), у .lua и
    .gradle — ничего, у остальных — сам файл."""
    if name.endswith((".lua", ".gradle")):
        return []
    if name.endswith(".aar"):
        with zipfile.ZipFile(io.BytesIO(data)) as aar:
            if java:
                return [(n, aar.read(n)) for n in aar.namelist() if n == "classes.jar"]
            return [(n, aar.read(n)) for n in aar.namelist() if n.startswith("jni/") and n.endswith(".so")]
    return [(name, data)]


def marker_problem(pl: Plagin, name: str, data: bytes) -> str | None:
    if name.endswith((".lua", ".gradle")):
        return None
    parts = binaries(name, data, pl.java)
    if not parts:
        return "в AAR нет classes.jar" if pl.java else "в AAR нет ни одной .so"
    problems = []
    if name.endswith(".aar") and pl.java:
        # Загрузчик Java-плагина ищется отражением: plugin.<имя>.LuaLoader
        zagruzchik = f"plugin/{pl.imya}/LuaLoader.class"
        with zipfile.ZipFile(io.BytesIO(parts[0][1])) as jar:
            if zagruzchik not in jar.namelist():
                problems.append(f"в classes.jar нет {zagruzchik}")
    elif name.endswith(".aar"):
        abis = {n.split("/")[1] for n, _ in parts}
        nehvataet = {"arm64-v8a", "armeabi-v7a", "x86", "x86_64"} - abis
        if nehvataet:
            problems.append(f"нет ABI {sorted(nehvataet)}")
    for m in pl.markery:
        missing = [n for n, blob in parts if m not in blob]
        if missing:
            problems.append(f"нет маркера {m.decode()!r} в {missing}")
    return "; ".join(problems) or None


def path_problem(name: str, data: bytes, java: bool = False) -> str | None:
    for part, blob in binaries(name, data, java):
        found = BUILD_PATH.search(blob)
        if found:
            sample = blob[found.start():found.start() + 60].split(b"\0")[0].decode("ascii", "replace")
            return f"путь сборочной машины в {part}: {sample}…"
    return None


def pack(members: list) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, src, mode in members:
            data = src.read_bytes()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            info.mtime = int(src.stat().st_mtime)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    # mtime=0 в заголовке gzip: иначе архив менялся бы при каждой упаковке
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def build(pl: Plagin, only: list) -> int:
    failed = False
    for platform, members in pl.istochniki().items():
        if only and platform not in only:
            continue
        problems = []
        for name, src, _ in members:
            if not src.exists():
                problems.append(f"нет {src.relative_to(pl.koren)}")
                continue
            data = src.read_bytes()
            for problem in (marker_problem(pl, name, data), path_problem(name, data, pl.java)):
                if problem:
                    problems.append(f"{name}: {problem}")
        if problems:
            failed = True
            print(f"{platform:11} ПРОПУЩЕН: {'; '.join(problems)}")
            continue
        archive = pl.put(f"plugins/{platform}/data.tgz")
        archive.parent.mkdir(parents=True, exist_ok=True)
        data = pack(members)
        old = archive.read_bytes() if archive.exists() else None
        archive.write_bytes(data)
        state = "без изменений" if old == data else "обновлён"
        print(f"{platform:11} {state:14} {len(data):>10} байт  {', '.join(n for n, _, _ in members)}")
    return 1 if failed else 0


def check(pl: Plagin) -> int:
    """Сверка готовых архивов с текущими библиотеками: что выложено, то ли собрано."""
    failed = False
    for platform, members in pl.istochniki().items():
        archive = pl.put(f"plugins/{platform}/data.tgz")
        if not archive.exists():
            print(f"{platform:11} НЕТ АРХИВА")
            failed = True
            continue
        with tarfile.open(archive, "r:gz") as tar:
            names = tar.getnames()
            notes = []
            if sorted(names) != sorted(n for n, _, _ in members):
                notes.append(f"состав {names}")
            for name, src, _ in members:
                if name not in names:
                    continue
                data = tar.extractfile(name).read()
                for problem in (marker_problem(pl, name, data), path_problem(name, data, pl.java)):
                    if problem:
                        notes.append(f"{name}: {problem}")
                if not src.exists():
                    notes.append(f"нет {src.relative_to(pl.koren)} для сверки")
                elif sha256(src.read_bytes()) != sha256(data):
                    notes.append(f"{name} отличается от {src.relative_to(pl.koren)}")
        failed |= bool(notes)
        print(f"{platform:11} {'; '.join(notes) if notes else 'совпадает'}")
    return 1 if failed else 0


if __name__ == "__main__":
    nastroit_vyvod()
    args = sys.argv[1:]
    unknown = [a for a in args if not a.startswith("--") and a not in PLATFORMY]
    if unknown:
        sys.exit(f"неизвестные платформы: {unknown}; допустимы {PLATFORMY}")
    plagin = Plagin(najti_koren())
    sys.exit(check(plagin) if "--proverit" in args else build(plagin, [a for a in args if not a.startswith("--")]))
