#!/usr/bin/env /usr/bin/python3
"""Готує іконку застосунку → Sources/Assets.xcassets/AppIcon.appiconset/

Вихідне зображення — Scripts/icon-source.png, надане користувачем із ресурсу
вільних зображень. Скрипт лише обробляє його: прибирає біле тло, кладе на
чорне й нарізає потрібні розміри.

Тло чорне, а не біле: іконка часто перша яскрава пляма при запуску в темряві.
Прозорим його зробити не можна — iOS і macOS однаково підкладуть біле.

Запуск: ./Scripts/generate-app-icon.py
"""

import json
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Scripts", "icon-source.png")
OUT_DIR = os.path.join(ROOT, "Sources", "Assets.xcassets", "AppIcon.appiconset")

BACKDROP = (10, 10, 10)

# Частка полотна, яку займає малюнок. Поля обовʼязкові: iOS і macOS обрізають
# іконку маскою зі скругленням, і зображення впритул до краю втрачає кути.
CONTENT_SCALE = 0.78

WHITE_TOLERANCE = 42


def remove_white_background(img: Image.Image) -> Image.Image:
    """Робить прозорим саме тло, а не все світле.

    Заливка йде від кутів, тому світлі ділянки всередині контуру — сторінки,
    наличка — лишаються недоторканими.
    """
    rgb = img.convert("RGB")
    w, h = rgb.size

    # Маска: 255 — те, що лишаємо.
    mask = Image.new("L", (w, h), 255)
    work = rgb.copy()

    for corner in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if min(work.getpixel(corner)) > 255 - WHITE_TOLERANCE:
            ImageDraw.floodfill(work, corner, (255, 0, 255), thresh=WHITE_TOLERANCE)

    pixels = work.load()
    mask_px = mask.load()
    for y in range(h):
        for x in range(w):
            if pixels[x, y] == (255, 0, 255):
                mask_px[x, y] = 0

    # Вихідне зображення згладжене на білому, тому по контуру лишається
    # світлий обідок. Підтискаємо маску всередину, щоб його зрізати, і лише
    # потім пом'якшуємо край.
    mask = mask.filter(ImageFilter.MinFilter(5))
    mask = mask.filter(ImageFilter.GaussianBlur(0.8))

    out = rgb.convert("RGBA")
    out.putalpha(mask)
    return out


def silverize_red(img: Image.Image) -> Image.Image:
    """Замінює червону палітуру на шліфований метал.

    Колір не заливається рівно: яскравість кожного пікселя переноситься в
    срібну шкалу, тож затінення оригіналу — темніший корінець, світліша
    лицьова площина — лишається, і книга не втрачає обʼєм.

    Що саме вважаємо червоним: червоний канал помітно переважає над іншими,
    а зелений і синій близькі між собою. Друга умова обовʼязкова — без неї під
    заміну потрапляють коричнева закладка (G значно більший за B) і золоті
    куточки.
    """
    rgba = img.convert("RGBA")
    w, h = rgba.size
    px = rgba.load()

    random.seed(4711)
    # Штрихи шліфування: одне значення на рядок, щоб смуги були
    # горизонтальними й тонкими, як на справжньому металі.
    streaks = [random.gauss(0, 11.0) for _ in range(h)]
    grain = [random.gauss(0, 4.5) for _ in range(4096)]

    def specular(position):
        """Два відблиски: широкий основний і вузький вторинний.

        Саме вони роблять поверхню металевою. Рівна світла заливка, яка була
        тут раніше, читалася як білий папір: у металу мусить бути темна
        основа, на якій блиск виділяється.
        """
        main = 104 * math.exp(-(((position - 0.34) / 0.15) ** 2))
        secondary = 54 * math.exp(-(((position - 0.74) / 0.075) ** 2))
        return main + secondary

    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue

            dominant = r > g * 1.25 and r > b * 1.25 and r > 55
            neutral_gb = abs(g - b) < 0.35 * r
            if not (dominant and neutral_gb):
                continue

            # Темна основа: яскравим лишається тільки блиск.
            t = min(1.0, r / 200.0)
            value = 58 + t * 56

            # Вісь відблиску — коса, щоб площина читалася як нахилена.
            axis = (x / w) * 0.62 + (1 - y / h) * 0.38
            value += specular(axis)

            value += streaks[y]
            value += grain[(y * 31 + x) % len(grain)]

            value = max(18, min(246, value))
            # Срібло холодне: синій вищий за червоний.
            px[x, y] = (
                int(max(0, min(255, value - 9))),
                int(max(0, min(255, value - 1))),
                int(max(0, min(255, value + 12))),
                a,
            )

    return rgba


def trim(img: Image.Image) -> Image.Image:
    """Обрізає порожнечу навколо малюнка, щоб поля задавали ми, а не джерело."""
    bbox = img.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    return img.crop(bbox) if bbox else img


def main() -> None:
    source = trim(silverize_red(remove_white_background(Image.open(SRC))))

    size = 1024
    content = int(size * CONTENT_SCALE)
    scale = min(content / source.width, content / source.height)
    scaled = source.resize(
        (max(1, round(source.width * scale)), max(1, round(source.height * scale))),
        Image.LANCZOS,
    )

    icon = Image.new("RGB", (size, size), BACKDROP)
    icon.paste(
        scaled,
        ((size - scaled.width) // 2, (size - scaled.height) // 2),
        scaled,
    )

    os.makedirs(OUT_DIR, exist_ok=True)
    icon.save(os.path.join(OUT_DIR, "icon-1024.png"))

    # macOS потребує власного набору розмірів; Catalyst бере саме його.
    mac = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
           (256, 1), (256, 2), (512, 1), (512, 2)]
    images = [{
        "filename": "icon-1024.png",
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
    }]
    for s, scale_factor in mac:
        px = s * scale_factor
        name = f"mac-{s}x{s}@{scale_factor}x.png"
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(OUT_DIR, name))
        images.append({
            "filename": name,
            "idiom": "mac",
            "scale": f"{scale_factor}x",
            "size": f"{s}x{s}",
        })

    with open(os.path.join(OUT_DIR, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)

    print(f"записано {OUT_DIR} ({len(images)} зображень)")


if __name__ == "__main__":
    main()
