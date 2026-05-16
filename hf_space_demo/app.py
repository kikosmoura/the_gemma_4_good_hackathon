from __future__ import annotations

import asyncio
import base64
import json
import mimetypes
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field


APP_DIR = Path(__file__).resolve().parent
STATIC_DIR = APP_DIR / "static"
ASSET_DIR = APP_DIR / "assets" / "cases"

MODEL_REPO = os.getenv("MODEL_REPO", "unsloth/gemma-4-E2B-it-GGUF")
MODEL_FILE = os.getenv("MODEL_FILE", "gemma-4-E2B-it-UD-Q4_K_XL.gguf")
MMPROJ_FILE = os.getenv("MMPROJ_FILE", "mmproj-F16.gguf")
MODEL_DIR = Path(os.getenv("MODEL_DIR", str(APP_DIR / "models")))
MODEL_PATH = Path(os.getenv("MODEL_PATH", str(MODEL_DIR / MODEL_FILE)))
MMPROJ_PATH = Path(os.getenv("MMPROJ_PATH", str(MODEL_DIR / MMPROJ_FILE)))

LLAMA_HOST = os.getenv("LLAMA_HOST", "127.0.0.1")
LLAMA_PORT = int(os.getenv("LLAMA_PORT", "8081"))
LLAMA_CONTEXT = os.getenv("LLAMA_CONTEXT", "8192")
LLAMA_THREADS = os.getenv("LLAMA_THREADS", "2")
LLAMA_MAX_TOKENS = int(os.getenv("LLAMA_MAX_TOKENS", "1400"))
LLAMA_TIMEOUT_SECONDS = float(os.getenv("LLAMA_TIMEOUT_SECONDS", "360"))
APP_PORT = int(os.getenv("PORT", os.getenv("APP_PORT", "7860")))
DISABLE_MODEL_SERVER = os.getenv("DISABLE_MODEL_SERVER", "0") == "1"

LLAMA_BASE_URL = f"http://{LLAMA_HOST}:{LLAMA_PORT}"
LLAMA_CHAT_URL = f"{LLAMA_BASE_URL}/v1/chat/completions"

_model_process: subprocess.Popen[str] | None = None
_model_started_at: float | None = None
_model_start_error: str | None = None


CASE_SUMMARIES = {
    "hanseniase_01.jpeg": "well-defined skin patch in an exposed area",
    "hanseniase_02.jpeg": "broad hypopigmented area with visible borders",
    "hanseniase_03.jpeg": "multiple lesions with skin tone variation",
    "hanseniase_04.jpeg": "reference image for screening demonstration",
    "hanseniase_05.jpeg": "reference image for screening demonstration",
    "hanseniase_06.jpeg": "reference image for screening demonstration",
    "hanseniase_07.jpeg": "reference image for screening demonstration",
    "hanseniase_08.jpeg": "reference image for screening demonstration",
    "hanseniase_09.jpeg": "reference image for screening demonstration",
    "hanseniase_10.png": "reference image for screening demonstration",
    "hanseniase_11.png": "reference image for screening demonstration",
    "hanseniase_12.png": "reference image for screening demonstration",
    "hanseniase_13.png": "reference image for screening demonstration",
}


class AnalyzeRequest(BaseModel):
    case_id: str = Field(default="hanseniase_01.jpeg")
    language: str = Field(default="en")
    patient_name: str = Field(default="Demo patient")
    patient_age: int = Field(default=42, ge=0, le=120)
    patient_sex: str = Field(default="other")
    has_numbness: bool = False
    changed_color: bool = True
    has_contact_with_confirmed_case: bool = False
    has_nerve_pain_or_shock: bool = False
    has_muscle_weakness: bool = False
    has_dryness_or_hair_loss: bool = False
    has_multiple_lesions: bool = False
    has_wound_or_burn_without_pain: bool = False
    duration: str = Field(default="3 to 12 months")
    notes: str = Field(default="", max_length=800)


