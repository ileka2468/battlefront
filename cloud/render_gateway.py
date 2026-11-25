"""Stateless HTTPS edge for Battlefront. SQLite remains on the DCS origin."""
from http import client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import re
from urllib.parse import urlsplit
import mimetypes

WEB = Path(__file__).resolve().parents[1] / 'web'
MAX_REQUEST_BODY = 16384
READ = {'/api/state','/api/campaign','/api/upgrades','/api/telemetry',
        '/api/weather','/api/app-telemetry','/api/auth/oauth/status','/mcp','/mcp/app'}
WRITE = {'/api/workspace/login','/api/workspace/logout','/api/workspace/signup',
         '/api/dcs/link/start','/api/dcs/link/finish','/api/player/set_callsign','/api/requisition',
         '/api/marketplace/list','/api/marketplace/buy','/api/marketplace/cancel','/api/armory/mount',
         '/api/operations/join','/api/operations/leave','/api/operations/propose',
         '/api/operations/command','/api/operations/launch','/api/dcs/deliver',
         '/api/app-telemetry','/mcp'}
STATIC = {'/','/index.html','/sectors.json','/tacview.js','/caucasus_terrain.js','/airframes.js',
          '/dist/companion.js','/dist/tailwind.css','/terrain/caucasus-height.png','/terrain/caucasus-relief.jpg',
          '/vendor/three.min.js','/vendor/OrbitControls.js','/vendor/GLTFLoader.js',
          '/models/vendor/manifest.json','/models/vendor/credits.html','/models/vendor/flightgear-source.zip',
          '/models/vendor/su-35-license.txt'}
for row in json.loads((WEB/'models/vendor/manifest.json').read_text()).values():
    if re.fullmatch(r'/models/vendor/[a-z0-9-]+\.glb',row['file']): STATIC.add(row['file'])


def release_id(raw):
    return raw[:12].lower() if raw and re.fullmatch(r'[a-fA-F0-9]{12,64}',raw) else None


def declared_body_size(headers):
    lengths=headers.get_all('Content-Length',[])
    # The edge only accepts already framed, fixed-length bodies. Don't
    # reinterpret duplicate lengths or dechunk content on behalf of the origin.
    if headers.get_all('Transfer-Encoding',[]) or len(lengths)>1:
        raise ValueError('Unsupported request framing')
    if not lengths:
        return None
    raw=lengths[0]
    if not re.fullmatch(r'[0-9]+',raw):
        raise ValueError('Invalid request length')
    if len(raw)>10 or (size:=int(raw))>MAX_REQUEST_BODY:
        raise OverflowError('Request body too large')
    return size


