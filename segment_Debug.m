clear all
clc
close all

% =========================================================================
% SINGLE-PAIR FORENSIC COMPARISON OF CLOSURE-DETECTION METHODS
%
% PURPOSE
%   Compare multiple obstruction-detection approaches on one OP/CL pair
%   using the OPEN lumen mask as the fixed ROI.
%
% METHODS COMPARED
%   A) Closed-mask overlap method (your current pipeline behavior)
%   B) Continuous intensity-loss map inside the open lumen ROI
%   C) Grayscale imfill-hole method inside the open lumen ROI
%
% NOTES
%   - Registration is done first.
%   - Open lumen is segmented once and treated as the reference ROI.
%   - For B and C, we avoid arbitrary thresholding by using weighted
%     obstruction fractions and weighted reach. For visualization only,
%     a red outline is drawn from a non-arbitrary top-percent contour of
%     the continuous map (default: 50% of its own max). That contour is
%     only for display, not for the reported weighted metrics.
%   - Method A is included so you can directly see why it fails.
% =========================================================================

%% USER INPUTS

depDir = 'C:\Users\rvoronov\Dropbox\DRY_LAB\3D_PRINTING_IMAGE_ANALYSIS\SAG_ANALYSIS_SAM_SEGMENTATION';
addpath(depDir);

inputDir = 'C:\Users\rvoronov\Dropbox\MANUSCRIPTS\micromachines_valve_printing_framework\Figures\NanoClear\Sorted_ConstH5\Cutout_ConstH5_Cleaned';

openFile   = fullfile(inputDir, 'Cutouts_H5_W50_ML1_R3_OP.jpg');
closedFile = fullfile(inputDir, 'Cutouts_H5_W50_ML1_R3_CL.jpg');

samCheckpointFile = fullfile(depDir, 'sam_vit_b_01ec64.pth');

roi.bottomFrac = 0.09;
roi.leftFrac   = 0.00;
roi.widthFrac  = 1.00;
roi.heightFrac = 0.09;

doRegistration = true;
forceRerunSegmentation = true;

% Visualization-only contour level for continuous methods.
% Not used for the quantitative weighted metrics.
vizLevelFrac = 0.50;

debugOutDir = fullfile(inputDir, 'FORENSIC_COMPARE_METHODS_H5_W50_ML1_R3');
if ~exist(debugOutDir, 'dir')
    mkdir(debugOutDir);
end

%% READ IMAGES
Iopen   = imread(openFile);
Iclosed = imread(closedFile);

Iopen   = ensureRGB_local(Iopen);
Iclosed = ensureRGB_local(Iclosed);

IopenGray = im2double(rgb2gray(Iopen));
IclosedGray = im2double(rgb2gray(Iclosed));

%% SEGMENT OPEN LUMEN ONCE
fprintf('\n=== OPEN LUMEN SEGMENTATION ===\n');
[BWopen, qOpen] = segmentOneImageForensic(Iopen, roi, debugOutDir, ...
    'H5_W50_ML1_R3_OP', samCheckpointFile, forceRerunSegmentation);

fprintf('Open status: %s\n', string(qOpen.status));
fprintf('Open valid:  %d\n', qOpen.lumen_valid);

if ~qOpen.lumen_valid || ~any(BWopen(:))
    error('Open segmentation failed. Cannot continue.');
end

BWopen = largestComponent_local(BWopen);

%% REGISTER CLOSED TO OPEN
fprintf('\n=== REGISTRATION ===\n');
if doRegistration
    [IclosedReg, tform] = registerClosedToOpen_local(Iopen, Iclosed, roi);
    IclosedGrayReg = im2double(rgb2gray(IclosedReg));
    fprintf('Translation dx = %.3f px\n', tform.T(3,1));
    fprintf('Translation dy = %.3f px\n', tform.T(3,2));
else
    IclosedReg = Iclosed;
    IclosedGrayReg = IclosedGray;
    fprintf('Registration disabled.\n');
end

