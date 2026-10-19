#!/usr/bin/env python3
"""Compose the 1.1 store gallery from unchanged native app captures.

Requires Pillow. Run after exporting Release-* XCTest attachments into
docs/app-store/screenshots/1.1/raw/{iphone,ipad}/ with numbered filenames.
All image content comes from the app; only the surrounding artwork is drawn.
"""
from pathlib import Path
import argparse
import hashlib
import json
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/app-store/screenshots/1.1'
FONTS = Path('/System/Library/Fonts')
LATIN = FONTS / 'Supplemental/Arial Bold.ttf'
REGULAR = FONTS / 'Supplemental/Arial.ttf'
CJK = FONTS / 'Supplemental/Arial Unicode.ttf'
COPY = {
    'en-US': [
        ('Your cloud computer.\nWithin reach.', 'Chat, files and tools. One Memoh workspace.'),
        ('Keep work together.', 'Your conversations and files, within reach.'),
        ('From idea to file.', 'Read and edit right in your workspace.'),
        ('A team of your own.', 'Switch agents. Explore their workspaces.'),
    ],
    'zh-Hans': [
        ('你的云电脑。\n触手可及。', '对话、文件与工具，汇聚在 Memoh 工作空间。'),
        ('让工作井然有序。', '随时访问对话与工作空间文件。'),
        ('从灵感到文件。', '直接在工作空间中阅读与编辑。'),
        ('你的智能体团队。', '切换智能体，探索各自的工作空间。'),
    ],
    'ja': [
        ('クラウドのコンピュータを、\nいつも手元に。', '会話もファイルもツールも、Memoh のひとつの場所で。'),
        ('作業をひとつの場所に。', '会話とワークスペースのファイルに、いつでもアクセス。'),
        ('アイデアをファイルに。', 'ワークスペースでそのまま閲覧・編集。'),
        ('自分だけのチーム。', 'エージェントを切り替え、それぞれの作業場所へ。'),
    ],
    'es-ES': [
        ('Tu ordenador en la nube.\nSiempre a mano.', 'Chats, archivos y herramientas en Memoh.'),
        ('Todo tu trabajo, junto.', 'Tus conversaciones y archivos, a mano.'),
        ('De la idea al archivo.', 'Lee y edita en tu espacio de trabajo.'),
        ('Tu propio equipo.', 'Cambia de agente y explora sus espacios.'),
    ],
}
SOURCES = {
    'iphone': [('raw/iphone/01-conversation.png', 0), ('raw/iphone/03-files.png', 1), ('raw/iphone/04-editor.png', 2), ('raw/iphone/02-agents.png', 3)],
    'ipad': [('raw/ipad/01-conversation.png', 0), ('raw/ipad/03-files.png', 1), ('raw/ipad/04-editor.png', 2), ('raw/ipad/02-agents.png', 3)],
    'mac': [('../native-mac/en-US/01-chat.jpg', 0), ('../native-mac/en-US/02-split-files.jpg', 1), ('../native-mac/en-US/03-file-editor.jpg', 2), ('../native-mac/en-US/04-agents.jpg', 3)],
    'vision': [('raw/vision/01-conversation.png', 0), ('raw/vision/03-files.png', 1), ('raw/vision/04-chats.png', 1), ('raw/vision/02-agents.png', 3)],
}
SIZES = {'iphone': (1320, 2868), 'ipad': (2064, 2752), 'mac': (2880, 1800), 'vision': (3840, 2160)}

def font(size, locale, bold=True):
    return ImageFont.truetype(str(CJK if locale in ('zh-Hans', 'ja') else LATIN if bold else REGULAR), size)

