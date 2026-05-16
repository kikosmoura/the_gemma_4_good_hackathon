---
title: Hansen Guard Demo
emoji: 🩺
colorFrom: green
colorTo: yellow
sdk: docker
app_port: 7860
pinned: false
license: apache-2.0
---

# Hansen Guard Demo

### 🩺 Note to Judges

The core submission of this project is the **Hansen Guard Mobile App**, which is built using **Gemma 4 with LiteRT** for high-performance, on-device Edge AI. 

This web-based demo is provided for convenience and accessibility during the judging process. While the mobile app runs on LiteRT, this Space utilizes **Gemma 4 via llama.cpp** to serve the model over the web. We have also substituted the camera interface with a **curated gallery of real-world cases** to facilitate immediate testing of the model's analytical capabilities.

---

This Space serves a web interface that mirrors the Hansen Guard mobile workflow and runs community leprosy screening with a quantized Gemma 4 E2B IT GGUF model through `llama.cpp`.

Default runtime configuration:

- `MODEL_REPO=unsloth/gemma-4-E2B-it-GGUF`
- `MODEL_FILE=gemma-4-E2B-it-UD-Q4_K_XL.gguf`
- `MMPROJ_FILE=mmproj-F16.gguf`
- `LLAMA_CONTEXT=8192`
- `LLAMA_THREADS=2`
- `LLAMA_MAX_TOKENS=1400`

This demo is for screening support only. It does not diagnose leprosy and does not replace in-person clinical assessment.

Deployment notes are available in [DEPLOY.md](DEPLOY.md).