%% SEGMENT CLOSED IMAGE TOO (ONLY FOR METHOD A COMPARISON)
fprintf('\n=== CLOSED LUMEN SEGMENTATION (FOR METHOD A ONLY) ===\n');
[BWclosed, qClosed] = segmentOneImageForensic(IclosedReg, roi, debugOutDir, ...
    'H5_W50_ML1_R3_CL', samCheckpointFile, forceRerunSegmentation);

fprintf('Closed status: %s\n', string(qClosed.status));
fprintf('Closed valid:  %d\n', qClosed.lumen_valid);

if any(BWclosed(:))
    BWclosed = largestComponent_local(BWclosed);
else
    BWclosed = false(size(BWopen));
end

%% BASIC OPEN-LUMEN GEOMETRY
geom = computeOpenGeometry(BWopen);

fprintf('\n=== OPEN LUMEN GEOMETRY ===\n');
fprintf('Open area (px):    %.0f\n', geom.openArea_px);
fprintf('Open height (px):  %.3f\n', geom.openHeight_px);
fprintf('Open columns:      %d\n', numel(geom.validCols));

%% DEFINE ROI = OPEN LUMEN
ROI = BWopen;

%% ------------------------------------------------------------------------
% METHOD A: CLOSED-MASK OVERLAP (CURRENT APPROACH)
% -------------------------------------------------------------------------
BWclosedInOpen = BWclosed & BWopen;
resA = computeMethodA(BWopen, BWclosedInOpen);

%% ------------------------------------------------------------------------
% METHOD B: CONTINUOUS INTENSITY-LOSS MAP INSIDE OPEN ROI
% Avoid hard threshold in the actual metric.
%
% lossMap = max(0, Iopen - IclosedReg) normalized by the brightest open
% lumen intensity, restricted to BWopen.
% -------------------------------------------------------------------------
resB = computeMethodB_ContinuousLoss(IopenGray, IclosedGrayReg, BWopen, geom, vizLevelFrac);

%% ------------------------------------------------------------------------
% METHOD C: GRAYSCALE IMFILL-HOLE METHOD INSIDE OPEN ROI
%
% Build a cropped ROI box around BWopen. Inside that box:
%   - set perimeter white
%   - set pixels outside BWopen to white
%   - imfill holes on grayscale-inverted cavity representation
%   - obstruction is the hole-like dark intrusion inside BWopen
%
% Quantification again is weighted, not hard-thresholded.
% -------------------------------------------------------------------------
resC = computeMethodC_ImfillGray(IclosedGrayReg, BWopen, geom, vizLevelFrac);

%% PRINT SUMMARY
fprintf('\n============================================================\n');
fprintf('COMPARISON OF CLOSURE METHODS\n');
fprintf('============================================================\n');

printMethodSummary('A) Closed-mask overlap', resA);
printMethodSummary('B) Continuous intensity-loss', resB);
printMethodSummary('C) Grayscale imfill-hole', resC);

%% FIGURE 1: RAW IMAGES
fig1 = figure('Name','Raw images','Position',[50 50 1400 700],'Color','w');
subplot(1,2,1);
imshow(Iopen);
title('Open image');

subplot(1,2,2);
imshow(IclosedReg);
title('Closed image (registered)');

saveas(fig1, fullfile(debugOutDir, '01_raw_images.png'));

%% FIGURE 2: OPEN / CLOSED MASKS
fig2 = figure('Name','Masks','Position',[50 50 1600 700],'Color','w');

subplot(1,3,1);
imshow(BWopen);
title('Open lumen mask');

subplot(1,3,2);
imshow(BWclosed);
title('Closed lumen mask (Method A input)');

subplot(1,3,3);
imshow(BWclosedInOpen);
title('Residual lumen in closed state (Method A)');

saveas(fig2, fullfile(debugOutDir, '02_masks_methodA.png'));

%% FIGURE 3: HEATMAPS OF CONTINUOUS MAPS
fig3 = figure('Name','Continuous maps','Position',[50 50 1800 700],'Color','w');

