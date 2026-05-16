# Publishing To Hugging Face Spaces

## 1. Create the Space

1. Open <https://huggingface.co/spaces>.
2. Click **Create new Space**.
3. Choose a public name, for example `hansen-guard-gemma4-demo`.
4. Select **Docker** as the SDK.
5. Set visibility to **Public**.
6. Create the empty Space.

## 2. Push This Folder

From the root of this project:

```bash
cd hf_space_demo
git init
git branch -M main
git lfs install
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/huggingface/xet-core/refs/heads/main/git_xet/install.sh | sh
git xet install
git-xet track "assets/cases/*.jpeg" "assets/cases/*.png"
git remote remove origin 2>/dev/null || true
git remote add origin https://huggingface.co/spaces/YOUR_USER/hansen-guard-gemma4-demo
git add .
git commit -m "Add Hansen Guard Gemma 4 demo"
git push -u origin main
```

Replace `YOUR_USER/hansen-guard-gemma4-demo` with the real Space path.

If you cloned the Space inside this folder to copy files, do not add that clone as a nested repository. Copy the files into the Space repository root and keep `hansen-guard-gemma4-demo/` only in `.gitignore`.

Hugging Face may reject binary image pushes made with plain Git. Because this demo includes images in `assets/cases/`, install and enable Git Xet before the first push and track those image patterns with `git-xet track`.

If local commits already contain the images before Xet was enabled, the simplest fix is to recreate the local branch as one clean commit and then push with `--force-with-lease`. This avoids uploading old raw binary blobs in the branch history.

If `git push -u origin main` fails with `fetch first`, the remote Space probably already has Hugging Face's initial commit. This project includes the correct YAML block in `README.md`, so you can replace that initial commit safely:

```bash
git push -u origin main --force-with-lease
```

## 3. Wait For The Build

The Dockerfile downloads the Gemma 4 E2B IT GGUF model and the `mmproj` file during the build. The first build can take a while because the model files are several GB.

After the build completes, the Space can still spend a few minutes in **Starting** while `llama.cpp` loads the model. The demo screen shows the model status.

## 4. Hardware And Memory Tuning

The default quantization is `gemma-4-E2B-it-UD-Q4_K_XL.gguf`. If a free Space runs out of memory, use a smaller model file in the Dockerfile or Space variables:

```text
MODEL_FILE=gemma-4-E2B-it-Q3_K_M.gguf
LLAMA_CONTEXT=4096
LLAMA_THREADS=2
```

For better quality on paid hardware, use:

```text
MODEL_FILE=gemma-4-E2B-it-Q5_K_M.gguf
LLAMA_CONTEXT=8192
```

To adapt the Space to E4B:

```text
MODEL_REPO=unsloth/gemma-4-E4B-it-GGUF
MODEL_FILE=gemma-4-E4B-it-UD-Q5_K_XL.gguf
MMPROJ_FILE=mmproj-BF16.gguf
```

## 5. Kaggle Link

When the Space is **Running**, copy the public URL:

```text
https://huggingface.co/spaces/YOUR_USER/hansen-guard-gemma4-demo
```

In the Kaggle writeup, add this URL under **Attachments > Project Links**.

Add the technical note for judges: Clarify that the mobile app uses **LiteRT** for edge inference, while this demo uses **llama.cpp** for web accessibility, utilizing a curated case gallery instead of a live camera.
