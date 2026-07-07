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
inputDir = 'C:\Users\rvoronov\Dropbox\MANUSCRIPTS\micromachines_valve_printing_framework\Figures\NanoClear\Sorted_ConstH5\Cutout_ConstH5_Cleaned';

depDir = 'C:\Users\rvoronov\Dropbox\DRY_LAB\3D_PRINTING_IMAGE_ANALYSIS\SAG_ANALYSIS_SAM_SEGMENTATION';
addpath(depDir);

% Since you said you are fine with a clean rerun:
resumeRun = false;
cleanStartDeletesOldOutputs = true;

closureMethod = 'MethodB_IntensityLoss';
vizLevelFrac = 0.50;   % display-only contour level for debug overlay

% Explicit checkpoint path
samCheckpointFile = fullfile(depDir, 'sam_vit_b_01ec64.pth');

% ROI convention consistent with earlier workflow
roi.bottomFrac = 0.09;
roi.leftFrac   = 0.00;
roi.widthFrac  = 1.00;
roi.heightFrac = 0.09;

doRegistration   = true;
saveDebugFigures = true;
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
for i = 1:N

    if Notes(i) == "OK" || Notes(i) == "OK_zero_reach" || ...
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
        % -------------------------------------------------------------
        fprintf('Running SAM on OPEN image...\n');

        try
            [BWopen, qOpen] = segmentLumenSAM2(Iopen, roi, samDebugDir, [baseTag '_OP']);
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
            [IclosedReg, tform] = registerClosedToOpen(Iopen, Iclosed, roi);
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

        results = computeClosureMetrics_MethodB(IopenGray, IclosedGrayReg, BWopen, vizLevelFrac);

        OpenArea_px(i)           = results.openArea_px;
        ClosedResidualArea_px(i) = results.closedAreaEquivalent_px;
        AreaObstructed_pct(i)    = results.areaObstructed_pct;
        OpenHeight_px(i)         = results.openHeight_px;
        MaxDownwardReach_px(i)   = results.maxReach_px;
        MaxDownwardReach_pct(i)  = results.reach_pct;

        if results.reachMethod == "parabola"
            Notes(i) = "OK";
        elseif results.reachMethod == "zero_no_obstruction"
            Notes(i) = "OK_zero_reach";
        else
            Notes(i) = "OK_reach_geom_fallback";
        end

        % -------------------------------------------------------------
        % DEBUG FIGURE (Method B)
        % -------------------------------------------------------------
        if saveDebugFigures

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
            title('Loss map');

            subplot(2,3,4);
            imshow(IclosedReg);
            title('Closed image (registered)');

            % --- Subplot 5: Physical obstruction overlay ---
            subplot(2,3,5);
            imshow(IclosedReg);
            hold on;
            visboundaries(BWopen, 'Color', 'g', 'LineWidth', 0.8);
            if any(results.obstructionMaskCompute(:))
                redLayer = cat(3, ones(size(BWopen)), zeros(size(BWopen)), zeros(size(BWopen)));
                hOv = imshow(redLayer);
                set(hOv, 'AlphaData', 0.35 * double(results.obstructionMaskCompute));
            end
            if any(~isnan(results.frontSmooth))
                vCols = find(~isnan(results.frontSmooth));
                plot(vCols, results.frontSmooth(vCols), 'c-', 'LineWidth', 1.5);
            end
            title(sprintf('Physical obstruction (thresh=%.3f)', results.computeThresh));
            hold off;

            % --- Subplot 6: Reach profile with single honest vertex ---
            subplot(2,3,6);
            hold on;

            % Full smoothed front (thin black) — shows edges for context
            if any(~isnan(results.frontSmooth))
                allCols = find(~isnan(results.frontSmooth));
                plot(allCols, results.frontSmooth(allCols) - results.baselineY, ...
                    'k-', 'LineWidth', 1.0);
            end

            % Trimmed reach curve (blue, thicker) — what's actually measured
            legHandles = [];
            legEntries = {};
            if any(~isnan(results.reachCurve_px))
                rCols = find(~isnan(results.reachCurve_px));
                hRC = plot(rCols, results.reachCurve_px(rCols), 'b-', 'LineWidth', 2.0);
                legHandles(end+1) = hRC;
                legEntries{end+1} = 'Trimmed reach';
            end

            % Parabola fit (red)
            if any(~isnan(results.fitY))
                fCols = find(~isnan(results.fitY));
                hFit = plot(fCols, results.fitY(fCols), 'r-', 'LineWidth', 2.0);
                legHandles(end+1) = hFit;
                legEntries{end+1} = 'Parabola fit';
            end

            % Single reach marker — always at the exact point that determined reach
            if ~isnan(results.reachX) && ~isnan(results.reachY)
                hVert = plot(results.reachX, results.reachY, ...
                    'ro', 'MarkerSize', 8, 'LineWidth', 1.5);
                legHandles(end+1) = hVert;
                legEntries{end+1} = 'Reach point';
            end

            % Span boundaries (vertical dashed lines)
            if isfield(results, 'spanLeft') && isfield(results, 'spanRight')
                yl = ylim;
                hSL = plot([results.spanLeft results.spanLeft], yl, 'g--', 'LineWidth', 1);
                plot([results.spanRight results.spanRight], yl, 'g--', 'LineWidth', 1, ...
                    'HandleVisibility', 'off');
                legHandles(end+1) = hSL;
                legEntries{end+1} = 'Span boundary';
            end

            grid on;
            xlabel('Column index');
            ylabel('Reach depth (px)');

            title(sprintf('Obstructed = %.1f%% | Reach = %.1f%% | R^2 = %.3f | %s', ...
                results.areaObstructed_pct, ...
                results.reach_pct, ...
                results.parabolaR2, ...
                char(results.reachMethod)));

            if ~isempty(legHandles)
                legend(legHandles, legEntries, 'Location', 'best');
            end

            set(gca, 'YDir', 'reverse');
            hold off;

            sgtitle(sprintf('%s | %s', ...
                strrep(baseTag,'_','\_'), closureMethod), ...
                'Interpreter','none');

            saveas(fig, fullfile(pairDebugDir,[baseTag '_debug.png']));
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