class ModelStatus(BaseModel):
    status: str
    model_repo: str
    model_file: str
    mmproj_file: str
    llama_base_url: str
    detail: str | None = None
    uptime_seconds: int | None = None


app = FastAPI(title="Hansen Guard Gemma 4 Demo")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
app.mount("/assets/cases", StaticFiles(directory=ASSET_DIR), name="cases")


@app.on_event("startup")
async def on_startup() -> None:
    start_model_server()


@app.on_event("shutdown")
async def on_shutdown() -> None:
    stop_model_server()


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/cases")
async def list_cases() -> dict[str, Any]:
    files = sorted(
        path.name
        for path in ASSET_DIR.iterdir()
        if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}
    )
    cases = []
    for index, filename in enumerate(files, start=1):
        cases.append(
            {
                "id": filename,
                "title": f"Case {index:02d}",
                "region": "Local image",
                "visual_summary": CASE_SUMMARIES.get(
                    filename,
                    "reference image for screening demonstration",
                ),
                "image_url": f"/assets/cases/{filename}",
            }
        )
    return {"cases": cases}


@app.get("/api/status", response_model=ModelStatus)
async def status() -> ModelStatus:
    return await current_model_status()


@app.get("/health")
async def health() -> dict[str, str]:
    model_status = await current_model_status()
    return {"app": "ok", "model": model_status.status}


@app.post("/api/analyze")
async def analyze(request: AnalyzeRequest) -> dict[str, Any]:
    case_file = safe_case_file(request.case_id)
    model_status = await current_model_status()
    if model_status.status != "ready":
        raise HTTPException(
            status_code=503,
            detail=(
                "Gemma 4 is not ready for inference yet. "
                f"Current status: {model_status.status}."
            ),
        )

    image_b64 = base64.b64encode(case_file.read_bytes()).decode("ascii")
    mime_type = mimetypes.guess_type(case_file.name)[0] or "image/jpeg"
    language = "en"
    prompt = build_prompt(request, case_file.name, language)

    payload = {
        "model": f"{MODEL_REPO}:{MODEL_FILE}",
        "messages": [
            {"role": "system", "content": system_prompt(language)},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{mime_type};base64,{image_b64}"},
                    },
                ],
            },
        ],
        "temperature": 0.2,
        "top_p": 0.9,
        "max_tokens": LLAMA_MAX_TOKENS,
        "response_format": {"type": "json_object"},
        "stream": False,
    }

    try:
        async with httpx.AsyncClient(timeout=LLAMA_TIMEOUT_SECONDS) as client:
            response = await client.post(LLAMA_CHAT_URL, json=payload)
            if response.status_code == 400:
                fallback_payload = {key: value for key, value in payload.items() if key != "response_format"}
                response = await client.post(LLAMA_CHAT_URL, json=fallback_payload)
            response.raise_for_status()
            model_payload = response.json()
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Failed to call the local Gemma 4 server: {exc}",
        ) from exc

    content = extract_model_content(model_payload)
    parsed = parse_model_json(content, language)
    calibrated = apply_clinical_guardrails(parsed, request, language)
    calibrated["model"] = {
        "repo": MODEL_REPO,
        "file": MODEL_FILE,
        "mmproj": MMPROJ_FILE,
        "runtime": "llama.cpp",
        "response_was_json": parsed.get("_response_was_json", True),
    }
    calibrated.pop("_response_was_json", None)
    return calibrated


