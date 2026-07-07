clear all
clc
close all

% =========================================================================
% BATCH VALVE CLOSURE ANALYSIS
%
% Filename format:
%   Cutouts_H5_W20_ML1_R1_CL.jpg
%   Cutouts_H5_W20_ML1_R1_OP.jpg
%
% Meaning:
%   H  = channel height in layers
%   W  = width in pixels
%   ML = membrane layers
%   R  = replicate number
%   CL = closed image
%   OP = open image
%
% METHOD USED:
%   Method B = continuous intensity-loss inside the fixed open-lumen ROI.
%
% IMPORTANT:
%   - SAM is used ONLY on the OPEN image.
%   - There is NO fallback segmentation.
%   - If open-image SAM fails, the pair is skipped.
%   - Closed image is registered to open, then compared inside BWopen.
% =========================================================================

%% USER INPUTS
% Resolve paths relative to this machine's Dropbox root so the identical
% script runs on the laptop (C:\Users\rvoronov\Dropbox) and on Olympus
% (C:\Users\Professor\Dropbox) without edits.
dropboxRoot = fullfile(getenv('USERPROFILE'), 'Dropbox');
if ~exist(dropboxRoot, 'dir')
    error('Dropbox root not found at %s. Set dropboxRoot manually.', dropboxRoot);
end

inputDir = fullfile(dropboxRoot, 'MANUSCRIPTS', 'micromachines_valve_printing_framework', ...
    'Figures', 'NanoClear', 'Sorted_ConstH5', 'Cutout_ConstH5_Cleaned');

depDir = fullfile(dropboxRoot, 'DRY_LAB', '3D_PRINTING_IMAGE_ANALYSIS', 'SAG_ANALYSIS_SAM_SEGMENTATION');
addpath(depDir);

% Since you said you are fine with a clean rerun:
resumeRun = false;
cleanStartDeletesOldOutputs = true;

closureMethod = 'MethodB_IntensityLoss';
vizLevelFrac = 0.50;   % display-only contour level for debug overlay

% --- Measurement robustness (Fixes A/B/D) ---
mparams.noiseGateAbsMin = 0.05;  % absolute intensity-loss floor (0-1 gray scale)
mparams.noiseGateFactor = 2.0;   % gate = max(AbsMin, Factor * outside-lumen 99th-pctile loss)
mparams.minSignalFrac   = 0.02;  % >=2% of lumen pixels must exceed gate, else "no closure"
mparams.strongFactor    = 2.0;   % "strong core" = loss > strongFactor * gate
mparams.minStrongFrac   = 0.005; % >=0.5% of lumen must be strong-core (kills edge-glow strips)
mparams.centerZoneFrac  = 0.40;  % central span fraction that must contain the deepest point
mparams.edgeTolFrac     = 0.15;  % columns deeper than center by > this*openHeight are artifacts
mparams.frontStrongFrac = 0.5;   % reach front traced only through loss >= this frac of peak (Fix C)
regShiftLimit_px        = 8;     % registration shifts larger than this are rejected (Fix D)

% Explicit checkpoint path
samCheckpointFile = fullfile(depDir, 'sam_vit_b_01ec64.pth');

% ROI convention consistent with earlier workflow
roi.bottomFrac = 0.09;
roi.leftFrac   = 0.00;
roi.widthFrac  = 1.00;
roi.heightFrac = 0.09;

doRegistration   = true;
saveDebugFigures = true;    % per-pair Method-B debug PNG (needed to hunt bad measurements)
saveSamDebugFigures = false; % SAM open-image debug figs are ~10/pair and dominate runtime; keep off for production runs
autosaveEveryN   = 5;

% image extensions
exts = {'*.jpg','*.jpeg','*.png','*.tif','*.tiff','*.bmp'};

% output folders
outputDir       = fullfile(inputDir, 'VALVE_CLOSURE_RESULTS');
debugDir        = fullfile(outputDir, 'debug');
samDebugDir     = fullfile(debugDir, 'sam_Debug');
pairDebugDir    = fullfile(debugDir, 'pair_Debug');
pairCacheDir    = fullfile(outputDir, 'cache_pairs');
backupDir       = fullfile(outputDir, 'backup');
checkpointDir   = fullfile(outputDir, 'checkpoints');

csvFile             = fullfile(outputDir, 'valve_closure_pairwise_results.csv');
matFile             = fullfile(outputDir, 'valve_closure_pairwise_results.mat');
statsFile           = fullfile(outputDir, 'valve_closure_group_stats.csv');
checkpointTableFile = fullfile(checkpointDir, 'Tresults_checkpoint.mat');

%% SETUP FOLDERS
dirsToMake = {outputDir, debugDir, samDebugDir, pairDebugDir, pairCacheDir, backupDir, checkpointDir};

if ~resumeRun && cleanStartDeletesOldOutputs
    for d = 1:numel(dirsToMake)
        if exist(dirsToMake{d}, 'dir')
            try
                rmdir(dirsToMake{d}, 's');
            catch
            end
        end
    end
end

for d = 1:numel(dirsToMake)
    if ~exist(dirsToMake{d}, 'dir')
        mkdir(dirsToMake{d});
    end
end

% SAM open-mask cache: lives OUTSIDE outputDir so clean starts never wipe it.
% Reruns then skip SAM inference entirely (the expensive step) and only redo
% the cheap Method-B math. Delete this folder manually to force re-segmentation
% (e.g., after changing the SAM model or the roi).
samMaskCacheDir = fullfile(inputDir, 'SAM_MASK_CACHE');
if ~exist(samMaskCacheDir, 'dir')
    mkdir(samMaskCacheDir);
end

%% CHECKPOINT INFO
if exist(samCheckpointFile, 'file')
    fprintf('Checkpoint file exists: %s\n', samCheckpointFile);
else
    fprintf('Checkpoint file NOT found at explicit path: %s\n', samCheckpointFile);
    fprintf('SAM may still work if segmentLumenSAM2 finds it by its own internal logic.\n');
end

%% FIND FILES
files = [];
for k = 1:numel(exts)
    files = [files; dir(fullfile(inputDir, exts{k}))]; %#ok<AGROW>
end

if isempty(files)
    error('No image files found in inputDir.');
end

fileNames = {files.name}';

%% PARSE FILENAMES
parsed = struct( ...
    'File', [], ...
    'FullPath', [], ...
    'Height_layers', [], ...
    'Width_px', [], ...
    'MembraneLayers', [], ...
    'Replicate', [], ...
    'State', [] );

P = repmat(parsed, numel(fileNames), 1);

for i = 1:numel(fileNames)
    thisName = fileNames{i};
    thisPath = fullfile(files(i).folder, files(i).name);

    meta = parseValveFilename(thisName);

    P(i).File            = thisName;
    P(i).FullPath        = thisPath;
    P(i).Height_layers   = meta.H;
    P(i).Width_px        = meta.W;
    P(i).MembraneLayers  = meta.ML;
    P(i).Replicate       = meta.R;
    P(i).State           = meta.State;
end

