FROM python:3.12-slim
WORKDIR /app
COPY scripts/admin-requirements.txt .
RUN pip install --no-cache-dir -r admin-requirements.txt
COPY scripts/admin_web.py scripts/admin_config.py scripts/admin_status.py scripts/admin-bootstrap.py scripts/admin_telemetry.py ./
COPY deploy/keycloak/nephos-realm.json /deploy/keycloak/nephos-realm.json
COPY scripts/admin-templates ./admin-templates
COPY scripts/admin-static ./admin-static
USER 65534:65534
CMD ["gunicorn", "--bind=0.0.0.0:8080", "--workers=2", "--threads=4", "--timeout=90", "--worker-tmp-dir=/tmp", "admin_web:app"]
