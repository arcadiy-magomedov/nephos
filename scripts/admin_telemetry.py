"""Bounded central telemetry without credentials, request bodies, or raw URLs."""

from functools import wraps
import logging
import time

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.metrics import Observation
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

resource = Resource.create({"service.name": "nephos-admin-console"})
traces = TracerProvider(resource=resource)
traces.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(timeout=1), max_queue_size=512, max_export_batch_size=128, schedule_delay_millis=1000
    )
)
trace.set_tracer_provider(traces)
logs = LoggerProvider(resource=resource)
logs.add_log_record_processor(
    BatchLogRecordProcessor(
        OTLPLogExporter(timeout=1), max_queue_size=512, max_export_batch_size=128, schedule_delay_millis=1000
    )
)
logger = logging.getLogger("nephos.admin")
logger.setLevel(logging.INFO)
logger.addHandler(LoggingHandler(logger_provider=logs))
logger.addHandler(logging.StreamHandler())
metrics.set_meter_provider(
    MeterProvider(
        resource=resource,
        metric_readers=[
            PeriodicExportingMetricReader(
                OTLPMetricExporter(timeout=1), export_interval_millis=5000, export_timeout_millis=2000
            )
        ],
    )
)
meter = metrics.get_meter("Nephos.Administration")
requests = meter.create_counter("nephos.admin.requests")
meter.create_observable_gauge(
    "nephos.service.heartbeat",
    callbacks=[lambda _: [Observation(int(time.time()), {"service": "nephos-admin-console"})]],
)
tracer = trace.get_tracer("Nephos.Administration")
propagator = TraceContextTextMapPropagator()


def instrument(handler):
    @wraps(handler)
    def wrapped(self):
        context = propagator.extract(self.headers)
        with tracer.start_as_current_span(
            "private administration request",
            context=context,
            kind=trace.SpanKind.SERVER,
            record_exception=False,
            set_status_on_exception=False,
        ) as span:
            self.status_code = 500
            span.set_attribute("http.request.method", self.command)
            try:
                return handler(self)
            finally:
                span.set_attribute("http.response.status_code", self.status_code)
                requests.add(1, {"method": self.command, "status": self.status_code})
                logger.log(
                    logging.ERROR if self.status_code >= 500 else logging.INFO,
                    "Private administration request completed",
                    extra={"http_status": self.status_code},
                )

    return wrapped
