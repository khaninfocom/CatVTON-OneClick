#!/usr/bin/env bash
set -Eeuo pipefail

# CatVTON + LayerStyle Advance One-Click Installer
# Tested target: Linux + NVIDIA GPU + Python 3.11 + existing ComfyUI
# Known-good CatVTON compatibility pins from manual setup:
# numpy 1.26.4, Pillow 9.5.0, diffusers 0.30.3,
# opencv-contrib-python 4.10.0.84, scikit-image 0.22.0, timm 1.0.19

log()  { printf "\n\033[1;36m[CatVTON-OneClick]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# -----------------------------
# 1. Detect ComfyUI
# -----------------------------
detect_comfyui() {
  local candidates=(
    "${COMFYUI_DIR:-}"
    "/opt/ComfyUI"
    "/workspace/ComfyUI"
    "$HOME/ComfyUI"
    "/root/ComfyUI"
  )

  for d in "${candidates[@]}"; do
    [[ -n "$d" && -f "$d/main.py" ]] && { COMFYUI_DIR="$d"; return 0; }
  done

  return 1
}

if ! detect_comfyui; then
  die "ComfyUI not found. Set COMFYUI_DIR=/path/to/ComfyUI and run again."
fi

PYTHON_BIN="${PYTHON_BIN:-python}"
PIP_BIN="${PIP_BIN:-$PYTHON_BIN -m pip}"

log "Using ComfyUI: $COMFYUI_DIR"
log "Using Python: $($PYTHON_BIN --version 2>&1)"

# -----------------------------
# 2. Basic checks
# -----------------------------
command -v git >/dev/null 2>&1 || die "git is missing."
command -v wget >/dev/null 2>&1 || warn "System wget missing; Python wget package will still be installed."
command -v hf >/dev/null 2>&1 || die "'hf' CLI is missing. Install huggingface_hub CLI first."

if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU detected:"
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
else
  warn "nvidia-smi not found. Installation can continue, but GPU runtime is not verified."
fi

cd "$COMFYUI_DIR"

# -----------------------------
# 3. Clone / update custom nodes
# -----------------------------
CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
mkdir -p "$CUSTOM_NODES"

clone_or_update() {
  local url="$1"
  local dest="$2"

  if [[ -d "$dest/.git" ]]; then
    log "Updating $(basename "$dest")"
    git -C "$dest" pull --ff-only || warn "Could not update $(basename "$dest"); keeping existing copy."
  elif [[ -d "$dest" ]]; then
    warn "$dest exists but is not a git repo; keeping existing directory."
  else
    log "Cloning $(basename "$dest")"
    git clone "$url" "$dest"
  fi
}

clone_or_update \
  "https://github.com/chflame163/ComfyUI_CatVTON_Wrapper.git" \
  "$CUSTOM_NODES/ComfyUI_CatVTON_Wrapper"

clone_or_update \
  "https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git" \
  "$CUSTOM_NODES/ComfyUI_LayerStyle_Advance"

# -----------------------------
# 4. Install Python dependencies
# -----------------------------
log "Installing bulk dependencies..."

$PIP_BIN install \
  "timm==1.0.19" \
  pymatting \
  scikit-learn \
  matplotlib \
  loguru \
  "colour-science==0.4.6" \
  addict \
  omegaconf \
  iopath \
  mediapipe \
  bitsandbytes \
  peft \
  hydra-core \
  qrcode \
  "psd-tools<1.12" \
  typer-config \
  rich \
  google-generativeai \
  google-genai \
  ultralytics \
  transparent-background \
  accelerate \
  yapf \
  pyzbar \
  zhipuai \
  openai \
  blend-modes \
  wget \
  onnxruntime \
  "git+https://github.com/facebookresearch/segment-anything.git"

log "Restoring CatVTON-safe pinned versions..."

$PIP_BIN install --force-reinstall \
  "numpy==1.26.4" \
  "pillow==9.5.0" \
  "importlib-metadata"

$PIP_BIN install --force-reinstall --no-deps \
  "diffusers==0.30.3" \
  "opencv-contrib-python==4.10.0.84" \
  "scikit-image==0.22.0"

# -----------------------------
# 5. Download CatVTON models
# -----------------------------
CATVTON_MODEL_DIR="$COMFYUI_DIR/models/CatVTON"

if [[ -d "$CATVTON_MODEL_DIR" ]] && [[ "$(du -sb "$CATVTON_MODEL_DIR" 2>/dev/null | awk '{print $1}')" -gt 3000000000 ]]; then
  ok "CatVTON models already present; skipping 3.44 GB download."
else
  log "Downloading CatVTON models (~3.44 GB)..."
  mkdir -p "$CATVTON_MODEL_DIR"
  hf download EmmanuelMr/ComfyUI_CatVTON_Wrapper \
    --local-dir "$CATVTON_MODEL_DIR"
fi

# -----------------------------
# 6. Download Human Parts ONNX
# -----------------------------
HUMAN_PARTS_DIR="$COMFYUI_DIR/models/onnx/human-parts"
HUMAN_ONNX="$HUMAN_PARTS_DIR/deeplabv3p-resnet50-human.onnx"

mkdir -p "$HUMAN_PARTS_DIR"

if [[ -f "$HUMAN_ONNX" ]] && [[ "$(stat -c%s "$HUMAN_ONNX" 2>/dev/null || echo 0)" -ge 47000000 ]]; then
  ok "Human Parts ONNX already present; skipping download."
else
  log "Downloading Human Parts ONNX (~45 MB)..."
  wget -O "$HUMAN_ONNX" \
    "https://huggingface.co/chflame163/ComfyUI_LayerStyle/resolve/main/ComfyUI/models/onnx/human-parts/deeplabv3p-resnet50-human.onnx?download=true"
fi

# -----------------------------
# 7. Validate critical versions/imports
# -----------------------------
log "Validating base environment..."

$PYTHON_BIN - <<'PY'
import numpy, PIL, diffusers, cv2, skimage, timm, onnxruntime, blend_modes, wget, segment_anything
print("numpy:", numpy.__version__)
print("Pillow:", PIL.__version__)
print("diffusers:", diffusers.__version__)
print("cv2:", cv2.__version__)
print("skimage:", skimage.__version__)
print("timm:", timm.__version__)
print("onnxruntime:", onnxruntime.__version__)
print("BASE IMPORTS OK")
PY

log "Validating LayerStyle Advance..."
$PYTHON_BIN - <<PY
import sys
sys.path.insert(0, "$CUSTOM_NODES")
import ComfyUI_LayerStyle_Advance
print("LAYERSTYLE IMPORT OK")
PY

log "Validating CatVTON Wrapper..."
$PYTHON_BIN - <<PY
import sys
sys.path.insert(0, "$CUSTOM_NODES")
import ComfyUI_CatVTON_Wrapper
print("CATVTON WRAPPER IMPORT OK")
PY

# Direct diffusers classes used by CatVTON
log "Validating CatVTON diffusers classes..."
$PYTHON_BIN - <<'PY'
from diffusers import AutoencoderKL, UNet2DConditionModel, DDIMScheduler
print("CATVTON DIFFUSERS IMPORT OK")
PY

# Check required model files/directories
[[ -d "$CATVTON_MODEL_DIR/stable-diffusion-inpainting/unet" ]] || die "CatVTON UNet folder missing."
[[ -d "$CATVTON_MODEL_DIR/stable-diffusion-inpainting/scheduler" ]] || die "CatVTON scheduler folder missing."
[[ -d "$CATVTON_MODEL_DIR/sd-vae-ft-mse" ]] || die "CatVTON VAE folder missing."
[[ -f "$HUMAN_ONNX" ]] || die "Human Parts ONNX file missing."

ok "All installation checks passed."

# -----------------------------
# 8. Optional ComfyUI launch
# -----------------------------
cat <<EOF

============================================================
 CatVTON-OneClick setup completed successfully
============================================================

ComfyUI:
  $COMFYUI_DIR

CatVTON models:
  $CATVTON_MODEL_DIR

Human Parts model:
  $HUMAN_ONNX

To start ComfyUI on GridShare / remote GPU:

  cd "$COMFYUI_DIR"
  python main.py --listen 0.0.0.0 --enable-cors-header "*"

For a normal local machine you can usually use:

  cd "$COMFYUI_DIR"
  python main.py --listen 0.0.0.0

IMPORTANT:
- CUDA/xformers "cu130 optimized operations" warnings can be non-blocking.
- This script intentionally restores numpy/Pillow/diffusers after bulk
  dependency installation because LayerStyle dependencies may upgrade them.
- Model files are skipped when already present and sufficiently large.
============================================================

EOF

if [[ "${START_COMFYUI:-0}" == "1" ]]; then
  log "START_COMFYUI=1 detected; starting ComfyUI..."
  exec "$PYTHON_BIN" main.py --listen 0.0.0.0 --enable-cors-header "*"
fi
