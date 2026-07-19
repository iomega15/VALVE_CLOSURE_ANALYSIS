function plotReachLinearFits(T, resultsFolder)
% Linear characterization of membrane deflection vs channel width, per
% (H, ML) series, restricted to the RISING (pre-saturation) regime.
%
% Two complementary outputs:
%
% 1) reach_linear_fits.png -- normalized axes (reach % vs printer px),
%    ONSET model:  reach ~ k_slope * (W - W0)
%    k_slope [%/px] is the marginal rate once deflection has begun and W0
%    [px] is the closure-onset width. Best for the manuscript (shows the
%    onset physics).
%
% 2) reach_linear_fits_physical.png -- physical axes (sagitta s [um] vs
%    membrane width C [um]), THROUGH-ORIGIN model:  s = k * C
%    k is dimensionless (um/um) and directly usable in the design tool,
%    which assumes s = kC. This k is the AVERAGE sag-per-width from zero,
%    so thicker (stiffer) membranes give smaller k.
%
% Conversions (quantized-unit convention, Section 2.3 of the manuscript):
%   C  = W_px * umPerPx          s = reach/100 * Hc,  Hc = H_layers * umPerLayer
%
% Rising regime = longest contiguous run of widths whose MEAN reach lies in
% (riseMin, satMax); replicate-level points are fitted, not means.

riseMin    = 3;     % mean reach (%) below this  = valve not yet closing
satMax     = 85;    % mean reach (%) above this  = floor-contact saturation
minPts     = 3;     % minimum number of widths required to fit
umPerPx    = 32;    % lateral printer-pixel pitch (um)
umPerLayer = 50;    % vertical layer pitch (um)

if ~exist(resultsFolder, 'dir')
    mkdir(resultsFolder);
end

good = (strcmp(string(T.Notes), "OK") | ...
    strcmp(string(T.Notes), "OK_parabola") | ...
    strcmp(string(T.Notes), "OK_zero_reach") | ...
    strcmp(string(T.Notes), "OK_reach_geom_fallback") | ...
    strcmp(string(T.Notes), "Incomplete pair -> assumed no closure")) ...
    & ~isnan(T.MaxDownwardReach_pct);

T_clean = T(good, :);
% Trailing non-functional trim (data-driven; see plotCombinedClosureReach for
% the rationale). Within each (Height, MembraneLayers) series, drop the
% trailing run of widths that never actuate (reach ~ 0, open == closed past
% the printability limit) while keeping genuine narrow-width low-reach points.
% The rising-regime selection below further restricts which of the remaining
% widths enter the fit; this trim only removes the misleading trailing zeros.
reachEps = 1.0;
keepRow  = true(height(T_clean), 1);
combos   = unique(T_clean(:, {'Height_layers','MembraneLayers'}), 'rows');
for cc = 1:height(combos)
    sel = T_clean.Height_layers == combos.Height_layers(cc) & ...
          T_clean.MembraneLayers == combos.MembraneLayers(cc);
    ws  = sort(unique(T_clean.Width_px(sel)));
    isFunc = false(numel(ws), 1);
    for wi = 1:numel(ws)
        wsel = sel & T_clean.Width_px == ws(wi);
        isFunc(wi) = any(T_clean.MaxDownwardReach_pct(wsel) > reachEps);
    end
    lastFunc = find(isFunc, 1, 'last');
    if isempty(lastFunc) || lastFunc == numel(ws)
        continue;
    end
    droppedW = ws(lastFunc+1:end);
    keepRow(sel & ismember(T_clean.Width_px, droppedW)) = false;
end
T_clean = T_clean(keepRow, :);
if isempty(T_clean)
    warning('No valid rows for linear fits. Skipping.');
    return;
end
T_clean.MaxDownwardReach_pct = max(0, min(100, T_clean.MaxDownwardReach_pct));

groupVars = {'Height_layers','MembraneLayers','Width_px'};
T_stats = groupsummary(T_clean, groupVars, {'mean','std'}, 'MaxDownwardReach_pct');
T_stats.SEM = T_stats.std_MaxDownwardReach_pct ./ sqrt(T_stats.GroupCount);

comboKeys = unique(T_stats(:, {'Height_layers','MembraneLayers'}), 'rows');
comboKeys = sortrows(comboKeys, {'Height_layers','MembraneLayers'});
nCombo    = height(comboKeys);

cols = lines(max(nCombo, 3));
markerList = {'o','s','^','d','v','>','<'};

