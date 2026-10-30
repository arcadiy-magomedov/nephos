FROM python:3.12-slim
WORKDIR /app
COPY scripts/admin-requirements.txt .
RUN pip install --no-cache-dir -r admin-requirements.txt
COPY scripts/admin-console.py scripts/admin_telemetry.py ./
USER 65534:65534
CMD ["python", "/app/admin-console.py"]
