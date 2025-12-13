
import unittest
import requests
import time
import threading
import os
import sys

# Add the directory containing test_server.py to the path
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from test_server import app

# Port to run the test server on
TEST_PORT = 8081
BASE_URL = f"http://127.0.0.1:{TEST_PORT}"

class TestServerTestCase(unittest.TestCase):
    
    @classmethod
    def setUpClass(cls):
        # Start the Flask app in a separate thread
        cls.server_thread = threading.Thread(target=app.run, kwargs={'host': '127.0.0.1', 'port': TEST_PORT})
        cls.server_thread.daemon = True
        cls.server_thread.start()
        
        # Give the server a moment to start
        time.sleep(1)

    def test_index(self):
        response = requests.get(f"{BASE_URL}/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.text, "Local Test Server Running")

    def test_fail(self):
        response = requests.get(f"{BASE_URL}/fail")
        self.assertEqual(response.status_code, 403)

    def test_echo_post(self):
        data = {'test': 'data'}
        response = requests.post(f"{BASE_URL}/echo_post", json=data)
        self.assertEqual(response.status_code, 200)
        json_resp = response.json()
        self.assertEqual(json_resp['json'], data)

    def test_echo_get(self):
        response = requests.get(f"{BASE_URL}/echo_get?json=true&param=val", headers={'X-Header': 'val'})
        self.assertEqual(response.status_code, 200)
        json_resp = response.json()
        self.assertEqual(json_resp['args']['param'], 'val')
        self.assertEqual(json_resp['headers']['X-Header'], 'val')

    def test_redirect(self):
        # Using allow_redirects=False to verify the 302 first, or True to follow
        response = requests.get(f"{BASE_URL}/redirect", allow_redirects=True)
        self.assertEqual(response.status_code, 200)
        # Should end up at echo_get?redirected=true. 
        # But echo_get only returns json if json=true.
        # The redirect URL is '/echo_get?redirected=true'.
        # So we expect the string representation.
        self.assertIn("'redirected': 'true'", response.text)

    def test_upload_file(self):
        files = {'file': ('test.txt', 'content')}
        response = requests.post(f"{BASE_URL}/upload_file", files=files)
        self.assertEqual(response.status_code, 200)

    def test_httpbin_get(self):
        response = requests.get(f"{BASE_URL}/get?p=1")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['args']['p'], '1')

    def test_httpbin_cookies(self):
        cookies = {'c1': 'v1'}
        response = requests.get(f"{BASE_URL}/cookies", cookies=cookies)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['cookies']['c1'], 'v1')

    def test_file_delay_5MB(self):
        start_time = time.time()
        # Not downloading content to avoid long wait/memory, just checking headers if possible? 
        # But to trigger delay (which is before sending file), we need to request it.
        # Requests.get downloads body by default. Stream=True might download headers first?
        # The sleep happens before send_from_directory, so TTFB will be delayed.
        try:
             requests.get(f"{BASE_URL}/files/5MB-test.ZIP", timeout=5) 
        except requests.exceptions.ReadTimeout:
             # If it times out (and we set timeout < delay), that confirms delay... 
             # wait, delay is 1s. Timeout 5 should pass.
             pass
        
        duration = time.time() - start_time
        # Duration should be at least 1s
        self.assertGreaterEqual(duration, 1.0)
    
    def test_file_delay_57MB(self):
        # This has a 10s delay.
        start_time = time.time()
        # requests timeout applies to inter-chunk gaps, so it won't timeout if we send data regularly.
        # We should just measure the total time.
        requests.get(f"{BASE_URL}/files/57MB-test.ZIP")
        
        duration = time.time() - start_time
        # Duration should be at least 8s (allowing for some variance/overhead)
        self.assertGreaterEqual(duration, 8.0)

if __name__ == '__main__':
    unittest.main()
