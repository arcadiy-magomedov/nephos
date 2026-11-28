"""Service exception locations without messages, credentials or request data."""

import re
import sys


def exception_locations(text):
    names = set(re.findall(r"\b([A-Za-z][\w.$]*(?:Exception|Error)):", text))
    names.update(re.findall(r"\bat (app\.nephos\.keycloak\.[\w.$]+\([\w.]+\.java:\d+\))", text))
    return names


def print_service_diagnostics(text):
    names = exception_locations(text)
    if names:
        print("Sanitized service exception locations: " + ", ".join(sorted(names)), file=sys.stderr)
