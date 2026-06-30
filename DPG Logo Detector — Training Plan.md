# DPG Logo Detector — Training Plan

> Companion to `Pfand Module.md` (§5.2, Run 1). This is the detailed build plan for the
> **DPG Pfand-logo detector**: a single-class object-detection model that locates the DPG mark
> in a label close-up. It reuses the proven `Container Type Detector.ipynb` pipeline
> (YOLOv8n → CoreML), so most of this is a focused adaptation, not new infrastructure.
>
> **Last updated:** 2026-06-30

---

## 0. Why detection (and why not the alternatives)

- **Object detection, single class `dpg_logo`.** Localizes a small logo inside a larger frame —
  the exact case where the abandoned ORB approach failed (see `Pfand Module.md` §5.1). It also
  outputs a `VNRecognizedObjectObservation` bounding box that drops straight into the existing
  Vision + `BoundingBoxOverlay` code.
- **Not image classification.** "Logo: yes/no" throws away location and degrades when the logo is
  small relative to the frame.
- **Not feature matching (ORB/SIFT).** The DPG mark is a flat, near-binary, self-similar icon —
  the worst case for descriptor matching. Documented dead end.

**Target metric that actually matters:** precision / false-positive rate on a **logo-absent** test
set. The ORB approach died because it fired on empty labels; the whole point of training with
negatives is to drive that to near-zero.

---

## 1. Data collection

No public DPG-logo dataset exists, so this is the only genuinely new work. Build **three buckets**.

### 1.1 Real positives (labels WITH the logo)
- **Count:** ~150–250 (low end is fine *because* synthetic augmentation carries scale/rotation variety).
- **Variety is everything** — more impact than raw count:
  - Brands/products (water, soft drink, beer, energy), bottle vs can vs PET.
  - Logo **scale** in frame (small → filling the frame).
  - **Angle / tilt / perspective**, curved-bottle distortion.
  - **Lighting**: glare, shadow, dim, mixed; crinkled/wet labels; partial occlusion.
- **Match deployment:** the app captures a **close-up of the label**, so most shots should look like
  that — not full-room scenes.
- **Annotation:** one tight bounding box around the **framed mark** (the four corner ticks + the
  bottle/can/arrow glyph). Tool: **Roboflow** (same ecosystem as the container model), or CVAT /
  Label Studio. Export **YOLOv8** format.

### 1.2 Real negatives (labels WITHOUT the logo) — the false-positive cure
- **Count:** ~300–500. **Include `0` boxes** (empty `.txt`) → YOLO treats them as *background images*
  and learns to **not** fire.
- **Hard negatives matter most:** other barcodes, the recycling "Der Grüne Punkt" loop, triman/other
  recycling symbols, busy ingredient text, nutrition tables, *other* brand logos. These teach the model
  the DPG mark **specifically**.
- These photos double as **backgrounds** for synthetic compositing (§2).

### 1.3 Synthetic positives (bootstrap)
- **Count:** ~2,000 composites. Paste a transparent DPG-logo cutout onto the real-negative backgrounds
  with randomized transforms; derive the YOLO box from the logo's alpha (§2).
- **Training only.** Never put synthetic images in validation/test.

### 1.4 Splits
- **Validation + test = REAL only** (~100 positives + ~100 negatives held out). Synthetic-only metrics
  look great and lie — keep the eval honest and deployment-representative.
- **Train** = remaining real positives + real negatives + all synthetic.

| Bucket | Train | Val/Test |
|---|---|---|
| Real positives | ~150 | ~100 (held out) |
| Real negatives (backgrounds) | ~300 | ~100 (held out) |
| Synthetic positives | ~2,000 | 0 |

---

## 2. Synthetic generation

Take a transparent cutout of the logo → random transform (scale/rotate/perspective/recolor/lighting/
blur) → paste onto a logo-free background → compute the YOLO box from the alpha channel.

> Requirements: `pip install opencv-python pillow numpy`

### 2.1 Make a transparent logo cutout
Clean logo art is flat-on-background, so key out the background to get an RGBA cutout. (A real
transparent PNG of the DPG mark is even better — then skip the keying.)

