"""Diagramma diagnostico, non screenshot Fusion. Richiede Pillow.
Uso: python tests/render_preview.py anteprima.json anteprima.png
"""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
nodes = json.loads(args.source.read_text(encoding='utf-8'))['nodes']
by_name = {n['name']: n for n in nodes}
min_x = min(n['x'] for n in nodes)
min_y = min(n['y'] for n in nodes)


def xy(node):
    return (round(100 + (node['x'] - min_x) * 160),
            round(70 + (node['y'] - min_y) * 65))


width = max(xy(n)[0] for n in nodes) + 110
height = max(xy(n)[1] for n in nodes) + 80
image = Image.new('RGB', (width, height), '#171c24')
draw = ImageDraw.Draw(image)
for node in nodes:
    for inp in node['inputs']:
        source = by_name[inp['source']]
        color = '#69b77f' if inp['id'] == 'Background' else '#d3ad64'
        draw.line([xy(source), xy(node)], fill=color, width=2)
for node in nodes:
    x, y = xy(node)
    draw.rounded_rectangle((x-76, y-15, x+76, y+15), radius=4,
                           fill='#35465a', outline='#9bb0c7')
    draw.text((x-68, y-6), node['name'], fill='white')
args.output.parent.mkdir(parents=True, exist_ok=True)
image.save(args.output)
print(args.output)