validRows = ~isnan([P.Height_layers])' & ...
    ~isnan([P.Width_px])' & ...
    ~isnan([P.MembraneLayers])' & ...
    ~isnan([P.Replicate])' & ...
    ~cellfun(@isempty, {P.State}');

P = P(validRows);

if isempty(P)
    error('No files matched expected naming convention.');
end

%% BUILD FILE TABLE
Tfiles = struct2table(P);

%% SPLIT OPEN / CLOSED
isOpen   = strcmpi(Tfiles.State, 'OP');
isClosed = strcmpi(Tfiles.State, 'CL');

Topen = Tfiles(isOpen, :);
Tcl   = Tfiles(isClosed, :);

keyVars = {'Height_layers','Width_px','MembraneLayers','Replicate'};

TopenSmall = Topen(:, [keyVars, {'File','FullPath'}]);
TopenSmall.Properties.VariableNames{'File'} = 'OpenFile';
TopenSmall.Properties.VariableNames{'FullPath'} = 'OpenPath';

TclSmall = Tcl(:, [keyVars, {'File','FullPath'}]);
TclSmall.Properties.VariableNames{'File'} = 'ClosedFile';
TclSmall.Properties.VariableNames{'FullPath'} = 'ClosedPath';

Tpairs = outerjoin(TopenSmall, TclSmall, ...
    'Keys', keyVars, ...
    'MergeKeys', true, ...
    'Type', 'full');

Tpairs = sortrows(Tpairs, {'Height_layers','Width_px','MembraneLayers','Replicate'});

hasOpen   = ~cellfun(@isempty, Tpairs.OpenPath);
hasClosed = ~cellfun(@isempty, Tpairs.ClosedPath);

Tpairs.PairStatus = strings(height(Tpairs),1);
Tpairs.PairStatus(hasOpen & hasClosed)   = "complete";
Tpairs.PairStatus(hasOpen & ~hasClosed)  = "open_only";
Tpairs.PairStatus(~hasOpen & hasClosed)  = "closed_only";

fprintf('Found %d geometry/replicate rows total.\n', height(Tpairs));
fprintf('  Complete pairs: %d\n', sum(Tpairs.PairStatus == "complete"));
fprintf('  Open only:      %d\n', sum(Tpairs.PairStatus == "open_only"));
fprintf('  Closed only:    %d\n', sum(Tpairs.PairStatus == "closed_only"));

%% PREALLOCATE RESULTS
N = height(Tpairs);

OpenSegStatus             = repmat("not_run", N, 1);
ClosedSegStatus           = repmat("not_run", N, 1);
OpenSegValid              = false(N,1);
ClosedSegValid            = false(N,1);

OpenArea_px               = nan(N,1);
ClosedResidualArea_px     = nan(N,1);
AreaObstructed_pct        = nan(N,1);

OpenHeight_px             = nan(N,1);
MaxDownwardReach_px       = nan(N,1);
MaxDownwardReach_pct      = nan(N,1);

Registration_dx_px        = nan(N,1);
Registration_dy_px        = nan(N,1);

Notes                     = repmat("", N, 1);

% Open-image segmentation failure summary tracking
OpenSegFailureCount       = 0;
OpenSegFailureTags        = strings(0,1);
OpenSegFailureReasons     = strings(0,1);

%% RESUME GLOBAL CHECKPOINT TABLE IF REQUESTED
if resumeRun && exist(checkpointTableFile, 'file')
    fprintf('Loading checkpoint table: %s\n', checkpointTableFile);
    Scheck = load(checkpointTableFile, 'Tpartial');
    if isfield(Scheck, 'Tpartial')
        Tpartial = Scheck.Tpartial;

        mapN = min(height(Tpartial), N);

        flds = {'OpenSegStatus','ClosedSegStatus','OpenSegValid','ClosedSegValid', ...
            'OpenArea_px','ClosedResidualArea_px','AreaObstructed_pct', ...
            'OpenHeight_px','MaxDownwardReach_px','MaxDownwardReach_pct', ...
            'Registration_dx_px','Registration_dy_px','Notes'};

        for k = 1:numel(flds)
            if ismember(flds{k}, Tpartial.Properties.VariableNames)
                eval([flds{k} '(1:mapN) = Tpartial.' flds{k} '(1:mapN);']);
            end
        end
    end
end

%% MAIN LOOP
% Passing an empty debug folder disables segmentLumenSAM2's ~10 per-image
% debug figures (the dominant runtime cost per the profiler).
if saveSamDebugFigures
    samDebugArg = samDebugDir;
else
    samDebugArg = '';
end

for i = 1:N

    if Notes(i) == "OK" || Notes(i) == "OK_parabola" || Notes(i) == "OK_zero_reach" || ...
            Notes(i) == "OK_reach_geom_fallback" || contains(Notes(i), "Incomplete pair")
        fprintf('\n[%d/%d] Skipping cached/completed row.\n', i, N);
        continue;
    end

    fprintf('\n[%d/%d] H=%d W=%d ML=%d R=%d | %s\n', ...
        i, N, ...
        Tpairs.Height_layers(i), ...
        Tpairs.Width_px(i), ...
        Tpairs.MembraneLayers(i), ...
        Tpairs.Replicate(i), ...
        Tpairs.PairStatus(i));

    baseTag = sprintf('H%d_W%d_ML%d_R%d', ...
        Tpairs.Height_layers(i), ...
        Tpairs.Width_px(i), ...
        Tpairs.MembraneLayers(i), ...
        Tpairs.Replicate(i));

    pairCacheFile = fullfile(pairCacheDir, [baseTag '_pairResult.mat']);

    % -------------------------------------------------------------
    % LOAD PAIR CACHE IF PRESENT
    % -------------------------------------------------------------
    if resumeRun && exist(pairCacheFile, 'file')
        try
            Spair = load(pairCacheFile, 'pairResult');
            pr = Spair.pairResult;

            OpenSegStatus(i)         = pr.OpenSegStatus;
            ClosedSegStatus(i)       = pr.ClosedSegStatus;
            OpenSegValid(i)          = pr.OpenSegValid;
            ClosedSegValid(i)        = pr.ClosedSegValid;
            OpenArea_px(i)           = pr.OpenArea_px;
            ClosedResidualArea_px(i) = pr.ClosedResidualArea_px;
            AreaObstructed_pct(i)    = pr.AreaObstructed_pct;
            OpenHeight_px(i)         = pr.OpenHeight_px;
            MaxDownwardReach_px(i)   = pr.MaxDownwardReach_px;
            MaxDownwardReach_pct(i)  = pr.MaxDownwardReach_pct;
            Registration_dx_px(i)    = pr.Registration_dx_px;
            Registration_dy_px(i)    = pr.Registration_dy_px;
            Notes(i)                 = pr.Notes;

            fprintf('  Loaded cached pair result.\n');
            continue
        catch
        end
    end

    % -------------------------------------------------------------
    % INCOMPLETE PAIRS = NO FLEXING = ZERO CLOSURE
    % -------------------------------------------------------------
    if Tpairs.PairStatus(i) ~= "complete"
        OpenSegStatus(i)           = "not_run";
        ClosedSegStatus(i)         = "not_run";
        OpenSegValid(i)            = false;
        ClosedSegValid(i)          = false;
        OpenArea_px(i)             = NaN;
        ClosedResidualArea_px(i)   = NaN;
        AreaObstructed_pct(i)      = 0;
        OpenHeight_px(i)           = NaN;
        MaxDownwardReach_px(i)     = 0;
        MaxDownwardReach_pct(i)    = 0;
        Registration_dx_px(i)      = 0;
        Registration_dy_px(i)      = 0;
        Notes(i)                   = "Incomplete pair -> assumed no closure";

        pairResult = packPairResult( ...
            OpenSegStatus(i), ClosedSegStatus(i), OpenSegValid(i), ClosedSegValid(i), ...
            OpenArea_px(i), ClosedResidualArea_px(i), AreaObstructed_pct(i), ...
            OpenHeight_px(i), MaxDownwardReach_px(i), MaxDownwardReach_pct(i), ...
            Registration_dx_px(i), Registration_dy_px(i), Notes(i));

        save(pairCacheFile, 'pairResult', '-v7.3');
        fprintf('  Incomplete pair assigned zero closure.\n');
        continue
    end

    openPath   = Tpairs.OpenPath{i};
    closedPath = Tpairs.ClosedPath{i};

    try
        Iopen   = imread(openPath);
        Iclosed = imread(closedPath);

        Iopen   = ensureRGB_local(Iopen);
        Iclosed = ensureRGB_local(Iclosed);

        % -------------------------------------------------------------
        % OPEN SEGMENTATION (SAM only; no fallback)
        % Cached masks are reused so threshold/fit iterations skip SAM.
        % -------------------------------------------------------------
        maskCacheFile = fullfile(samMaskCacheDir, [baseTag '_openmask.mat']);
        gotCachedMask = false;
        if exist(maskCacheFile, 'file')
            try
                Smask  = load(maskCacheFile, 'BWopen', 'qOpen');
                BWopen = Smask.BWopen;
                qOpen  = Smask.qOpen;
                gotCachedMask = true;
                fprintf('Loaded cached SAM open mask.\n');
            catch
                gotCachedMask = false;
            end
        end

        if ~gotCachedMask
        fprintf('Running SAM on OPEN image...\n');

        try
            [BWopen, qOpen] = segmentLumenSAM2(Iopen, roi, samDebugArg, [baseTag '_OP']);
            try
                save(maskCacheFile, 'BWopen', 'qOpen', '-v7.3');
            catch
            end
        catch ME
            warning('SAM failed on OPEN image: %s', ME.message);
            fprintf('Skipping pair %s (no open lumen segmentation)\n', baseTag);

            OpenSegFailureCount = OpenSegFailureCount + 1;
            OpenSegFailureTags(end+1,1) = string(baseTag);
            OpenSegFailureReasons(end+1,1) = "SAM_error: " + string(ME.message);

            OpenSegStatus(i)         = "SAM_failed";
            ClosedSegStatus(i)       = "not_attempted";
            OpenSegValid(i)          = false;
            ClosedSegValid(i)        = false;

            OpenArea_px(i)           = NaN;
            ClosedResidualArea_px(i) = NaN;
            AreaObstructed_pct(i)    = NaN;
            OpenHeight_px(i)         = NaN;
            MaxDownwardReach_px(i)   = NaN;
            MaxDownwardReach_pct(i)  = NaN;

            Registration_dx_px(i)    = NaN;
            Registration_dy_px(i)    = NaN;

            Notes(i) = "SAM open segmentation failed";

            pairResult = packPairResult( ...
                OpenSegStatus(i), ClosedSegStatus(i), OpenSegValid(i), ClosedSegValid(i), ...
                OpenArea_px(i), ClosedResidualArea_px(i), AreaObstructed_pct(i), ...
                OpenHeight_px(i), MaxDownwardReach_px(i), MaxDownwardReach_pct(i), ...
                Registration_dx_px(i), Registration_dy_px(i), Notes(i));

            save(pairCacheFile, 'pairResult', '-v7.3');
            continue
        end
        end   % ~gotCachedMask

        if isempty(BWopen) || ~any(BWopen(:)) || ~qOpen.lumen_valid
            warning('SAM returned invalid/empty open lumen mask for %s', baseTag);
            fprintf('Skipping pair %s (invalid open lumen segmentation)\n', baseTag);

            OpenSegFailureCount = OpenSegFailureCount + 1;
            OpenSegFailureTags(end+1,1) = string(baseTag);

            if isfield(qOpen,'status') && ~isempty(qOpen.status)
                thisReason = string(qOpen.status);
            else
                thisReason = "SAM_empty_or_invalid";
            end

            if isfield(qOpen,'rejection_reason') && ~isempty(qOpen.rejection_reason)
                thisReason = thisReason + " | " + string(qOpen.rejection_reason);
            end

            OpenSegFailureReasons(end+1,1) = thisReason;

            OpenSegStatus(i)         = thisReason;
            ClosedSegStatus(i)       = "not_attempted";
            OpenSegValid(i)          = false;
            ClosedSegValid(i)        = false;

            OpenArea_px(i)           = NaN;
            ClosedResidualArea_px(i) = NaN;
            AreaObstructed_pct(i)    = NaN;
            OpenHeight_px(i)         = NaN;
            MaxDownwardReach_px(i)   = NaN;
            MaxDownwardReach_pct(i)  = NaN;

            Registration_dx_px(i)    = NaN;
            Registration_dy_px(i)    = NaN;

            Notes(i) = "SAM open segmentation failed";

            pairResult = packPairResult( ...
                OpenSegStatus(i), ClosedSegStatus(i), OpenSegValid(i), ClosedSegValid(i), ...
                OpenArea_px(i), ClosedResidualArea_px(i), AreaObstructed_pct(i), ...
                OpenHeight_px(i), MaxDownwardReach_px(i), MaxDownwardReach_pct(i), ...
                Registration_dx_px(i), Registration_dy_px(i), Notes(i));

            save(pairCacheFile, 'pairResult', '-v7.3');
            continue
        end

        OpenSegStatus(i) = "SAM_success";
        OpenSegValid(i)  = true;

        BWopen = largestComponent_local(BWopen);

        % -------------------------------------------------------------
        % REGISTER CLOSED TO OPEN
        % -------------------------------------------------------------
        if doRegistration
            [IclosedReg, tform] = registerClosedToOpen(Iopen, Iclosed, roi, regShiftLimit_px);
            Registration_dx_px(i) = tform.T(3,1);
            Registration_dy_px(i) = tform.T(3,2);
        else
            IclosedReg = Iclosed;
            Registration_dx_px(i) = 0;
            Registration_dy_px(i) = 0;
        end

        % -------------------------------------------------------------
        % METHOD B: CLOSED IMAGE IS NOT SEGMENTED
        % Use registered closed intensity inside fixed open-lumen ROI
        % -------------------------------------------------------------
        ClosedSegStatus(i) = "not_used_methodB";
        ClosedSegValid(i)  = false;

        IopenGray      = im2double(rgb2gray(Iopen));
        IclosedGrayReg = im2double(rgb2gray(IclosedReg));

        results = computeClosureMetrics_MethodB(IopenGray, IclosedGrayReg, BWopen, vizLevelFrac, mparams);

        %% ============================================================
        %  QUALITY GATE — decide if this measurement is trustworthy
        %  ============================================================
        [qcPass, qcInfo] = qualityGateDeflection(results, results.openHeight_px, baseTag);

        if qcPass
            % --- Trusted measurement ---
            OpenArea_px(i)           = results.openArea_px;
            ClosedResidualArea_px(i) = results.closedAreaEquivalent_px;
            AreaObstructed_pct(i)    = results.areaObstructed_pct;
            OpenHeight_px(i)         = results.openHeight_px;
            MaxDownwardReach_px(i)   = results.maxReach_px;
            MaxDownwardReach_pct(i)  = results.reach_pct;

            if results.reachMethod == "circular_arc"
                Notes(i) = "OK";
            elseif results.reachMethod == "constrained_parabola"
                Notes(i) = "OK_parabola";
            elseif results.reachMethod == "zero_no_obstruction"
                Notes(i) = "OK_zero_reach";
            else
                Notes(i) = "OK_reach_geom_fallback";
            end

        else
            % --- Untrusted: discard as NaN ---
            OpenArea_px(i)           = results.openArea_px;       % keep geometry
            ClosedResidualArea_px(i) = NaN;
            AreaObstructed_pct(i)    = NaN;
            OpenHeight_px(i)         = results.openHeight_px;     % keep geometry
            MaxDownwardReach_px(i)   = NaN;
            MaxDownwardReach_pct(i)  = NaN;

            Notes(i) = "QC_DISCARD: " + string(qcInfo.verdict);

            fprintf('    DISCARDED: %s\n', qcInfo.verdict);
        end

  
        % -------------------------------------------------------------
        % DEBUG FIGURE (Method B)
        % -------------------------------------------------------------
        if saveDebugFigures

            if qcPass
                qcLabel = 'QC: PASS';
                qcColor = [0 0.5 0];
            else
                qcLabel = sprintf('QC: DISCARDED (%d issues)', qcInfo.nFailures);
                qcColor = [0.8 0 0];
            end

            fig = figure('Visible','off','Position',[50 50 1800 900]);


            subplot(2,3,1);
            imshow(Iopen);
            title('Open image');

            subplot(2,3,2);
            imshow(BWopen);
            title('Open lumen mask');

            subplot(2,3,3);
            imagesc(results.lossMap);
            axis image off;
            colorbar;
            title(sprintf('Loss map (gate=%.3f [p99=%.2f rsig=%.3f], sig=%.1f%%, strong=%.1f%%%s)', ...
                results.noiseGate, results.refP99, results.refSig, ...
                100*results.signalFrac, 100*results.strongFrac, ...
                ternary_local(results.noClosureByGate, ', GATED->0', '')));

            subplot(2,3,4);
            imshow(IclosedReg);
            title('Closed image (registered)');

            % --- Subplot 5: Physical obstruction overlay ---
            subplot(2,3,5);
            imshow(IclosedReg);
            hold on;
            % bwboundaries + plot is much faster than visboundaries
            lumenB = bwboundaries(BWopen, 'noholes');
            for bi = 1:numel(lumenB)
                plot(lumenB{bi}(:,2), lumenB{bi}(:,1), 'g-', 'LineWidth', 0.8);
            end
            if any(results.obstructionMaskCompute(:))
                redLayer = cat(3, ones(size(BWopen)), zeros(size(BWopen)), zeros(size(BWopen)));
                hOv = imshow(redLayer);
                set(hOv, 'AlphaData', 0.35 * double(results.obstructionMaskCompute));
            end
            if any(~isnan(results.frontSmooth))
                vCols = find(~isnan(results.frontSmooth));
                plot(vCols, results.frontSmooth(vCols), 'c-', 'LineWidth', 1.5);
            end
            % Selected fit (arc/parabola) in image coordinates: row = baseline + depth
            if any(~isnan(results.fitY)) && ~isnan(results.baselineY)
                fitCols = find(~isnan(results.fitY));
                plot(fitCols, results.baselineY + results.fitY(fitCols), ...
                    'y-', 'LineWidth', 2.0);
            end
            title(sprintf('Physical obstruction (thresh=%.3f) | yellow = selected fit', ...
                results.computeThresh));
            hold off;


            %% --- Subplot 6: Reach profile with arc + parabola fits ---
            subplot(2,3,6);
            hold on;

            % Full smoothed front (thin black)
            if any(~isnan(results.frontSmooth))
                allCols = find(~isnan(results.frontSmooth));
                plot(allCols, results.frontSmooth(allCols) - results.baselineY, ...
                    'k-', 'LineWidth', 1.0);
            end

            legHandles = [];
            legEntries = {};

            % Trimmed reach curve (blue)
            if any(~isnan(results.reachCurve_px))
                rCols = find(~isnan(results.reachCurve_px));
                hRC = plot(rCols, results.reachCurve_px(rCols), 'b-', 'LineWidth', 2.0);
                legHandles(end+1) = hRC;
                legEntries{end+1} = 'Measured depth';
            end

            % Circular arc fit (red, thick)
            if any(~isnan(results.fitY_arc))
                aCols = find(~isnan(results.fitY_arc));
                hArc = plot(aCols, results.fitY_arc(aCols), 'r-', 'LineWidth', 2.5);
                legHandles(end+1) = hArc;
                legEntries{end+1} = sprintf('Arc (R²=%.3f)', results.arcR2);
            end

            % Constrained parabola fit (magenta, dashed)
            if any(~isnan(results.fitY_parabola))
                pCols = find(~isnan(results.fitY_parabola));
                hPar = plot(pCols, results.fitY_parabola(pCols), 'm--', 'LineWidth', 1.8);
                legHandles(end+1) = hPar;
                legEntries{end+1} = sprintf('Parabola (R²=%.3f)', results.parabola_R2);
            end

            % Primary fit (whatever was selected — shown via fitY in green dots)
            if any(~isnan(results.fitY))
                fCols = find(~isnan(results.fitY));
                hSel = plot(fCols, results.fitY(fCols), 'g:', 'LineWidth', 1.5);
                legHandles(end+1) = hSel;
                legEntries{end+1} = sprintf('Selected: %s', char(results.reachMethod));
            end

            % Reach point marker
            if ~isnan(results.reachX) && ~isnan(results.reachY)
                hVert = plot(results.reachX, results.reachY, ...
                    'ro', 'MarkerSize', 10, 'LineWidth', 2.0, 'MarkerFaceColor', 'r');
                legHandles(end+1) = hVert;
                legEntries{end+1} = sprintf('Reach = %.1f px (%.1f%%)', ...
                    results.maxReach_px, results.reach_pct);
            end

            % Anchor points (corners where membrane is fixed)
            if isfield(results, 'spanLeft') && isfield(results, 'spanRight')
                plot(results.spanLeft, 0, 'ks', 'MarkerSize', 10, 'MarkerFaceColor', 'k');
                plot(results.spanRight, 0, 'ks', 'MarkerSize', 10, 'MarkerFaceColor', 'k');

                yl = ylim;
                hSL = plot([results.spanLeft results.spanLeft], yl, 'g--', 'LineWidth', 1);
                plot([results.spanRight results.spanRight], yl, 'g--', 'LineWidth', 1, ...
                    'HandleVisibility', 'off');
                legHandles(end+1) = hSL;
                legEntries{end+1} = 'Anchors';
            end

            grid on;
            xlabel('Column index');
            ylabel('Reach depth (px)');

            if ~isnan(results.R_fit)
                arcInfo = sprintf(' | R=%.0fpx', results.R_fit);
            else
                arcInfo = '';
            end

            title(sprintf('Obstr=%.1f%% (mask %.1f%%) | Reach=%.1f%% | %s%s', ...
                results.areaObstructed_pct, ...
                results.areaObstructedMask_pct, ...
                results.reach_pct, ...
                char(results.reachMethod), ...
                arcInfo));

            if ~isempty(legHandles)
                legend(legHandles, legEntries, 'Location', 'best', 'FontSize', 7);
            end

            set(gca, 'YDir', 'reverse');
            hold off;

            sgtitle({sprintf('%s | %s', strrep(baseTag,'_','\_'), closureMethod), ...
                qcLabel}, ...
                'Interpreter', 'none', ...
                'Color', qcColor, ...
                'FontSize', 13, ...
                'FontWeight', 'bold');

            % exportgraphics is markedly faster than saveas (avoids the legacy print pipeline).
            % Guarded: a transient PNG write error (e.g. Dropbox briefly locking the
            % file) must not discard an otherwise-successful measurement.
            try
                exportgraphics(fig, fullfile(pairDebugDir,[baseTag '_debug.png']), 'Resolution', 120);
            catch MEfig
                warning('Debug figure save failed for %s (%s). Measurement kept.', ...
                    baseTag, MEfig.message);
            end
            close(fig);

        end

        % -------------------------------------------------------------
        % SAVE PAIR CACHE
        % -------------------------------------------------------------
        pairResult = packPairResult( ...
            OpenSegStatus(i), ClosedSegStatus(i), OpenSegValid(i), ClosedSegValid(i), ...
            OpenArea_px(i), ClosedResidualArea_px(i), AreaObstructed_pct(i), ...
            OpenHeight_px(i), MaxDownwardReach_px(i), MaxDownwardReach_pct(i), ...
            Registration_dx_px(i), Registration_dy_px(i), Notes(i));

        save(pairCacheFile, 'pairResult', '-v7.3');

    catch ME
        Notes(i) = "FAIL: " + string(ME.message);
        warning('Failed on %s: %s', baseTag, ME.message);

        pairResult = packPairResult( ...
            OpenSegStatus(i), ClosedSegStatus(i), OpenSegValid(i), ClosedSegValid(i), ...
            OpenArea_px(i), ClosedResidualArea_px(i), AreaObstructed_pct(i), ...
            OpenHeight_px(i), MaxDownwardReach_px(i), MaxDownwardReach_pct(i), ...
            Registration_dx_px(i), Registration_dy_px(i), Notes(i));

        save(pairCacheFile, 'pairResult', '-v7.3');
    end

    % -------------------------------------------------------------
    % PERIODIC AUTOSAVE OF WHOLE TABLE
    % -------------------------------------------------------------
    if mod(i, autosaveEveryN) == 0 || i == N
        Tpartial = buildResultsTable(Tpairs, ...
            OpenSegStatus, ClosedSegStatus, OpenSegValid, ClosedSegValid, ...
            OpenArea_px, ClosedResidualArea_px, AreaObstructed_pct, ...
            OpenHeight_px, MaxDownwardReach_px, MaxDownwardReach_pct, ...
            Registration_dx_px, Registration_dy_px, Notes);

        save(checkpointTableFile, 'Tpartial', '-v7.3');
        writetable(Tpartial, fullfile(backupDir, 'valve_closure_pairwise_results_checkpoint.csv'));

        fprintf('  Autosaved checkpoint after row %d.\n', i);
    end
end

%% BUILD FINAL RESULTS TABLE
Tresults = buildResultsTable(Tpairs, ...
    OpenSegStatus, ClosedSegStatus, OpenSegValid, ClosedSegValid, ...
    OpenArea_px, ClosedResidualArea_px, AreaObstructed_pct, ...
    OpenHeight_px, MaxDownwardReach_px, MaxDownwardReach_pct, ...
    Registration_dx_px, Registration_dy_px, Notes);

%% GROUP STATS OVER REPLICATES
valid = strcmp(Tresults.Notes, "OK") | ...
    strcmp(Tresults.Notes, "OK_parabola") | ...
    strcmp(Tresults.Notes, "OK_zero_reach") | ...
    strcmp(Tresults.Notes, "OK_reach_geom_fallback") | ...
    strcmp(Tresults.Notes, "Incomplete pair -> assumed no closure");

if any(valid)
    Tstats = groupsummary(Tresults(valid,:), ...
        {'Height_layers','Width_px','MembraneLayers'}, ...
        {'mean','std','median'}, ...
        {'AreaObstructed_pct','MaxDownwardReach_pct'});
else
    Tstats = table();
end

%% SAVE FINAL RESULTS
writetable(Tresults, csvFile);
save(matFile, 'Tresults', 'Tstats', '-v7.3');

if exist('Tstats', 'var') && istable(Tstats) && height(Tstats) > 0
    writetable(Tstats, statsFile);
end

fprintf('\nSaved results:\n%s\n%s\n', csvFile, matFile);
if exist('Tstats', 'var') && istable(Tstats) && height(Tstats) > 0
    fprintf('%s\n', statsFile);
end

failedIdx = find(~OpenSegValid);

if ~isempty(failedIdx)

    fprintf('\n=== SAM OPEN SEGMENTATION FAILURES ===\n');

    for k = 1:length(failedIdx)
        idx = failedIdx(k);
        fprintf('H%d_W%d_ML%d_R%d\n', ...
            Tresults.Height_layers(idx), ...
            Tresults.Width_px(idx), ...
            Tresults.MembraneLayers(idx), ...
            Tresults.Replicate(idx));
    end

    fprintf('Total failures: %d\n\n', length(failedIdx));

end

%% PLOTS
% try
%     plotComparativeClosure(Tresults, outputDir, 'AreaObstructed_pct', ...
%         'Area Obstructed (%)', '_obstruction');
% catch ME
%     warning('Plotting AreaObstructed failed: %s', ME.message);
% end
%
% try
%     plotComparativeClosure(Tresults, outputDir, 'MaxDownwardReach_pct', ...
%         'Membrane Reach (% of Open Height)', '_reach');
% catch ME
%     warning('Plotting MaxDownwardReach failed: %s', ME.message);
% end

%% COMBINED DUAL-AXIS PLOT: Area Obstructed + Membrane Reach vs Width
try
    plotCombinedClosureReach(Tresults, outputDir);
catch ME
    warning('Combined dual-axis plot failed: %s', ME.message);
end

%% LINEAR k-FITS OF REACH VS WIDTH (pre-saturation regime, per H/ML series)
try
    plotReachLinearFits(Tresults, outputDir);
catch ME
    warning('Reach linear fits failed: %s', ME.message);
end

fprintf('\n=== PROCESSING COMPLETE ===\n');
fprintf('Total rows: %d\n', height(Tresults));
fprintf('OK rows:    %d\n', ...
    sum(strcmp(Tresults.Notes, "OK")) + ...
    sum(strcmp(Tresults.Notes, "OK_parabola")) + ...
    sum(strcmp(Tresults.Notes, "OK_zero_reach")) + ...
    sum(strcmp(Tresults.Notes, "OK_reach_geom_fallback")));
fprintf('Incomplete: %d\n', sum(strcmp(Tresults.Notes, "Incomplete pair -> assumed no closure")));
fprintf('Failed:     %d\n', sum(startsWith(string(Tresults.Notes), "FAIL")) + sum(strcmp(Tresults.Notes, "SAM open segmentation failed")));

fprintf('\n=== OPEN IMAGE SEGMENTATION FAILURE SUMMARY ===\n');
openFailMask = strcmp(string(Tresults.Notes), "SAM open segmentation failed");
nOpenFails = sum(openFailMask);

fprintf('Total open-image segmentation failures: %d\n', nOpenFails);

if nOpenFails > 0
    for k = find(openFailMask').'
        baseTag = sprintf('H%d_W%d_ML%d_R%d', ...
            Tresults.Height_layers(k), ...
            Tresults.Width_px(k), ...
            Tresults.MembraneLayers(k), ...
            Tresults.Replicate(k));

        reasonStr = string(Tresults.OpenSegStatus(k));
        fprintf('  %s --> %s\n', baseTag, reasonStr);
    end
else
    fprintf('  None\n');
end

try, findfigs; catch, end   % no-op / harmless when running headless via matlab -batch

%% QC SUMMARY
fprintf('\n=== QUALITY GATE SUMMARY ===\n');

nOK       = sum(startsWith(string(Tresults.Notes), "OK"));
nZero     = sum(strcmp(string(Tresults.Notes), "OK_zero_reach"));
nDiscard  = sum(startsWith(string(Tresults.Notes), "QC_DISCARD"));
nIncomp   = sum(strcmp(string(Tresults.Notes), "Incomplete pair -> assumed no closure"));
nSAMfail  = sum(strcmp(string(Tresults.Notes), "SAM open segmentation failed"));
nOtherFail = sum(startsWith(string(Tresults.Notes), "FAIL"));

fprintf('  Trusted measurements:   %d (of which %d = zero reach)\n', nOK, nZero);
fprintf('  QC discarded (-> NaN):  %d\n', nDiscard);
fprintf('  Incomplete pairs:       %d\n', nIncomp);
fprintf('  SAM failures:           %d\n', nSAMfail);
fprintf('  Other failures:         %d\n', nOtherFail);
fprintf('  Total:                  %d\n', height(Tresults));

if nDiscard > 0
    fprintf('\n  Discarded cases:\n');
    discIdx = find(startsWith(string(Tresults.Notes), "QC_DISCARD"));
    for k = 1:numel(discIdx)
        idx = discIdx(k);
        fprintf('    H%d_W%d_ML%d_R%d: %s\n', ...
            Tresults.Height_layers(idx), ...
            Tresults.Width_px(idx), ...
            Tresults.MembraneLayers(idx), ...
            Tresults.Replicate(idx), ...
            string(Tresults.Notes(idx)));
    end
end

%% COMPLETION NOTIFICATION
% Preferred: direct email via Gmail SMTP. One-time setup on the machine that
% runs the batch: create an App Password at
%   https://myaccount.google.com/apppasswords   (requires 2-Step Verification)
% and save it (just the 16 characters) into:
%   %USERPROFILE%\gmail_app_password.txt
% The file stays local to that machine (NOT in Dropbox/git). If the file is
% missing, falls back to an anonymous ntfy.sh push: watch the topic at
% https://ntfy.sh/rvoronov-valve-2026 in any browser tab or the ntfy app.
notifyAddr = 'bopohob@gmail.com';
notifyMsg  = sprintf('Valve batch complete: %d rows, %d OK (%d zero-reach), %d QC-discarded, %d failed.', ...
    height(Tresults), nOK, nZero, nDiscard, nOtherFail + nSAMfail);

try
    pwFile = fullfile(getenv('USERPROFILE'), 'gmail_app_password.txt');
    if exist(pwFile, 'file')
        gmailAppPassword = strtrim(fileread(pwFile));
        setpref('Internet', 'SMTP_Server',   'smtp.gmail.com');
        setpref('Internet', 'E_mail',        notifyAddr);
        setpref('Internet', 'SMTP_Username', notifyAddr);
        setpref('Internet', 'SMTP_Password', gmailAppPassword);
        props = java.lang.System.getProperties;
        props.setProperty('mail.smtp.auth', 'true');
        props.setProperty('mail.smtp.socketFactory.port', '465');
        props.setProperty('mail.smtp.socketFactory.class', 'javax.net.ssl.SSLSocketFactory');
        sendmail(notifyAddr, 'BATCH_VALVE_CLOSURE done', notifyMsg);
        fprintf('\nCompletion email sent to %s.\n', notifyAddr);
    else
        system(sprintf('curl -s -d "%s" https://ntfy.sh/rvoronov-valve-2026', notifyMsg));
        fprintf('\nNo %s found -> push sent to https://ntfy.sh/rvoronov-valve-2026 instead.\n', pwFile);
    end
catch MEnotify
    warning('Completion notification failed: %s', MEnotify.message);
end

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================

function meta = parseValveFilename(fname)
meta.H = NaN;
meta.W = NaN;
meta.ML = NaN;
meta.R = NaN;
meta.State = '';

[~, base, ~] = fileparts(fname);
tok = regexp(base, 'H(\d+)_W(\d+)_ML(\d+)_R(\d+)_(CL|OP)$', 'tokens', 'once', 'ignorecase');

if isempty(tok)
    return;
end

meta.H     = str2double(tok{1});
meta.W     = str2double(tok{2});
meta.ML    = str2double(tok{3});
meta.R     = str2double(tok{4});
meta.State = upper(tok{5});
end

function [IclosedReg, tform] = registerClosedToOpen(IopenRGB, IclosedRGB, roi, maxShift_px)

if nargin < 4 || isempty(maxShift_px)
    maxShift_px = 8;
end

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

% Fix F: validate the estimated shift by RESIDUAL COMPARISON, not a blind
% size clamp. Some pairs have genuinely large stage shifts (e.g. -54 px in
% W80_ML1_R3) that imregcorr finds correctly; rejecting those misaligns the
% pair, explodes the adaptive noise gate, and zeroes real closures. Keep the
% transform only if it actually improves alignment over doing nothing.
dxEst = tformEstimate.T(3,1);
dyEst = tformEstimate.T(3,2);

Rmov     = imref2d(size(moving));
movReg   = imwarp(moving, tformEstimate, 'OutputView', Rmov);
suppMask = imwarp(ones(size(moving), 'single'), tformEstimate, 'OutputView', Rmov) > 0.5;

if nnz(suppMask) > 0.25 * numel(moving)
    % Normalized cross-correlation: gain/offset-invariant AND sensitive to
    % structural alignment. (A median-residual test proved nearly blind to
    % horizontal shifts because the layer striations are horizontal.)
    corrReg = corr2(fixed(suppMask), movReg(suppMask));
    corrId  = corr2(fixed(suppMask), moving(suppMask));
else
    corrReg = -inf;   % transform pushed most of the image out of frame
    corrId  = inf;
end

if corrReg > corrId
    if abs(dxEst) > maxShift_px || abs(dyEst) > maxShift_px
        fprintf('  Registration: accepting large shift (%.1f, %.1f) px (NCC %.4f > %.4f).\n', ...
            dxEst, dyEst, corrReg, corrId);
    end
else
    if abs(dxEst) > 0.5 || abs(dyEst) > 0.5
        fprintf('  Registration: rejecting shift (%.1f, %.1f) px (NCC %.4f <= %.4f). Using identity.\n', ...
            dxEst, dyEst, corrReg, corrId);
    end
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

function out = ternary_local(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end

function pairResult = packPairResult(OpenSegStatus, ClosedSegStatus, OpenSegValid, ClosedSegValid, ...
    OpenArea_px, ClosedResidualArea_px, AreaObstructed_pct, ...
    OpenHeight_px, MaxDownwardReach_px, MaxDownwardReach_pct, ...
    Registration_dx_px, Registration_dy_px, Notes)

pairResult = struct();
pairResult.OpenSegStatus         = OpenSegStatus;
pairResult.ClosedSegStatus       = ClosedSegStatus;
pairResult.OpenSegValid          = OpenSegValid;
pairResult.ClosedSegValid        = ClosedSegValid;
pairResult.OpenArea_px           = OpenArea_px;
pairResult.ClosedResidualArea_px = ClosedResidualArea_px;
pairResult.AreaObstructed_pct    = AreaObstructed_pct;
pairResult.OpenHeight_px         = OpenHeight_px;
pairResult.MaxDownwardReach_px   = MaxDownwardReach_px;
pairResult.MaxDownwardReach_pct  = MaxDownwardReach_pct;
pairResult.Registration_dx_px    = Registration_dx_px;
pairResult.Registration_dy_px    = Registration_dy_px;
pairResult.Notes                 = Notes;
end

function Tresults = buildResultsTable(Tpairs, ...
    OpenSegStatus, ClosedSegStatus, OpenSegValid, ClosedSegValid, ...
    OpenArea_px, ClosedResidualArea_px, AreaObstructed_pct, ...
    OpenHeight_px, MaxDownwardReach_px, MaxDownwardReach_pct, ...
    Registration_dx_px, Registration_dy_px, Notes)

Tresults = Tpairs;
Tresults.OpenSegStatus         = OpenSegStatus;
Tresults.ClosedSegStatus       = ClosedSegStatus;
Tresults.OpenSegValid          = OpenSegValid;
Tresults.ClosedSegValid        = ClosedSegValid;
Tresults.OpenArea_px           = OpenArea_px;
Tresults.ClosedResidualArea_px = ClosedResidualArea_px;
Tresults.AreaObstructed_pct    = AreaObstructed_pct;
Tresults.OpenHeight_px         = OpenHeight_px;
Tresults.MaxDownwardReach_px   = MaxDownwardReach_px;
Tresults.MaxDownwardReach_pct  = MaxDownwardReach_pct;
Tresults.Registration_dx_px    = Registration_dx_px;
Tresults.Registration_dy_px    = Registration_dy_px;
Tresults.Notes                 = Notes;
end

function plotComparativeClosure(T, resultsFolder, metricColumn, metricLabel, outputSuffix)

if nargin < 3 || isempty(metricColumn), metricColumn = 'AreaObstructed_pct'; end
if nargin < 4 || isempty(metricLabel),  metricLabel  = metricColumn; end
if nargin < 5 || isempty(outputSuffix), outputSuffix = ''; end

if ~ismember(metricColumn, T.Properties.VariableNames)
    warning('Column "%s" not found. Skipping.', metricColumn);
    return;
end

if ~exist(resultsFolder, 'dir')
    mkdir(resultsFolder);
end

good = (strcmp(string(T.Notes), "OK") | ...
    strcmp(string(T.Notes), "OK_parabola") | ...
    strcmp(string(T.Notes), "OK_zero_reach") | ...
    strcmp(string(T.Notes), "OK_reach_geom_fallback") | ...
    strcmp(string(T.Notes), "Incomplete pair -> assumed no closure")) ...
    & ~isnan(T.(metricColumn));

T_clean = T(good, :);

if isempty(T_clean) || height(T_clean) == 0
    warning('No valid rows for %s. Skipping.', metricColumn);
    return;
end

T_clean.(metricColumn) = max(0, min(100, T_clean.(metricColumn)));

groupVars = {'Width_px','MembraneLayers','Height_layers'};
T_stats = groupsummary(T_clean, groupVars, {'mean','std'}, metricColumn);

meanCol  = ['mean_' metricColumn];
stdCol   = ['std_' metricColumn];
countCol = 'GroupCount';

T_stats.SEM = T_stats.(stdCol) ./ sqrt(T_stats.(countCol));
T_stats = T_stats(~isnan(T_stats.(meanCol)), :);

if isempty(T_stats) || height(T_stats) == 0
    warning('No valid grouped statistics for %s.', metricColumn);
    return;
end

fprintf('\n=== CLOSURE PLOT SUMMARY (%s) ===\n', metricLabel);
fprintf('Rows in table:        %d\n', height(T));
fprintf('Rows used:            %d\n', height(T_clean));
fprintf('Grouped conditions:   %d\n', height(T_stats));
fprintf('Replicate n range:    [%d, %d]\n', ...
    min(T_stats.(countCol)), max(T_stats.(countCol)));

markerList = {'o','s','^','d','v','>','<','p','h'};
lineStyles = {'-','--',':','-.'};

Hvals = unique(T_stats.Height_layers, 'stable');
colors = lines(max(numel(Hvals),3));

%% FIGURE 1: 3D SCATTER
fig1 = figure('Position', [100 100 1100 750], 'Color', 'w');
hold on

legH1 = [];
legL1 = {};

for h = 1:numel(Hvals)
    Hval = Hvals(h);
    mask = T_stats.Height_layers == Hval;
    subT = T_stats(mask, :);
    if isempty(subT) || height(subT) == 0
        continue;
    end

    col = colors(h,:);
    mk = markerList{mod(h-1,numel(markerList))+1};

    xD = subT.Width_px;
    yD = subT.MembraneLayers;
    zD = subT.(meanCol);
    eD = subT.SEM;

    hs = scatter3(xD, yD, zD, 80, col, mk, 'filled', ...
        'MarkerEdgeColor', 'k', 'LineWidth', 0.5);
    legH1 = [legH1 hs]; %#ok<AGROW>
    legL1 = [legL1 {sprintf('H = %d', Hval)}]; %#ok<AGROW>

    for j = 1:height(subT)
        if ~isnan(eD(j)) && eD(j) > 0 && subT.(countCol)(j) > 1
            plot3([xD(j) xD(j)], [yD(j) yD(j)], [zD(j)-eD(j) zD(j)+eD(j)], ...
                '-', 'Color', col, 'LineWidth', 1.2, 'HandleVisibility', 'off');
        end
    end
end

xlabel('Width (printer px)', 'FontSize', 11, 'FontWeight', 'bold');
ylabel('Membrane Layers', 'FontSize', 11, 'FontWeight', 'bold');
zlabel(metricLabel, 'FontSize', 11, 'FontWeight', 'bold');
title({sprintf('%s (3D Scatter)', metricLabel), ...
    sprintf('%d grouped conditions, error bars = ±1 SEM', height(T_stats))}, ...
    'FontSize', 12);
grid on
view(45, 30)
zlim([0 100])

if ~isempty(legH1)
    legend(legH1, legL1, 'Location', 'bestoutside');
end

hold off

saveas(fig1, fullfile(resultsFolder, ['closure_3Dscatter' outputSuffix '.png']));
try
    exportgraphics(fig1, fullfile(resultsFolder, ['closure_3Dscatter' outputSuffix '.pdf']), ...
        'ContentType', 'vector');
catch
end

%% FIGURE 2: 3D SURFACE
nUniqueX = numel(unique(T_stats.Width_px));
nUniqueY = numel(unique(T_stats.MembraneLayers));
makeSurface = (nUniqueX >= 2) && (nUniqueY >= 2);

if makeSurface
    fig2 = figure('Position', [100 100 1100 750], 'Color', 'w');
    hold on

    legH2 = [];
    legL2 = {};

    for h = 1:numel(Hvals)
        Hval = Hvals(h);
        mask = T_stats.Height_layers == Hval;
        subT = T_stats(mask, :);
        if isempty(subT) || height(subT) < 3
            continue;
        end

        xD = subT.Width_px;
        yD = subT.MembraneLayers;
        zD = subT.(meanCol);

        if numel(unique(xD)) < 2 || numel(unique(yD)) < 2
            hp = scatter3(xD, yD, zD, 60, colors(h,:), 'o', 'filled', ...
                'MarkerEdgeColor', 'k', 'LineWidth', 0.5);
            legH2 = [legH2 hp]; %#ok<AGROW>
            legL2 = [legL2 {sprintf('H = %d', Hval)}]; %#ok<AGROW>
            continue;
        end

        widths = unique(xD, 'sorted');
        mls    = unique(yD, 'sorted');
        [Xg, Yg] = meshgrid(widths, mls);
        Zg = nan(size(Xg));

        for ii = 1:numel(widths)
            for jj = 1:numel(mls)
                idx = (xD == widths(ii)) & (yD == mls(jj));
                if any(idx)
                    Zg(jj, ii) = zD(find(idx, 1));
                end
            end
        end

        if sum(~isnan(Zg(:))) >= 4
            try
                F = scatteredInterpolant(xD, yD, zD, 'natural', 'none');
                Zg_interp = F(Xg, Yg);
                nanMask = isnan(Zg);
                Zg(nanMask) = Zg_interp(nanMask);
            catch
            end
        end

        if ~isscalar(Zg) && ~isvector(Zg) && any(~isnan(Zg(:)))
            surf(Xg, Yg, Zg, ...
                'FaceColor', colors(h,:), 'FaceAlpha', 0.35, ...
                'EdgeColor', colors(h,:), 'EdgeAlpha', 0.5, ...
                'LineWidth', 0.8);

            hp = scatter3(xD, yD, zD, 60, colors(h,:), 'o', 'filled', ...
                'MarkerEdgeColor', 'k', 'LineWidth', 0.5);
        else
            hp = scatter3(xD, yD, zD, 60, colors(h,:), 'o', 'filled', ...
                'MarkerEdgeColor', 'k', 'LineWidth', 0.5);
        end

        legH2 = [legH2 hp]; %#ok<AGROW>
        legL2 = [legL2 {sprintf('H = %d', Hval)}]; %#ok<AGROW>
    end

    xlabel('Width (printer px)', 'FontSize', 11, 'FontWeight', 'bold');
    ylabel('Membrane Layers', 'FontSize', 11, 'FontWeight', 'bold');
    zlabel(metricLabel, 'FontSize', 11, 'FontWeight', 'bold');
    title({sprintf('%s (Surface Fit)', metricLabel), ...
        'Interpolated surface through group means'}, 'FontSize', 12);
    grid on
    view(45, 30)
    zlim([0 100])

    if ~isempty(legH2)
        legend(legH2, legL2, 'Location', 'bestoutside');
    end

    hold off

    saveas(fig2, fullfile(resultsFolder, ['closure_3Dsurface' outputSuffix '.png']));
    try
        exportgraphics(fig2, fullfile(resultsFolder, ['closure_3Dsurface' outputSuffix '.pdf']), ...
            'ContentType', 'vector');
    catch
    end
else
    fprintf('Skipping 3D surface for %s: dataset is effectively 1D (unique Width=%d, unique ML=%d).\n', ...
        metricColumn, nUniqueX, nUniqueY);
end

%% FIGURE 3: 2D LINES VS WIDTH
fig3 = figure('Position', [100 100 1200 700], 'Color', 'w');
hold on

uniqueML = sort(unique(T_stats.MembraneLayers));
legH3 = [];
legL3 = {};

for m = 1:numel(uniqueML)
    MLval = uniqueML(m);
    subT = T_stats(T_stats.MembraneLayers == MLval, :);

    if isempty(subT) || height(subT) == 0
        continue;
    end

    [xData, si] = sort(subT.Width_px);
    yData = subT.(meanCol)(si);
    eData = subT.SEM(si);

    eLow = min(eData, yData);
    eHigh = eData;

    col = colors(mod(m-1,size(colors,1))+1, :);
    mk = markerList{mod(m-1,numel(markerList))+1};
    ls = lineStyles{mod(m-1,numel(lineStyles))+1};

    h = errorbar(xData, yData, eLow, eHigh, ...
        'LineStyle', ls, ...
        'Marker', mk, ...
        'LineWidth', 1.6, ...
        'MarkerSize', 7, ...
        'CapSize', 6, ...
        'Color', col, ...
        'MarkerFaceColor', col);

    legH3 = [legH3 h]; %#ok<AGROW>
    legL3 = [legL3 {sprintf('ML = %d', MLval)}]; %#ok<AGROW>
end

xlabel('Width (printer px, 1 px = 32 \mum)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel(metricLabel, 'FontSize', 12, 'FontWeight', 'bold');
title({sprintf('%s vs Width', metricLabel), ...
    'Mean ± SEM across replicates'}, 'FontSize', 13);
grid on
box on
set(gca, 'FontSize', 11, 'LineWidth', 1)
ylim([0 100])

if numel(uniqueML) > 1
    legend(legH3, legL3, 'Location', 'bestoutside', 'Interpreter', 'none');
end

hold off

saveas(fig3, fullfile(resultsFolder, ['closure_lines' outputSuffix '.png']));
try
    exportgraphics(fig3, fullfile(resultsFolder, ['closure_lines' outputSuffix '.pdf']), ...
        'ContentType', 'vector');
catch
end
end

function results = computeClosureMetrics_MethodB(IopenGray, IclosedGrayReg, BWopen, vizLevelFrac, mp)

if nargin < 5 || isempty(mp)
    mp = struct('noiseGateAbsMin', 0.05, 'noiseGateFactor', 2.0, ...
        'minSignalFrac', 0.02, 'strongFactor', 2.0, 'minStrongFrac', 0.005, ...
        'centerZoneFrac', 0.40, 'edgeTolFrac', 0.15, 'frontStrongFrac', 0.5);
end

BWopen = logical(BWopen);
[nRows, nCols] = size(BWopen);

%% OPEN-LUMEN GEOMETRY
openTop    = nan(1, nCols);
openBottom = nan(1, nCols);

for c = 1:nCols
    rows = find(BWopen(:, c));
    if ~isempty(rows)
        openTop(c)    = rows(1);
        openBottom(c) = rows(end);
    end
end

validCols = find(~isnan(openTop) & ~isnan(openBottom));
if isempty(validCols)
    error('Could not extract open-lumen geometry.');
end

openHeightByCol = openBottom(validCols) - openTop(validCols) + 1;
openHeight_px   = median(openHeightByCol);
openArea_px     = nnz(BWopen);

%% REFERENCE REGION (static: same rows as the lumen, laterally away from it)
lumenRowBand = false(nRows, nCols);
lumenRowBand(any(BWopen, 2), :) = true;
guardMask = imdilate(BWopen, strel('disk', 15));
refMask   = lumenRowBand & ~guardMask;

%% ================================================================
%  FIX G: PHOTOMETRIC NORMALIZATION
%  Some pairs have a global illumination/exposure difference between
%  the open and closed captures. That inflates the difference image
%  everywhere, drives the adaptive gate sky-high (observed gate=0.45
%  vs typical 0.05-0.13), and real closures get zeroed. Map the closed
%  image into the open image's photometric frame using a robust linear
%  fit over the static reference region before differencing.
%  ================================================================
if nnz(refMask) > 100
    xPh = double(IclosedGrayReg(refMask));
    yPh = double(IopenGray(refMask));
    pPh = polyfit(xPh, yPh, 1);
    if pPh(1) > 0.5 && pPh(1) < 2
        IclosedGrayReg = pPh(1) * IclosedGrayReg + pPh(2);
    else
        % implausible gain -> offset-only correction
        IclosedGrayReg = IclosedGrayReg + (median(yPh) - median(xPh));
    end
end

%% COMPUTE INTENSITY LOSS MAP
rawLoss = IopenGray - IclosedGrayReg;
rawLoss(rawLoss < 0) = 0;

lossMap = rawLoss;
lossMap(~BWopen) = 0;

%% ================================================================
%  FIX A: ABSOLUTE NOISE GATE
%  Estimate the noise level of the (photometrically corrected)
%  open-vs-closed difference from the static reference region. This
%  self-calibrates against JPEG noise, layer-line striations, and
%  registration jitter. If the loss inside the lumen does not clearly
%  exceed that noise level, the valve did not close: report a genuine
%  zero instead of normalizing noise up to full scale (the root cause
%  of the 0% -> 98% false positives on non-closing valves).
%  ================================================================
% Noise scale from the SIGNED difference (before positive clipping): for a
% well-matched pair the signed residual is ~zero-mean noise, and a robust
% MAD-based sigma ignores the heavy tail produced by pressure-induced
% deformation around the lumen (H10 devices). 2.33*sigma is the Gaussian
% equivalent of the positive-tail p99, so healthy pairs get the same gate
% as the original p99 estimator while deformed pairs no longer explode.
% NOTE: never gate on statistics of the positive-CLIPPED loss -- its median
% is ~0 for matched pairs, which collapses MAD-based estimates to the
% absolute floor and resurrects the empty-lumen false positives
% (observed at W20_ML2_R1: gate hit 0.05 while p99 was 0.10).
refDiff = IopenGray - IclosedGrayReg;
refD    = refDiff(refMask);
refD    = refD(:);
lossRef = rawLoss(refMask);
if isempty(refD)
    noiseRef = 0; refP99 = 0; refSig = 0;
else
    vv     = sort(lossRef(:));
    refP99 = vv(max(1, round(0.99 * numel(vv))));   % diagnostic only
    refSig = 1.4826 * median(abs(refD - median(refD)));
    noiseRef = 2.33 * refSig;
end

noiseGate  = max(mp.noiseGateAbsMin, mp.noiseGateFactor * noiseRef);

lumenLoss  = lossMap(BWopen);
signalFrac = nnz(lumenLoss > noiseGate) / max(1, nnz(BWopen));
strongFrac = nnz(lumenLoss > mp.strongFactor * noiseGate) / max(1, nnz(BWopen));

% No-closure decision needs BOTH a minimum detected fraction AND a "strong
% core" well above the gate. Edge-glow strips (thin bands of marginal loss
% along the blurred bright top edge of the lumen) can span >10% of the
% lumen yet have almost no pixels well above the gate, whereas a real
% membrane always produces a strong-loss core.
noClosureByGate = (signalFrac < mp.minSignalFrac) || (strongFrac < mp.minStrongFrac);

maxLoss = max(lossMap(:));

% Normalize against at least the noise gate so a pure-noise loss map is
% NOT stretched to full 0-1 scale.
lossMapNorm = lossMap / max(maxLoss, noiseGate);

%% ADAPTIVE THRESHOLD
lossInsideLumen = lossMapNorm(BWopen);

if max(lossInsideLumen(:)) > 0
    computeThresh = graythresh(lossInsideLumen);
    computeThresh = min(computeThresh, 0.15);
else
    computeThresh = 0.15;
end

%% RAW DETECTION MASK
if noClosureByGate
    rawDetect = false(nRows, nCols);   % Fix A: below noise floor -> no detection
else
    rawDetect = BWopen & (lossMapNorm >= computeThresh);
end

%% PHYSICALLY-INFORMED OBSTRUCTION MASK
[rowIdx, colIdx] = find(rawDetect);

if numel(rowIdx) >= 3

    seRadius = max(3, round(openHeight_px * 0.15));
    se = strel('disk', seRadius);
    mergedMask = imclose(rawDetect, se);

    CC = bwconncomp(mergedMask, 8);
    if CC.NumObjects > 0
        numPx = cellfun(@numel, CC.PixelIdxList);
        [~, bigIdx] = max(numPx);
        cleanMask = false(nRows, nCols);
        cleanMask(CC.PixelIdxList{bigIdx}) = true;
    else
        cleanMask = false(nRows, nCols);
    end

    cleanMask = imfill(cleanMask, 'holes');
    cleanMask = cleanMask & BWopen;

elseif ~isempty(rowIdx)
    cleanMask = rawDetect;
    CC = bwconncomp(cleanMask, 8);
    if CC.NumObjects > 0
        numPx = cellfun(@numel, CC.PixelIdxList);
        [~, bigIdx] = max(numPx);
        cleanMask = false(nRows, nCols);
        cleanMask(CC.PixelIdxList{bigIdx}) = true;
    end
else
    cleanMask = false(nRows, nCols);
end

%% DEFINE MEASUREMENT SPAN FROM LUMEN BOUNDING BOX
lumenCols    = find(any(BWopen, 1));
lumenLeft    = lumenCols(1);
lumenRight   = lumenCols(end);
lumenWidth   = lumenRight - lumenLeft;

trimFrac  = 0.15;
trimPx    = max(3, round(lumenWidth * trimFrac));
spanLeft  = lumenLeft + trimPx;
spanRight = lumenRight - trimPx;

if spanLeft >= spanRight
    spanLeft  = lumenLeft;
    spanRight = lumenRight;
end

%% FLOOD FROM TOP (full lumen for area measurement)
obstructionMaskCompute = false(nRows, nCols);

for c = 1:nCols
    if isnan(openTop(c)) || isnan(openBottom(c))
        continue;
    end

    maskRows = find(cleanMask(:, c));
    if isempty(maskRows)
        continue;
    end

    deepest    = max(maskRows);
    topOfLumen = openTop(c);

    obstructionMaskCompute(topOfLumen:deepest, c) = true;
end

obstructionMaskCompute = obstructionMaskCompute & BWopen;

%% DISPLAY MASK = COMPUTE MASK
obstructionMaskDisplay = obstructionMaskCompute;

%% AREA METRICS (mask-based; overridden by fit-based area when a fit is selected)
obstructedArea_px       = nnz(obstructionMaskCompute);
areaObstructed_pct      = 100 * obstructedArea_px / openArea_px;
closedAreaEquivalent_px = openArea_px - obstructedArea_px;
areaObstructedMask_pct  = areaObstructed_pct;   % kept for diagnostics

%% EXTRACT BOTTOM EDGE OF THE MEMBRANE (Fix C: strong-loss front)
%  The permissive detection mask (and its flood fill) extends below the
%  membrane apex through the dark "pinch" gap between membrane and floor,
%  dragging the front to the channel floor and inflating reach toward 100%
%  (e.g. H10_W90_ML1_R1: mask 99.5% while the apex was mid-lumen). The
%  membrane BODY always carries the strongest intensity loss -- the loss
%  map is normalized to its peak -- so the reach front is traced only
%  through strong-loss pixels. Genuine full touchdowns keep strong loss
%  all the way down and are unaffected.
strongFront = cleanMask & (lossMapNorm >= mp.frontStrongFrac);

frontBottom = nan(1, nCols);

for c = 1:nCols
    rows = find(strongFront(:, c));
    if ~isempty(rows)
        frontBottom(c) = max(rows);
    end
end

obsCols = find(~isnan(frontBottom));

%% DEFAULT REACH OUTPUTS
reachCurve_px  = nan(1, nCols);
fitX           = [];
fitY           = nan(1, nCols);
xVertex        = NaN;
yVertex        = NaN;
parabolaR2     = NaN;
arcR2          = NaN;
fitValid       = false;
maxReach_px    = NaN;
reach_pct      = NaN;
baselineY      = NaN;
frontSmooth    = nan(1, nCols);
reachMethod    = "none";
reachX         = NaN;
reachY         = NaN;

% Circular arc specific defaults
R_fit          = NaN;
d_fit          = NaN;

% Constrained parabola specific defaults
a_parabola     = NaN;
fitY_parabola  = nan(1, nCols);
parabola_R2    = NaN;

% Circular arc fit arrays
fitY_arc       = nan(1, nCols);

%% CASE 0: no meaningful obstruction
if areaObstructed_pct <= 0.5 || isempty(obsCols)
    maxReach_px       = 0;
    reach_pct         = 0;
    reachCurve_px(:)  = 0;
    reachX            = NaN;
    reachY            = 0;
    fitValid          = false;
    reachMethod       = "zero_no_obstruction";
    results           = packResults();
    return;
end

%% SMOOTH THE FULL FRONT (for visualization)
fullBottomProfile    = frontBottom(obsCols);
windowSizeFull       = max(5, round(length(fullBottomProfile) / 30));
fullBottomSmooth     = movmedian(fullBottomProfile, windowSizeFull);
frontSmooth(obsCols) = fullBottomSmooth;

%% TRIMMED SPAN FOR REACH MEASUREMENT
trimmedObsCols = obsCols(obsCols >= spanLeft & obsCols <= spanRight);

% Fix B: do NOT fall back to untrimmed columns. Wall-adjacent columns are
% dominated by registration shear / edge artifacts (they were the source of
% the single-column edge spikes). If nothing is detected inside the span,
% there is no measurable membrane reach.
if isempty(trimmedObsCols)
    maxReach_px       = 0;
    reach_pct         = 0;
    reachCurve_px(:)  = 0;
    reachX            = NaN;
    reachY            = 0;
    fitValid          = false;
    reachMethod       = "zero_no_obstruction";
    results           = packResults();
    return;
end

%% BASELINE FROM OPEN-LUMEN TOP AT SPAN EDGES
leftTopY   = openTop(trimmedObsCols(1));
rightTopY  = openTop(trimmedObsCols(end));
baselineY  = mean([leftTopY, rightTopY]);

%% DEPTH PROFILE ON TRIMMED SPAN
xRange        = trimmedObsCols;
bottomProfile = frontBottom(xRange);

windowSize    = max(5, round(length(bottomProfile) / 30));
bottomSmooth  = movmedian(bottomProfile, windowSize);

%% DEPTH RELATIVE TO BASELINE
depthProfile = bottomSmooth - baselineY;

%% ================================================================
%  FIX B: EDGE/OUTLIER SUPPRESSION
%  Physics: the membrane is anchored at the walls and sags downward,
%  so its deepest point must lie in (or plateau through) the center
%  of the span. Any column significantly deeper than the central
%  region is an artifact (registration shear at the walls, debris)
%  and is excluded from the reach measurement and the fits.
%  ================================================================
spanW_fit = spanRight - spanLeft;
cLo = spanLeft + (0.5 - mp.centerZoneFrac/2) * spanW_fit;
cHi = spanLeft + (0.5 + mp.centerZoneFrac/2) * spanW_fit;
centerSel = (xRange >= cLo) & (xRange <= cHi);

if any(centerSel)
    centerDepth = max(depthProfile(centerSel));
else
    centerDepth = 0;   % nothing detected centrally -> nothing can be deeper
end

edgeTol = max(3, mp.edgeTolFrac * openHeight_px);
artifactCols = depthProfile > (centerDepth + edgeTol);
if any(artifactCols)
    depthProfile(artifactCols) = NaN;
end

reachCurve_px(xRange) = depthProfile;

%% GEOMETRIC MAX (always available as ultimate fallback)
geomMax = max(0, max(depthProfile));
[~, geomIdx] = max(depthProfile);

%% CASE 1: too few columns for any fit
if numel(trimmedObsCols) < 5
    maxReach_px = geomMax;
    reach_pct   = 100 * maxReach_px / openHeight_px;
    reachX      = xRange(geomIdx);
    reachY      = geomMax;
    fitValid    = false;
    reachMethod = "geom_fallback_too_few_cols";
    results     = packResults();
    return;
end

    %% ================================================================
    %  ANCHOR POINTS = CHANNEL WALLS (spanLeft / spanRight)
    %  Build full-span depth profile: zero where no obstruction detected,
    %  measured depth where obstruction exists. This forces the fit
    %  through the physical anchor points exactly.
    %  ================================================================
    xL   = double(lumenLeft);
    xR   = double(lumenRight);
    W    = xR - xL;
    xMid = (xL + xR) / 2;

    % Full-span column indices
    xFullSpan = xL:xR;
    depthFullSpan = zeros(1, length(xFullSpan));

    % Fill in measured depths where obstruction was detected
    % (columns suppressed as artifacts by Fix B stay at zero)
    for k = 1:length(xRange)
        col = xRange(k);
        idx = col - xL + 1;   % index into xFullSpan
        if ~isnan(depthProfile(k)) && idx >= 1 && idx <= length(depthFullSpan)
            depthFullSpan(idx) = depthProfile(k);
        end
    end

    % Convert to doubles for fitting
    xRangeD       = double(xFullSpan(:)');
    depthProfileD = double(depthFullSpan(:)');

%% ================================================================
%  FIT 1: CIRCULAR ARC (primary — physically correct for membrane)
%
%  Model: y(x; d) = R - sqrt(R^2 - (x - xMid)^2)
%         where R = W^2/(8*d) + d/2
%
%  Single free parameter: d = sag depth at midpoint
%  Boundary conditions:   y(xL) = 0,  y(xR) = 0  (exact)
%  ================================================================
arcFitSuccess = false;

if W > 0

    % Initial guess: peak of observed depth profile
    d0 = max(1, geomMax);

    % Physical bounds: sag must be positive but less than channel height
    dLower = 0.1;
    dUpper = max(openHeight_px, geomMax * 2);

    try
        opts = optimoptions('lsqcurvefit', ...
            'Display', 'off', ...
            'TolX', 1e-8, ...
            'TolFun', 1e-10, ...
            'MaxIterations', 500, ...
            'MaxFunctionEvaluations', 2000);

        d_fit = lsqcurvefit(@(d, x) circularArcProfile(d, x, xMid, W), ...
            d0, xRangeD, depthProfileD, dLower, dUpper, opts);

        fitDepthArc = circularArcProfile(d_fit, xRangeD, xMid, W);
        R_fit = W^2 / (8 * d_fit) + d_fit / 2;

        % Goodness of fit
        ssRes = sum((depthProfileD - fitDepthArc).^2);
        ssTot = sum((depthProfileD - mean(depthProfileD)).^2);
        if ssTot > 0
            arcR2 = 1 - ssRes / ssTot;
        else
            arcR2 = NaN;
        end

        fitY_arc(xFullSpan) = fitDepthArc(:)';
        arcFitSuccess = isfinite(arcR2) && (d_fit > 0);

    catch ME_arc
        warning('Circular arc fit failed: %s', ME_arc.message);
        arcFitSuccess = false;
    end
end

%% ================================================================
%  FIT 2: CONSTRAINED PARABOLA (fallback)
%
%  Model: y(x) = a * (x - xL) * (x - xR)
%
%  Single free parameter: a
%  Boundary conditions:   y(xL) = 0,  y(xR) = 0  (exact)
%  ================================================================
parabolaFitSuccess = false;

if W > 0
    try
        % Basis function: phi(x) = (x - xL)*(x - xR)
        % Note: phi is NEGATIVE inside [xL, xR], and we want y > 0
        %   => a must be negative
        phi = (xRangeD - xL) .* (xRangeD - xR);

        % Least-squares for single parameter: y = a * phi
        a_parabola = (phi(:)' * depthProfileD(:)) / (phi(:)' * phi(:));

        fitDepthParabola = a_parabola * phi;

        % Vertex is at midpoint (by symmetry of the anchors)
        xVertexParabola = xMid;
        yVertexParabola = a_parabola * (xMid - xL) * (xMid - xR);

        % Goodness of fit
        ssRes = sum((depthProfileD - fitDepthParabola).^2);
        ssTot = sum((depthProfileD - mean(depthProfileD)).^2);
        if ssTot > 0
            parabola_R2 = 1 - ssRes / ssTot;
        else
            parabola_R2 = NaN;
        end

        fitY_parabola(xFullSpan) = fitDepthParabola(:)';
        parabolaFitSuccess = isfinite(parabola_R2) && (yVertexParabola > 0);

    catch ME_para
        warning('Constrained parabola fit failed: %s', ME_para.message);
        parabolaFitSuccess = false;
    end
end

%% ================================================================
%  SELECT BEST FIT: prefer arc, fall back to parabola, then geom
%  ================================================================

if arcFitSuccess && arcR2 >= 0.5
    % --- Circular arc wins ---
    maxReach_px = d_fit;
    reach_pct   = 100 * maxReach_px / openHeight_px;
    reachX      = round(xMid);
    reachY      = d_fit;

    xVertex     = round(xMid);
    yVertex     = d_fit;

    fitX        = xFullSpan;
    fitY        = fitY_arc;
    parabolaR2  = arcR2;          % store primary fit R^2 in generic field
    fitValid    = true;
    reachMethod = "circular_arc";

    fprintf('    Arc fit: d=%.1f px, R=%.1f px, R²=%.4f\n', d_fit, R_fit, arcR2);

elseif parabolaFitSuccess && parabola_R2 >= 0.4
    % --- Constrained parabola fallback ---
    maxReach_px = yVertexParabola;
    reach_pct   = 100 * maxReach_px / openHeight_px;
    reachX      = round(xMid);
    reachY      = yVertexParabola;

    xVertex     = round(xMid);
    yVertex     = yVertexParabola;

    fitX        = xFullSpan;
    fitY        = fitY_parabola;
    parabolaR2  = parabola_R2;
    fitValid    = true;
    reachMethod = "constrained_parabola";

    fprintf('    Parabola fit: vertex=%.1f px, R²=%.4f\n', yVertexParabola, parabola_R2);

else
    % --- Geometric fallback ---
    maxReach_px = geomMax;
    reach_pct   = 100 * maxReach_px / openHeight_px;
    reachX      = xRange(geomIdx);
    reachY      = geomMax;
    fitValid    = false;
    reachMethod = "geom_fallback";

    fprintf('    Geometric fallback: max=%.1f px\n', geomMax);
end

%% AREA FROM SELECTED FIT
%  Consistent with the fit-based reach and immune to sub-membrane floor
%  fill and debris that inflate the mask-based area. Caveat: for genuine
%  full touchdowns the membrane flattens along the floor, so the arc
%  slightly underestimates area there (mask value kept as diagnostic).
if fitValid
    fitColsA = find(~isnan(fitY));
    if ~isempty(fitColsA)
        fitDepthsA = min(max(fitY(fitColsA), 0), openHeight_px);
        obstructedArea_px       = sum(fitDepthsA);
        areaObstructed_pct      = min(100, 100 * obstructedArea_px / openArea_px);
        closedAreaEquivalent_px = openArea_px - obstructedArea_px;
    end
end

%% CLAMP REACH TO PHYSICALLY REASONABLE BOUNDS
maxReach_px = max(0, min(maxReach_px, openHeight_px));
reach_pct   = max(0, min(reach_pct, 100));

results = packResults();

%% ==============================================================
%  NESTED: packResults
%  ==============================================================
    function out = packResults()
        out = struct();

        out.lossMap                 = lossMapNorm;
        out.computeThresh           = computeThresh;

        % Fix A diagnostics
        out.noiseGate               = noiseGate;
        out.refP99                  = refP99;
        out.refSig                  = refSig;
        out.signalFrac              = signalFrac;
        out.strongFrac              = strongFrac;
        out.noClosureByGate         = noClosureByGate;

        out.areaObstructed_pct      = areaObstructed_pct;
        out.areaObstructedMask_pct  = areaObstructedMask_pct;
        out.reach_pct               = reach_pct;
        out.maxReach_px             = maxReach_px;
        out.reachCurve_px           = reachCurve_px;

        out.openArea_px             = openArea_px;
        out.openHeight_px           = openHeight_px;
        out.closedAreaEquivalent_px = closedAreaEquivalent_px;
        out.obstructedArea_px       = obstructedArea_px;

        out.obstructionMaskCompute  = obstructionMaskCompute;
        out.obstructionMaskDisplay  = obstructionMaskDisplay;

        out.openTop                 = openTop;
        out.openBottom              = openBottom;
        out.validCols               = validCols;

        out.frontBottom             = frontBottom;
        out.frontSmooth             = frontSmooth;
        out.fitX                    = fitX;
        out.fitY                    = fitY;
        out.xVertex                 = xVertex;
        out.yVertex                 = yVertex;
        out.parabolaR2              = parabolaR2;
        out.fitValid                = fitValid;
        out.baselineY               = baselineY;
        out.reachMethod             = reachMethod;
        out.reachX                  = reachX;
        out.reachY                  = reachY;
        out.spanLeft                = spanLeft;
        out.spanRight               = spanRight;

        % Additional outputs for the new fits
        out.arcR2                   = arcR2;
        out.R_fit                   = R_fit;
        out.d_fit                   = d_fit;
        out.parabola_R2             = parabola_R2;
        out.a_parabola              = a_parabola;
        out.fitY_arc                = fitY_arc;
        out.fitY_parabola           = fitY_parabola;
    end

end

%% ====================================================================
%  STANDALONE HELPER: Circular arc profile
%  ====================================================================
function y = circularArcProfile(d, x, xMid, W)
%CIRCULARARCPROFILE  Circular arc with sag depth d, anchored at ±W/2
%
%   The circle center is at (xMid, yc) where yc = d/2 - W^2/(8d)
%   and R = W^2/(8d) + d/2.
%
%   y(x) = (d - R) + sqrt(R^2 - (x - xMid)^2)
%
%   Boundary conditions (exact):
%     y(xMid - W/2) = 0   (left anchor)
%     y(xMid + W/2) = 0   (right anchor)
%     y(xMid)       = d   (maximum deflection at midpoint)

    R = W^2 / (8*d) + d/2;

    arg = R^2 - (x - xMid).^2;
    arg = max(arg, 0);   % numerical safety near endpoints

    y = (d - R) + sqrt(arg);
end

function y = arcProfile(d, x, xMid, W)
R = W^2 / (8*d) + d/2;
arg = R^2 - (x - xMid).^2;
arg = max(arg, 0);  % numerical safety
y = R - sqrt(arg);
end