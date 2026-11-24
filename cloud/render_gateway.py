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
READ = {'/api/state','/api/campaign','/api/upgrades','/api/telemetry'}
WRITE = {'/api/workspace/login','/api/workspace/logout','/api/player/set_callsign','/api/requisition',
         '/api/marketplace/list','/api/marketplace/buy','/api/marketplace/cancel','/api/armory/mount',
         '/api/operations/join','/api/operations/leave','/api/operations/propose',
         '/api/operations/command','/api/operations/launch'}
STATIC = {'/','/index.html','/sectors.json','/tacview.js','/caucasus_terrain.js','/airframes.js',
          '/dist/companion.js','/dist/tailwind.css','/terrain/caucasus-height.png','/terrain/caucasus-relief.jpg',
          '/vendor/three.min.js','/vendor/OrbitControls.js','/vendor/GLTFLoader.js',
          '/models/vendor/manifest.json','/models/vendor/credits.html','/models/vendor/flightgear-source.zip',
          '/models/vendor/su-35-license.txt'}
for row in json.loads((WEB/'models/vendor/manifest.json').read_text()).values():
    if re.fullmatch(r'/models/vendor/[a-z0-9-]+\.glb',row['file']): STATIC.add(row['file'])


class Gateway(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'

    def end_headers(self):
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('X-Frame-Options','DENY')
        self.send_header('Referrer-Policy','same-origin')
        super().end_headers()

    def log_message(self, fmt, *values):
        # Polling is frequent. No request body, identity or credentials in logs.
        if self.path.split('?',1)[0]!='/api/telemetry': super().log_message(fmt,*values)

    def payload(self,status,data,content='application/json',headers=()):
        self.send_response(status)
        self.send_header('Content-Type',content)
        self.send_header('Content-Length',str(len(data)))
        for name,value in headers: self.send_header(name,value)
        self.end_headers()
        if self.command!='HEAD': self.wfile.write(data)

    def error(self,status,message):
        self.payload(status,json.dumps({'success':False,'error':message}).encode(),headers=[('Cache-Control','no-store')])

    def handle_route(self):
        target=urlsplit(self.path); path=target.path
        if target.netloc or target.scheme or len(self.path)>400:
            return self.error(400,'Invalid request target')
        if path=='/healthz' and self.command in ('GET','HEAD'):
            return self.payload(200,b'{"ok":true,"service":"battlefront-edge"}')
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
            if origin!=self.server.public_origin or self.headers.get('Sec-Fetch-Site') not in (None,'same-origin'):
                return self.error(403,'Same-origin request required')
            try: size=int(self.headers.get('Content-Length','-1'))
            except ValueError: size=-1
            if not 0<=size<=16384 or self.headers.get('Transfer-Encoding'):
                return self.error(413,'Invalid request size')
            if self.headers.get_content_type()!='application/json': return self.error(415,'JSON is required')
            headers.update({'Content-Type':'application/json','Origin':self.server.upstream_origin})
            body=self.rfile.read(size)
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
        print(f'Battlefront Render gateway listening on {port}',flush=True)
        server.serve_forever()


if __name__=='__main__': main()