subplot(1,3,1);
imagesc(resB.lossMap);
axis image off;
colorbar;
title('Method B: intensity-loss map');

subplot(1,3,2);
imagesc(resC.holeStrengthMap);
axis image off;
colorbar;
title('Method C: imfill-hole map');

subplot(1,3,3);
imagesc(resB.lossMap - resC.holeStrengthMap);
axis image off;
colorbar;
title('B - C map difference');

saveas(fig3, fullfile(debugOutDir, '03_continuous_heatmaps.png'));

%% FIGURE 4: OVERLAY COMPARISON
fig4 = figure('Name','Overlay comparison','Position',[50 50 1900 900],'Color','w');

subplot(2,2,1);
imshow(IclosedReg);
hold on;
visboundaries(BWopen, 'Color', 'g', 'LineWidth', 0.8);
if any(resA.obstructionMaskDisplay(:))
    visboundaries(resA.obstructionMaskDisplay, 'Color', 'r', 'LineWidth', 1.0);
end
title(sprintf('A: overlap | Obs = %.1f%% | Reach = %.1f%%', ...
    resA.areaObstructed_pct, resA.reach_pct));
hold off;

subplot(2,2,2);
imshow(IclosedReg);
hold on;
visboundaries(BWopen, 'Color', 'g', 'LineWidth', 0.8);
if any(resB.obstructionMaskDisplay(:))
    visboundaries(resB.obstructionMaskDisplay, 'Color', 'r', 'LineWidth', 1.0);
end
title(sprintf('B: continuous loss | Obs = %.1f%% | Reach = %.1f%%', ...
    resB.areaObstructed_pct, resB.reach_pct));
hold off;

subplot(2,2,3);
imshow(IclosedReg);
hold on;
visboundaries(BWopen, 'Color', 'g', 'LineWidth', 0.8);
if any(resC.obstructionMaskDisplay(:))
    visboundaries(resC.obstructionMaskDisplay, 'Color', 'r', 'LineWidth', 1.0);
end
title(sprintf('C: imfill-hole | Obs = %.1f%% | Reach = %.1f%%', ...
    resC.areaObstructed_pct, resC.reach_pct));
hold off;

subplot(2,2,4);
imshow(Iopen);
hold on;
visboundaries(BWopen, 'Color', 'g', 'LineWidth', 0.8);
title('Reference open lumen ROI');
hold off;

saveas(fig4, fullfile(debugOutDir, '04_overlay_comparison.png'));

%% FIGURE 5: COLUMN-WISE REACH CURVES
fig5 = figure('Name','Reach curves','Position',[50 50 1600 700],'Color','w');
plot(resA.reachCurve_px, 'r-', 'LineWidth', 1.5); hold on;
plot(resB.reachCurve_px, 'b-', 'LineWidth', 1.5);
plot(resC.reachCurve_px, 'm-', 'LineWidth', 1.5);
grid on;
xlabel('Column index');
ylabel('Reach (px)');
title('Column-wise reach comparison');
legend({'A overlap','B intensity-loss','C imfill-hole'}, 'Location', 'best');
hold off;

saveas(fig5, fullfile(debugOutDir, '05_reach_curves.png'));

%% FIGURE 6: BINARY DISPLAY MASK COMPARISON
fig6 = figure('Name','Display masks','Position',[50 50 1800 700],'Color','w');

subplot(1,3,1);
imshow(resA.obstructionMaskDisplay);
title('A display obstruction mask');

subplot(1,3,2);
imshow(resB.obstructionMaskDisplay);
title('B display obstruction mask');

subplot(1,3,3);
imshow(resC.obstructionMaskDisplay);
title('C display obstruction mask');

saveas(fig6, fullfile(debugOutDir, '06_display_masks.png'));

fprintf('\nSaved comparison debug outputs to:\n%s\n', debugOutDir);

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================

