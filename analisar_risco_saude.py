#!/usr/bin/env python3

import argparse
import base64
import json
import sys
from pathlib import Path
from urllib import error, request


DEFAULT_IMAGE = Path("images/imagem_comunidade.png")
DEFAULT_MODEL = "gemma4:e4b"
DEFAULT_OLLAMA_URL = "http://localhost:11434/api/chat"

PROMPT = """Voce e um analista de saude publica.
Analise a imagem enviada e identifique problemas que representem risco para a saude publica.

Responda apenas em JSON valido, sem markdown, com este formato exato:
{
  "pontos_risco": [
    {
      "item": "nome curto do risco",
      "descricao": "explicacao objetiva do risco observado na imagem",
      "gravidade": "baixa|media|alta"
    }
  ],
  "urgencia_intervencao": {
    "nota": 0,
    "justificativa": "motivo objetivo para a nota entre 0 e 10"
  }
}

Se nao houver evidencia visual suficiente para afirmar um risco com seguranca, deixe isso claro na descricao.
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analisa uma imagem com o Ollama e lista riscos de saude publica."
    )
    parser.add_argument(
        "--image",
        type=Path,
        default=DEFAULT_IMAGE,
        help=f"Caminho da imagem a ser analisada. Padrao: {DEFAULT_IMAGE}",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Modelo multimodal do Ollama. Padrao: {DEFAULT_MODEL}",
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_OLLAMA_URL,
        help=f"Endpoint da API do Ollama. Padrao: {DEFAULT_OLLAMA_URL}",
    )
    return parser.parse_args()


def encode_image(image_path: Path) -> str:
    if not image_path.is_file():
        raise FileNotFoundError(f"Imagem nao encontrada: {image_path}")

    return base64.b64encode(image_path.read_bytes()).decode("utf-8")


def build_payload(model: str, image_b64: str) -> bytes:
    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {
                "role": "user",
                "content": PROMPT,
                "images": [image_b64],
            }
        ],
    }
    return json.dumps(payload).encode("utf-8")


def call_ollama(url: str, payload: bytes) -> str:
    req = request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with request.urlopen(req) as response:
            body = response.read().decode("utf-8")
    except error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"Falha HTTP ao chamar o Ollama ({exc.code}): {details}"
        ) from exc
    except error.URLError as exc:
        raise RuntimeError(
            "Nao foi possivel conectar ao Ollama. Verifique se o servico esta ativo."
        ) from exc

    data = json.loads(body)
    return data.get("message", {}).get("content", "")


def extract_json(text: str) -> dict:
    cleaned = text.strip()

    if cleaned.startswith("```"):
        lines = cleaned.splitlines()
        if len(lines) >= 3:
            cleaned = "\n".join(lines[1:-1]).strip()

    try:
        return json.loads(cleaned)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            "O modelo respondeu, mas o conteudo nao veio em JSON valido.\n"
            f"Resposta recebida:\n{cleaned}"
        ) from exc


def print_result(result: dict) -> None:
    print("Riscos de saude publica identificados:")
    pontos_risco = result.get("pontos_risco", [])

    if not pontos_risco:
        print("- Nenhum ponto de risco foi listado pelo modelo.")
    else:
        for index, risco in enumerate(pontos_risco, start=1):
            item = risco.get("item", "Risco sem nome")
            descricao = risco.get("descricao", "Sem descricao")
            gravidade = risco.get("gravidade", "nao informada")
            print(f"{index}. {item} ({gravidade})")
            print(f"   {descricao}")

    urgencia = result.get("urgencia_intervencao", {})
    nota = urgencia.get("nota", "nao informada")
    justificativa = urgencia.get("justificativa", "Sem justificativa")

    print()
    print(f"Urgencia de intervencao: {nota}/10")
    print(justificativa)


def main() -> int:
    args = parse_args()

    try:
        image_b64 = encode_image(args.image)
        payload = build_payload(args.model, image_b64)
        response_text = call_ollama(args.url, payload)
        result = extract_json(response_text)
        print_result(result)
    except Exception as exc:
        print(f"Erro: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())