```python
import cv2, numpy as np

def prepare_logo_rgba(path, bg_is_light=True):
    """Key out the flat background of a clean logo → RGBA cutout (marks opaque)."""
    img  = cv2.imread(path, cv2.IMREAD_COLOR)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    # marks are dark on a light background → opaque where dark (invert if bg is dark)
    alpha = (gray < 200).astype(np.uint8) * 255 if bg_is_light else (gray > 55).astype(np.uint8) * 255
    alpha = cv2.morphologyEx(alpha, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))  # fill speckles
    rgba  = cv2.cvtColor(img, cv2.COLOR_BGR2BGRA)
    rgba[:, :, 3] = alpha
    ys, xs = np.where(alpha > 0)                 # crop to the marks
    return rgba[ys.min():ys.max() + 1, xs.min():xs.max() + 1]

LOGO = prepare_logo_rgba("dpg_logo_black.png")   # black DPG logo on white → transparent cutout
```

### 2.2 Transform + paste + emit a YOLO label

```python
import random, glob
from pathlib import Path

def warp_logo(logo, max_rot=25, persp=0.16):
    """Random rotation + perspective jitter (fakes tilt / curved-bottle viewing angle)."""
    h, w = logo.shape[:2]
    pad  = int(0.35 * max(h, w))
    logo = cv2.copyMakeBorder(logo, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=(0, 0, 0, 0))
    H, W = logo.shape[:2]
    M    = cv2.getRotationMatrix2D((W / 2, H / 2), random.uniform(-max_rot, max_rot), 1.0)
    logo = cv2.warpAffine(logo, M, (W, H), borderValue=(0, 0, 0, 0))
    src  = np.float32([[0, 0], [W, 0], [W, H], [0, H]])
    j    = persp * W
    dst  = src + np.random.uniform(-j, j, src.shape).astype(np.float32)
    logo = cv2.warpPerspective(logo, cv2.getPerspectiveTransform(src, dst), (W, H), borderValue=(0, 0, 0, 0))
    ys, xs = np.where(logo[:, :, 3] > 10)        # re-crop to alpha
    return logo[ys.min():ys.max() + 1, xs.min():xs.max() + 1]

def recolor(logo):
    """DPG logos appear black / dark-blue / green / white / embossed — randomize the ink."""
    color = random.choice([(20, 20, 20), (120, 60, 20), (40, 90, 30), (235, 235, 235)])  # BGR
    out = logo.copy(); a = out[:, :, 3] > 0
    for c in range(3):
        out[:, :, c][a] = color[c]
    return out

def composite(bg, logo):
    bg = bg.copy(); Hb, Wb = bg.shape[:2]
    logo = recolor(warp_logo(logo))
    scale = random.uniform(0.10, 0.40)                       # logo width as fraction of frame
    lw = max(16, int(Wb * scale)); lh = int(lw * logo.shape[0] / logo.shape[1])
    if lh >= Hb or lw >= Wb:
        return None
    logo = cv2.resize(logo, (lw, lh), interpolation=cv2.INTER_AREA)
    x, y = random.randint(0, Wb - lw), random.randint(0, Hb - lh)
    a    = (logo[:, :, 3:4].astype(np.float32) / 255.0) * random.uniform(0.85, 1.0)  # printed opacity
    roi  = bg[y:y + lh, x:x + lw].astype(np.float32)
    bg[y:y + lh, x:x + lw] = (a * logo[:, :, :3] + (1 - a) * roi).astype(np.uint8)
    if random.random() < 0.5:                                # mild realism: blur the whole frame
        k = random.choice([3, 5]); bg = cv2.GaussianBlur(bg, (k, k), 0)
    cx, cy = (x + lw / 2) / Wb, (y + lh / 2) / Hb            # YOLO normalized box
    return bg, (cx, cy, lw / Wb, lh / Hb)

# ── Driver ──────────────────────────────────────────────────────────────────
BG_DIR  = "backgrounds"     # logo-FREE label/bottle photos (reuse your real negatives)
OUT     = Path("synthetic"); (OUT / "images").mkdir(parents=True, exist_ok=True); (OUT / "labels").mkdir(parents=True, exist_ok=True)
PER_BG  = 5                 # composites per background

n = 0
for bgp in glob.glob(f"{BG_DIR}/*.jpg") + glob.glob(f"{BG_DIR}/*.png"):
    bg0 = cv2.imread(bgp)
    if bg0 is None:
        continue
    for _ in range(PER_BG):
        r = composite(bg0, LOGO)
        if r is None:
            continue
        img, (cx, cy, w, h) = r
        cv2.imwrite(str(OUT / "images" / f"syn_{n:06}.jpg"), img)
        (OUT / "labels" / f"syn_{n:06}.txt").write_text(f"0 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}\n")
        n += 1
print(f"generated {n} synthetic samples")
```

