# Dependency-free orthographic geometry renderer for reviewing the authored parts.
import json, math, struct, zlib, sys
D=json.load(open(sys.argv[1]))
W,H=1200,520
pixels=bytearray([39,47,52]*(W*H)); zb=[1e9]*(W*H)
def sub(a,b):return tuple(x-y for x,y in zip(a,b))
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def cross(a,b):return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def unit(a):return tuple(x/math.sqrt(dot(a,a)) for x in a)
fwd=unit((-6,-3.6,-7)); right=unit(cross(fwd,(0,1,0))); up=cross(right,fwd)
light=unit((-.6,1,.8))
def project(v,cx):return (cx+dot(v,right)*82,350-dot(v,up)*82,dot(v,fwd))
def triangle(vs,col,cx):
 n=unit(cross(sub(vs[1],vs[0]),sub(vs[2],vs[0])))
 shade=.53+.47*abs(dot(n,light))
 rgb=[int(max(0,min(255,c*255*shade))) for c in col]
 a,b,c=[project(v,cx) for v in vs]
 denom=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
 if abs(denom)<1e-8:return
 xlo=max(0,int(min(a[0],b[0],c[0])));xhi=min(W-1,int(max(a[0],b[0],c[0]))+1)
 ylo=max(0,int(min(a[1],b[1],c[1])));yhi=min(H-1,int(max(a[1],b[1],c[1]))+1)
 for y in range(ylo,yhi+1):
  for x in range(xlo,xhi+1):
   u=((b[1]-c[1])*(x-c[0])+(c[0]-b[0])*(y-c[1]))/denom
   v=((c[1]-a[1])*(x-c[0])+(a[0]-c[0])*(y-c[1]))/denom
   w=1-u-v
   if min(u,v,w)<0:continue
   z=u*a[2]+v*b[2]+w*c[2];idx=y*W+x
   if z<zb[idx]:zb[idx]=z;pixels[idx*3:idx*3+3]=bytes(rgb)
def faces(p):
 sx,sy,sz=[n/2 for n in p['size']]
 if p['shape']=='Cylinder':
  verts=[(x,sy*math.cos(i*math.pi/8),sz*math.sin(i*math.pi/8)) for x in [-sx,sx] for i in range(16)]
  fs=[list(range(15,-1,-1)),list(range(16,32))]+[[i,(i+1)%16,(i+1)%16+16,i+16] for i in range(16)]
 elif p['shape']=='Wedge':
  verts=[(-sx,-sy,-sz),(sx,-sy,-sz),(-sx,-sy,sz),(sx,-sy,sz),(-sx,sy,sz),(sx,sy,sz)]
  fs=[[0,1,3,2],[2,3,5,4],[0,4,5,1],[0,2,4],[1,5,3]]
 else:
  verts=[(x*sx,y*sy,z*sz) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
  fs=[[0,3,2,1],[4,5,6,7],[0,1,5,4],[3,7,6,2],[0,4,7,3],[1,2,6,5]]
 cf=p['cf'];t=cf[:3];r=[cf[3:6],cf[6:9],cf[9:12]]
 verts=[tuple(t[j]+dot(r[j],v) for j in range(3)) for v in verts]
 for f in fs:
  for i in range(1,len(f)-1):yield [verts[f[0]],verts[f[i]],verts[f[i+1]]]
for kind,cx in [('sedan',295),('pickup',895)]:
 for p in D[kind]:
  for tri in faces(p):triangle(tri,p['color'],cx)
def chunk(t,d):return struct.pack('!I',len(d))+t+d+struct.pack('!I',zlib.crc32(t+d)&0xffffffff)
raw=b''.join(b'\0'+pixels[y*W*3:(y+1)*W*3] for y in range(H))
open(sys.argv[2],'wb').write(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',W,H,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
