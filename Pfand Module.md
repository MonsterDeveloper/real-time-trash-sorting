# Pfand Module — WIP Feature Report

> **Status:** Work in progress. Container detection (Photo 1) is shipped and validated.
> The label-analysis runs (Photo 2) are partially built / planned. This document is the
> single source of truth for the module's design, decisions, and current state.
>
> **Last updated:** 2026-06-30

---

## 1. Goal

Determine, from two photos of a beverage container, whether it carries a German **Pfand**
(deposit) and **how much** — and present a clear verdict in the app.

The German deposit domain (researched separately, condensed in §7) makes the constraints clear:

- **Single-use (Einweg)** deposit is a legally fixed **flat €0.25** (VerpackG §31).
- **Reusable (Mehrweg)** deposit (~€0.08 / €0.15) is a private, non-standardized arrangement —
  not derivable from rules, only from printed text or a (closed) database.
- **There is no public/free GTIN→deposit database.** The authoritative DPG System Database is
  closed to registered industry participants. Open Food Facts has **no deposit field**.

⟹ The only feasible approach is **on-device computer vision + OCR + barcode identity**, fused into
a final verdict. This module implements exactly that.

---

## 2. Architecture — two-photo pipeline

The flow lives in `ios-app/real-time-trash-sorter/PfandViewModel.swift` (state machine:
`awaitingBottlePhoto → awaitingLabelPhoto → processing → result`).

```
Photo 1 — whole object in frame
  └─ Run A: Container-type object detection (CoreML/Vision)  ........... DONE

Photo 2 — label close-up
  ├─ Run 1: DPG Pfand-logo detector (CoreML/Vision)  .................. IN PROGRESS (pivoted)
  ├─ Run 2: OCR — Apple Vision VNRecognizeTextRequest  ............... PLANNED
  ├─ Run 3: Barcode — VNDetectBarcodesRequest → Open Food Facts  .... PLANNED
  └─ Run 4: LLM aggregation — on-device System Language Model  ....... PLANNED
             (structured signals primary + both raw images as context)
                          │
                          ▼
        Final verdict → DETERMINISTIC Pfand amount (§7 amount table)
```

**Design principle for fusion (Run 4):** the structured signals (detector, OCR, barcode) are each
purpose-built and validated for their job, so they are the **primary grounding**. The general
on-device model's own read of the raw pixels is **corroborating context only** — used to break ties
or fill gaps when signals are missing, low-confidence, or contradictory (e.g. logo run ambiguous, but
the model can read "Pfand 0,25 €" printed on the label). The model must not be allowed to second-guess
a confident detector based on a weaker visual read. The final **amount is deterministic**: once the
verdict identifies the container/Pfand class, the amount comes from the fixed table in §7, not from the
model's free generation.

---

## 3. Status table

| # | Component | Stage | Status | Notes |
|---|---|---|---|---|
| — | Two-photo capture flow, camera, result UI | App | ✅ Done | `PfandViewModel`, `PfandView`, `CameraManager` |
| A | **Container-type detection** (Photo 1) | Model + app | ✅ Done | YOLOv8n → CoreML, mAP@50 **0.978**; `ContainerDetector.swift` |
| 1 | **DPG logo detection** (Photo 2) | Model + app | 🟡 In progress | ORB approach **abandoned** (see §5); pivoting to trained CoreML detector |
| 2 | **OCR** of label text (Photo 2) | App | ⬜ Planned | `VNRecognizeTextRequest`, on-device, German printed text |
| 3 | **Barcode + Open Food Facts** (Photo 2) | App + API | ⬜ Planned | `VNDetectBarcodesRequest` → OFF for product identity (no deposit field) |
| 4 | **LLM aggregation** (Photo 2) | App | ⬜ Planned | On-device System Language Model (WWDC 2026), `@Generable`/`@Guide` |
| — | Final verdict → deterministic amount | Logic | ⬜ Planned | Maps verdict to §7 amount table |
| — | Cleanup: remove OpenCV-SPM dep + ORB matcher + logo reference assets | App | ⬜ Planned | Dead once Run 1 lands as CoreML |

