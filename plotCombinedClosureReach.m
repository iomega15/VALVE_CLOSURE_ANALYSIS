function plotCombinedClosureReach(T, resultsFolder)

if ~exist(resultsFolder, 'dir')
    mkdir(resultsFolder);
end

good = (strcmp(string(T.Notes), "OK") | ...
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

groupVars = {'Width_px','MembraneLayers','Height_layers'};
T_stats = groupsummary(T_clean, groupVars, 'mean', ...
    {'AreaObstructed_pct','MaxDownwardReach_pct'});

T_stats = T_stats(~isnan(T_stats.mean_AreaObstructed_pct) & ...
                   ~isnan(T_stats.mean_MaxDownwardReach_pct), :);

if isempty(T_stats) || height(T_stats) == 0
    warning('No valid grouped statistics for combined plot.');
    return;
end

uniqueML = sort(unique(T_stats.MembraneLayers));
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

for m = 1:numel(uniqueML)
    MLval = uniqueML(m);
    subT = T_stats(T_stats.MembraneLayers == MLval, :);
    if isempty(subT), continue; end

    [xData, si] = sort(subT.Width_px);
    yData = subT.mean_AreaObstructed_pct(si);

    col = blueColors(mod(m-1, size(blueColors,1))+1, :);
    mk  = markerList{mod(m-1, numel(markerList))+1};
    ls  = lineStyles{mod(m-1, numel(lineStyles))+1};

    h = plot(xData, yData, ...
        'LineStyle', ls, 'Marker', mk, ...
        'LineWidth', 2.0, 'MarkerSize', 8, ...
        'Color', col, 'MarkerFaceColor', col);

    legHandlesL(end+1) = h; %#ok<AGROW>
    %legLabelsL{end+1}  = sprintf('Area Obstructed (ML=%d)', MLval); %#ok<AGROW>
    legLabelsL{end+1}  = sprintf('Area Obstructed', MLval); %#ok<AGROW>
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

for m = 1:numel(uniqueML)
    MLval = uniqueML(m);
    subT = T_stats(T_stats.MembraneLayers == MLval, :);
    if isempty(subT), continue; end

    [xData, si] = sort(subT.Width_px);
    yData = subT.mean_MaxDownwardReach_pct(si);

    col = redColors(mod(m-1, size(redColors,1))+1, :);
    mk  = markerList{mod(m-1, numel(markerList))+1};
    ls  = lineStyles{mod(m-1, numel(lineStyles))+1};

    h = plot(xData, yData, ...
        'LineStyle', ls, 'Marker', mk, ...
        'LineWidth', 2.0, 'MarkerSize', 8, ...
        'Color', col, 'MarkerFaceColor', col);

    legHandlesR(end+1) = h; %#ok<AGROW>
    %legLabelsR{end+1}  = sprintf('Membrane Reach (Mebrane Layers = %d)', MLval); %#ok<AGROW>
    legLabelsR{end+1}  = sprintf('Membrane Reach', MLval); 
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
    legend(allHandles, allLabels, 'Location', 'best', 'Interpreter', 'none');
end

exportgraphics(fig, fullfile(resultsFolder, 'closure_combined_dual_axis.png'), 'Resolution', 200);
try
    exportgraphics(fig, fullfile(resultsFolder, 'closure_combined_dual_axis.pdf'), ...
        'ContentType', 'vector');
catch
end

fprintf('Saved: closure_combined_dual_axis.png\n');

end