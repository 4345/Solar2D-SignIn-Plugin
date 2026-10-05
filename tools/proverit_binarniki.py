"""Проверка собранных библиотек плагина без устройства и без Mac: то, что «сборка прошла» не говорит.

Использование (из репозитория плагина):
    python tools/proverit_binarniki.py            библиотеки из каталогов сборки
    python tools/proverit_binarniki.py --arhivy   библиотеки внутри plugins/<платформа>/data.tgz

Что проверяется:
    win32       DLL 32-битная (Simulator под Windows — i386) и экспортирует luaopen_plugin_<имя>
    android     в AAR все четыре ABI; каждая .so зависит от liblua.so и libcorona.so (иначе на
                Android 6+ «cannot locate symbol»), экспортирует luaopen_… и JNI-вход LuaLoader;
                в classes.jar есть plugin/<имя>/LuaLoader.class. Плагин на чистой Java
                ("java": true в plagin.json) — .so в AAR НЕ должно быть, нужен только класс
    iphone      срез arm64 содержит _luaopen_…; metadata.lua называет библиотеку в staticLibs
    iphone-sim  ОБА среза, arm64 и x86_64, содержат _luaopen_… (заголовок lipo этого не доказывает)
    macOS       оба среза экспортируют _luaopen_…, есть подпись (LC_CODE_SIGNATURE)
    всё         строки-маркеры из plagin.json в каждой библиотеке

Нужны утилиты llvm-* — берутся из Android NDK (они читают ELF, COFF и Mach-O на любой ОС),
иначе из PATH; на Mac без NDK — xcrun nm/objdump.
"""

import io
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plagin_konfig import Plagin, najti_koren, nastroit_vyvod, ndk_llvm_bin  # noqa: E402

ITOG = {"ok": 0, "fail": 0}


def report(ok: bool, text: str) -> None:
    ITOG["ok" if ok else "fail"] += 1
    print(f"  {'ok  ' if ok else 'FAIL'} {text}")


def tool(name: str) -> list[str]:
    b = ndk_llvm_bin()
    exe = name + (".exe" if platform.system() == "Windows" else "")
    if b and (b / exe).exists():
        return [str(b / exe)]
    if shutil.which(name):
        return [name]
    if platform.system() == "Darwin":
        return ["xcrun", name.replace("llvm-", "")]
    sys.exit(f"нет {name}: поставьте Android NDK или LLVM")


def run(args: list[str]) -> str:
    r = subprocess.run(args, capture_output=True, text=True, errors="replace")
    return r.stdout + r.stderr


def nm_defined(path: Path, arch: str | None = None, dynamic: bool = False) -> set[str]:
    args = tool("llvm-nm") + ["--defined-only", "-g"]
    if dynamic:
        args.append("-D")
    if arch:
        args.append(f"--arch={arch}")
    out = run(args + [str(path)])
    return {line.split()[-1] for line in out.splitlines() if len(line.split()) >= 2}


def check_markers(pl: Plagin, label: str, blob: bytes) -> None:
    for m in pl.markery:
        report(m in blob, f"{label}: маркер {m.decode()!r}")


def check_dll(pl: Plagin, path: Path) -> None:
    out = run(tool("llvm-objdump") + ["-p", str(path)])
    fmt = run(tool("llvm-objdump") + ["-f", str(path)])
    found = re.search(r"file format (\S+)", fmt)
    report("coff-i386" in fmt, f"DLL 32-битная (Simulator i386): {found.group(1) if found else '?'}")
    report(f"luaopen_{pl.osnova}" in out, f"DLL экспортирует luaopen_{pl.osnova}")
    dlls = sorted(set(re.findall(r"DLL Name: (\S+)", out)))
    debug = [d for d in dlls if re.search(r"(MSVCP|VCRUNTIME|ucrtbase)\w*D\.dll", d, re.I)]
    report(not debug, f"нет отладочных runtime-библиотек: импорты {dlls}")
    check_markers(pl, "DLL", path.read_bytes())