(Separate from this module: the **Trash-sorting** mode uses an image **classifier**, `TrashClassifier`,
trained from TrashNet → German bins in `Colab Notebook.ipynb`. Unrelated to Pfand but shares the camera UI.)

---

## 4. Run A — Container-type detection ✅ DONE

**What it does.** On Photo 1 (whole object), detects the container and its type, returning a class +
confidence + bounding box.

- **Classes:** `plastic_bottle`, `glass_bottle`, `can`, `carton`.
- **Model:** YOLOv8n (~3M params), fine-tuned from COCO-pretrained `yolov8n.pt`.
- **Training notebook:** `Container Type Detector.ipynb`.
- **Datasets (unified):**
  - Roboflow Universe — **Beverage Containers** (`beverage-containers-3atxb`, v3)
  - Roboflow Universe — **Reverse Vending Machine** (`reverse-vending-machine-ogew0`, v1)
  - Kaggle — **Drinking Waste Classification** (`arkadiyhacks/drinking-waste-classification`)
  - Pipeline: download (YOLOv8 format) → remap each source's class IDs to the 4 unified classes →
    merge (~11k images, ~13.7k boxes) → stratified 80/10/10 split by majority class.
- **Training config:** `epochs=80, imgsz=640, batch=32, patience=10`, resumable.
- **Results (held-out test):** mAP@50 **0.978**, mAP@50-95 0.810; per-class AP@50 0.97–0.98.
- **Export:** CoreML fp16 with embedded NMS (`format='coreml', half=True, nms=True`) → `.mlpackage`.
- **App integration:** `ContainerDetector.swift` wraps `VNCoreMLModel` + `VNCoreMLRequest`, reads
  `VNRecognizedObjectObservation`, returns `ContainerDetection { type, confidence, boundingBox }`.
  Rendered with `BoundingBoxOverlay` in `PfandView`.

---

## 5. Run 1 — DPG logo detection 🟡 IN PROGRESS

### 5.1 Abandoned approach: ORB feature matching (post-mortem)

> **Verdict: abandoned — do not revisit.** Classical feature matching is the wrong tool for this target.

**What we tried.** The textbook "find a known graphic in a photo" pipeline using OpenCV (via the
`Yeatse/OpenCV-SPM` package, OpenCV 5.0, called from Swift):
ORB keypoints + binary descriptors → BFMatcher (Hamming) `knnMatch` (k=2) → Lowe ratio test →
`findHomography` (RANSAC) → reproject reference-logo corners to draw a quad. We iterated hard:

- Fixed a grayscale-conversion bug (`Mat(uiImage:)` returns 4-channel RGBA; was using `COLOR_BGR2GRAY`).
- Downscaled the query to ~1400 px and raised ORB to 3000 features / 10 pyramid levels (feature density
  on a small logo in a 12 MP frame was the first wall).
- Bundled multiple reference crops (clean blue, clean black, photographed).
- Added geometric gates: inlier-ratio threshold + convex/non-degenerate quad validation.

**Why it failed (root cause).** The DPG logo is a **flat, near-binary, self-similar icon** (four
near-identical corner marks, a symmetric arrow, large uniform areas). ORB needs **rich, unique,
non-repeating texture**. On this target:

- Many "good" matches survived the ratio test but were **geometrically inconsistent** — e.g. a real
  logo gave ~40 good matches but only **~8 inliers (≈20%)**; a genuine planar match sits at 50–90%.
- The homography was unstable → **non-convex, collapsed quads** even on true positives.
- An **empty label** produced the *same* weak signal (~10 inliers) → signal and noise **overlap**;
  no threshold separates them. The earlier "it detects!" was a fluke that the geometry gate then
  correctly killed (along with the true positives).

**Conclusion.** Algorithm/target mismatch. The ORB matcher, `DPGLogoFeatureMatcher.swift`, the
OpenCV-SPM dependency, and the `dpg_logo_*` reference image assets are slated for removal.

### 5.2 Current direction: trained CoreML detector

