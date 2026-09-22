# Valve-closure analysis of 3D-printed membrane valves (side views)

MATLAB program that measures how far a pressurized membrane valve closes a
3D-printed channel, from a pair of back-illuminated side views of the same
*functionality device*: one unpressurized (open, `OP`) and one pressurized
(closed, `CL`). It is one of three programs described in the preprint
*Cross-Section and Top-View Image-Analysis Pipelines for Automated
Characterization of 3D-Printed Microfluidic Channels and Valves*
(Nguyen et al., 2026); the companion valve-design framework is
[engrXiv 10.31224/8053](https://doi.org/10.31224/8053).

## How it works
1. **Open-state reference.** SAM segments only the open image, using the
   segmentation and validation code of
   [SAG_ANALYSIS_SAM_SEGMENTATION](https://github.com/iomega15/SAG_ANALYSIS_SAM_SEGMENTATION),
   which must be on the MATLAB path (`depDir` in the script).
2. **Registration.** Phase correlation, accepted only if it raises the normalized
   cross-correlation with the open image; robust photometric normalization.
3. **Intensity-loss map.** Open minus closed inside the open channel, gated by a
   noise level estimated from the same pair (dual signal / strong-core criterion).
4. **Reach.** The membrane front, traced through strong-loss pixels over the
   central span, is fitted with a circular arc (parabola fallback); reach is the
   deepest point as % of the open channel height.
5. **Quality gate.** Eight criteria turn unreliable measurements into missing
   data (NaN), never a false zero (`qualityGateDeflection.m`). Discarded pairs go
   to a re-imaging list.
6. **Aggregates.** Area obstructed and reach vs width, onset fits
   reach = k(W - W0), and through-origin fits s = kappa*C
   (`plotCombinedClosureReach.m`, `plotReachLinearFits.m`).

## Requirements
* MATLAB R2026a (tested) with the Image Processing, Computer Vision, and
  Optimization (`lsqcurvefit`) Toolboxes.
* The Python/SAM environment of SAG_ANALYSIS_SAM_SEGMENTATION.

## Usage
1. Name the images `Cutouts_H{n}_W{n}_ML{n}_R{n}_{CL|OP}[_{MMDDYY}][_redoN].jpg`.
   The highest `redoN` wins, then the newest date.
2. Set `inputDir` and `depDir` under `%% USER INPUTS` in
   `BATCH_VALVE_CLOSURE_ANALYSIS2.m` (the main script) and run it.
3. Optional completion notification: set the environment variable
   `VALVE_NOTIFY_EMAIL` and put a Gmail app password in
   `%USERPROFILE%\gmail_app_password.txt`, or set `VALVE_NTFY_TOPIC` for an
   ntfy.sh push. With neither set, nothing is sent.

Outputs (`VALVE_CLOSURE_RESULTS/` beside the images): per-pair and per-condition
tables, fit tables, aggregate figures, and a diagnostic figure per pair in
`debug/pair_Debug/`. `BATCH_VALVE_CLOSURE_ANALYSIS.m` and
`VALVE_CLOSURE_ANALYSIS.m` are earlier versions kept for reference.

## License
MIT, see [`LICENSE`](LICENSE).
