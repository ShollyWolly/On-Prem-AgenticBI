# This image builds the pinned RAG API with CPU-only machine learning dependencies.
FROM python:3.12 AS main

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        pandoc \
        netcat-openbsd \
        libgl1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

ARG OPENCV_VERSION=4.9.0.80

ARG TORCH_VERSION=2.6.0

COPY requirements.txt .
RUN pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        "torch==${TORCH_VERSION}" \
    && printf 'opencv-python==%s\ntorch==%s\n' "$OPENCV_VERSION" "$TORCH_VERSION" \
        > /tmp/constraints.txt \
    && pip install --no-cache-dir -r requirements.txt -c /tmp/constraints.txt \
    && python -c "import torch; assert not torch.version.cuda, f'CUDA torch leaked in: {torch.__version__}'; print('torch', torch.__version__, 'cpu-only OK')"

ENV NLTK_DATA=/app/nltk_data
RUN mkdir -p "$NLTK_DATA" \
    && python -c "import nltk, sys; pkgs=['punkt_tab','averaged_perceptron_tagger','averaged_perceptron_tagger_eng']; missing=[p for p in pkgs if not nltk.download(p, quiet=True)]; sys.exit('NLTK download failed: %s' % missing if missing else 0)" \
    && python -c "import nltk; [nltk.data.find(p) for p in ('tokenizers/punkt_tab','taggers/averaged_perceptron_tagger')]; print('nltk data present, no runtime egress needed')"

ENV SCARF_NO_ANALYTICS=true

COPY . .

CMD ["python", "main.py"]