def fit(draw, text, size, width, locale, bold=True):
    while True:
        f = font(size, locale, bold)
        if max(draw.textlength(line, font=f) for line in text.split('\n')) <= width or size <= 24:
            return f
        size -= 1

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def render(platform, locale, index, source, copy_index):
    w, h = SIZES[platform]
    portrait = platform == 'iphone'
    scale = w / (1320 if portrait else 2880)
    image = Image.new('RGB', (w, h), '#101b28')
    draw = ImageDraw.Draw(image)
    # Quiet geometric detail; no synthetic product interface or device frame.
    draw.ellipse((int(w*.55), int(h*.42), int(w*1.45), int(h*1.3)), fill='#172c3b')
    margin = int(w * (.085 if portrait else .06))
    top = int(100 * scale)
    draw.text((margin, top), 'HOMEM', font=font(int(34*scale), 'en-US'), fill='#88e8d0')
    draw.text((w-margin, top), f'0{index}', anchor='ra', font=font(int(30*scale), 'en-US'), fill='#8babb7')
    title, subtitle = COPY[locale][copy_index]
    if not portrait:
        title = title.replace('\n', ' ')
    if platform == 'vision' and index == 1:
        title = {'en-US': 'Your workspace. All around you.', 'zh-Hans': '你的工作空间，就在身边。', 'ja': 'ワークスペースが、あなたの周りに。', 'es-ES': 'Tu espacio de trabajo, a tu alrededor.'}[locale]
    title_y = int((220 if portrait else 175)*scale)
    title_font = fit(draw, title, int((112 if portrait else 104)*scale), w-2*margin, locale)
    draw.multiline_text((margin, title_y), title, font=title_font, fill='#f2f6f8', spacing=int(12*scale))
    subtitle_y = int((530 if portrait else 310)*scale)
    subtitle_font = fit(draw, subtitle, int((37 if portrait else 37)*scale), w-2*margin, locale, False)
    draw.text((margin, subtitle_y), subtitle, font=subtitle_font, fill='#b9cbd3')
    capture = Image.open(source).convert('RGB')
    image_top = int((650 if portrait else 425)*scale)
    available = (w-2*margin, h-image_top-int(65*scale))
    capture = ImageOps.contain(capture, available, Image.Resampling.LANCZOS)
    x = (w-capture.width)//2
    y = image_top
    shadow = Image.new('RGBA', (w,h))
    ImageDraw.Draw(shadow).rectangle((x, y+int(22*scale), x+capture.width, y+capture.height+int(22*scale)), fill=(0,0,0,120))
    image = Image.alpha_composite(image.convert('RGBA'), shadow.filter(ImageFilter.GaussianBlur(int(25*scale)))).convert('RGB')
    image.paste(capture, (x,y))
    draw = ImageDraw.Draw(image)
    draw.rectangle((x-1, y-1, x+capture.width, y+capture.height), outline='#6f8794', width=max(1,int(scale)))
    destination = OUT/platform/locale/f'{index:02d}-{source.stem.split("-",1)[-1]}.jpg'
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, quality=96, subsampling=0)
    return {'path': str(destination.relative_to(ROOT)), 'platform': platform, 'locale': locale, 'dimensions': [w,h], 'title': title, 'subtitle': subtitle, 'source': str(source.resolve().relative_to(ROOT)), 'sourceSHA256': digest(source), 'sha256': digest(destination)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platforms', nargs='+', choices=SOURCES, default=list(SOURCES))
    options = parser.parse_args()
    manifest = []
    for platform, sources in SOURCES.items():
        if platform not in options.platforms:
            continue
        for locale in COPY:
            for index, (relative, copy_index) in enumerate(sources, 1):
                source = OUT/relative
                if not source.is_file():
                    raise SystemExit(f'Missing native capture: {source}')
                manifest.append(render(platform, locale, index, source, copy_index))
    (OUT/'manifest.json').write_text(json.dumps({'version': '1.1', 'artworkDate': '2026-10-19', 'nativeInterfaceAltered': False, 'assets': manifest}, ensure_ascii=False, indent=2)+'\n')
    # A compact review image is separate from the individual store exports.
    preview = Image.new('RGB', (1600, 1050), '#101b28')
    d = ImageDraw.Draw(preview)
    for row, platform in enumerate(SOURCES):
        d.text((20, row*260+10), platform.upper(), font=font(18,'en-US'), fill='#88e8d0')
        for col, asset in enumerate(a for a in manifest if a['platform']==platform and a['locale']=='en-US'):
            thumb=ImageOps.contain(Image.open(ROOT/asset['path']), (370,220), Image.Resampling.LANCZOS)
            preview.paste(thumb, (20+col*395+(370-thumb.width)//2, row*260+40))
    preview.save(OUT/'preview.jpg', quality=92)
    print(f'Exported {len(manifest)} store assets and preview.')

if __name__ == '__main__':
    main()