def check_aar(pl: Plagin, data: bytes) -> None:
    with zipfile.ZipFile(io.BytesIO(data)) as aar:
        names = aar.namelist()
        sos = [n for n in names if n.startswith("jni/") and n.endswith("/lib" + pl.osnova + ".so")]
        abis = sorted(n.split("/")[1] for n in sos)
        if pl.java:
            report(abis == [], f"AAR: плагин на Java, .so нет (ABI {abis})")
        else:
            report(abis == ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"], f"AAR: ABI {abis}")
        lishnie = [n for n in names if n.endswith(("/liblua.so", "/libcorona.so"))]
        report(not lishnie, "в AAR нет копий liblua.so / libcorona.so (они в приложении из Corona.aar)")
        if "classes.jar" in names:
            with zipfile.ZipFile(io.BytesIO(aar.read("classes.jar"))) as jar:
                loader = f"plugin/{pl.imya}/LuaLoader.class"
                report(loader in jar.namelist(), f"classes.jar: {loader}")
        elif pl.java:
            report(False, "в AAR нет classes.jar — у плагина на Java больше ничего нет")
        with tempfile.TemporaryDirectory() as tmp:
            for n in sos:
                so = Path(tmp) / n.replace("/", "_")
                so.write_bytes(aar.read(n))
                abi = n.split("/")[1]
                deps = re.findall(r"NEEDED\s+(\S+)", run(tool("llvm-objdump") + ["-p", str(so)]))
                report("liblua.so" in deps and "libcorona.so" in deps, f"{abi}: зависит от liblua.so и libcorona.so ({deps})")
                syms = nm_defined(so, dynamic=True)
                jni = f"Java_plugin_{pl.imya}_LuaLoader_nativeOpen"
                report(f"luaopen_{pl.osnova}" in syms and jni in syms, f"{abi}: экспортирует luaopen_{pl.osnova} и {jni}")
                check_markers(pl, abi, so.read_bytes())


def check_static(pl: Plagin, path: Path, archs: list[str], label: str) -> None:
    for arch in archs:
        syms = nm_defined(path, arch=arch)
        report(f"_luaopen_{pl.osnova}" in syms, f"{label} [{arch}]: _luaopen_{pl.osnova} в срезе")
    check_markers(pl, label, path.read_bytes())


def check_metadata(pl: Plagin, text: str, label: str) -> None:
    m = re.search(r"staticLibs\s*=\s*\{([^}]*)\}", text)
    libs = re.findall(r"['\"]([^'\"]+)['\"]", m.group(1)) if m else []
    report(pl.osnova in libs, f"{label}: metadata.lua staticLibs = {libs} (сборщик читает staticLibs, не staticLibraryName)")


def check_dylib(pl: Plagin, path: Path) -> None:
    for arch in ("arm64", "x86_64"):
        syms = nm_defined(path, arch=arch)
        report(f"_luaopen_{pl.osnova}" in syms, f"dylib [{arch}]: экспортирует _luaopen_{pl.osnova}")
    heads = run(tool("llvm-objdump") + ["--macho", "--private-headers", "--arch=arm64", str(path)])
    report("LC_CODE_SIGNATURE" in heads, "dylib подписана (без подписи dlopen на Apple Silicon отказывает)")
    check_markers(pl, "dylib", path.read_bytes())


def main() -> int:
    nastroit_vyvod()
    pl = Plagin(najti_koren())
    iz_arhivov = "--arhivy" in sys.argv[1:]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # платформа -> {имя в архиве: путь к файлу}
        files: dict[str, dict[str, Path]] = {}
        for platforma, chleny in pl.istochniki().items():
            if iz_arhivov:
                arh = pl.put(f"plugins/{platforma}/data.tgz")
                if not arh.exists():
                    continue
                d = tmp / platforma
                d.mkdir()
                with tarfile.open(arh, "r:gz") as tar:
                    for member in tar.getmembers():
                        (d / member.name).write_bytes(tar.extractfile(member).read())
                files[platforma] = {p.name: p for p in d.iterdir()}
            else:
                files[platforma] = {n: s for n, s, _ in chleny if s.exists()}

        for platforma in ("win32", "android", "iphone", "iphone-sim", "macOS"):
            f = files.get(platforma) or {}
            print(f"== {platforma}")
            if not f:
                print("  нет файлов — пропущено")
                continue
            for name, path in f.items():
                if name.endswith(".dll"):
                    check_dll(pl, path)
                elif name.endswith(".aar"):
                    check_aar(pl, path.read_bytes())
                elif name.endswith(".a"):
                    archs = ["arm64"] if platforma == "iphone" else ["arm64", "x86_64"]
                    check_static(pl, path, archs, platforma)
                elif name == "metadata.lua":
                    check_metadata(pl, path.read_text(encoding="utf-8"), platforma)
                elif name.endswith(".dylib"):
                    check_dylib(pl, path)
        if iz_arhivov:
            # win32-sim и mac-sim обязаны нести тот же файл, что win32 и macOS
            for a, b in (("win32", "win32-sim"), ("macOS", "mac-sim")):
                fa, fb = files.get(a), files.get(b)
                if fa and fb:
                    same = {n: p.read_bytes() for n, p in fa.items()} == {n: p.read_bytes() for n, p in fb.items()}
                    report(same, f"{b} совпадает с {a}")
    print(f"ИТОГ: ok {ITOG['ok']}, FAIL {ITOG['fail']}")
    return 1 if ITOG["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