### 2.3 Sanity-check before training (do not skip)
A wrong bbox silently poisons the whole synthetic set. Render ~15 random samples with boxes drawn:

```python
import matplotlib.pyplot as plt
files = sorted((OUT / "images").glob("*.jpg")); random.shuffle(files)
plt.figure(figsize=(20, 12))
for i, img_p in enumerate(files[:15]):
    img = cv2.cvtColor(cv2.imread(str(img_p)), cv2.COLOR_BGR2RGB); H, W = img.shape[:2]
    cx, cy, w, h = map(float, (OUT / "labels" / (img_p.stem + ".txt")).read_text().split()[1:])
    x1, y1 = int((cx - w / 2) * W), int((cy - h / 2) * H)
    x2, y2 = int((cx + w / 2) * W), int((cy + h / 2) * H)
    cv2.rectangle(img, (x1, y1), (x2, y2), (255, 0, 0), 3)
    plt.subplot(3, 5, i + 1); plt.imshow(img); plt.axis("off")
plt.tight_layout(); plt.show()
```

### 2.4 Optional: cylindrical warp (curved-bottle realism)
Bottles are cylinders, so a horizontal "bulge" on the logo improves realism. Apply before `composite`:

```python
def cylinder_warp(logo, strength=0.25):
    h, w = logo.shape[:2]
    map_x, map_y = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    norm   = (map_x - w / 2) / (w / 2)                       # -1 … 1 across width
    map_x  = (w / 2) + (w / 2) * np.sign(norm) * (np.abs(norm) ** (1 + strength))
    return cv2.remap(logo, map_x, map_y, cv2.INTER_LINEAR, borderValue=(0, 0, 0, 0))
```

---

## 3. Dataset assembly

Lay it out like the container model's `unified_dataset_split` so training is a copy.

```
dpg_dataset_split/
├── train/{images,labels}/   # real-pos(train) + real-neg(train) + ALL synthetic
├── valid/{images,labels}/    # REAL only
├── test/{images,labels}/     # REAL only
└── data.yaml
```

```yaml
# data.yaml
path: /content/dpg_dataset_split
train: train/images
val: valid/images
test: test/images
nc: 1
names: ['dpg_logo']
```

Negatives are images **with no `.txt`** (or an empty `.txt`). Keep their image files in `images/`.

---

## 4. Training

Identical to `Container Type Detector.ipynb` (cell 20) with two task-specific changes.

```python
from ultralytics import YOLO

model = YOLO('yolov8n.pt')          # COCO-pretrained ~3M-param backbone (same as container model)

model.train(
    data='/content/dpg_dataset_split/data.yaml',
    epochs=100, imgsz=640, batch=32, device=0,
    patience=15,
    fliplr=0.0,                      # ← the DPG arrow points LEFT; a mirrored logo doesn't exist.
    degrees=20,                      # ← logo appears tilted in real shots
    perspective=0.0005,              # ← mild perspective on top of the synthetic warps
    project='/content/runs/detect', name='dpg_v1',
    plots=True, cache='disk',
)
```

**Why the two changes vs the container run:**
- `fliplr=0.0` — horizontal flip would synthesize a mirrored logo that doesn't exist in reality and
  waste capacity / risk accepting mirrored marks.
- stronger geometric aug (`degrees`, `perspective`) — the logo genuinely appears rotated/skewed on
  curved, hand-held bottles.

`imgsz=640` is fine because the UX is a close-up; bump to `imgsz=960` only if validation shows the logo
is consistently tiny in-frame (small-object regime).

---

## 5. Evaluation

