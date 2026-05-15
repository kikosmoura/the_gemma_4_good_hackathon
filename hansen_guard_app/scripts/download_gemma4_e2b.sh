#!/usr/bin/env bash
set -euo pipefail

DEST_DIR="${1:-$HOME/Downloads/gemma4-litert}"
MODEL_NAME="gemma-4-E2B-it.litertlm"
MODEL_URL="https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/${MODEL_NAME}?download=true"

# Download the exact LiteRT-LM artifact name expected by the Android helper
# script and by the app's default model path.

mkdir -p "$DEST_DIR"

echo "Baixando ${MODEL_NAME} para ${DEST_DIR}"
curl -L --fail -C - -o "$DEST_DIR/$MODEL_NAME" "$MODEL_URL"

echo
echo "Modelo pronto em: $DEST_DIR/$MODEL_NAME"