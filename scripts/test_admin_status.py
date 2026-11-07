"""Service and telemetry state semantics never confuse missing observations with zero."""

import time
import unittest
from unittest.mock import Mock, patch

import requests
import admin_status


class AdminStatusTests(unittest.TestCase):
    def test_absent_optional_service_is_not_probed(self):
        with patch.object(admin_status.requests, "get") as get:
            status = admin_status.probe(("Faces", "optional", None))
        self.assertEqual(status["state"], "Не установлен")
        get.assert_not_called()

    def test_service_ready_unready_timeout_unavailable(self):
        for response, state in (
            (Mock(status_code=200), "Готов"),
            (Mock(status_code=503), "Не готов"),
            (requests.Timeout(), "Время ожидания истекло"),
            (requests.ConnectionError(), "Недоступен"),
        ):
            with (
                self.subTest(state=state),
                patch.object(
                    admin_status.requests,
                    "get",
                    **({"side_effect": response} if isinstance(response, Exception) else {"return_value": response}),
                ) as get,
            ):
                self.assertEqual(
                    admin_status.probe(("Library", "ready", "http://library/health/ready"))["state"], state
                )
                self.assertFalse(get.call_args.kwargs["allow_redirects"])

    def test_zero_is_distinct_from_missing_stale_and_error(self):
        for value, timestamp, state, expected in (
            ("0", time.time(), "Нет данных", 0),
            (None, time.time(), "Нет данных", None),
            ("5", time.time() - 120, "Данные устарели", None),
            ("NaN", time.time(), "Ошибка сбора", None),
        ):

            def get(_url, params, **_kwargs):
                observed = timestamp if "timestamp(" in params["query"] else value
                samples = [] if observed is None else [{"value": [time.time(), str(observed)]}]
                return Mock(json=Mock(return_value={"status": "success", "data": {"result": samples}}))

            with self.subTest(value=value, state=state), patch.object(admin_status.requests, "get", side_effect=get):
                metrics = admin_status.broker_metrics()
                self.assertTrue(all(metric["value"] == expected and metric["state"] == state for metric in metrics))

    def test_failed_collection_reports_error(self):
        with patch.object(admin_status.requests, "get", side_effect=requests.ConnectionError):
            self.assertTrue(all(item["state"] == "Ошибка сбора" for item in admin_status.broker_metrics()))
