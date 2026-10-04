"""Общая часть инструментов плагина Solar2D: где корень репозитория и что где лежит.

Корень — ближайший вверх от текущего каталога (или от каталога скрипта) каталог с plagin.json:

    {
      "imya": "primer",            модуль plugin.primer, библиотеки plugin_primer.*
      "izdatel": "ovh.azi",        publisherId
      "repo": "owner/Repo",        GitHub-репозиторий для ссылок supportedPlatforms
      "vetka": "main",
      "markery": [],               строки, обязанные быть в каждой библиотеке (например ALPN)
      "java": false,               Android-часть — чистая Java (без .so): в AAR проверяется
                                   classes.jar и класс plugin.<имя>.LuaLoader, а не ABI
      "istochniki": {...},         необязательно: свои пути для нестандартной раскладки
      "lua": "shared/plugin_primer.lua",       необязательно
      "baitkod": ["shared/plugin_primer.c"]    необязательно
    }

Пути по умолчанию — раскладка шаблона навыка solar2d-plaginy (novyj_plagin.py).
"""

import json
import os
import platform
import sys
from pathlib import Path

PLATFORMY = ["win32", "win32-sim", "android", "iphone", "iphone-sim", "macOS", "mac-sim"]


def nastroit_vyvod() -> None:
    """Русский вывод в консоли Windows с любой кодовой страницей."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def najti_koren(start: Path | None = None) -> Path:
    for base in [start or Path.cwd(), Path(__file__).resolve().parent]:
        for d in [base, *base.parents]:
            if (d / "plagin.json").is_file():
                return d
    sys.exit("не найден plagin.json: запускайте из репозитория плагина (или передайте --koren)")


class Plagin:
    def __init__(self, koren: Path):
        self.koren = koren
        self.k = json.loads((koren / "plagin.json").read_text(encoding="utf-8"))
        self.imya = self.k["imya"]
        self.izdatel = self.k["izdatel"]
        self.modul = f"plugin.{self.imya}"
        self.osnova = f"plugin_{self.imya}"          # имя библиотек и функции luaopen_…
        self.repo = self.k.get("repo", "")
        self.vetka = self.k.get("vetka", "main")
        self.markery = [m.encode() for m in self.k.get("markery", [])]
        self.java = bool(self.k.get("java", False))

    # --- пути ---------------------------------------------------------------

    def put(self, rel: str) -> Path:
        return self.koren / rel

    @property
    def dll(self) -> Path:
        return self.put(f"win32/Release/{self.osnova}.dll")

    @property
    def aar(self) -> Path:
        return self.put("android/plugin/build/outputs/aar/plugin-release.aar")

    def ios_lib(self, platforma: str) -> Path:
        return self.put(f"ios/BuiltPlugin/{platforma}/lib{self.osnova}.a")

    @property
    def dylib(self) -> Path:
        return self.put(f"mac/{self.osnova}.dylib")

    @property
    def lua(self) -> Path:
        return self.put(self.k.get("lua", f"shared/{self.osnova}.lua"))

    @property
    def baitkod(self) -> list[Path]:
        return [self.put(p) for p in self.k.get("baitkod", [f"shared/{self.osnova}.c"])]

    def istochniki(self) -> dict[str, list[tuple[str, Path, int]]]:
        """Платформа Solar2D -> [(имя в архиве, источник, права)]."""
        svoi = self.k.get("istochniki")
        if svoi:
            return {p: [(n, self.put(s), int(str(m), 8)) for n, s, m in chleny] for p, chleny in svoi.items()}

        def ios(p: str):
            base = self.put(f"ios/BuiltPlugin/{p}")
            return [(f"lib{self.osnova}.a", base / f"lib{self.osnova}.a", 0o644),
                    ("metadata.lua", base / "metadata.lua", 0o644)]

        return {
            "win32": [(f"{self.osnova}.dll", self.dll, 0o644)],
            "win32-sim": [(f"{self.osnova}.dll", self.dll, 0o644)],
            "android": [("plugin-release.aar", self.aar, 0o644)],
            "iphone": ios("iphone"),
            "iphone-sim": ios("iphone-sim"),
            "macOS": [(f"{self.osnova}.dylib", self.dylib, 0o755)],
            "mac-sim": [(f"{self.osnova}.dylib", self.dylib, 0o755)],
        }

    def ssylka(self, platforma: str) -> str:
        return f"https://raw.githubusercontent.com/{self.repo}/{self.vetka}/plugins/{platforma}/data.tgz"


# --- окружение ------------------------------------------------------------------

def corona_native() -> Path:
    if platform.system() == "Windows":
        return Path(os.environ.get("CORONA_ROOT") or r"C:\Program Files (x86)\Corona Labs\Corona\Native")
    return Path.home() / "Library" / "Application Support" / "Corona" / "Native"


def android_sdk() -> Path:
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(var):
            return Path(os.environ[var])
    if platform.system() == "Windows":
        return Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk"
    if platform.system() == "Darwin":
        return Path.home() / "Library" / "Android" / "sdk"
    return Path.home() / "Android" / "Sdk"


def ndk_llvm_bin() -> Path | None:
    """Каталог llvm-* из самого нового NDK: ими читаются ELF, COFF и Mach-O на любой ОС."""
    ndk = android_sdk() / "ndk"
    if not ndk.is_dir():
        return None
    versii = sorted((p for p in ndk.iterdir() if p.is_dir()),
                    key=lambda p: [int(x) for x in p.name.split(".") if x.isdigit()])
    if not versii:
        return None
    host = {"Windows": "windows-x86_64", "Darwin": "darwin-x86_64"}.get(platform.system(), "linux-x86_64")
    b = versii[-1] / "toolchains" / "llvm" / "prebuilt" / host / "bin"
    return b if b.is_dir() else None


def java_home_17() -> str | None:
    """JDK 17 из состава Solar2D: Gradle 8.13 шаблона не запускается на JDK 25 (JBR Android Studio)."""
    if platform.system() == "Windows":
        jre = Path(r"C:\Program Files (x86)\Corona Labs\Corona\jre")
        return str(jre) if jre.is_dir() else None
    return os.environ.get("JAVA_HOME")
