# LaMa Core ML Model

Retouch AI inpainting uses the free Apache-2.0 [LaMa](https://github.com/advimman/lama) model converted to Core ML.

## Download

The model is ~195 MB and is not committed to git. Run:

```bash
bash Scripts/download_lama_model.sh
```

This downloads `Watermarkly/Watermarkly/LaMa.mlpackage` from Hugging Face
(`jerhoads/lama-coreml`, default mirror `hf-mirror.com`).

After download completes, rebuild in Xcode so the model is compiled into the app.

## Behavior

1. While dragging: colored brush preview (instant)
2. On finger release: LaMa inpainting fills the painted region
3. If the model is missing/incomplete: falls back to Gaussian blur

## Source

- Model: [advimman/lama](https://github.com/advimman/lama) (Apache-2.0)
- Core ML package: [jerhoads/lama-coreml](https://huggingface.co/jerhoads/lama-coreml)
- Conversion reference: [mallman/CoreMLaMa](https://github.com/mallman/CoreMLaMa)
