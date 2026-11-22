#!/usr/bin/env /usr/bin/python3
"""Генерує безшовне зерно паперу й плівки → Sources/Resources/grain@2x.png

Зерно виводиться як **напівпрозоре сіре накладання**, а не готовий кольоровий
аркуш. Так колір тла стає налаштовним: будь-який колір задається знизу, а це
PNG лише додає фактуру поверх. Інакше при зміні кольору текстура лишалася б
оливковою і виглядала б брудною плямою.

Текстура процедурна й оригінальна: нічого не запозичено й не скопійовано.

Безшовність забезпечують дві речі:
  * зерно — гаусів шум на піксель, без низькочастотної структури, тому стики
    тайлів око не читає;
  * волокна — координати беруться по модулю розміру, тож штрих, що виходить
    за край, заходить із протилежного.

Потрібен системний /usr/bin/python3: саме в ньому є PIL.
Запуск: ./Scripts/generate-paper-texture.py
"""

import math
import os
import random

from PIL import Image, ImageFilter

SEED = 20261121
SIZE = 256
MID = 128                   # нейтральна середина: світліше — освітлює, темніше — затемнює
GRAIN_SIGMA = 2.4
FIBER_COUNT = 420

# Зерно старої целюлозної плівки. Кластери срібла різного калібру —
# саме різнокаліберність відрізняє плівкове зерно від рівного цифрового шуму.
# Амплітуди навмисно малі: це тло для читання, а не художній фільтр.
FILM_OCTAVES = ((2, 3.6), (4, 2.4), (8, 1.6))   # (розмір кластера, амплітуда)
DUST_COUNT = 80
SCRATCH_COUNT = 5

# Сила накладання: у скільки разів відхилення від нейтралі стає альфою.
OVERLAY_GAIN = 3.4

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources", "Resources", "grain@2x.png",
)


def seamless_clumps(size: int, cell: int) -> Image.Image:
    """Плямистий шум, який тайлиться без шва.

    Дрібний пошумовий шум кластерів не дає — потрібне згладжування, а воно
    псує стики. Тому шум генерується у низькій роздільності, викладається 3×3,
    збільшується цілком і з результату береться центр: інтерполяція на краях
    бачить сусідні копії, тож шов зникає.
    """
    low = size // cell
    noise = Image.new("L", (low, low))
    noise.putdata([max(0, min(255, int(random.gauss(128, 46)))) for _ in range(low * low)])

    tiled = Image.new("L", (low * 3, low * 3))
    for tx in range(3):
        for ty in range(3):
            tiled.paste(noise, (tx * low, ty * low))

    grown = tiled.resize((size * 3, size * 3), Image.BICUBIC)
    return grown.crop((size, size, size * 2, size * 2))


def apply_film_grain(img: Image.Image, size: int) -> Image.Image:
    """Накладає зерно, порошинки й подряпини старої плівки."""
    layers = [(seamless_clumps(size, cell).load(), amp) for cell, amp in FILM_OCTAVES]
    px = img.load()

    for y in range(size):
        for x in range(size):
            delta = 0.0
            for data, amp in layers:
                delta += (data[x, y] - 128) / 128.0 * amp
            r, g, b = px[x, y]
            # Зерно чіпляється за світло сильніше, ніж за колір, тому зсув
            # майже однаковий по каналах, із легким теплим ухилом.
            px[x, y] = (
                max(0, min(255, int(r + delta))),
                max(0, min(255, int(g + delta * 0.97))),
                max(0, min(255, int(b + delta * 0.92))),
            )

    # Порошинки: дрібні темні й світлі крупинки, як на старому негативі.
    for _ in range(DUST_COUNT):
        cx, cy = random.randrange(size), random.randrange(size)
        radius = random.choice((0, 0, 0, 1))
        shade = random.choice((-1, 1)) * random.uniform(5, 16)
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                x, y = (cx + dx) % size, (cy + dy) % size
                r, g, b = px[x, y]
                px[x, y] = (
                    max(0, min(255, int(r + shade))),
                    max(0, min(255, int(g + shade))),
                    max(0, min(255, int(b + shade * 0.95))),
                )

    # Подряпини: майже вертикальні волосини від протяжки плівки.
    for _ in range(SCRATCH_COUNT):
        x0 = random.uniform(0, size)
        y0 = random.uniform(0, size)
        length = random.uniform(size * 0.2, size * 0.9)
        drift = random.uniform(-0.05, 0.05)
        shade = random.choice((-1, 1)) * random.uniform(2.5, 5.5)
        steps = int(length)
        for i in range(steps):
            t = i / steps
            x = int((x0 + drift * length * t) % size)
            y = int((y0 + length * t) % size)
            fade = math.sin(math.pi * t) ** 0.6
            r, g, b = px[x, y]
            px[x, y] = (
                max(0, min(255, int(r + shade * fade))),
                max(0, min(255, int(g + shade * fade))),
                max(0, min(255, int(b + shade * fade))),
            )

    return img


def main() -> None:
    random.seed(SEED)

    pixels = []
    for _ in range(SIZE * SIZE):
        n = random.gauss(0, GRAIN_SIGMA)
        v = max(0, min(255, int(MID + n)))
        pixels.append((v, v, v))

    img = Image.new("RGB", (SIZE, SIZE))
    img.putdata(pixels)
    img = img.filter(ImageFilter.GaussianBlur(0.4))

    px = img.load()
    for _ in range(FIBER_COUNT):
        x0, y0 = random.uniform(0, SIZE), random.uniform(0, SIZE)
        angle = random.gauss(0, 0.5) + (0 if random.random() < 0.5 else math.pi / 2)
        length = random.uniform(6, 34)
        shade = random.uniform(-4.5, 3.0)
        steps = int(length * 2)
        for i in range(steps):
            t = i / steps
            x = int((x0 + math.cos(angle) * length * t) % SIZE)
            y = int((y0 + math.sin(angle) * length * t) % SIZE)
            r, g, b = px[x, y]
            fade = math.sin(math.pi * t)
            px[x, y] = (
                max(0, min(255, int(r + shade * fade))),
                max(0, min(255, int(g + shade * fade))),
                max(0, min(255, int(b + shade * fade * 0.9))),
            )

    img = img.filter(ImageFilter.GaussianBlur(0.3))
    img = apply_film_grain(img, SIZE)

    # Переводимо яскравість у прозорість: нейтральні пікселі стають
    # невидимими, відхилення — ледь помітним світлим або темним серпанком.
    rgba = Image.new("RGBA", (SIZE, SIZE))
    src = img.load()
    out = rgba.load()
    for y in range(SIZE):
        for x in range(SIZE):
            v = src[x, y][0]
            delta = v - MID
            if delta >= 0:
                out[x, y] = (255, 255, 255, min(255, int(delta * OVERLAY_GAIN)))
            else:
                out[x, y] = (0, 0, 0, min(255, int(-delta * OVERLAY_GAIN)))

    rgba.save(OUT, optimize=True)
    print(f"записано {OUT} ({SIZE}×{SIZE}, прозоре накладання)")


if __name__ == "__main__":
    main()
