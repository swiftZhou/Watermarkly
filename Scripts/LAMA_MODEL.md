# Retouch Inpainting Models

Retouch uses **MI-GAN 256** for interactive on-device erase (target ~1–2s on iPhone 13).

Full **LaMa 800** remains optional as a slower high-quality fallback if bundled.

## MI-GAN (recommended)

MIT license. ~12 MB Core ML package.

```bash
bash Scripts/download_migan_model.sh
```

Copies `Watermarkly/Watermarkly/migan_coreml.mlpackage` from
[tatsuya-ogawa/MI-GAN-CoreML](https://github.com/tatsuya-ogawa/MI-GAN-CoreML)
(original weights: [Picsart-AI-Research/MI-GAN](https://github.com/Picsart-AI-Research/MI-GAN)).

Then rebuild in Xcode.

## Behavior

1. While dragging: colored brush preview (instant)
2. On finger release: MI-GAN fills the painted crop (~256×256 inference)
3. If MI-GAN is missing: try LaMa, then local blur

## Optional LaMa (slow, ~195 MB)

```bash
bash Scripts/download_lama_model.sh
```

LaMa is fixed **800×800** and commonly takes ~10–15s per stroke on iPhone 13 —
fine as fallback, not for interactive use.
