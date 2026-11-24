from email.message import Message
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from threading import Thread
import unittest
from cloud import render_gateway as gateway


class GatewayContract(unittest.TestCase):
    def test_dcs_mutation_never_proxied(self):
        for path in ('/api/kill_event','/api/telemetry/push','/api/demo/grant_merits','/api/upgrades/purchase'):
            self.assertNotIn(path,gateway.READ|gateway.WRITE)
        self.assertIn('/api/telemetry',gateway.READ)
        self.assertNotIn('/api/telemetry',gateway.WRITE)
        self.assertIn('/api/marketplace/buy',gateway.WRITE)

    def test_static_routes_are_explicit(self):
        mapping=json.loads((gateway.WEB/'models/vendor/manifest.json').read_text())
        for model in mapping.values():
            self.assertIn(model['file'],gateway.STATIC)
        self.assertNotIn('/server.py',gateway.STATIC)
        self.assertNotIn('/.env',gateway.STATIC)

    def test_request_framing_policy(self):
        cases=(
            ([],None),
            ([('Content-Length','16')],16),
            ([('Content-Length','0')],0),
            ([('Content-Length','2'),('Content-Length','2')],ValueError),
            ([('Content-Length','2, 2')],ValueError),
            ([('Transfer-Encoding','chunked')],ValueError),
            ([('Content-Length','16385')],OverflowError),
        )
        for fields,expected in cases:
            with self.subTest(fields=fields):
                headers=Message()
                for name,value in fields:
                    headers[name]=value
                if isinstance(expected,type):
                    with self.assertRaises(expected): gateway.declared_body_size(headers)
                else:
                    self.assertEqual(gateway.declared_body_size(headers),expected)

    def test_release_identifier_is_optional_and_hex_only(self):
        self.assertEqual(gateway.release_id('A123456789BCD'+'0'*27),'a123456789bc')
        for value in (None,'local-build','1234','not-a-commit-abcdef'):
            self.assertIsNone(gateway.release_id(value))


class GatewayHTTP(unittest.TestCase):
    def setUp(self):
        class SilentGateway(gateway.Gateway):
            def log_message(self,*_):
                pass
        self.server=ThreadingHTTPServer(('127.0.0.1',0),SilentGateway)
        self.server.upstream=None
        self.server.public_origin='https://workspace.invalid'
        self.server.release=gateway.release_id('0a1b2c3d4e5f'+'0'*28)
        self.thread=Thread(target=self.server.serve_forever,kwargs={'poll_interval':.01},daemon=True)
        self.thread.start()
        self.addCleanup(self.finish_server)
        self.connection=HTTPConnection(*self.server.server_address,timeout=3)
        self.addCleanup(self.connection.close)

    def finish_server(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def response(self,method,path,body=None,headers=None):
        self.connection.request(method,path,body=body,headers=headers or {})
        response=self.connection.getresponse()
        data=response.read()
        return response,json.loads(data) if data else None

    def assert_rejected_and_closed(self,response,status):
        self.assertEqual(response.status,status)
        self.assertEqual(response.getheader('Connection'),'close')
        self.assertTrue(response.will_close)

    def test_regular_denied_posts_are_closed_then_health_is_normal(self):
        headers={'Content-Type':'application/json'}
        for path in ('/api/kill_event','/api/telemetry/push','/api/upgrades/purchase'):
            with self.subTest(path=path):
                response,data=self.response('POST',path,'{}',headers)
                self.assert_rejected_and_closed(response,404)
                self.assertEqual(data,{'success':False,'error':'Not found'})
        response,data=self.response('GET','/healthz')
        self.assertEqual(response.status,200)
        self.assertEqual(response.getheader('Cache-Control'),'no-store')
        self.assertEqual(data,{'ok':True,'service':'battlefront-edge','release':'0a1b2c3d4e5f'})
        head,attached=self.response('HEAD','/healthz')
        self.assertEqual(head.status,200)
        self.assertIsNone(attached)

    def test_unavailable_origin_and_body_on_read_route_are_closed(self):
        response,_=self.response('POST','/api/workspace/login','{}',{'Content-Type':'application/json'})
        self.assert_rejected_and_closed(response,503)
        response,_=self.response('GET','/healthz','{}',{'Content-Type':'application/json'})
        self.assert_rejected_and_closed(response,400)
        self.server.release=None
        response,data=self.response('GET','/healthz')
        self.assertEqual(response.status,200)
        self.assertNotIn('release',data)


if __name__=='__main__': unittest.main()
