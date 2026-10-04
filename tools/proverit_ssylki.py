"""Проверка прямых ссылок на архивы плагина: скачиваются ли без входа и совпадают ли с собранными.

Использование (из репозитория плагина):
    python tools/proverit_ssylki.py              скачать все 7 ссылок и сверить с plugins/
    python tools/proverit_ssylki.py --nastrojki  только напечатать блок plugins для build.settings
    python tools/proverit_ssylki.py --lokalno 8765
        ссылки на http://127.0.0.1:8765/<платформа>/data.tgz — для проверки архивов ДО публикации:
        python -m http.server 8765 --bind 127.0.0.1 --directory plugins

Ссылки строятся из plagin.json: https://raw.githubusercontent.com/<repo>/<vetka>/plugins/<платформа>/data.tgz.
Заодно проверяется, что README перечисляет именно их. Проверять ПОСЛЕ каждого пуша: архив в
репозитории мог разойтись с проверенным (не тот коммит, не та ветка, LFS, приватный репозиторий —
тогда raw отдаёт 404).
"""

import hashlib
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plagin_konfig import PLATFORMY, Plagin, najti_koren, nastroit_vyvod  # noqa: E402


def nastrojki(pl: Plagin, baza: str | None) -> str:
    """Блок plugins для build.settings приложения: ссылка на каждую платформу."""
    out = ["plugins =", "{", f'\t["{pl.modul}"] =', "\t{", f'\t\tpublisherId = "{pl.izdatel}",',
           "\t\tsupportedPlatforms =", "\t\t{"]
    for p in PLATFORMY:
        url = f"{baza}/{p}/data.tgz" if baza else pl.ssylka(p)
        key = p if p.isidentifier() else f'["{p}"]'
        out.append(f'\t\t\t{key} = {{ url = "{url}" }},')
    out += ["\t\t},", "\t},", "},"]
    return "\n".join(out)


def main() -> int:
    nastroit_vyvod()
    pl = Plagin(najti_koren())
    args = sys.argv[1:]
    if "--nastrojki" in args:
        print(nastrojki(pl, None))
        return 0
    if "--lokalno" in args:
        port = args[args.index("--lokalno") + 1]
        print(nastrojki(pl, f"http://127.0.0.1:{port}"))
        return 0
    if not pl.repo:
        sys.exit("в plagin.json нет repo (owner/Repo)")

    bad = 0
    readme = next((pl.put(n) for n in ("ReadMe.md", "README.md") if pl.put(n).exists()), None)
    text = readme.read_text(encoding="utf-8") if readme else ""
    for p in PLATFORMY:
        url = pl.ssylka(p)
        if readme and url not in text:
            print(f"{p:11} нет в {readme.name}: {url}")
            bad += 1
        local = pl.put(f"plugins/{p}/data.tgz")
        want = hashlib.sha256(local.read_bytes()).hexdigest() if local.exists() else None
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "solar2d-plugin-check"})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            got = hashlib.sha256(data).hexdigest()
            state = "ok" if got == want else ("НЕТ ЛОКАЛЬНОГО" if want is None else "РАЗНЫЕ")
            print(f"{p:11} {r.status} {len(data):>9} байт  {state}")
            bad += state != "ok"
        except Exception as e:  # noqa: BLE001 — печатаем любую сетевую причину
            print(f"{p:11} ОШИБКА {e}")
            bad += 1
    print("ИТОГ:", "все ссылки работают и совпадают" if not bad else f"проблем: {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
