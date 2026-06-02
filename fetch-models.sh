#!/usr/bin/env bash
#
# Fetch the Kokoro-82M TTS assets that KokoroSwift loads at runtime, into the (gitignored)
# Resources folder bundled with the app. These are the *exact* MLX-ready formats from
# prince-canuma/Kokoro-82M — the fp32 model and the per-voice safetensors style packs —
# so no conversion is needed. The 327 MB model is kept out of git; run this once after a
# fresh checkout (and Xcode differential-installs it, so it isn't re-copied every build).
#
# Usage:
#   ./fetch-models.sh            # model + all 54 voices
#   ./fetch-models.sh af_heart   # model + only the named voice(s)
set -euo pipefail

REPO="https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main"
DEST="$(cd "$(dirname "$0")" && pwd)/mc/Resources"
VOICES_DIR="$DEST/voices"
mkdir -p "$VOICES_DIR"

# Default voice set: all 54. The picker lists whatever is present; af_heart is the default.
ALL_VOICES=(
  af_alloy af_aoede af_bella af_heart af_jessica af_kore af_nicole af_nova af_river af_sarah af_sky
  am_adam am_echo am_eric am_fenrir am_liam am_michael am_onyx am_puck am_santa
  bf_alice bf_emma bf_isabella bf_lily bm_daniel bm_fable bm_george bm_lewis
  ef_dora em_alex em_santa ff_siwis hf_alpha hf_beta hm_omega hm_psi if_sara im_nicola
  jf_alpha jf_gongitsune jf_nezumi jf_tebukuro jm_kumo pf_dora pm_alex pm_santa
  zf_xiaobei zf_xiaoni zf_xiaoxiao zf_xiaoyi zm_yunjian zm_yunxi zm_yunxia zm_yunyang
)
VOICES=("$@")
[ ${#VOICES[@]} -eq 0 ] && VOICES=("${ALL_VOICES[@]}")

# -L follow redirects, -f fail on HTTP error, -C - resume, --retry transient failures.
fetch() { curl -fL -C - --retry 3 --retry-delay 2 -o "$2" "$1"; }

echo "→ model: kokoro-v1_0.safetensors (~327 MB)"
fetch "$REPO/kokoro-v1_0.safetensors" "$DEST/kokoro-v1_0.safetensors"

for v in "${VOICES[@]}"; do
  echo "→ voice: $v"
  fetch "$REPO/voices/$v.safetensors" "$VOICES_DIR/$v.safetensors"
done

echo "✓ done → $DEST"
