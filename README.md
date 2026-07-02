# Real-Time Trash Sorting & Pfand Recognition

Final project for our "Introduction to AI" course. We are a team of three students —
Andrei Bobkov, Matus Oremus, and Samanta Mendez — and we built a native iOS app that
demonstrates two on-device computer-vision/ML pipelines end to end: a **trash-sorting
classifier** that tells you which German waste bin an item belongs in, and a **Pfand
(bottle deposit) recognizer** that identifies whether a beverage container carries a
deposit and how much.

Everything in the app runs **locally on-device** — no server, no cloud inference. We
use Apple's Vision framework for Core ML inference, OCR, and barcode scanning, and
Apple's on-device Foundation Models framework for the final reasoning step in the
Pfand module.

> **Status at a glance:** the trash-sorting module is fully trained, evaluated, and
> integrated. The Pfand module's photo capture flow, container-type detection, OCR,
> barcode/Open Food Facts lookup, and on-device LLM fusion are all implemented and
> wired together; the one piece still in progress is a dedicated DPG-logo detector
> (see [`Pfand Module.md`](./Pfand%20Module.md) for the full write-up).

---

## Table of contents

1. [Repository layout](#repository-layout)
2. [Module 1 — Trash-sorting classifier](#module-1--trash-sorting-classifier)
3. [Module 2 — Pfand (deposit) recognition](#module-2--pfand-deposit-recognition)
4. [iOS app architecture](#ios-app-architecture)
5. [Running the app](#running-the-app)
6. [What we're working on right now](#what-were-working-on-right-now)
7. [Datasets, models & attributions](#datasets-models--attributions)
8. [License](#license)

---

## Repository layout

```
├── Colab Notebook.ipynb                     # Trash classifier: dataset prep → training → CoreML export
├── Container Type Detector.ipynb            # Pfand Run A: 3-dataset unification → YOLOv8n → CoreML export
├── Pfand Module.md                          # Detailed design doc for the Pfand module (single source of truth)
├── DPG Logo Detector — Training Plan.md     # Build plan for the still-in-progress DPG-logo detector
├── data/
│   ├── splits.json                          # Train/val/test split produced by the trash-classifier notebook
│   └── class_weights.json                   # Computed class weights for the imbalanced TrashNet remap
├── efficientnetv2b0_trashnet_de.keras       # Trained Keras trash-classifier checkpoint (pre-CoreML)
├── ios-app/
│   └── real-time-trash-sorter/
│       ├── real_time_trash_sorterApp.swift  # App entry point
│       ├── ContentView.swift / CameraView.swift   # Single full-screen camera UI, mode toggle
│       ├── CameraManager.swift / CameraPreviewView.swift  # AVFoundation capture session
│       ├── TrashClassifier.swift / BinCategory.swift      # Module 1: classifier + bin presentation
│       ├── CaptureViewModel.swift           # Module 1: capture → classify → result state machine
│       ├── ContainerTypeObjectDetector.swift    # Module 2, Run A: YOLOv8n container detector (Vision)
│       ├── LabelOCR.swift                   # Module 2, Run 2: on-device OCR of the label
│       ├── LabelBarcode.swift               # Module 2, Run 3: on-device barcode decoding
│       ├── OpenFoodFactsClient.swift        # Module 2, Run 3: Open Food Facts product lookup
│       ├── PfandAggregator.swift            # Module 2, Run 4: on-device LLM fusion + deterministic amount table
│       ├── PfandViewModel.swift / PfandView.swift  # Module 2: two-photo capture flow + result UI
│       ├── TrashSorterDEModel.mlpackage     # Exported trash classifier (EfficientNetV2B0)
│       └── ContainerTypeDetector.mlpackage  # Exported container-type detector (YOLOv8n)
└── LICENSE                                  # MIT
```

---

## Module 1 — Trash-sorting classifier

**Goal:** given a photo of a single item, predict which of the four German household
waste bins it belongs to.

```
Blaue Tonne (paper/cardboard) · Glas (glass) · Wertstofftonne (plastics/metal) · Restmüll (residual)
```

The full, runnable process lives in [`Colab Notebook.ipynb`](./Colab%20Notebook.ipynb).
Below is what we did and why, distilled from that notebook.

### Dataset

We used **[TrashNet](https://github.com/garythung/trashnet)** (Gary Thung & Mindy Yang,
Stanford), a public dataset of 2,527 hand-photographed trash images across 6 classes
(`cardboard`, `glass`, `metal`, `paper`, `plastic`, `trash`).

Since our app targets German household recycling, we **remapped TrashNet's 6 classes
onto our 4 German bins**:

| TrashNet class | → German bin |
|---|---|
| `cardboard`, `paper` | `blaue_tonne` (blue bin) |
| `glass` | `glas` |
| `metal`, `plastic` | `wertstofftonne` (recyclables) |
| `trash` | `restmuell` (residual waste) |

This gave us 4 classes with a meaningful **imbalance**: `blaue_tonne` 997, `glas` 501,
`wertstofftonne` 892, `restmuell` only 137 images.

We know this is a limitation worth stating plainly: TrashNet was collected in the US in
2016, so its packaging doesn't always match what you see on German shelves. That's
exactly why we're now collecting our own small set of real German trash photos to
validate the model against (see [What we're working on right now](#what-were-working-on-right-now)).

### Data preparation

- **Split:** stratified 70/15/15 train/val/test (`sklearn.train_test_split`, two-step:
  30% held out, then split 50/50 into val/test), seed 42 → **1,766 train / 380 val /
  381 test** images. Saved to `data/splits.json`.
- **Class weights:** computed with `sklearn`'s `"balanced"` scheme and saved to
  `data/class_weights.json`, since `restmuell` is ~7× rarer than the largest class:

  | Class | Weight |
  |---|---|
  | `blaue_tonne` | 0.634 |
  | `glas` | 1.261 |
  | `restmuell` | 4.611 |
  | `wertstofftonne` | 0.708 |

- **Augmentation** (train-time only, baked into the Keras model): random horizontal
  flip, ±0.08 rotation, ±10% zoom, ±10% contrast.

### Model & training

We fine-tuned **EfficientNetV2B0** (ImageNet weights, `include_preprocessing=True` so
normalization is baked into the graph), because it's lightweight enough to run smoothly
on-device via Core ML while still being accurate — a good fit for a real-time mobile
demo rather than a server-side model.

- **Input:** 224×224×3.
- **Head:** `GlobalAveragePooling2D → Dropout(0.30) → Dense(4, softmax)`.
- **Two-stage fine-tuning:**
  1. **Warm-up** — backbone fully frozen (5,124 trainable params out of 5.9M), head
     trained for 15 epochs, `Adam(lr=1e-3)`, `categorical_crossentropy`, class weights
     applied. Reached val accuracy 0.884.
  2. **Fine-tune** — unfroze the last 40 of 270 backbone layers (keeping all
     `BatchNormalization` layers frozen, since their running statistics are fragile on
     a dataset this small), 10 more epochs at `Adam(lr=1e-5)` — 100× lower LR. Best val
     accuracy **0.903** (epoch 7 of 10).
  3. Callbacks throughout: `ModelCheckpoint` (best `val_accuracy`), `EarlyStopping`
     (patience 5), `ReduceLROnPlateau` (factor 0.3, patience 2).

### Results

Evaluated on the held-out 381-image test split:

| Metric | Value |
|---|---|
| **Top-1 accuracy** | **89.8%** |
| Test loss | 0.291 |

| Class | Precision | Recall | F1 | Support |
|---|---|---|---|---|
| `blaue_tonne` | 0.959 | **0.947** | 0.953 | 150 |
| `glas` | 0.903 | **0.855** | 0.878 | 76 |
| `restmuell` | 0.667 | **0.952** | 0.784 | 21 |
| `wertstofftonne` | 0.878 | **0.858** | 0.868 | 134 |

Both of our proposal's success criteria (≥85% accuracy overall, ≥70% recall per class)
are met. The trade-off we accepted: `restmuell`'s precision is lower (66.7%) because
its heavy class weight (4.61×) makes the model somewhat trigger-happy about predicting
it — we chose to protect recall on the rarest, "when in doubt" bin rather than overall
precision. The main confusion pattern is `glas` ↔ `wertstofftonne` (glass containers
visually resembling plastic packaging).

### Core ML export & app integration

We converted the trained Keras model with **coremltools 9.0** to an ML Program
(`.mlpackage`, not the legacy `.mlmodel` format), targeting iOS 26, with a
`ClassifierConfig` attaching the 4 German bin labels directly to the model so it
returns a human-readable class + probability. No quantization was applied — this is a
straightforward fp32/mlprogram export.

In the app, `TrashClassifier.swift` wraps the exported `TrashSorterDEModel.mlpackage`
in a `VNCoreMLRequest` run through Apple's **Vision** framework, letting Vision handle
the resize/center-crop to 224×224. `CaptureViewModel.swift` drives the
capture → classify → animated result flow, and `BinCategory.swift` maps the raw model
label to a German display name, icon, and color.

---

## Module 2 — Pfand (deposit) recognition

**Goal:** from two photos of a beverage container (the whole bottle/can, then a
close-up of the label), determine whether it carries a German **Pfand** deposit and
how much, then tell the user where they can return it.

This module is considerably more involved than Module 1, because — unlike trash
sorting — there is **no public database** that maps a barcode to its deposit status
(the authoritative DPG database is closed to registered industry participants, and
Open Food Facts has no deposit field). That constraint is what shapes the whole design:
we fuse several **on-device** computer-vision/ML signals into a verdict, rather than
looking anything up. The full design rationale, the abandoned approaches, and the
domain research (Pfand law, amounts, markings) are documented in
[`Pfand Module.md`](./Pfand%20Module.md) — this section is a summary of where things
stand.

### Pipeline

```
Photo 1 — whole container
  └─ Run A: Container-type object detection (YOLOv8n → CoreML/Vision)  ......... DONE

Photo 2 — label close-up
  ├─ Run 1: DPG Pfand-logo detection (CoreML/Vision)  ........................ IN PROGRESS
  ├─ Run 2: OCR — Apple Vision RecognizeTextRequest  .......................... DONE
  ├─ Run 3: Barcode decoding → Open Food Facts product lookup  ................ DONE
  └─ Run 4: On-device LLM fusion (Apple Foundation Models)  ................... DONE
                          │
                          ▼
        Verdict (system: Einweg / Mehrweg / none) → DETERMINISTIC amount lookup
```

**Design principle:** the structured signals (detector, OCR, barcode/product data) are
the primary grounding for the verdict; the on-device language model's job is to fuse
them (and to use its own read of the photos to break ties when signals are missing or
contradictory), not to second-guess a confident detector. The **deposit amount is never
generated by the model** — once the verdict fixes the deposit system, the amount comes
from a fixed lookup table derived from German packaging law (VerpackG §31), since the
€0.25 Einweg amount is legally fixed and Mehrweg amounts are only ever a range.

### Run A — Container-type detection (done)

We trained a custom **YOLOv8n** object detector to localize and classify the container
in the first photo as `plastic_bottle`, `glass_bottle`, `can`, or `carton`. Full process
in [`Container Type Detector.ipynb`](./Container%20Type%20Detector.ipynb).

**Datasets unified (3 sources, all downloaded programmatically):**

| Source | License | Original classes | Raw images |
|---|---|---|---|
| Roboflow Universe — [`beverage-containers-3atxb`](https://universe.roboflow.com/roboflow-universe-projects/beverage-containers-3atxb/dataset/3) v3 | CC BY 4.0 | 9 (bottles, cups, mugs, tin can, …) | ~15,645 |
| Roboflow Universe — [`reverse-vending-machine-ogew0`](https://universe.roboflow.com/reverse-vending-machine-lqerh/reverse-vending-machine-ogew0/dataset/1) v1 | CC BY 4.0 | 5 (bottle, can, paper cup/pack, pet) | ~1,027 |
| Kaggle — [`arkadiyhacks/drinking-waste-classification`](https://www.kaggle.com/datasets/arkadiyhacks/drinking-waste-classification) v2 | not specified by the source | 4 (AluCan, Glass, HDPEM, PET) | ~4,820 |

We remapped each source's class IDs onto our unified 4-class taxonomy (dropping classes
with no equivalent, e.g. cups/mugs), merged everything, and split it **stratified
80/10/10 by each image's majority class** (seed 42):

- **Unified dataset: 11,138 images, 13,704 boxes** (per-class share: plastic_bottle
  40.3%, glass_bottle 32.2%, can 26.2%, carton only 1.3% — carton is intentionally the
  scarcest class here, since it's rare in real Pfand-bearing containers).
- Split: **8,910 train / 1,114 val / 1,114 test.**

**Training:** `yolov8n.pt` (COCO-pretrained, ~3.0M params) fine-tuned with Ultralytics
YOLO at `imgsz=640, batch=32, patience=10`, standard YOLOv8 augmentation (mosaic, HSV
jitter, horizontal flip, light Albumentations blur/CLAHE).

**Results (held-out test set, 1,114 images / 1,338 instances):**

| Metric | Value |
|---|---|
| **mAP@50** | **0.978** |
| **mAP@50-95** | **0.810** |
| Precision / Recall | 0.976 / 0.923 |

| Class | AP@50 |
|---|---|
| plastic_bottle | 0.984 |
| glass_bottle | 0.975 |
| can | 0.982 |
| carton | 0.972 |

**Export:** `format='coreml', half=True, nms=True` → a 5.9 MB `.mlpackage` with NMS
embedded directly in the graph, so it drops straight into Vision as a
`VNCoreMLRequest` returning `VNRecognizedObjectObservation`s — no separate NMS pass
needed. In the app, `ContainerTypeObjectDetector.swift` wraps this model and
`PfandView.swift` renders the detected box over the bottle photo.

### Runs 2–4 — Label analysis (done)

Once the label close-up is captured, three things run **concurrently**:

- **Run 2 — OCR** (`LabelOCR.swift`): Apple Vision's `RecognizeTextRequest` in accurate
  mode, biased toward German + English with a custom Pfand/recycling vocabulary
  (`Pfand`, `Einweg`, `Mehrweg`, `DPG`, `PET`, …), so a printed "Einwegpfand 0,25 €" is
  read reliably.
- **Run 3 — Barcode → Open Food Facts** (`LabelBarcode.swift`,
  `OpenFoodFactsClient.swift`): Apple Vision's `DetectBarcodesRequest` decodes
  EAN-13/EAN-8/UPC-E/Code128/QR on the still image. When a genuine product barcode
  (EAN-13/EAN-8/UPC-E) is found, we look it up against the free
  **[Open Food Facts](https://world.openfoodfacts.org/)** API (v3, product name, brand,
  quantity, packaging, categories) as corroborating product-identity evidence — OFF has
  no deposit field, so it never answers the Pfand question by itself. We identify our
  requests with a descriptive `User-Agent` per OFF's usage policy and attribute the data
  (ODbL) in the result UI.

Then **Run 4 — fusion** (`PfandAggregator.swift`) combines the container-type
detection, OCR text, barcode, and Open Food Facts data using Apple's on-device
**Foundation Models** framework (`FoundationModels`, iOS 26+ Apple Intelligence
devices). We define a `@Generable` `PfandVerdict` struct (`system: einweg | mehrweg |
none | unsure`, `confidence: high | medium | low`, a short German `rationale`) so the
model returns type-safe structured output via `@Guide`-annotated fields, with explicit
system instructions encoding VerpackG §31 decision rules (e.g. cans/PET bottles default
to Einweg unless marked Mehrweg; unmarked glass bottles default to Mehrweg, since real
Mehrweg glass is normally *un*marked). If the on-device model is unavailable (Apple
Intelligence off, device ineligible, model still downloading) or itself reports low
confidence/"unsure", we fall back to a small deterministic rule-based classifier over
the same signals, so the app always produces an answer. Either way, the **deposit
amount and return-location text are never generated** — `PfandAggregator.resolve(...)`
maps the verdict's `system` onto a fixed table (Einweg → €0.25 / any retailer selling
that material; Mehrweg → ~€0.08–0.15 / only matching retailers; none → no deposit).

> **Current caveat:** we originally planned to also pass both photos directly into the
> LLM prompt as image grounding, not just the text signals. `Prompt` only gains an
> image-attachment API in **iOS 27.0 beta**, and we're not raising the app's deployment
> target that high just for this — so for now Run 4 fuses the *text* signals only. Both
> photos are already threaded through the call site so image grounding can be added
> with a minimal change once we're comfortable targeting iOS 27.

### Run 1 — DPG logo detection (in progress)

We first tried classical **ORB feature matching** (OpenCV) to find the DPG deposit logo
on the label — the textbook "find a known graphic in a photo" approach. We abandoned
it: the DPG mark is a flat, near-binary, self-similar icon, which is close to a
worst-case target for descriptor matching — genuine matches and pure noise produced
statistically indistinguishable inlier ratios, so no threshold could separate them. The
full post-mortem is in `Pfand Module.md` §5.1.

We're now building a small, purpose-trained **YOLOv8n single-class detector** for the
logo instead — the same pipeline that worked well for Run A. Because no public dataset
of DPG-marked labels exists, this requires us to collect our own images: we're
currently gathering label photos **with and without** the DPG logo (the negatives are
just as important — they're what teaches the model not to fire on other barcodes,
recycling symbols, or busy label text) and plan to bootstrap additional positives with
a synthetic-compositing generator (paste a logo cutout onto real backgrounds with
randomized scale/rotation/lighting). The full build plan, including the compositing
code, is in [`DPG Logo Detector — Training Plan.md`](./DPG%20Logo%20Detector%20—%20Training%20Plan.md).

---

## iOS app architecture

Single SwiftUI app (`ios-app/real-time-trash-sorter`, iOS 26, Liquid Glass UI, German
UI copy). `CameraView.swift` hosts one live camera preview with a mode toggle between
the two modules; each module owns its own `@Observable` view model driving a small
state machine (`CaptureViewModel` for trash-sorting, `PfandViewModel` for the two-photo
Pfand flow) on top of a shared `CameraManager` (AVFoundation capture session, flash,
zoom, front/back switching). All inference — Core ML classification, Core ML object
detection, OCR, barcode decoding, and the on-device LLM call — runs off the main thread
and is bridged back via Swift concurrency (`async`/`await`, `async let` for the
concurrent Pfand runs).

## Running the app

1. Open `ios-app/real-time-trash-sorter.xcodeproj` in Xcode (a recent Xcode targeting
   iOS 26 SDK; the Pfand LLM fusion needs a physical device with Apple Intelligence
   enabled — the Simulator/older devices will use the rule-based fallback instead).
2. Build & run on a device — the app needs camera access.
3. For the trash-sorting side, follow along in `Colab Notebook.ipynb` (Google Colab, no
   local setup needed) to reproduce training. For the container detector, use
   `Container Type Detector.ipynb`.

## What we're working on right now

- **Real German trash photos:** collecting our own small evaluation set of German
  household trash across the 4 bins, to sanity-check the TrashNet-trained classifier
  against the domain it's actually meant for (TrashNet is US/Stanford-sourced).
- **DPG-logo dataset:** collecting label close-ups with and without the DPG deposit
  logo to train the Run 1 detector described above.

## Datasets, models & attributions

- **TrashNet** — Gary Thung & Mindy Yang, [github.com/garythung/trashnet](https://github.com/garythung/trashnet). Used for Module 1 training data.
- **Roboflow Universe — Beverage Containers** (`beverage-containers-3atxb` v3, workspace `roboflow-universe-projects`), CC BY 4.0.
- **Roboflow Universe — Reverse Vending Machine** (`reverse-vending-machine-ogew0` v1, workspace `reverse-vending-machine-lqerh`), CC BY 4.0.
- **Kaggle — Drinking Waste Classification** (`arkadiyhacks/drinking-waste-classification`), Arkadiy Serezhkin.
- **Open Food Facts** — product data used under [ODbL](https://opendatacommons.org/licenses/odbl/); attributed in-app.
- **Ultralytics YOLOv8** — object detection training framework (AGPL-3.0 by default; used here for academic/non-commercial coursework).
- **Apple frameworks** — Vision, Core ML, Foundation Models, AVFoundation, SwiftUI (Apple platform SDKs).

## License

MIT — see [`LICENSE`](./LICENSE). Copyright (c) 2026 Andrei Bobkov, Matus Oremus,
Samanta Mendez.
