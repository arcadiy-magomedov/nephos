"""Service and telemetry state semantics never confuse missing observations with zero."""

import time
import unittest
from unittest.mock import Mock, patch

import admin_status
import requests


class AdminStatusTests(unittest.TestCase):
    def test_absent_optional_service_is_not_probed(self):
        with patch.object(admin_status.requests, "get") as get:
            status = admin_status.probe(("Faces", "optional", None))
        self.assertEqual(status["state"], "Not installed")
        get.assert_not_called()

    def test_service_ready_unready_timeout_unavailable(self):
        for response, state in (
            (Mock(status_code=200), "Ready"),
            (Mock(status_code=503), "Not ready"),
            (requests.Timeout(), "Timed out"),
            (requests.ConnectionError(), "Unavailable"),
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
            ("0", time.time(), "No data", 0),
            (None, time.time(), "No data", None),
            ("5", time.time() - 120, "Data is stale", None),
            ("NaN", time.time(), "Collection error", None),
        ):

            def get(_url, params, *, timestamp=timestamp, value=value, **_kwargs):
                observed = timestamp if "timestamp(" in params["query"] else value
                samples = [] if observed is None else [{"value": [time.time(), str(observed)]}]
                return Mock(json=Mock(return_value={"status": "success", "data": {"result": samples}}))

            with self.subTest(value=value, state=state), patch.object(admin_status.requests, "get", side_effect=get):
                metrics = admin_status.broker_metrics()
                self.assertTrue(all(metric["value"] == expected and metric["state"] == state for metric in metrics))

    def test_failed_collection_reports_error(self):
        with patch.object(admin_status.requests, "get", side_effect=requests.ConnectionError):
            self.assertTrue(all(item["state"] == "Collection error" for item in admin_status.broker_metrics()))

    def test_malformed_metric_samples_are_collection_errors_not_unhandled_exceptions(self):
        for samples in ([{}], [{"value": []}], [{"value": [1]}], [{"value": [1, None]}], [None], "invalid", None):
            payload = {"status": "success", "data": {"result": samples}}
            with (
                self.subTest(samples=samples),
                patch.object(admin_status.requests, "get", return_value=Mock(json=Mock(return_value=payload))),
                self.assertLogs(admin_status.logger, level="WARNING"),
            ):
                metrics = admin_status.broker_metrics()
            self.assertTrue(
                all(metric["state"] == "Collection error" and metric["value"] is None for metric in metrics)
            )

    def test_malformed_observation_time_is_reported_without_partial_values(self):
        valid = {"status": "success", "data": {"result": [{"value": [time.time(), "2"]}]}}
        invalid = {"status": "success", "data": {"result": [{"value": []}]}}

        def get(_url, params, **_kwargs):
            payload = invalid if "timestamp(" in params["query"] else valid
            return Mock(json=Mock(return_value=payload))

        with (
            patch.object(admin_status.requests, "get", side_effect=get),
            self.assertLogs(admin_status.logger, level="WARNING"),
        ):
            metrics = admin_status.broker_metrics()
        self.assertTrue(all(metric["state"] == "Collection error" and metric["value"] is None for metric in metrics))
