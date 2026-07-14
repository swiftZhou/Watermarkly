# Retouch Inpainting (MI-GAN)

Retouch uses **MI-GAN 256** for on-device erase (~1–2s on iPhone 13).

## Setup

```bash
bash Scripts/download_migan_model.sh
```

Copies `Watermarkly/Watermarkly/migan_coreml.mlpackage` from
[tatsuya-ogawa/MI-GAN-CoreML](https://github.com/tatsuya-ogawa/MI-GAN-CoreML)
(original weights: [Picsart-AI-Research/MI-GAN](https://github.com/Picsart-AI-Research/MI-GAN)).

Then rebuild in Xcode.

## Behavior

1. While dragging: colored brush preview (instant)
2. On finger release: MI-GAN fills the painted crop (~256×256)
3. Solid UI (chat bubbles / white cards): opaque neighborhood fill (instant)
4. If MI-GAN is missing: local blur fallback