function printMethodSummary(nameStr, res)
    fprintf('\n%s\n', nameStr);
    fprintf('  %% obstruction: %.3f\n', res.areaObstructed_pct);
    fprintf('  %% reach:       %.3f\n', res.reach_pct);
    fprintf('  open area px:   %.0f\n', res.openArea_px);
    fprintf('  obstructed px*: %.3f\n', res.obstructedAreaEquivalent_px);
    fprintf('  max reach px:   %.3f\n', res.maxReach_px);
    fprintf('  notes:          %s\n', res.notes);
end

function geom = computeOpenGeometry(BWopen)

    BWopen = logical(BWopen);
    [~, W] = size(BWopen);

    openTop = nan(1, W);
    openBottom = nan(1, W);

    for c = 1:W
        rows = find(BWopen(:, c));
        if ~isempty(rows)
            openTop(c) = rows(1);
            openBottom(c) = rows(end);
        end
    end

    validCols = find(~isnan(openTop) & ~isnan(openBottom));
    if isempty(validCols)
        error('Could not extract open-lumen geometry.');
    end

    openHeightByCol = openBottom(validCols) - openTop(validCols) + 1;
    openHeight_px = median(openHeightByCol);
    openArea_px = nnz(BWopen);

    geom = struct();
    geom.openTop = openTop;
    geom.openBottom = openBottom;
    geom.validCols = validCols;
    geom.openHeight_px = openHeight_px;
    geom.openArea_px = openArea_px;
end

function res = computeMethodA(BWopen, BWclosedInOpen)

    geom = computeOpenGeometry(BWopen);

    openArea = geom.openArea_px;
    closedArea = nnz(BWclosedInOpen);

    areaObstructed_pct = 100 * (openArea - closedArea) / openArea;

    closedTop = nan(size(geom.openTop));
    [~, W] = size(BWopen);
    for c = 1:W
        rows = find(BWclosedInOpen(:, c));
        if ~isempty(rows)
            closedTop(c) = rows(1);
        end
    end

    reachCurve = nan(1, W);
    commonCols = find(~isnan(geom.openTop) & ~isnan(closedTop));
    reachCurve(commonCols) = max(0, closedTop(commonCols) - geom.openTop(commonCols));

    if closedArea == 0
        maxReach_px = geom.openHeight_px;
        reach_pct = 100;
    else
        validReach = find(~isnan(reachCurve));
        if isempty(validReach)
            maxReach_px = geom.openHeight_px;
            reach_pct = 100;
        else
            maxReach_px = max(reachCurve(validReach));
            reach_pct = 100 * maxReach_px / geom.openHeight_px;
        end
    end

    obstructionMaskDisplay = BWopen & ~BWclosedInOpen;

    res = struct();
    res.areaObstructed_pct = areaObstructed_pct;
    res.reach_pct = reach_pct;
    res.maxReach_px = maxReach_px;
    res.reachCurve_px = reachCurve;
    res.openArea_px = openArea;
    res.obstructedAreaEquivalent_px = openArea - closedArea;
    res.obstructionMaskDisplay = obstructionMaskDisplay;
    res.notes = 'Current overlap-based method.';
end

