import hashlib,json,math,pathlib
from PIL import Image,ImageDraw
root=pathlib.Path(__file__).parent
out=root/'fixtures'
colors=[('red',(210,35,40),'rot'),('blue',(30,85,210),'blau'),('green',(30,155,65),'grün'),('yellow',(235,195,20),'gelb'),('purple',(135,55,175),'violett')]
objects=['house','car','tree','flower','boat','star']
assets=[]
for object_index,kind in enumerate(objects):
 for color_index,(english,color,german) in enumerate(colors):
  image=Image.new('RGB',(256,256),(245,246,248))
  d=ImageDraw.Draw(image)
  stroke=(32,36,43)
  if kind=='house':
   d.rectangle((53,110,203,218),fill=color,outline=stroke,width=3)
   d.polygon([(37,113),(128,35),(219,113)],fill=color,outline=stroke,width=3)
   d.rectangle((111,158,144,218),fill=(115,78,48),outline=stroke,width=3)
   for x in [69,159]: d.rectangle((x,127,x+30,156),fill=(200,229,250),outline=stroke,width=3)
  elif kind=='car':
   d.polygon([(35,136),(72,132),(95,85),(171,85),(201,131),(224,145),(224,183),(31,183)],fill=color,outline=stroke,width=3)
   d.polygon([(100,95),(124,95),(124,129),(82,129)],fill=(203,232,247),outline=stroke,width=2)
   d.polygon([(134,95),(164,95),(186,129),(134,129)],fill=(203,232,247),outline=stroke,width=2)
   for x in [74,185]:
    d.ellipse((x-23,161,x+23,207),fill=(30,32,37))
    d.ellipse((x-11,173,x+11,195),fill=(195,198,206))
  elif kind=='tree':
   d.rectangle((111,135,145,229),fill=(114,75,43),outline=stroke,width=3)
   for bounds in [(53,74,146,170),(110,73,203,169),(80,28,179,126),(30,104,118,190),(135,102,226,191)]:
    d.ellipse(bounds,fill=color,outline=stroke,width=2)
  elif kind=='flower':
   d.line((128,130,128,232),fill=(30,130,58),width=12)
   d.ellipse((70,169,128,197),fill=(30,150,64),outline=stroke,width=2)
   d.ellipse((128,188,186,216),fill=(30,150,64),outline=stroke,width=2)
   for j in range(7):
    angle=j*2*math.pi/7
    x=128+48*math.cos(angle);y=100+48*math.sin(angle)
    d.ellipse((int(x)-30,int(y)-30,int(x)+30,int(y)+30),fill=color,outline=stroke,width=2)
   d.ellipse((102,74,154,126),fill=(244,189,40),outline=stroke,width=2)
  elif kind=='boat':
   d.polygon([(27,163),(231,163),(201,215),(62,215)],fill=color,outline=stroke,width=3)
   d.line((126,31,126,167),fill=stroke,width=5)
   d.polygon([(120,43),(120,153),(44,153)],fill=(254,254,252),outline=stroke,width=3)
   d.polygon([(134,53),(209,153),(134,153)],fill=color,outline=stroke,width=3)
   d.line((20,229,236,229),fill=(80,157,209),width=4)
  else:
   points=[]
   for j in range(10):
    angle=-math.pi/2+j*math.pi/5;r=102 if j%2==0 else 43
    points.append((int(128+r*math.cos(angle)),int(128+r*math.sin(angle))))
   d.polygon(points,fill=color,outline=stroke,width=3)
  asset_id=f'fixture-{object_index*5+color_index+1:02d}'
  path=out/(asset_id+'.png')
  image.save(path)
  assets.append(dict(id=asset_id,kind=kind,color=english,path='fixtures/'+path.name,width=256,height=256,rgb_sha256=hashlib.sha256(image.tobytes()).hexdigest(),png_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
queries=[]
for kind,de_noun,article,ending in [('house','Haus','ein','es'),('car','Auto','ein','es'),('flower','Blume','eine','e'),('boat','Boot','ein','es')]:
 for english,color,german in colors:
  target=next(a for a in assets if a['kind']==kind and a['color']==english)
  queries.append(dict(id=f'q-{len(queries)+1:02d}',de=f'{article} {german}{ending} {de_noun}',en=f'a {english} {kind}',relevant_asset_ids=[target['id']]))
manifest=dict(version=1,description='Frozen before first model inference; programmatically drawn synthetic objects, no user photos or embedded words.',assets=assets,queries=queries,negative_queries=[dict(de='ein Elefant',en='an elephant'),dict(de='ein Flugzeug',en='an airplane'),dict(de='eine Geige',en='a violin'),dict(de='ein Fußball',en='a soccer ball'),dict(de='eine Schnecke',en='a snail')])
body=json.dumps(manifest,ensure_ascii=False,sort_keys=True,indent=2).encode()
(root/'ground-truth.json').write_bytes(body)
(root/'ground-truth.sha256').write_text(hashlib.sha256(body).hexdigest()+'  ground-truth.json\n')
print('Frozen',len(assets),'images,',len(queries),'DE/EN query pairs, 5 negative pairs; SHA256',hashlib.sha256(body).hexdigest())