class Gateway(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'

    def end_headers(self):
        self.send_header('X-Content-Type-Options','nosniff')
        frame_policy = 'SAMEORIGIN' if urlsplit(getattr(self,'path','')).path=='/mcp/app' else 'DENY'
        self.send_header('X-Frame-Options',frame_policy)
        self.send_header('Referrer-Policy','same-origin')
        super().end_headers()

    def log_message(self, fmt, *values):
        # Polling is frequent. No request body, identity or credentials in logs.
        if getattr(self,'path','').split('?',1)[0]!='/api/telemetry': super().log_message(fmt,*values)

    def payload(self,status,data,content='application/json',headers=()):
        self.send_response(status)
        self.send_header('Content-Type',content)
        self.send_header('Content-Length',str(len(data)))
        for name,value in headers: self.send_header(name,value)
        self.end_headers()
        if self.command!='HEAD': self.wfile.write(data)

    def error(self,status,message):
        # Early exits can leave the request body unread. This connection must
        # not be reused for another request.
        self.close_connection=True
        self.payload(status,json.dumps({'success':False,'error':message}).encode(),
                     headers=[('Cache-Control','no-store'),('Connection','close')])

    def handle_expect_100(self):
        self.error(417,'Request expectations are not supported')
        return False

    def handle_route(self):
        try:
            target=urlsplit(self.path); path=target.path
        except ValueError:
            return self.error(400,'Invalid request target')
        if target.netloc or target.scheme or len(self.path)>400:
            return self.error(400,'Invalid request target')
        if self.headers.get_all('Expect',[]):
            return self.error(417,'Request expectations are not supported')
        try:
            size=declared_body_size(self.headers)
        except (ValueError,OverflowError) as error:
            return self.error(413 if isinstance(error,OverflowError) else 400,str(error))
        if self.command!='POST' and size:
            return self.error(400,'Request body is not allowed on this method')
        if path=='/healthz' and self.command in ('GET','HEAD'):
            health={'ok':True,'service':'battlefront-edge'}
            release=getattr(self.server,'release',None)
            if release:
                health['release']=release
            return self.payload(200,json.dumps(health).encode(),headers=[('Cache-Control','no-store')])
        if self.command in ('GET','HEAD') and path in STATIC:
            relative='index.html' if path=='/' else path[1:]
            item=WEB/relative
            if not item.is_file(): return self.error(404,'Not found')
            # Send immutable-ish heavy assets without buffering them in memory.
            media=mimetypes.guess_type(item.name)[0] or ('model/gltf-binary' if item.suffix=='.glb' else 'application/octet-stream')
            self.send_response(200)
            self.send_header('Content-Type',media)
            self.send_header('Content-Length',str(item.stat().st_size))
            cache='no-cache' if item.suffix in ('.html','.js','.json','.css') else 'public, max-age=86400'
            self.send_header('Cache-Control',cache)
            self.end_headers()
            if self.command!='HEAD':
                with item.open('rb') as source:
                    while chunk:=source.read(131072): self.wfile.write(chunk)
            return
        get=self.command=='GET' and path in READ
        post=self.command=='POST' and path in WRITE
        if not get and not post: return self.error(404,'Not found')
        if not self.server.upstream: return self.error(503,'The live Battlefront origin is not configured')
        headers={'Accept':'application/json','X-Forwarded-Proto':'https'}
        origin,cookie,csrf=(self.headers.get(k) for k in ('Origin','Cookie','X-BF-CSRF'))
        if cookie and len(cookie)<4096: headers['Cookie']=cookie
        if csrf and len(csrf)<256: headers['X-BF-CSRF']=csrf
        body=None
        if post:
            if path!='/mcp' and (origin!=self.server.public_origin or self.headers.get('Sec-Fetch-Site') not in (None,'same-origin')):
                return self.error(403,'Same-origin request required')
            if size is None: return self.error(411,'Request length is required')
            if self.headers.get_content_type()!='application/json': return self.error(415,'JSON is required')
            headers.update({'Content-Type':'application/json','Origin':self.server.upstream_origin})
            body=self.rfile.read(size)
            if len(body)!=size: return self.error(400,'Request body ended early')
        try: link=self.server.pool.get_nowait()
        except queue.Empty: link=client.HTTPSConnection(self.server.upstream,timeout=4)
        try:
            link.request(self.command,self.path,body=body,headers=headers)
            response=link.getresponse(); data=response.read(2_000_001)
            if len(data)>2_000_000 or not 200<=response.status<=599 or 300<=response.status<400:
                raise ValueError('Unexpected upstream response')
            cookies=[(name,value) for name,value in response.getheaders() if name.lower()=='set-cookie' and value.startswith('bf_workspace=')]
            self.payload(response.status,data,response.getheader('Content-Type','application/json'),[('Cache-Control','no-store'),*cookies])
        except (OSError,client.HTTPException,ValueError):
            link.close()
            return self.error(502,'Live Battlefront origin is temporarily unavailable')
        else:
            try: self.server.pool.put_nowait(link)
            except queue.Full: link.close()

    do_GET=do_HEAD=do_POST=handle_route


def main():
    origin=os.environ.get('BF_ORIGIN_URL','').rstrip('/')
    upstream=urlsplit(origin)
    if origin and (upstream.scheme!='https' or not upstream.hostname or upstream.port or upstream.path or upstream.query
                   or upstream.fragment or upstream.username or upstream.password):
        raise ValueError('BF_ORIGIN_URL must be an HTTPS origin without a path')
    port=int(os.environ.get('PORT','10000'))
    with ThreadingHTTPServer(('0.0.0.0',port),Gateway) as server:
        server.upstream=upstream.hostname
        server.upstream_origin=origin
        server.public_origin=(os.environ.get('BF_PUBLIC_ORIGIN') or os.environ.get('RENDER_EXTERNAL_URL','')).rstrip('/')
        server.pool=queue.LifoQueue(16)
        server.release=release_id(os.environ.get('RENDER_GIT_COMMIT'))
        print(f'Battlefront Render gateway listening on {port}',flush=True)
        server.serve_forever()


if __name__=='__main__': main()