def start_model_server() -> None:
    global _model_process, _model_started_at, _model_start_error

    if DISABLE_MODEL_SERVER:
        _model_start_error = "Model server disabled by DISABLE_MODEL_SERVER=1."
        return

    if _model_process and _model_process.poll() is None:
        return

    if not MODEL_PATH.exists():
        _model_start_error = f"Model file not found at {MODEL_PATH}."
        return
    if not MMPROJ_PATH.exists():
        _model_start_error = f"mmproj file not found at {MMPROJ_PATH}."
        return

    executable = find_llama_server()
    if executable is None:
        _model_start_error = "Could not find llama-server or llama-cli in the Docker image."
        return

    if Path(executable).name == "llama-cli":
        command = [
            executable,
            "--server",
            "-m",
            str(MODEL_PATH),
            "--mmproj",
            str(MMPROJ_PATH),
            "--host",
            LLAMA_HOST,
            "--port",
            str(LLAMA_PORT),
            "-c",
            LLAMA_CONTEXT,
            "-t",
            LLAMA_THREADS,
            "-n",
            str(LLAMA_MAX_TOKENS),
        ]
    else:
        command = [
            executable,
            "-m",
            str(MODEL_PATH),
            "--mmproj",
            str(MMPROJ_PATH),
            "--host",
            LLAMA_HOST,
            "--port",
            str(LLAMA_PORT),
            "-c",
            LLAMA_CONTEXT,
            "-t",
            LLAMA_THREADS,
            "-n",
            str(LLAMA_MAX_TOKENS),
        ]

    print("Starting Gemma 4 runtime:", " ".join(command), flush=True)
    _model_process = subprocess.Popen(command, text=True)
    _model_started_at = time.time()
    _model_start_error = None


def stop_model_server() -> None:
    global _model_process

    if _model_process is None or _model_process.poll() is not None:
        return

    _model_process.send_signal(signal.SIGTERM)
    try:
        _model_process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        _model_process.kill()
        _model_process.wait(timeout=10)


