FROM ghcr.io/ggml-org/llama.cpp:full

WORKDIR /app

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /app/requirements.txt

ENV MODEL_REPO="unsloth/gemma-4-E2B-it-GGUF"
ENV MODEL_FILE="gemma-4-E2B-it-UD-Q4_K_XL.gguf"
ENV MMPROJ_FILE="mmproj-F16.gguf"
ENV MODEL_DIR="/app/models"

RUN python3 -c "import os; from huggingface_hub import hf_hub_download; repo=os.environ['MODEL_REPO']; dest=os.environ['MODEL_DIR']; hf_hub_download(repo_id=repo, filename=os.environ['MODEL_FILE'], local_dir=dest); hf_hub_download(repo_id=repo, filename=os.environ['MMPROJ_FILE'], local_dir=dest)"

COPY app.py /app/app.py
COPY static /app/static
COPY assets /app/assets

EXPOSE 7860

ENTRYPOINT []
CMD ["python3", "/app/app.py"]
