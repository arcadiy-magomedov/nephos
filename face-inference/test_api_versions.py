"""Transport compatibility is independent of model/pipeline versioning."""

import io
import os
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import Mock, patch


class ApiVersionTests(unittest.TestCase):
    def test_v1_and_legacy_routes_share_authentication_and_processing(self):
        for file, setting, header, route in (
            ("server.py", "INFERENCE_KEY", "X-Nephos-Inference-Key", "infer"),
            ("derivative_server.py", "DERIVATIVE_KEY", "X-Nephos-Service-Key", "render"),
        ):
            with patch.dict(os.environ, {setting: "k" * 32}), patch("http.server.ThreadingHTTPServer"):
                server = runpy.run_path(str(Path(__file__).with_name(file)))
            for path in ("/" + route, "/v1/" + route, "/v2/" + route):
                for authorized in (False, True):
                    with self.subTest(service=file, path=path, authorized=authorized):
                        handler = object.__new__(server["Handler"])
                        handler.connection = Mock()
                        handler.path = path
                        handler.headers = {"Content-Length": "4", header: "k" * 32 if authorized else "wrong"}
                        handler.rfile = io.BytesIO(b"body")
                        handler.reply = Mock()
                        result = subprocess.CompletedProcess([], 0, stdout=b'{"fixture":true}')
                        with patch("subprocess.run", return_value=result) as child:
                            handler.do_POST()
                            if authorized and not path.startswith("/v2/"):
                                self.assertEqual(b"body", child.call_args.kwargs["input"])
                                handler.reply.assert_called_once_with(200, result.stdout)
                            else:
                                child.assert_not_called()
                                handler.reply.assert_called_once_with(403, b"{}")
