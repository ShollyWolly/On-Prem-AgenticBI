# Ours, not vendor/rag_api/Dockerfile. requirements.txt pins
# rapidocr-onnxruntime==1.4.4 (needs opencv-python) alongside
# opencv-python-headless==4.9.0.80 with nothing pinning opencv-python itself, so
# pip backtracks through releases looking for a compatible build -- it does not
# fail, it just appears to hang mid-install for several minutes. Pinning
# opencv-python to the same release fixes it with one candidate, no search.
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

# sentence_transformers depends on torch, unpinned, and the default PyPI wheel
# is the CUDA build -- 1.5+ GB of NVIDIA packages for a container with no GPU.
# Installing the CPU wheel first and constraining requirements.txt against it
# stops the CUDA build from being pulled in.
ARG TORCH_VERSION=2.6.0

COPY requirements.txt .
RUN pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        "torch==${TORCH_VERSION}+cpu" \
    && printf 'opencv-python==%s\ntorch==%s+cpu\n' "$OPENCV_VERSION" "$TORCH_VERSION" \
        > /tmp/constraints.txt \
    && pip install --no-cache-dir -r requirements.txt -c /tmp/constraints.txt \
    && python -c "import torch; assert not torch.version.cuda, f'CUDA torch leaked in: {torch.__version__}'; print('torch', torch.__version__, 'cpu-only OK')"

# `unstructured` fetches NLTK corpora on first use; baking them in keeps Foundry
# the only egress. ENV must be set BEFORE the download: nltk 3.10 added a path
# allowlist, and a directory not already in nltk.data.path is refused -- which
# then prompts interactively and hangs the build on EOFError (no stdin).
ENV NLTK_DATA=/app/nltk_data
RUN mkdir -p "$NLTK_DATA" \
    && python -c "import nltk, sys; pkgs=['punkt_tab','averaged_perceptron_tagger','averaged_perceptron_tagger_eng']; missing=[p for p in pkgs if not nltk.download(p, quiet=True)]; sys.exit('NLTK download failed: %s' % missing if missing else 0)" \
    && python -c "import nltk; [nltk.data.find(p) for p in ('tokenizers/punkt_tab','taggers/averaged_perceptron_tagger')]; print('nltk data present, no runtime egress needed')"

ENV SCARF_NO_ANALYTICS=true

COPY . .

CMD ["python", "main.py"]
