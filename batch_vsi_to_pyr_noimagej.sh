#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# batch_vsi_to_pyr_noimagej.sh
#
# Convert all *.vsi in VSI_DIR into:
#   1) *.ome.tif            (multi-series OME-TIFF)
#   2) *.series<S>.tif      (largest-series extracted)
#   3) *.series<S>.contig.tif (PlanarConfiguration=CONTIG; BigTIFF)
#   4) *.pyr.tif            (tiled JPEG pyramid BigTIFF)
#   5) *.pyr.noimagej.tif   (same pyramid with ImageDescription tag 270 cleared)
# ============================================================

BFCONVERT="${BFCONVERT:-$HOME/local/bin/bftools/bfconvert}"
VIPS_BIN="${VIPS_BIN:-$(command -v vips || true)}"
TIFFCP_BIN="${TIFFCP_BIN:-$(command -v tiffcp || true)}"
TIFFSET_BIN="${TIFFSET_BIN:-$(command -v tiffset || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python || true)}"

PYR_TILE_WH="${PYR_TILE_WH:-128}"
PYR_JPEG_Q="${PYR_JPEG_Q:-95}"

# tiffcp memory limit in MB (libtiff cap).
TIFFCP_MEM_MB="${TIFFCP_MEM_MB:-65536}"

# Clear ImageDescription (tag 270) across IFDs 0..N
STRIP_DIR_MAX="${STRIP_DIR_MAX:-15}"

# Args
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <VSI_DIR> <OUT_DIR>"
  echo "  VSI_DIR: folder containing *.vsi"
  echo "  OUT_DIR: output folder"
  exit 1
fi

VSI_DIR="$1"
OUT_DIR="$2"
mkdir -p "$OUT_DIR"

# Sanity checks
die() { echo "[ERROR] $*" 1>&2; exit 1; }

[[ -x "$BFCONVERT" ]] || die "bfconvert not found/executable at: $BFCONVERT"
[[ -n "$VIPS_BIN" && -x "$VIPS_BIN" ]] || die "vips not found. Activate conda env (msseg) or set VIPS_BIN=/path/to/vips"
[[ -n "$TIFFCP_BIN" && -x "$TIFFCP_BIN" ]] || die "tiffcp not found. Activate conda env (msseg) or set TIFFCP_BIN=/path/to/tiffcp"
[[ -n "$TIFFSET_BIN" && -x "$TIFFSET_BIN" ]] || die "tiffset not found. Activate conda env (msseg) or set TIFFSET_BIN=/path/to/tiffset"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || die "python not found. Activate conda env (msseg) or set PYTHON_BIN=/path/to/python"

echo "[INFO] Using tools:"
echo "       bfconvert : $BFCONVERT"
echo "       vips      : $VIPS_BIN"
echo "       tiffcp    : $TIFFCP_BIN"
echo "       tiffset   : $TIFFSET_BIN"
echo "       python    : $PYTHON_BIN"
echo

# Helper: pick largest series from OME using tifffile
pick_largest_series() {
  local ome_tif="$1"
  "$PYTHON_BIN" - "$ome_tif" <<'PY'
import sys
from tifffile import TiffFile

p = sys.argv[1]

def wh_from_shape(shape):
    if shape is None or len(shape) < 2:
        return None, None
    # (H,W,C)
    if len(shape) >= 3 and shape[-1] in (3,4) and shape[-2] > 16 and shape[-3] > 16:
        H, W = shape[-3], shape[-2]
        return W, H
    # (C,H,W)
    if len(shape) >= 3 and shape[0] in (3,4) and shape[1] > 16 and shape[2] > 16:
        H, W = shape[1], shape[2]
        return W, H
    # fallback: assume last two are (H,W) but guard weird RGB last-dim
    H, W = shape[-2], shape[-1]
    if W in (3,4) and len(shape) >= 3 and H > 16:
        H, W = shape[-3], shape[-2]
    return W, H

best_i = None
best_area = -1

with TiffFile(p) as tf:
    for i, s in enumerate(tf.series):
        W, H = wh_from_shape(getattr(s, "shape", None))
        if not W or not H:
            continue
        area = int(W) * int(H)
        if area > best_area:
            best_area = area
            best_i = i

print("-1" if best_i is None else str(best_i))
PY
}

# Helper: ensure PlanarConfiguration is CONTIG for directory 0
planar_config() {
  local tif="$1"
  "$PYTHON_BIN" - "$tif" <<'PY'
import sys
from tifffile import TiffFile

p=sys.argv[1]
with TiffFile(p) as tf:
    pc = tf.pages[0].tags.get("PlanarConfiguration")
    if pc is None:
        print("NA")
    else:
        v=str(pc.value)
        print("CONTIG" if "CONTIG" in v else ("SEPARATE" if "SEPARATE" in v else v))
PY
}

