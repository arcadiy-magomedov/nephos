FROM python:3.12.12-slim@sha256:f3fa41d74a768c2fce8016b98c191ae8c1bacd8f1152870a3f9f87d350920b7c AS codecs
WORKDIR /build
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    cmake g++ make pkg-config ca-certificates && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir setuptools==80.9.0 wheel==0.45.1
COPY face-inference/build_heif.py face-inference/heif-native.json ./
RUN python build_heif.py

FROM python:3.12.12-slim@sha256:f3fa41d74a768c2fce8016b98c191ae8c1bacd8f1152870a3f9f87d350920b7c
WORKDIR /app
COPY --from=codecs /build/native /opt/heif
COPY --from=codecs /build/wheels /wheels
ENV LD_LIBRARY_PATH=/opt/heif/lib
COPY face-inference/requirements.txt .
RUN pip install --no-cache-dir --no-deps /wheels/*.whl && \
    pip install --no-cache-dir --only-binary=:all: -r requirements.txt && rm -rf /wheels
COPY face-inference/ .
RUN python -c "import pillow_heif; i=pillow_heif.libheif_info(); print(i); \
    assert set(i['decoders']) == {'libde265'}; assert not i['HEIF']; \
    assert not (set(i['encoders']) - {'mask'})"
RUN python download_models.py
USER 65534:65534
ENV OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8090
CMD ["python", "server.py"]