def find_llama_server() -> str | None:
    env_bin = os.getenv("LLAMA_SERVER_BIN")
    if env_bin:
        return env_bin

    candidates = [
        shutil.which("llama-server"),
        "/app/llama-server",
        "/usr/local/bin/llama-server",
        "/llama.cpp/build/bin/llama-server",
        shutil.which("llama-cli"),
        "/app/llama-cli",
        "/usr/local/bin/llama-cli",
        "/llama.cpp/build/bin/llama-cli",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    return None


async def current_model_status() -> ModelStatus:
    uptime = None
    if _model_started_at is not None:
        uptime = int(time.time() - _model_started_at)

    if _model_start_error:
        return ModelStatus(
            status="error",
            model_repo=MODEL_REPO,
            model_file=MODEL_FILE,
            mmproj_file=MMPROJ_FILE,
            llama_base_url=LLAMA_BASE_URL,
            detail=_model_start_error,
            uptime_seconds=uptime,
        )

    if _model_process is None:
        return ModelStatus(
            status="not_started",
            model_repo=MODEL_REPO,
            model_file=MODEL_FILE,
            mmproj_file=MMPROJ_FILE,
            llama_base_url=LLAMA_BASE_URL,
            detail="The model server has not been started yet.",
            uptime_seconds=uptime,
        )

    exit_code = _model_process.poll()
    if exit_code is not None:
        return ModelStatus(
            status="stopped",
            model_repo=MODEL_REPO,
            model_file=MODEL_FILE,
            mmproj_file=MMPROJ_FILE,
            llama_base_url=LLAMA_BASE_URL,
            detail=f"The llama.cpp process exited with code {exit_code}.",
            uptime_seconds=uptime,
        )

    async with httpx.AsyncClient(timeout=2.0) as client:
        for path in ("/health", "/v1/models"):
            try:
                response = await client.get(f"{LLAMA_BASE_URL}{path}")
                if response.status_code < 400:
                    return ModelStatus(
                        status="ready",
                        model_repo=MODEL_REPO,
                        model_file=MODEL_FILE,
                        mmproj_file=MMPROJ_FILE,
                        llama_base_url=LLAMA_BASE_URL,
                        detail="Gemma 4 is loaded and ready.",
                        uptime_seconds=uptime,
                    )
            except httpx.HTTPError:
                await asyncio.sleep(0.05)

    return ModelStatus(
        status="loading",
        model_repo=MODEL_REPO,
        model_file=MODEL_FILE,
        mmproj_file=MMPROJ_FILE,
        llama_base_url=LLAMA_BASE_URL,
        detail="llama.cpp has started; waiting for Gemma 4 to finish loading.",
        uptime_seconds=uptime,
    )


def safe_case_file(case_id: str) -> Path:
    filename = Path(case_id).name
    path = ASSET_DIR / filename
    if not path.exists() or path.suffix.lower() not in {".jpg", ".jpeg", ".png", ".webp"}:
        raise HTTPException(status_code=404, detail="Demonstration image not found.")
    return path


def system_prompt(language: str) -> str:
    return (
        "You support community leprosy screening. Do not diagnose or replace clinical evaluation. "
        "Always answer with valid compact JSON, no markdown. Every user-visible string value must be in English. "
        "Separate dermatologic visual risk from clinical-neural risk. Use insufficient_image only when no skin "
        "or lesion is visually assessable. If unsure, return a conservative structured result instead of prose."
    )


def build_prompt(request: AnalyzeRequest, image_name: str, language: str) -> str:
    summary = CASE_SUMMARIES.get(image_name, "reference image for screening demonstration")
    return f"""
Offline leprosy screening. Return only valid compact JSON.
Output language: English.

Patient:
- name: {request.patient_name or "Demo patient"}
- age: {request.patient_age}
- sex: {request.patient_sex}

Image:
- label: Demo image {image_name}
- source: curated local demonstration image
- summary: {summary}

Interview:
- numbness: {yes_no(request.has_numbness, language)}
- color change: {yes_no(request.changed_color, language)}
- confirmed contact: {yes_no(request.has_contact_with_confirmed_case, language)}
- nerve pain/tingling/electric shock: {yes_no(request.has_nerve_pain_or_shock, language)}
- muscle weakness: {yes_no(request.has_muscle_weakness, language)}
- dryness/hair loss: {yes_no(request.has_dryness_or_hair_loss, language)}
- more than one lesion/patch: {yes_no(request.has_multiple_lesions, language)}
- painless wound/burn: {yes_no(request.has_wound_or_burn_without_pain, language)}
- duration: {request.duration}
- notes: {request.notes.strip() or "no additional notes"}

Rules:
- Do not diagnose; indicate screening priority.
- image_quality must be exactly one of: "good", "limited", "insufficient".
- Low resolution or blur reduces confidence, but does not prevent scoring when skin or lesion is assessable.
- Use insufficient_image only when there is no assessable visual content.
- If any skin lesion, patch, or plaque is visible, visual_risk_score must be at least 30.
- If a well-defined patch, color change, border, or multiple lesions are visible, visual_risk_score must be at least 45.
- risk_increasing_factors must contain only factors that raise risk.
- confidence limitations and reassuring factors must be separated.
- Every string must be a complete sentence.
- Keep arrays short: at most 2 items in each array, and each item under 120 characters.
- Do not include markdown, comments, explanations, or text outside the JSON object.

Required JSON:
{{"image_quality_summary":[],"region_findings":[{{"region":"Region 1","image_quality":"good|limited|insufficient","findings":[]}}],"relevant_symptoms":[],"visual_risk_level":"low|moderate|high|insufficient_image","visual_risk_score":0,"clinical_neural_risk_level":"low|moderate|high","clinical_neural_risk_score":0,"risk_level":"low|moderate|high|insufficient_image","score":0,"risk_increasing_factors":[],"confidence_limiting_factors":[],"reassuring_factors":[],"referral_reason":"","next_action":"","reasoning":[]}}
""".strip()


def yes_no(value: bool, language: str) -> str:
    return "yes" if value else "no"


def extract_model_content(payload: dict[str, Any]) -> str:
    try:
        return str(payload["choices"][0]["message"]["content"]).strip()
    except (KeyError, IndexError, TypeError) as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Unexpected Gemma 4 response: {payload}",
        ) from exc