shopt -s nullglob
VSIS=("$VSI_DIR"/*.vsi)

if [[ ${#VSIS[@]} -eq 0 ]]; then
  die "No .vsi found in: $VSI_DIR"
fi

echo "[INFO] Found ${#VSIS[@]} VSI files in: $VSI_DIR"
echo "[INFO] Output dir: $OUT_DIR"
echo

for VSI in "${VSIS[@]}"; do
  base="$(basename "$VSI")"
  stem="${base%.vsi}"

  echo "============================================================"
  echo "[INFO] Processing: $base"
  echo "============================================================"

  OME="$OUT_DIR/${stem}.ome.tif"
  SERIES_TIF="$OUT_DIR/${stem}.series.tif"              # (kept for compatibility/logging)
  SERIES_S_TIF=""                                       # actual series file with S in name
  CONTIG_TIF=""                                         # contig path with S in name
  PYR_TIF="$OUT_DIR/${stem}.pyr.tif"
  PYR_NOIJ="$OUT_DIR/${stem}.pyr.noimagej.tif"

  # 1) VSI -> OME (multi-series)
  if [[ ! -f "$OME" ]]; then
    echo "[STEP] bfconvert VSI -> OME: $OME"
    "$BFCONVERT" -overwrite -bigtiff "$VSI" "$OME"
  else
    echo "[SKIP] OME exists: $OME"
  fi

  # 2) Pick largest series index
  echo "[STEP] Picking largest series from OME..."
  S="$(pick_largest_series "$OME")"
  if [[ "$S" == "-1" ]]; then
    echo "[ERROR] Could not determine largest series for: $OME"
    echo
    continue
  fi
  echo "[INFO] Largest series index: $S"

  SERIES_S_TIF="$OUT_DIR/${stem}.series${S}.tif"
  CONTIG_TIF="$OUT_DIR/${stem}.series${S}.contig.tif"

  # 3) Extract largest series -> series<S>.tif
  if [[ ! -f "$SERIES_S_TIF" ]]; then
    echo "[STEP] bfconvert OME series $S -> $SERIES_S_TIF"
    "$BFCONVERT" -overwrite -bigtiff -series "$S" "$OME" "$SERIES_S_TIF"
  else
    echo "[SKIP] Series TIFF exists: $SERIES_S_TIF"
  fi

  # also create a stable name *.series.tif pointing to the extracted series
  if [[ ! -f "$SERIES_TIF" ]]; then
    ln -s "$(basename "$SERIES_S_TIF")" "$SERIES_TIF" 2>/dev/null || cp -f "$SERIES_S_TIF" "$SERIES_TIF"
  fi

  # 4) Ensure planar CONTIG (needed for VIPS) using tiffcp (BigTIFF)
  if [[ ! -f "$CONTIG_TIF" ]]; then
    PC="$(planar_config "$SERIES_S_TIF")"
    echo "[INFO] Series PlanarConfiguration: $PC"
    if [[ "$PC" == "CONTIG" ]]; then
      echo "[STEP] Already CONTIG -> copy to contig path"
      cp -f "$SERIES_S_TIF" "$CONTIG_TIF"
    else
      echo "[STEP] tiffcp -> contig BigTIFF: $CONTIG_TIF"
      "$TIFFCP_BIN" -8 -m "$TIFFCP_MEM_MB" -p contig -c none "$SERIES_S_TIF" "$CONTIG_TIF"
    fi
  else
    echo "[SKIP] Contig TIFF exists: $CONTIG_TIF"
  fi

  # 5) Pyramid with VIPS (tiled JPEG pyramid BigTIFF)
  if [[ ! -f "$PYR_TIF" ]]; then
    echo "[STEP] vips tiffsave -> pyramid: $PYR_TIF"
    "$VIPS_BIN" tiffsave "$CONTIG_TIF" "$PYR_TIF" \
      --tile --tile-width "$PYR_TILE_WH" --tile-height "$PYR_TILE_WH" \
      --pyramid --compression jpeg --Q "$PYR_JPEG_Q" --bigtiff
  else
    echo "[SKIP] Pyramid TIFF exists: $PYR_TIF"
  fi

  # 6) Strip ImageJ ImageDescription tag (270) across IFDs -> pyr.noimagej.tif
  if [[ ! -f "$PYR_NOIJ" ]]; then
    echo "[STEP] Strip ImageJ tag -> $PYR_NOIJ"
    cp -f "$PYR_TIF" "$PYR_NOIJ"
    for d in $(seq 0 "$STRIP_DIR_MAX"); do
      "$TIFFSET_BIN" -d "$d" -s 270 "" "$PYR_NOIJ" 2>/dev/null || true
    done
  else
    echo "[SKIP] noimagej pyramid exists: $PYR_NOIJ"
  fi

  echo "[DONE] $base"
  echo
done

echo "[ALL DONE] Outputs in: $OUT_DIR"