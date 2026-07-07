clear all
clc
close all

% =========================================================================
% PAIRWISE VALVE CLOSURE ANALYSIS USING EXISTING SAM LUMEN SEGMENTATION
%
% INPUTS:
%   - open image
%   - closed image
%   - your existing segmentLumenSAM2.m on MATLAB path
%
% OUTPUTS:
%   - % area obstructed
%   - % membrane downward reach relative to open lumen height
%   - debug figure
% =========================================================================

%% USER INPUTS
openFile   = 'open.jpeg';
closedFile = 'closed.jpeg';

addpath('C:\Users\rvoronov\Dropbox\DRY_LAB\3D_PRINTING_IMAGE_ANALYSIS\SAG_ANALYSIS_SAM_SEGMENTATION'); %folder for existing dependencies

% Same style of ROI usage as your existing code
roi.bottomFrac = 0.09;
roi.leftFrac   = 0.00;
roi.widthFrac  = 1.00;
roi.heightFrac = 0.09;

debugFolder = '/mnt/data/debug_pairwise_closure';
if ~exist(debugFolder, 'dir')
    mkdir(debugFolder);
end

baseName = 'open_vs_closed';

% If you already know mmPerPx, set it here. Otherwise leave NaN.
% This is only needed for physical units; the requested percentages do not need it.
mmPerPx = NaN;

% Registration settings
doRegistration = true;

%% READ IMAGES
Iopen   = imread(openFile);
Iclosed = imread(closedFile);

IopenRGB   = ensureRGB_local(Iopen);
IclosedRGB = ensureRGB_local(Iclosed);

%% SEGMENT OPEN LUMEN WITH YOUR EXISTING SAM PIPELINE
[BWopen, qOpen] = segmentLumenSAM2(IopenRGB, roi, debugFolder, [baseName '_open']);

if ~qOpen.lumen_valid || ~any(BWopen(:))
    error('Open lumen segmentation failed. This image must segment successfully to define the reference lumen.');
end

%% OPTIONAL REGISTRATION OF CLOSED IMAGE TO OPEN IMAGE
% Register only on useful region (excluding bottom scale-bar band), then warp full image.
if doRegistration
    [IclosedReg, tform] = registerClosedToOpen(IopenRGB, IclosedRGB, roi);
else
    IclosedReg = IclosedRGB;
    tform = affine2d(eye(3));
end

%% SEGMENT CLOSED LUMEN AFTER REGISTRATION
[BWclosedReg, qClosed] = segmentLumenSAM2(IclosedReg, roi, debugFolder, [baseName '_closed_reg']);

%% KEEP ONLY MAIN COMPONENTS
BWopen = largestComponent_local(BWopen);

if any(BWclosedReg(:))
    BWclosedReg = largestComponent_local(BWclosedReg);
end

%% FORCE CLOSED LUMEN TO LIVE WITHIN OPEN LUMEN FOOTPRINT
% This suppresses mis-segmented regions outside the original lumen.
BWclosedInOpen = BWclosedReg & BWopen;

%% COMPUTE METRICS
results = computeClosureMetrics(BWopen, BWclosedInOpen, qClosed);

%% DISPLAY RESULTS
fprintf('\n=== VALVE CLOSURE RESULTS ===\n');
fprintf('Open lumen area (px):              %.0f\n', results.openArea_px);
fprintf('Closed residual lumen area (px):   %.0f\n', results.closedArea_px);
fprintf('Area obstructed (%%):               %.2f\n', results.areaObstructed_pct);
fprintf('Open lumen height (px):            %.2f\n', results.openHeight_px);
fprintf('Max membrane downward reach (px):  %.2f\n', results.maxDownwardReach_px);
fprintf('Membrane downward reach (%%):       %.2f\n', results.maxDownwardReach_pctOfOpenHeight);

if ~isnan(mmPerPx)
    fprintf('Max membrane downward reach (mm):  %.4f\n', results.maxDownwardReach_px * mmPerPx);
end

%% SAVE DEBUG FIGURE
fig = figure('Visible','on','Position',[50 50 1600 900]);

subplot(2,3,1);
imshow(IopenRGB);
title('Open image');

subplot(2,3,2);
imshow(BWopen);
title('Open lumen mask');

subplot(2,3,3);
imshow(IopenRGB);
hold on;
visboundaries(BWopen, 'Color', 'g', 'LineWidth', 0.8);
title('Open overlay');
hold off;

subplot(2,3,4);
imshow(IclosedReg);
title('Closed image (registered)');

subplot(2,3,5);
imshow(BWclosedInOpen);
title('Closed residual lumen mask');

subplot(2,3,6);
imshow(IclosedReg);
hold on;
visboundaries(BWopen, 'Color', 'g', 'LineWidth', 0.8);
if any(BWclosedInOpen(:))
    visboundaries(BWclosedInOpen, 'Color', 'r', 'LineWidth', 0.8);
end

if ~isempty(results.validCols)
    x = results.validCols;
    plot(x, results.openTop(x), 'g-', 'LineWidth', 1.2);
    plot(x, results.openBottom(x), 'g--', 'LineWidth', 1.0);

    if any(~isnan(results.closedTop))
        xc = find(~isnan(results.closedTop));
        plot(xc, results.closedTop(xc), 'r-', 'LineWidth', 1.4);
    end

    if ~isnan(results.xAtMaxReach)
        plot(results.xAtMaxReach, results.yClosedAtMaxReach, 'ro', ...
            'MarkerSize', 8, 'LineWidth', 1.5);
        plot([results.xAtMaxReach results.xAtMaxReach], ...
             [results.yOpenTopAtMaxReach results.yClosedAtMaxReach], ...
             'y-', 'LineWidth', 1.5);
    end
end

title(sprintf('Obstructed = %.2f%%, Reach = %.2f%%', ...
    results.areaObstructed_pct, results.maxDownwardReach_pctOfOpenHeight));
hold off;

sgtitle('Pairwise valve closure analysis', 'Interpreter', 'none');

saveas(fig, fullfile(debugFolder, [baseName '_closure_debug.png']));

%% OPTIONAL: SAVE RESULTS STRUCT
save(fullfile(debugFolder, [baseName '_results.mat']), 'results', 'qOpen', 'qClosed', 'tform');

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================


function [IclosedReg, tform] = registerClosedToOpen(IopenRGB, IclosedRGB, roi)

    IopenGray = rgb2gray(IopenRGB);
    IclosedGray = rgb2gray(IclosedRGB);

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