function plotReachLinearFits(T, resultsFolder)
% Linear fits of Membrane Reach (%) vs channel width per (H, ML) series,
% restricted to the RISING (pre-saturation) regime:
%
%   reach(W) ~ k * (W - W0)      k  = slope [% of open height / printer px]
%                                W0 = onset width (x-intercept) [printer px]
%
% Rising regime = longest contiguous run of widths whose MEAN reach lies in
% (riseMin, satMax). With <=9 width points per series, fixed physical
% thresholds are more robust and reproducible than changepoint detection
% (ischange/findchangepts move the breakpoint between noisy reruns).
% Fits use replicate-level points, not means, so R^2 reflects real scatter.
%
% Outputs: reach_linear_fits.png/.pdf + reach_linear_fits.csv + console table.

riseMin = 3;     % mean reach (%) below this  = valve not yet closing
satMax  = 85;    % mean reach (%) above this  = floor-contact saturation
minPts  = 3;     % minimum number of widths required to fit

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

fig = figure('Position', [100 100 1200 700], 'Color', 'w', 'Visible', 'off');
hold on

legH = [];
legL = {};
fitRows = [];   % accumulates CSV rows

fprintf('\n=== LINEAR REACH FITS (rising regime: %g%% < mean reach < %g%%) ===\n', ...
    riseMin, satMax);

for c = 1:nCombo
    Hval  = comboKeys.Height_layers(c);
    MLval = comboKeys.MembraneLayers(c);

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

    % Data: filled markers = used in fit, open markers = excluded (zero/saturated)
    hData = errorbar(subT.Width_px(useIdx), meanR(useIdx), subT.SEM(useIdx), ...
        'LineStyle', 'none', 'Marker', mk, 'MarkerSize', 9, ...
        'Color', col, 'MarkerFaceColor', col, 'LineWidth', 1.5, 'CapSize', 5);
    errorbar(subT.Width_px(~useIdx), meanR(~useIdx), subT.SEM(~useIdx), ...
        'LineStyle', 'none', 'Marker', mk, 'MarkerSize', 9, ...
        'Color', col, 'MarkerFaceColor', 'none', 'LineWidth', 1.0, ...
        'CapSize', 5, 'HandleVisibility', 'off');

    kFit = NaN; W0 = NaN; R2 = NaN;
    selW = subT.Width_px(useIdx);

    if numel(selW) >= minPts
        % Fit on replicate-level points at the selected widths
        repMask = T_clean.Height_layers == Hval & ...
                  T_clean.MembraneLayers == MLval & ...
                  ismember(T_clean.Width_px, selW);
        x = double(T_clean.Width_px(repMask));
        y = double(T_clean.MaxDownwardReach_pct(repMask));

        p    = polyfit(x, y, 1);
        yhat = polyval(p, x);
        ssRes = sum((y - yhat).^2);
        ssTot = sum((y - mean(y)).^2);
        if ssTot > 0, R2 = 1 - ssRes/ssTot; end

        kFit = p(1);
        W0   = -p(2) / p(1);

        xLine = linspace(max(min(selW) - 15, W0), max(selW) + 8, 50);
        plot(xLine, polyval(p, xLine), '-', 'Color', col, ...
            'LineWidth', 2.0, 'HandleVisibility', 'off');

        legL{end+1} = sprintf('H=%d ML=%d: k=%.2f %%/px, W_0=%.0f px, R^2=%.2f', ...
            Hval, MLval, kFit, W0, R2); %#ok<AGROW>
    else
        legL{end+1} = sprintf('H=%d ML=%d: <%d rising pts, no fit', ...
            Hval, MLval, minPts); %#ok<AGROW>
    end
    legH(end+1) = hData; %#ok<AGROW>

    fprintf('  H=%d ML=%d: k=%.3f %%/px | W0=%.1f px | R^2=%.3f | widths used: %s\n', ...
        Hval, MLval, kFit, W0, R2, mat2str(selW(:)'));

    fitRows = [fitRows; {Hval, MLval, kFit, W0, R2, numel(selW), ...
        min([selW; NaN]), max([selW; NaN])}]; %#ok<AGROW>
end

xlabel('Width (printer px, 1 px = 32 \mum)', 'FontSize', 16, 'FontWeight', 'bold');
ylabel('Membrane Reach (% of Open Height)', 'FontSize', 16, 'FontWeight', 'bold');
title({'Linear fits of reach vs width (pre-saturation regime)', ...
    'filled = used in fit, open = excluded (below onset / saturated)'}, 'FontSize', 13);
ylim([0 105]);
grid on
box on
set(gca, 'FontSize', 14, 'LineWidth', 1);
legend(legH, legL, 'Location', 'southeast', 'FontSize', 11);
hold off

exportgraphics(fig, fullfile(resultsFolder, 'reach_linear_fits.png'), 'Resolution', 200);
try
    exportgraphics(fig, fullfile(resultsFolder, 'reach_linear_fits.pdf'), ...
        'ContentType', 'vector');
catch
end
close(fig);

Tfits = cell2table(fitRows, 'VariableNames', ...
    {'Height_layers','MembraneLayers','k_pct_per_printerpx','W0_onset_px', ...
     'R2','nWidthsUsed','W_used_min','W_used_max'});
writetable(Tfits, fullfile(resultsFolder, 'reach_linear_fits.csv'));

fprintf('Saved: reach_linear_fits.png / .csv\n');

end