def parse_model_json(content: str, language: str) -> dict[str, Any]:
    cleaned = content.strip()
    if cleaned.startswith("```"):
        lines = cleaned.splitlines()
        if len(lines) >= 3:
            cleaned = "\n".join(lines[1:-1]).strip()

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start >= 0 and end > start:
        cleaned = cleaned[start : end + 1]

    try:
        data = json.loads(cleaned)
        if not isinstance(data, dict):
            raise ValueError("Root JSON is not an object.")
        data["_response_was_json"] = True
    except (json.JSONDecodeError, ValueError):
        data = fallback_from_unstructured_text(content, language)
        data["_response_was_json"] = False

    return normalize_result(data, language)


def fallback_from_unstructured_text(content: str, language: str) -> dict[str, Any]:
    return {
        "image_quality_summary": ["Gemma 4 returned a partial response in this attempt."],
        "region_findings": [
            {
                "region": "Assessed region",
                "image_quality": "limited",
                "findings": ["The visual response could not be structured safely from this run."],
            }
        ],
        "relevant_symptoms": [],
        "visual_risk_level": "moderate",
        "visual_risk_score": 45,
        "clinical_neural_risk_level": "low",
        "clinical_neural_risk_score": 0,
        "risk_level": "moderate",
        "score": 45,
        "risk_increasing_factors": [],
        "confidence_limiting_factors": ["The model response was incomplete and needed local structuring."],
        "reassuring_factors": [],
        "referral_reason": "Priority is provisional because Gemma 4 did not return complete valid JSON.",
        "next_action": "Repeat the analysis or refer for in-person evaluation if symptoms persist.",
        "reasoning": ["The raw model output was not shown because it was incomplete."],
    }


def normalize_result(data: dict[str, Any], language: str) -> dict[str, Any]:
    score = parse_score(data.get("score"), fallback=0)
    visual_score = parse_score(data.get("visual_risk_score"), fallback=score)
    clinical_score = parse_score(
        data.get("clinical_neural_risk_score", data.get("clinical_risk_score")),
        fallback=0,
    )

    normalized = {
        "image_quality_summary": string_list(data.get("image_quality_summary")),
        "region_findings": region_findings(data.get("region_findings"), language),
        "visual_findings": string_list(data.get("visual_findings")),
        "relevant_symptoms": string_list(data.get("relevant_symptoms")),
        "visual_risk_level": normalize_risk_level(data.get("visual_risk_level"), visual_score),
        "visual_risk_score": visual_score,
        "clinical_neural_risk_level": normalize_risk_level(
            data.get("clinical_neural_risk_level", data.get("clinical_risk_level")),
            clinical_score,
        ),
        "clinical_neural_risk_score": clinical_score,
        "risk_level": normalize_risk_level(data.get("risk_level", data.get("riskLevel")), score),
        "score": score,
        "risk_increasing_factors": string_list(
            data.get("risk_increasing_factors", data.get("risk_factors"))
        ),
        "confidence_limiting_factors": string_list(data.get("confidence_limiting_factors")),
        "reassuring_factors": string_list(data.get("reassuring_factors")),
        "referral_reason": clean_text(data.get("referral_reason")),
        "next_action": clean_text(data.get("next_action", data.get("recommended_action"))),
        "reasoning": string_list(data.get("reasoning")),
        "consistency_note": clean_text(data.get("consistency_note")),
        "score_adjusted": bool(data.get("score_adjusted", False)),
        "_response_was_json": data.get("_response_was_json", True),
    }

    if not normalized["visual_findings"]:
        normalized["visual_findings"] = [
            item
            for finding in normalized["region_findings"]
            for item in finding.get("findings", [])
        ][:4]

    apply_visual_guardrails(normalized)

    defaults = default_texts(language)
    if not normalized["reasoning"]:
        normalized["reasoning"] = [defaults["reasoning"]]
    if not normalized["referral_reason"]:
        normalized["referral_reason"] = defaults["referral_reason"]
    if not normalized["next_action"]:
        normalized["next_action"] = defaults["next_action"]

    return normalized


