function plotCombinedClosureReach(T, resultsFolder)
% Dual-axis closure plot: Area Obstructed (left) + Membrane Reach (right)
% vs channel width. One line per (Height, MembraneLayers) series — the
% dataset contains both H5 (ML1-3) and H10 (ML1), and mixing them into a
% single line per ML produced vertical sawtooth artifacts.
% Error bars = +/-1 SEM across replicates.

if ~exist(resultsFolder, 'dir')
    mkdir(resultsFolder);
end

good = (strcmp(string(T.Notes), "OK") | ...
    strcmp(string(T.Notes), "OK_parabola") | ...
    strcmp(string(T.Notes), "OK_zero_reach") | ...
    strcmp(string(T.Notes), "OK_reach_geom_fallback") | ...
    strcmp(string(T.Notes), "Incomplete pair -> assumed no closure")) ...
    & ~isnan(T.AreaObstructed_pct) & ~isnan(T.MaxDownwardReach_pct);

T_clean = T(good, :);

if isempty(T_clean) || height(T_clean) == 0
    warning('No valid rows for combined plot. Skipping.');
    return;
end

T_clean.AreaObstructed_pct    = max(0, min(100, T_clean.AreaObstructed_pct));
T_clean.MaxDownwardReach_pct  = max(0, min(100, T_clean.MaxDownwardReach_pct));

groupVars = {'Height_layers','MembraneLayers','Width_px'};
T_stats = groupsummary(T_clean, groupVars, {'mean','std'}, ...
    {'AreaObstructed_pct','MaxDownwardReach_pct'});

T_stats = T_stats(~isnan(T_stats.mean_AreaObstructed_pct) & ...
                   ~isnan(T_stats.mean_MaxDownwardReach_pct), :);

if isempty(T_stats) || height(T_stats) == 0
    warning('No valid grouped statistics for combined plot.');
    return;
end

T_stats.SEM_Area  = T_stats.std_AreaObstructed_pct   ./ sqrt(T_stats.GroupCount);
T_stats.SEM_Reach = T_stats.std_MaxDownwardReach_pct ./ sqrt(T_stats.GroupCount);

% One series per (Height, ML) combination present in the data
comboKeys = unique(T_stats(:, {'Height_layers','MembraneLayers'}), 'rows');
comboKeys = sortrows(comboKeys, {'Height_layers','MembraneLayers'});
nCombo    = height(comboKeys);

markerList = {'o','s','^','d','v','>','<','p','h'};
lineStyles = {'-','--',':','-.'};

% Colors: blue family for area, red family for reach
blueColors = [0.0 0.2 0.6; 0.2 0.4 0.8; 0.4 0.6 1.0; 0.1 0.3 0.7];
redColors  = [0.8 0.1 0.1; 1.0 0.3 0.2; 0.9 0.5 0.3; 0.7 0.0 0.0];

fig = figure('Position', [100 100 1200 700], 'Color', 'w');

yyaxis left
hold on
legHandlesL = [];
legLabelsL  = {};

for c = 1:nCombo
    Hval  = comboKeys.Height_layers(c);
    MLval = comboKeys.MembraneLayers(c);
    subT  = T_stats(T_stats.Height_layers == Hval & ...
                    T_stats.MembraneLayers == MLval, :);
    if isempty(subT), continue; end

    [xData, si] = sort(subT.Width_px);
    yData = subT.mean_AreaObstructed_pct(si);
    eData = subT.SEM_Area(si);

    col = blueColors(mod(c-1, size(blueColors,1))+1, :);
    mk  = markerList{mod(c-1, numel(markerList))+1};
    ls  = lineStyles{mod(c-1, numel(lineStyles))+1};

    h = errorbar(xData, yData, eData, ...
        'LineStyle', ls, 'Marker', mk, ...
        'LineWidth', 2.0, 'MarkerSize', 8, 'CapSize', 5, ...
        'Color', col, 'MarkerFaceColor', col);

    legHandlesL(end+1) = h; %#ok<AGROW>
    legLabelsL{end+1}  = sprintf('Area (H=%d, ML=%d)', Hval, MLval); %#ok<AGROW>
end

ylabel('Area Obstructed (%)', 'FontSize', 16, 'FontWeight', 'bold');
ylim([0 100]);
ax = gca;
ax.YColor = [0.0 0.2 0.6];
hold off

yyaxis right
hold on
legHandlesR = [];
legLabelsR  = {};

for c = 1:nCombo
    Hval  = comboKeys.Height_layers(c);
    MLval = comboKeys.MembraneLayers(c);
    subT  = T_stats(T_stats.Height_layers == Hval & ...
                    T_stats.MembraneLayers == MLval, :);
    if isempty(subT), continue; end

    [xData, si] = sort(subT.Width_px);
    yData = subT.mean_MaxDownwardReach_pct(si);
    eData = subT.SEM_Reach(si);

    col = redColors(mod(c-1, size(redColors,1))+1, :);
    mk  = markerList{mod(c-1, numel(markerList))+1};
    ls  = lineStyles{mod(c-1, numel(lineStyles))+1};

    h = errorbar(xData, yData, eData, ...
        'LineStyle', ls, 'Marker', mk, ...
        'LineWidth', 2.0, 'MarkerSize', 8, 'CapSize', 5, ...
        'Color', col, 'MarkerFaceColor', col);

    legHandlesR(end+1) = h; %#ok<AGROW>
    legLabelsR{end+1}  = sprintf('Reach (H=%d, ML=%d)', Hval, MLval); %#ok<AGROW>
end

ylabel('Membrane Reach (% of Open Height)', 'FontSize', 16, 'FontWeight', 'bold');
ylim([0 100]);
ax = gca;
ax.YColor = [0.8 0.1 0.1];
hold off

xlabel('Width (printer px, 1 px = 32 \mum)', 'FontSize', 16, 'FontWeight', 'bold');

grid on
box on
set(gca, 'FontSize', 16, 'LineWidth', 1);

allHandles = [legHandlesL legHandlesR];
allLabels  = [legLabelsL  legLabelsR];
if ~isempty(allHandles)
    legend(allHandles, allLabels, 'Location', 'bestoutside', 'Interpreter', 'none');
end

exportgraphics(fig, fullfile(resultsFolder, 'closure_combined_dual_axis.png'), 'Resolution', 200);
try
    exportgraphics(fig, fullfile(resultsFolder, 'closure_combined_dual_axis.pdf'), ...
        'ContentType', 'vector');
catch
end

fprintf('Saved: closure_combined_dual_axis.png\n');

end
