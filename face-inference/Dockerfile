FROM python:3.12.12-slim@sha256:f3fa41d74a768c2fce8016b98c191ae8c1bacd8f1152870a3f9f87d350920b7c
WORKDIR /app
COPY face-inference/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY face-inference/ .
RUN python download_models.py
USER 65534:65534
ENV OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8090
CMD ["python", "server.py"]