figN = figure('Position', [100 100 1200 700], 'Color', 'w', 'Visible', 'off');  % normalized / onset
figP = figure('Position', [100 100 1200 700], 'Color', 'w', 'Visible', 'off');  % physical / through-origin

legHN = []; legLN = {};
legHP = []; legLP = {};
fitRows = [];

fprintf('\n=== LINEAR REACH FITS (rising regime: %g%% < mean reach < %g%%) ===\n', ...
    riseMin, satMax);

for c = 1:nCombo
    Hval  = comboKeys.Height_layers(c);
    MLval = comboKeys.MembraneLayers(c);
    HcUm  = Hval * umPerLayer;   % nominal channel height in um

    subT = T_stats(T_stats.Height_layers == Hval & ...
                   T_stats.MembraneLayers == MLval, :);
    subT = sortrows(subT, 'Width_px');
    if isempty(subT), continue; end

    meanR = subT.mean_MaxDownwardReach_pct;

    % Longest contiguous run of rising-regime widths
    rising = (meanR > riseMin) & (meanR < satMax);
    d = diff([0; rising(:); 0]);
    runStarts = find(d == 1);
    runEnds   = find(d == -1) - 1;
    useIdx = false(size(rising));
    if ~isempty(runStarts)
        [~, iBest] = max(runEnds - runStarts);
        useIdx(runStarts(iBest):runEnds(iBest)) = true;
    end

    col = cols(c, :);
    mk  = markerList{mod(c-1, numel(markerList))+1};

    % ---------- Normalized plot: data ----------
    figure(figN); hold on
    hDataN = errorbar(subT.Width_px(useIdx), meanR(useIdx), subT.SEM(useIdx), ...
        'LineStyle', 'none', 'Marker', mk, 'MarkerSize', 9, ...
        'Color', col, 'MarkerFaceColor', col, 'LineWidth', 1.5, 'CapSize', 5);
    errorbar(subT.Width_px(~useIdx), meanR(~useIdx), subT.SEM(~useIdx), ...
        'LineStyle', 'none', 'Marker', mk, 'MarkerSize', 9, ...
        'Color', col, 'MarkerFaceColor', 'none', 'LineWidth', 1.0, ...
        'CapSize', 5, 'HandleVisibility', 'off');

    % ---------- Physical plot: data (means +- SEM, converted) ----------
    Cmean = subT.Width_px * umPerPx;
    Smean = meanR / 100 * HcUm;
    Ssem  = subT.SEM  / 100 * HcUm;
    figure(figP); hold on
    hDataP = errorbar(Cmean(useIdx), Smean(useIdx), Ssem(useIdx), ...
        'LineStyle', 'none', 'Marker', mk, 'MarkerSize', 9, ...
        'Color', col, 'MarkerFaceColor', col, 'LineWidth', 1.5, 'CapSize', 5);
    errorbar(Cmean(~useIdx), Smean(~useIdx), Ssem(~useIdx), ...
        'LineStyle', 'none', 'Marker', mk, 'MarkerSize', 9, ...
        'Color', col, 'MarkerFaceColor', 'none', 'LineWidth', 1.0, ...
        'CapSize', 5, 'HandleVisibility', 'off');

    kSlope = NaN; W0 = NaN; R2on = NaN;
    kTool  = NaN; R2to = NaN;
    selW = subT.Width_px(useIdx);

    if numel(selW) >= minPts
        repMask = T_clean.Height_layers == Hval & ...
                  T_clean.MembraneLayers == MLval & ...
                  ismember(T_clean.Width_px, selW);
        x = double(T_clean.Width_px(repMask));            % printer px
        y = double(T_clean.MaxDownwardReach_pct(repMask));% % of height

        % ----- Onset model on normalized axes: y = kSlope*(x - W0) -----
        p    = polyfit(x, y, 1);
        yhat = polyval(p, x);
        ssRes = sum((y - yhat).^2);
        ssTot = sum((y - mean(y)).^2);
        if ssTot > 0, R2on = 1 - ssRes/ssTot; end
        kSlope = p(1);
        W0     = -p(2) / p(1);

        figure(figN);
        xLine = linspace(max(min(selW) - 15, W0), max(selW) + 8, 50);
        plot(xLine, polyval(p, xLine), '-', 'Color', col, ...
            'LineWidth', 2.0, 'HandleVisibility', 'off');
        legLN{end+1} = sprintf('H=%d ML=%d: k=%.2f %%/px, W_0=%.0f px, R^2=%.2f', ...
            Hval, MLval, kSlope, W0, R2on); %#ok<AGROW>

        % ----- Through-origin model on physical axes: s = kTool * C -----
        Cr = x * umPerPx;              % um
        Sr = y / 100 * HcUm;           % um
        kTool = sum(Cr .* Sr) / sum(Cr.^2);
        sHat  = kTool * Cr;
        ssRes = sum((Sr - sHat).^2);
        ssTot = sum((Sr - mean(Sr)).^2);
        if ssTot > 0, R2to = 1 - ssRes/ssTot; end

        figure(figP);
        xLineC = linspace(0, max(Cr) * 1.08, 50);
        plot(xLineC, kTool * xLineC, '-', 'Color', col, ...
            'LineWidth', 2.0, 'HandleVisibility', 'off');
        legLP{end+1} = sprintf('H=%d ML=%d: k=%.4f (s/C, dimensionless), R^2=%.2f', ...
            Hval, MLval, kTool, R2to); %#ok<AGROW>
    else
        legLN{end+1} = sprintf('H=%d ML=%d: <%d rising pts, no fit', Hval, MLval, minPts); %#ok<AGROW>
        legLP{end+1} = sprintf('H=%d ML=%d: <%d rising pts, no fit', Hval, MLval, minPts); %#ok<AGROW>
    end

    legHN(end+1) = hDataN; %#ok<AGROW>
    legHP(end+1) = hDataP; %#ok<AGROW>

    fprintf('  H=%d ML=%d: k_slope=%.3f %%/px | W0=%.1f px | R2=%.3f || k_tool=%.4f (s/C) | R2=%.3f | widths: %s\n', ...
        Hval, MLval, kSlope, W0, R2on, kTool, R2to, mat2str(selW(:)'));

    fitRows = [fitRows; {Hval, MLval, kSlope, W0, R2on, kTool, R2to, ...
        numel(selW), min([selW; NaN]), max([selW; NaN])}]; %#ok<AGROW>
end

% ---------- Finalize normalized (onset-model) figure ----------
figure(figN);
xlabel('Width (printer px, 1 px = 32 \mum)', 'FontSize', 16, 'FontWeight', 'bold');
ylabel('Membrane Reach (% of Open Height)', 'FontSize', 16, 'FontWeight', 'bold');
title({'Onset-model fits: reach = k(W - W_0), pre-saturation regime', ...
    'filled = used in fit, open = excluded (below onset / saturated)'}, 'FontSize', 13);
ylim([0 105]);
grid on; box on
set(gca, 'FontSize', 14, 'LineWidth', 1);
legend(legHN, legLN, 'Location', 'southeast', 'FontSize', 11);
hold off
exportgraphics(figN, fullfile(resultsFolder, 'reach_linear_fits.png'), 'Resolution', 200);
try
    exportgraphics(figN, fullfile(resultsFolder, 'reach_linear_fits.pdf'), 'ContentType', 'vector');
catch
end
close(figN);

% ---------- Finalize physical (through-origin) figure ----------
figure(figP);
xlabel(sprintf('Membrane width C (\\mum)  [C = W \\times %g \\mum/px]', umPerPx), ...
    'FontSize', 16, 'FontWeight', 'bold');
ylabel(sprintf('Sagitta s (\\mum)  [s = reach \\times H_c, H_c = layers \\times %g \\mum]', umPerLayer), ...
    'FontSize', 16, 'FontWeight', 'bold');
title({'Through-origin fits: s = kC (tool-compatible, k dimensionless)', ...
    'filled = used in fit, open = excluded (below onset / saturated)'}, 'FontSize', 13);
grid on; box on
set(gca, 'FontSize', 14, 'LineWidth', 1);
xlim([0, inf]); ylim([0, inf]);
legend(legHP, legLP, 'Location', 'northwest', 'FontSize', 11);
hold off
exportgraphics(figP, fullfile(resultsFolder, 'reach_linear_fits_physical.png'), 'Resolution', 200);
try
    exportgraphics(figP, fullfile(resultsFolder, 'reach_linear_fits_physical.pdf'), 'ContentType', 'vector');
catch
end
close(figP);

Tfits = cell2table(fitRows, 'VariableNames', ...
    {'Height_layers','MembraneLayers','k_slope_pct_per_px','W0_onset_px','R2_onset', ...
     'k_tool_dimensionless','R2_throughOrigin','nWidthsUsed','W_used_min','W_used_max'});
writetable(Tfits, fullfile(resultsFolder, 'reach_linear_fits.csv'));

fprintf('Saved: reach_linear_fits(.png/.pdf), reach_linear_fits_physical(.png/.pdf), reach_linear_fits.csv\n');

end