function res = computeMethodB_ContinuousLoss(IopenGray, IclosedGrayReg, BWopen, geom, vizLevelFrac)

    % Normalize intensities globally to [0,1] already assumed from im2double.
    % Positive loss means lumen got darker in the closed image.
    rawLoss = max(0, IopenGray - IclosedGrayReg);

    lossMap = zeros(size(IopenGray));
    lossMap(BWopen) = rawLoss(BWopen);

    % Normalize only inside open lumen ROI to avoid arbitrary raw threshold.
    roiVals = lossMap(BWopen);
    if isempty(roiVals) || max(roiVals) <= 0
        lossMapNorm = zeros(size(lossMap));
    else
        lossMapNorm = zeros(size(lossMap));
        lossMapNorm(BWopen) = roiVals / max(roiVals);
    end

    % Weighted obstruction fraction: mean normalized loss inside ROI
    weightedObstruction = mean(lossMapNorm(BWopen));
    areaObstructed_pct = 100 * weightedObstruction;

    % Weighted reach:
    % for each column, compute weighted average depth from openTop,
    % using lossMapNorm as weights inside that column.
    [H, W] = size(BWopen); %#ok<ASGLU>
    reachCurve = nan(1, W);

    for c = geom.validCols
        rows = find(BWopen(:, c));
        if isempty(rows), continue; end

        w = lossMapNorm(rows, c);
        if sum(w) <= 0
            reachCurve(c) = 0;
        else
            depths = rows - geom.openTop(c);
            reachCurve(c) = sum(w .* depths) / sum(w);
        end
    end

    maxReach_px = max(reachCurve(geom.validCols));
    if isempty(maxReach_px) || isnan(maxReach_px)
        maxReach_px = 0;
    end
    reach_pct = 100 * maxReach_px / geom.openHeight_px;

    % Display-only binary mask from self-scaled contour level
    % This is for red outline only, not the reported metric.
    obstructionMaskDisplay = false(size(BWopen));
    if any(lossMapNorm(BWopen) > 0)
        obstructionMaskDisplay = BWopen & (lossMapNorm >= vizLevelFrac * max(lossMapNorm(:)));
    end

    res = struct();
    res.lossMap = lossMapNorm;
    res.areaObstructed_pct = areaObstructed_pct;
    res.reach_pct = reach_pct;
    res.maxReach_px = maxReach_px;
    res.reachCurve_px = reachCurve;
    res.openArea_px = geom.openArea_px;
    res.obstructedAreaEquivalent_px = weightedObstruction * geom.openArea_px;
    res.obstructionMaskDisplay = obstructionMaskDisplay;
    res.notes = 'Continuous intensity-loss inside fixed open-lumen ROI.';
end

function [BW, q] = segmentOneImageForensic(I, roi, debugOutDir, baseName, samCheckpointFile, forceRerunSegmentation)

    cacheFile = fullfile(debugOutDir, [baseName '_forensic_seg.mat']);

    if ~forceRerunSegmentation && exist(cacheFile, 'file')
        S = load(cacheFile, 'BW', 'q');
        BW = S.BW;
        q  = S.q;
        fprintf('Loaded cached forensic segmentation for %s\n', baseName);
        return;
    end

    BW = false(size(I,1), size(I,2));
    q = struct();
    q.status = 'unknown';
    q.lumen_valid = false;

    useSAM = true;
    if isempty(samCheckpointFile) || ~exist(samCheckpointFile, 'file')
        useSAM = false;
    end

    if useSAM
        try
            [BW, q] = segmentLumenSAM2(I, roi, debugOutDir, baseName);
        catch ME
            warning('SAM failed for %s: %s', baseName, ME.message);
            q.status = ['SAM_error: ' ME.message];
            q.lumen_valid = false;
            BW = false(size(I,1), size(I,2));
        end
    end

    if ~q.lumen_valid || ~any(BW(:))
        fprintf('Falling back for %s\n', baseName);
        [BW, q] = segmentLumenFallbackCentered_local(I, roi, debugOutDir, baseName);
    end

    save(cacheFile, 'BW', 'q', '-v7.3');
end