def apply_visual_guardrails(result: dict[str, Any]) -> None:
    visual_floor = estimate_visible_findings_floor(result)
    if visual_floor <= 0:
        return

    if result["visual_risk_score"] < visual_floor:
        result["visual_risk_score"] = visual_floor
        result["visual_risk_level"] = score_to_risk_level(visual_floor)

    if result["score"] < visual_floor:
        result["score"] = visual_floor
        result["risk_level"] = score_to_risk_level(visual_floor)

    if result["risk_level"] == "insufficient_image":
        result["risk_level"] = score_to_risk_level(result["score"])
    if result["visual_risk_level"] == "insufficient_image":
        result["visual_risk_level"] = score_to_risk_level(result["visual_risk_score"])

    result["risk_increasing_factors"] = dedupe(
        result["risk_increasing_factors"] + ["visible skin finding described in the image"]
    )


def estimate_visible_findings_floor(result: dict[str, Any]) -> int:
    findings = []
    findings.extend(result.get("visual_findings", []))
    for region in result.get("region_findings", []):
        findings.extend(region.get("findings", []))

    cleaned_findings = [
        clean_text(item)
        for item in findings
        if clean_text(item) and not is_unable_to_assess_finding(clean_text(item))
    ]
    if not cleaned_findings:
        return 0

    combined = " ".join(item.lower() for item in cleaned_findings)
    strong_terms = [
        "lesion",
        "lesions",
        "patch",
        "patches",
        "plaque",
        "plaques",
        "hypopigmented",
        "hyperpigmented",
        "erythema",
        "redness",
        "nodule",
        "ulcer",
        "wound",
        "skin patch",
        "skin lesion",
    ]
    pattern_terms = [
        "well-defined",
        "defined",
        "border",
        "borders",
        "color change",
        "color difference",
        "texture",
        "scaly",
        "dry",
        "raised",
        "diffuse",
        "multiple",
        "visible",
        "delimited",
        "exposed area",
    ]

    strong_hits = sum(1 for term in strong_terms if term in combined)
    pattern_hits = sum(1 for term in pattern_terms if term in combined)
    finding_count = len(cleaned_findings)

    if strong_hits >= 3 or (strong_hits >= 2 and pattern_hits >= 2):
        return 55
    if strong_hits >= 1 and pattern_hits >= 1:
        return 45
    if strong_hits >= 1 or (finding_count >= 2 and pattern_hits >= 2):
        return 30
    return 0


def is_unable_to_assess_finding(value: str) -> bool:
    text = value.lower()
    blocked_terms = [
        "cannot assess",
        "could not assess",
        "not assessable",
        "no assessable",
        "no visual finding",
        "no lesion",
        "no patch",
        "no skin",
        "insufficient image",
        "could not be structured",
        "partial response",
    ]
    return any(term in text for term in blocked_terms)