```python
best = YOLO('/content/runs/detect/dpg_v1/weights/best.pt')
m = best.val(data='/content/dpg_dataset_split/data.yaml', split='test', plots=True)
print(f"mAP@50: {m.box.map50:.4f}   mAP@50-95: {m.box.map:.4f}")
print(f"precision: {m.box.mp:.4f}   recall: {m.box.mr:.4f}")
```

- **mAP@50** for overall quality.
- **The decisive check: false positives on the logo-absent images.** Run prediction over the negative
  test set at the deployment confidence threshold and confirm near-zero detections:

```python
from pathlib import Path
neg = list(Path('/content/dpg_dataset_split/test/images').glob('neg_*'))   # name negatives clearly
fp  = sum(len(r.boxes) > 0 for r in best.predict(neg, conf=0.5, verbose=False))
print(f"false positives on {len(neg)} negatives: {fp}  ({100*fp/max(len(neg),1):.1f}%)")
```

If FP rate is too high → **add more real negatives / hard negatives first** (cheapest, most effective
lever), then consider raising the deployment `conf` threshold.

---

## 6. Export to CoreML

Identical to the container model (cell 22) → produces a Vision-compatible detector with embedded NMS.

```python
best.export(format='coreml', half=True, nms=True, imgsz=640)
# → dpg_logo_detector.mlpackage
```

---

## 7. App integration (after the model exists)

Mirror `ContainerDetector` exactly; this also *removes* code (the ORB path).

1. Add `dpg_logo_detector.mlpackage` to the target.
2. Add **`DPGLogoDetector.swift`** — `VNCoreMLModel` + `VNCoreMLRequest`, read `[VNRecognizedObjectObservation]`:

```swift
struct DPGLogoDetection: Sendable {
    let found: Bool
    let confidence: Double
    let boundingBox: CGRect      // Vision normalized, origin bottom-left
}

// In the request handler:
let best = results.max { $0.confidence < $1.confidence }
let found = (best?.confidence ?? 0) >= 0.5      // deployment threshold (tune from §5)
return DPGLogoDetection(found: found,
                        confidence: Double(best?.confidence ?? 0),
                        boundingBox: best?.boundingBox ?? .zero)
```

3. In `PfandViewModel.captureLabelPhoto`, run it on the **label** image (concurrently with the
   container detector on the bottle image), and carry `DPGLogoDetection` into `Step.result`.
4. In `PfandView`, render the box with the existing **`BoundingBoxOverlay`** on the label image;
   verdict + stats come straight from `found` / `confidence`.
5. Delete the dead ORB path: `DPGLogoFeatureMatcher.swift`, the OpenCV-SPM package dependency, and the
   `dpg_logo_*` reference image assets.

---

## 8. Checklist

- [ ] Collect ~150–250 real positives, annotate tight boxes in Roboflow → YOLOv8 export.
- [ ] Collect ~300–500 real negatives (incl. hard negatives: other barcodes/recycling/brand logos).
- [ ] Produce a transparent logo cutout (§2.1) — ideally a real transparent PNG.
- [ ] Generate ~2,000 synthetic composites onto the negative backgrounds (§2.2); **eyeball 15 boxes**.
- [ ] Assemble `dpg_dataset_split` (val/test REAL-only); write `data.yaml`.
- [ ] Train `yolov8n` with `fliplr=0.0` + geometric aug (§4).
- [ ] Evaluate mAP@50 **and** false-positive rate on negatives (§5).
- [ ] Export CoreML fp16 + NMS → `dpg_logo_detector.mlpackage` (§6).
- [ ] Wire `DPGLogoDetector.swift`; remove the ORB/OpenCV path (§7).

---

## 9. Tuning levers (if results disappoint)

| Symptom | First lever |
|---|---|
| Fires on logo-absent labels (false positives) | Add more **real negatives / hard negatives**; raise deployment `conf`. |
| Misses real logos (false negatives) | More real-positive variety; more synthetic scale/rotation range; lower `conf`. |
| Logo consistently tiny in frame, poor recall | Train/infer at `imgsz=960`. |
| Accepts mirrored/odd orientations | Confirm `fliplr=0.0`; reduce extreme `degrees`/`perspective`. |
| Great on synthetic, bad on real | Domain gap — add real positives, dial back unrealistic synthetic recolor/opacity ranges. |