fprintf('\n=== PROCESSING COMPLETE ===\n');
fprintf('Total rows: %d\n', height(Tresults));
fprintf('OK rows:    %d\n', ...
    sum(strcmp(Tresults.Notes, "OK")) + ...
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

findfigs

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

function [IclosedReg, tform] = registerClosedToOpen(IopenRGB, IclosedRGB, roi)

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

function results = computeClosureMetrics_MethodB(IopenGray, IclosedGrayReg, BWopen, vizLevelFrac)

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

    %% COMPUTE INTENSITY LOSS MAP (full lumen — no erosion)
    lossMap = IopenGray - IclosedGrayReg;
    lossMap(lossMap < 0) = 0;
    lossMap(~BWopen)     = 0;

    maxLoss = max(lossMap(:));
    if maxLoss > 0
        lossMapNorm = lossMap / maxLoss;
    else
        lossMapNorm = zeros(size(lossMap));
    end

    %% ADAPTIVE THRESHOLD
    lossInsideLumen = lossMapNorm(BWopen);

    if max(lossInsideLumen(:)) > 0
        computeThresh = graythresh(lossInsideLumen);
        computeThresh = min(computeThresh, 0.15);
    else
        computeThresh = 0.15;
    end

    %% RAW DETECTION MASK
    rawDetect = BWopen & (lossMapNorm >= computeThresh);

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

    %% AREA METRICS
    obstructedArea_px       = nnz(obstructionMaskCompute);
    areaObstructed_pct      = 100 * obstructedArea_px / openArea_px;
    closedAreaEquivalent_px = openArea_px - obstructedArea_px;

    %% EXTRACT BOTTOM EDGE (full width, for visualization)
    frontBottom = nan(1, nCols);

    for c = 1:nCols
        rows = find(obstructionMaskCompute(:, c));
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
    fitValid       = false;
    maxReach_px    = NaN;
    reach_pct      = NaN;
    baselineY      = NaN;
    frontSmooth    = nan(1, nCols);
    reachMethod    = "none";
    reachX         = NaN;
    reachY         = NaN;

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

    if numel(trimmedObsCols) < 5
        trimmedObsCols = obsCols;
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
    reachCurve_px(xRange) = depthProfile;

    %% GEOMETRIC MAX
    geomMax = max(0, max(depthProfile));
    [~, geomIdx] = max(depthProfile);

    %% CASE 1: too few columns
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

    %% CASE 2: parabola fit (on trimmed span only)
    xLocal    = 1:length(depthProfile);
    xCentered = xLocal - mean(xLocal);

    try
        p = polyfit(xCentered, depthProfile, 2);

        xVertexCentered = -p(2) / (2 * p(1));
        yVertexDepth    = polyval(p, xVertexCentered);

        xVertexLocal = xVertexCentered + mean(xLocal);
        xVertexLocal = max(1, min(length(depthProfile), xVertexLocal));

        fitDepthLocal = polyval(p, xCentered);

        ssRes = sum((depthProfile - fitDepthLocal).^2);
        ssTot = sum((depthProfile - mean(depthProfile)).^2);
        if ssTot > 0
            parabolaR2 = 1 - ssRes / ssTot;
        else
            parabolaR2 = NaN;
        end

        xVertex = xRange(round(xVertexLocal));
        xVertex = xRange(round(xVertexLocal));
        yVertex = yVertexDepth;

        fitX         = xRange;
        fitY(xRange) = fitDepthLocal;

        isVertexBetween = (xVertexLocal >= 1) && (xVertexLocal <= length(depthProfile));
        fitValid = isfinite(parabolaR2) && isVertexBetween && (yVertexDepth > 0);

        if fitValid
            if yVertexDepth >= geomMax
                maxReach_px = yVertexDepth;
                reachX      = xVertex;
                reachY      = yVertexDepth;
                reachMethod = "parabola";
            else
                maxReach_px = geomMax;
                reachX      = xRange(geomIdx);
                reachY      = geomMax;
                reachMethod = "parabola_geom_max";
            end
            reach_pct = 100 * maxReach_px / openHeight_px;
        else
            maxReach_px = geomMax;
            reachX      = xRange(geomIdx);
            reachY      = geomMax;
            reach_pct   = 100 * maxReach_px / openHeight_px;
            reachMethod = "geom_fallback_invalid_fit";
        end

    catch
        fitValid    = false;
        parabolaR2  = NaN;
        maxReach_px = geomMax;
        reachX      = xRange(geomIdx);
        reachY      = geomMax;
        reach_pct   = 100 * maxReach_px / openHeight_px;
        reachMethod = "geom_fallback_fit_error";
    end

    results = packResults();

    %% ==============================================================
    function out = packResults()
        out = struct();

        out.lossMap                 = lossMapNorm;
        out.computeThresh           = computeThresh;

        out.areaObstructed_pct      = areaObstructed_pct;
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
    end

end

function y = arcProfile(d, x, xMid, W)
    R = W^2 / (8*d) + d/2;
    arg = R^2 - (x - xMid).^2;
    arg = max(arg, 0);  % numerical safety
    y = R - sqrt(arg);
end