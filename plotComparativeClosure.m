function plotComparativeClosure(T, resultsFolder, metricColumn, metricLabel, outputSuffix)
% PLOTCOMPARATIVECLOSURE
%   Closure-version companion to plotComparativeSag.
%   Produces:
%     1) 3D scatter with SEM bars
%     2) 3D surface through group means, only when dataset is truly 2D
%     3) 2D mean ± SEM lines vs width
%
%   Expected columns in T:
%     Height_layers, Width_px, MembraneLayers, Replicate
%     metricColumn (e.g. AreaObstructed_pct, MaxDownwardReach_pct)
%     Notes
%
%   Important:
%     - If the design space is effectively 1D (for example Width varies but
%       MembraneLayers is constant), the surface plot is skipped automatically.
%     - Values are clamped to [0, 100].

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

    % =====================================================================
    % 1. FILTER VALID ROWS
    % =====================================================================
    good = strcmp(string(T.Notes), "OK") & ~isnan(T.(metricColumn));
    T_clean = T(good, :);

    if isempty(T_clean) || height(T_clean) == 0
        warning('No valid rows for %s. Skipping.', metricColumn);
        return;
    end

    % Clamp metric to [0,100]
    T_clean.(metricColumn) = max(0, min(100, T_clean.(metricColumn)));

    % =====================================================================
    % 2. GROUP STATISTICS ACROSS REPLICATES
    % =====================================================================
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

    % =====================================================================
    % STYLE SETUP
    % =====================================================================
    markerList = {'o','s','^','d','v','>','<','p','h'};
    lineStyles = {'-','--',':','-.'};

    Hvals = unique(T_stats.Height_layers, 'stable');
    colors = lines(max(numel(Hvals),3));

    % =====================================================================
    % FIGURE 1: 3D SCATTER
    % =====================================================================
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

    % =====================================================================
    % FIGURE 2: 3D SURFACE
    % Only meaningful when there is actual 2D variation in Width and ML.
    % =====================================================================
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

    % =====================================================================
    % FIGURE 3: 2D LINES VS WIDTH
    % One line per membrane thickness.
    % If there is only one ML, this naturally becomes one line.
    % =====================================================================
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