Reuse the **proven Run A pipeline**: a single-class YOLOv8n object detector for `dpg_logo`, exported to
CoreML, consumed by Vision exactly like `ContainerDetector`. Detection (not classification) because it
localizes a small logo in a larger frame — the exact case ORB failed — and fits the existing box-overlay UI.

**Data plan** (the only genuinely new work — no public dataset exists):

- **Real positives:** ~150–250 annotated photos of labels with the logo (varied brand/scale/angle/light).
- **Real negatives:** ~300–500 logo-free label/bottle photos as background images (empty label files) —
  these directly suppress the false positives ORB couldn't avoid. Include hard negatives (other barcodes,
  recycling symbols, busy text).
- **Synthetic bootstrap:** ~2,000 composites — paste a transparent DPG-logo cutout onto the real-negative
  backgrounds with random scale/rotation/perspective/recolor/blur, deriving the YOLO bbox from the alpha.
  Mix into **training only**; keep validation/test **real-only**.
- **Training tweaks vs Run A:** `fliplr=0.0` (the arrow points left — a mirrored logo doesn't exist),
  stronger geometric aug. Watch **precision on the negatives-only test set** as the key metric.
- **Export:** CoreML fp16 + NMS → `dpg_logo_detector.mlpackage`.

**App integration (planned):** add `DPGLogoDetector.swift` mirroring `ContainerDetector`; output
`DPGLogoDetection { found, confidence, boundingBox }`; `found = topConfidence ≥ ~0.5`; reuse
`BoundingBoxOverlay`. Remove the ORB/OpenCV path.

---

## 6. Runs 2–4 — Label analysis (planned)

### Run 2 — OCR (`VNRecognizeTextRequest`)
On-device Apple Vision text recognition on the label close-up. **Free, private, no network**, decent on
printed German text. Targets the explicit, high-contrast cues: **"Einweg" / "Einwegpfand" / "0,25 €" /
"Mehrweg" / "Pfand"**. Often the single most learnable, reliable signal when present (a printed
"Einwegpfand 0,25 €" is near-conclusive).

### Run 3 — Barcode (`VNDetectBarcodesRequest`) → Open Food Facts
Natively decode EAN-13/EAN-8/UPC-A/Code128/QR on a still image (fits the two-photo flow better than
continuous scanning), on-device and first-party. Feed the decoded **GTIN** to the Open Food Facts REST API
(`/api/v2/product/{barcode}.json`).
**Re-stated finding:** OFF has **no deposit field** and sparse/unreliable German Pfand tags, so this run
contributes **product identity** (name, brand, category) as **corroborating evidence** — e.g. "0.5 L PET
Coca-Cola bottle" reinforcing the container-type and logo signals — **not** a standalone Pfand answer.
Compliance: ODbL (attribution + share-alike), descriptive `User-Agent` (`AppName/Version (email)`),
"1 API call = 1 real scan", prefer a cached local dump over hammering the API.

### Run 4 — LLM aggregation (on-device System Language Model)
WWDC 2026: Apple's on-device model now **accepts images directly** and supports `@Generable`/`@Guide`
guided generation for **type-safe structured output**, free and offline on iOS 26+ Apple-Intelligence
devices. This run **fuses** the structured signals from Runs A/1/2/3 into a final verdict, optionally
also taking **both raw images** as additional context.

- **Primary grounding = structured signals.** Raw images are corroboration for missing/low-confidence/
  contradictory cases only (per the principle in §2).
- **Output is structured** (e.g. `{ isPfand: Bool, system: einweg|mehrweg|none, containerType, confidence,
  rationale }`).
- **Amount is deterministic:** once the verdict fixes the Pfand class, the app maps it to the §7 amount
  table (Einweg → €0.25; Mehrweg → range), rather than letting the model invent a number.

---

## 7. Domain reference (condensed)

**Eligibility (VerpackG §31).** Single-use deposit applies to beverage cans and single-use glass/plastic/
composite bottles, fill volume **0.1–3.0 L**. Since 2022: ~all single-use plastic bottles + all cans;
since 2024: milk/milk-based in single-use plastic. **Excluded:** wine, Sekt, spirits (alcohol-taxed),
beverage **cartons**, pouches, < 0.1 L or > 3.0 L. "Ausschlaggebend ist allein das **Material** … nicht die
Form, die Marke oder der Inhalt." Einweg = statutory; Mehrweg = private civil arrangement.

**Amounts (deterministic mapping target):**

| Type | Deposit | Set by |
|---|---|---|
| Single-use (Einweg) bottle/can, 0.1–3.0 L | **€0.25** | Law (flat, universal) |
| Reusable (Mehrweg) beer bottle ≤0.5 L | ~€0.08 | Filler/pool (convention) |
| Reusable (Mehrweg) larger / water / soft-drink / swing-top | ~€0.15 | Filler/pool (convention) |
| Beverage crate (Kasten) | ~€1.50 | Private |
| Special/wine (rare) | ~€0.02–0.03 | Private |

Only the **€0.25 Einweg** figure is legally fixed; Mehrweg must be presented as a **range** (can't be
derived from rules, may not be printed).

**Markings.** Einweg: **DPG logo** (blue/white, fixed 14×16 mm, "DPG Ink", on 50–120 mm cylindrical
packaging) + market-specific GTIN, often "Einweg"/"0,25 €". Mehrweg: "Mehrweg", "Pfand-Glas",
"Leihflasche", Blauer Engel, etc.

**Store takeback (encodable as static rules, §31(2)/§15).** Retailers selling single-use containers must
take back single-use of the **material types they sell**, regardless of purchase origin, no purchase
required. Shops **< 200 m²** only need take back the brands/materials they stock. Mehrweg: only the same
type/form/size they sell. (Why discounters refuse reusable glass beer bottles.) **No** authoritative public
nationwide RVM/store-location API exists (~40,000 machines; OSM `vending=bottle_return` is partial).

**Why no barcode lookup.** DPG System Database = closed B2B. GS1/GEPIR = company-of-prefix only, ~20–30
free queries/day, no deposit status. OFF = free but no deposit field, sparse tags. ⟹ visual + OCR is the
only viable primary path; RVMs themselves still ground truth on GTIN + DPG mark + weight + shape.

---

## 8. Key decisions & open questions

**Decisions locked in**
- Object **detection** (not classification) for both container type and DPG logo.
- ORB/OpenCV feature matching **abandoned** (§5.1).
- Structured signals are primary; on-device LLM is a fusion/tiebreak layer; **amount is deterministic**.
- Reuse the container-detector training/export pipeline for the logo detector.

**Open questions / next steps**
- Collect + annotate the DPG-logo dataset; build the synthetic-compositing generator (mostly drafted).
- Decide the verdict schema (`@Generable` struct) and the confidence-fusion rules across the 4 runs.
- Define fallback behavior when runs disagree (e.g. detector says "no logo" but OCR reads "Einwegpfand").
- Store-guidance (Stage 3): static VerpackG decision tree; optional OSM RVM overlay (with disclaimer).
- Periodic review of regulatory drift (2022 plastics/cans, 2024 milk, EU PPWR Mehrweg obligations from 2030).

**Benchmarks that would change the plan**
- A licensed GTIN→deposit feed → promote barcode to primary, demote CV to fallback.
- DPG-logo detector accuracy < ~90% under real lighting/occlusion → lean harder on OCR of "0,25 €"/"Einwegpfand".

---

## 9. Relevant files

- `ios-app/real-time-trash-sorter/PfandViewModel.swift` — two-photo state machine + run orchestration
- `ios-app/real-time-trash-sorter/PfandView.swift` — instructions, thumbnails, result card, overlays
- `ios-app/real-time-trash-sorter/ContainerDetector.swift` — Run A (CoreML/Vision)
- `ios-app/real-time-trash-sorter/ContainerTypeDetector.mlpackage` — trained container model
- `Container Type Detector.ipynb` — container training/export (template for the logo detector)
- `Colab Notebook.ipynb` — (separate) trash-sorting classifier
- _To remove:_ `DPGLogoFeatureMatcher.swift`, OpenCV-SPM dependency, `dpg_logo_*` reference assets
- _To add:_ `DPGLogoDetector.swift`, `dpg_logo_detector.mlpackage`, logo training notebook
