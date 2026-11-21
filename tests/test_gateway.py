import json
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


if __name__=='__main__': unittest.main()