def apply_clinical_guardrails(
    result: dict[str, Any],
    request: AnalyzeRequest,
    language: str,
) -> dict[str, Any]:
    factors: list[str] = []
    points = 0

    def add(condition: bool, factor: str, value: int) -> None:
        nonlocal points
        if condition:
            points += value
            factors.append(factor)

    add(request.has_numbness, "reported numbness", 28)
    add(
        request.has_nerve_pain_or_shock,
        "nerve pain, tingling, or electric shock sensation",
        20,
    )
    add(request.has_muscle_weakness, "muscle weakness", 26)
    add(
        request.has_contact_with_confirmed_case,
        "contact with a confirmed case",
        16,
    )
    add(
        request.has_dryness_or_hair_loss,
        "dryness or hair loss",
        10,
    )
    add(request.has_multiple_lesions, "more than one lesion", 12)
    add(
        request.has_wound_or_burn_without_pain,
        "painless wound or burn",
        24,
    )
    add(request.changed_color, "skin color change", 8)

    duration = request.duration.lower()
    if "12" in duration or "more" in duration:
        points += 15
        factors.append("persistence longer than 12 months")
    elif "3" in duration:
        points += 8
        factors.append("persistence longer than 3 months")

    floor = 0
    if points >= 75:
        floor = 78
    elif points >= 55:
        floor = 62
    elif points >= 35:
        floor = 48
    elif points >= 22:
        floor = 35

    previous_score = int(result["score"])
    if floor > previous_score:
        result["score"] = floor
        result["risk_level"] = score_to_risk_level(floor)
        result["score_adjusted"] = True
        result["consistency_note"] = (
            "Score raised for clinical consistency based on the interview."
        )

    if floor > int(result["clinical_neural_risk_score"]):
        result["clinical_neural_risk_score"] = floor
        result["clinical_neural_risk_level"] = score_to_risk_level(floor)

    result["risk_increasing_factors"] = dedupe(
        result["risk_increasing_factors"] + factors
    )[:6]
    return result


def parse_score(value: Any, fallback: int) -> int:
    try:
        return max(0, min(100, int(round(float(value)))))
    except (TypeError, ValueError):
        return fallback


def normalize_risk_level(value: Any, score: int) -> str:
    text = str(value or "").strip().lower()
    if text in {"low", "baixo", "baixa"}:
        return "low"
    if text in {"moderate", "medium", "moderado", "moderada"}:
        return "moderate"
    if text in {"high", "alto", "alta"}:
        return "high"
    if text in {"insufficient", "insufficient_image", "imagem_insuficiente"}:
        return "insufficient_image"
    return score_to_risk_level(score)


def score_to_risk_level(score: int) -> str:
    if score >= 70:
        return "high"
    if score >= 45:
        return "moderate"
    return "low"


def string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    items = []
    for item in value:
        cleaned = clean_text(item)
        if cleaned and not looks_like_raw_json_fragment(cleaned):
            items.append(cleaned)
    return items


def clean_text(value: Any) -> str:
    return " ".join(str(value or "").replace("\n", " ").split()).strip()


def looks_like_raw_json_fragment(value: str) -> bool:
    stripped = value.strip()
    if not stripped:
        return False
    return (
        stripped.startswith("{")
        or stripped.startswith('["')
        or stripped.count("{") > 0
        or stripped.count('"') >= 4
        or '"image_quality_summary"' in stripped
        or '"region_findings"' in stripped
        or '"risk_level"' in stripped
    )


def region_findings(value: Any, language: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    output = []
    for item in value:
        if not isinstance(item, dict):
            continue
        findings = string_list(item.get("findings"))
        region = clean_text(item.get("region")) or (
            "Assessed region"
        )
        image_quality = clean_text(item.get("image_quality"))
        if findings or image_quality:
            output.append(
                {
                    "region": region,
                    "image_quality": normalize_image_quality(image_quality, language),
                    "findings": findings,
                }
            )
    return output[:4]


def normalize_image_quality(value: str, language: str) -> str:
    text = value.strip().lower()
    if text in {"boa", "good"}:
        return "good"
    if text in {"limitada", "limitado", "limited"}:
        return "limited"
    if text in {"insuficiente", "insufficient"}:
        return "insufficient"
    return "limited"


def dedupe(items: list[str]) -> list[str]:
    seen = set()
    output = []
    for item in items:
        key = item.strip().lower()
        if key and key not in seen:
            seen.add(key)
            output.append(item)
    return output


def default_texts(language: str) -> dict[str, str]:
    return {
        "reasoning": "Priority is based on visual findings, reported symptoms, and confidence limits.",
        "referral_reason": "Screening priority was defined by combining the image and interview.",
        "next_action": "Refer for in-person clinical evaluation if the lesion persists, numbness is present, or symptoms worsen.",
    }


if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=APP_PORT, log_level="info")