function [BWlumen, quality] = segmentLumenFallbackCentered_local(I, roi, debugFolder, baseName)

    quality = struct();
    quality.status           = 'fallback';
    quality.lumen_valid      = false;
    quality.confidence       = NaN;
    quality.polarity         = 'bright';
    quality.score_gray       = NaN;
    quality.score_inv        = NaN;
    quality.imfill_score     = NaN;
    quality.is_textured      = false;
    quality.num_masks        = NaN;
    quality.rejection_reason = '';
    quality.lumen_area_px    = 0;
    quality.anchor_area_px   = NaN;
    quality.texture_ratio    = NaN;
    quality.texture_contrast = NaN;
    quality.lumen_density    = NaN;
    quality.anchor_density   = NaN;

    if nargin < 3, debugFolder = ''; end
    if nargin < 4, baseName = 'image'; end

    Irgb = ensureRGB_local(I);
    [H, W, ~] = size(Irgb);
    Igray = im2double(rgb2gray(Irgb));

    h_roi   = round(H * roi.bottomFrac);
    h_valid = H - h_roi;

    Ic = Igray(1:h_valid, :);
    Ic_f = imgaussfilt(Ic, 1.2);

    T = adaptthresh(Ic_f, 0.48, 'ForegroundPolarity', 'bright');
    BW = imbinarize(Ic_f, T);

    BW = imopen(BW, strel('disk', 2));
    BW = imclose(BW, strel('disk', 4));
    BW = imfill(BW, 'holes');
    BW = bwareaopen(BW, 300);

    CC = bwconncomp(BW, 8);
    BWkeep = false(size(BW));

    if CC.NumObjects > 0
        stats = regionprops(CC, 'Area', 'Centroid', 'BoundingBox');
        centerX = W / 2;
        centerY = h_valid / 2;

        score = -inf(1, numel(stats));
        for k = 1:numel(stats)
            c = stats(k).Centroid;
            d = hypot(c(1) - centerX, c(2) - centerY);
            a = stats(k).Area;
            bb = stats(k).BoundingBox;
            aspect = bb(3) / max(bb(4), eps);

            score(k) = 2.0 * log(max(a,1)) - 0.015 * d + 0.4 * min(aspect, 6);
        end

        [~, idx] = max(score);
        BWkeep(CC.PixelIdxList{idx}) = true;
    end

    BWlumen = false(H, W);
    BWlumen(1:h_valid, :) = BWkeep;

    quality.lumen_valid   = any(BWkeep(:));
    quality.lumen_area_px = nnz(BWkeep);

    if ~quality.lumen_valid
        quality.status = 'fallback_failed';
        quality.rejection_reason = 'Fallback lumen segmentation found no valid region.';
    end

    if ~isempty(debugFolder) && exist(debugFolder, 'dir')
        fig = figure('Visible', 'off', 'Position', [100 100 1200 400]);
        subplot(1,3,1); imshow(Ic, []); title('Cropped gray');
        subplot(1,3,2); imshow(BWkeep); title('Fallback lumen mask');
        subplot(1,3,3); imshow(Irgb); hold on;
        if any(BWlumen(:))
            visboundaries(BWlumen, 'Color', 'r');
        end
        hold off;
        title('Overlay');
        saveas(fig, fullfile(debugFolder, [baseName '_fallback_debug.png']));
        close(fig);
    end
end

function [IclosedReg, tform] = registerClosedToOpen_local(IopenRGB, IclosedRGB, roi)

    IopenGray = rgb2gray(ensureRGB_local(IopenRGB));
    IclosedGray = rgb2gray(ensureRGB_local(IclosedRGB));

    H = size(IopenGray, 1);
    hROI = round(H * roi.bottomFrac);
    hValid = H - hROI;

    fixed = IopenGray(1:hValid, :);
    moving = IclosedGray(1:hValid, :);

    fixed = im2single(fixed);
    moving = im2single(moving);

    try
        tformEstimate = imregcorr(moving, fixed, 'translation');
    catch
        warning('imregcorr failed. Proceeding without registration.');
        tformEstimate = affine2d(eye(3));
    end

    Rfixed = imref2d(size(IopenGray));
    IclosedReg = imwarp(IclosedRGB, tformEstimate, 'OutputView', Rfixed);

    tform = tformEstimate;
end

function BW = largestComponent_local(BW)
    BW = logical(BW);
    CC = bwconncomp(BW, 8);
    if CC.NumObjects == 0
        BW = false(size(BW));
        return;
    end
    numPixels = cellfun(@numel, CC.PixelIdxList);
    [~, idx] = max(numPixels);
    BW2 = false(size(BW));
    BW2(CC.PixelIdxList{idx}) = true;
    BW = BW2;
end

function Irgb = ensureRGB_local(I)
    if ndims(I) == 2
        Irgb = repmat(I, [1 1 3]);
    else
        Irgb = I;
    end
end