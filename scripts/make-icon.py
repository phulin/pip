from PIL import Image, ImageDraw
from pathlib import Path
import json
size = 1024
im = Image.new('RGB', (size, size), '#F3F1E8')
d = ImageDraw.Draw(im)
d.ellipse((267, 350, 617, 800), fill='#386652')
d.ellipse((434, 231, 759, 525), fill='#8BA98F')
d.line([(503, 708), (541, 423), (658, 341)], fill='#F3F1E8', width=25)
d.ellipse((625, 661, 699, 735), fill='#E5A77A')
path = Path('ios/Pip/Assets.xcassets/AppIcon.appiconset')
path.mkdir(parents=True, exist_ok=True)
im.save(path / 'AppIcon.png')
(path / 'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}}, indent=2))
