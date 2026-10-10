"""Байт-код Lua-части плагина (plugin_<имя>.c) для Android, iOS и macOS.

Использование (из репозитория плагина):
    python tools/obnovit_baitkod_lua.py             пересоздать
    python tools/obnovit_baitkod_lua.py --proverit  только сверить с plugin_<имя>.lua

Lua-часть вшивается в библиотеку байт-кодом. На Windows его при каждой сборке делает шаг
LuaToCpp проекта Visual Studio, а Android (CMake) и Xcode-проекты берут готовый
plugin_<имя>.c — его и пишет этот скрипт. Запускать после каждой правки Lua-части:
иначе Windows получит новую Lua-часть, а остальные платформы — прежнюю.

Преобразование — тем же lua2c.lua из Corona Native, что и на Windows, и с ОТНОСИТЕЛЬНЫМ
именем файла: string.dump вшивает имя чанка, и с полным путём в библиотеку попадал бы
путь сборочной машины. Байт-код переносим между платформами: Solar2D пишет в его
заголовок sizeof(uint32_t), а не sizeof(size_t), поэтому одна копия годится для 32- и
64-битных библиотек.
"""

import platform
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plagin_konfig import Plagin, corona_native, najti_koren, nastroit_vyvod  # noqa: E402


def generate(pl: Plagin) -> bytes:
    native = corona_native()
    win = platform.system() == "Windows"
    lua = native / "Corona" / ("win" if win else "mac") / "bin" / ("lua.exe" if win else "lua")
    lua2c = native / "Corona" / "shared" / "bin" / "lua2c.lua"
    for tool in (lua, lua2c):
        if not tool.exists():
            sys.exit(f"нет {tool}: нужен Corona Native (на Mac — Native/Setup Corona Native)")
    src = pl.lua
    if not src.exists():
        sys.exit(f"нет {src}")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / f"{pl.osnova}.c"
        subprocess.run([str(lua), str(lua2c), src.name, pl.osnova, str(out)], cwd=src.parent, check=True)
        data = out.read_bytes().replace(b"\r\n", b"\n")
    if str(pl.koren).encode() in data or b"Users" in data:
        sys.exit("в байт-коде остался путь сборочной машины")
    return data


def main() -> int:
    nastroit_vyvod()
    pl = Plagin(najti_koren())
    data = generate(pl)
    check_only = "--proverit" in sys.argv[1:]
    failed = False
    for target in pl.baitkod:
        current = target.read_bytes().replace(b"\r\n", b"\n") if target.exists() else None
        rel = target.relative_to(pl.koren)
        if current == data:
            print(f"совпадает   {rel}")
        elif check_only:
            print(f"ОТСТАЁТ     {rel}")
            failed = True
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            print(f"обновлён    {rel}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
