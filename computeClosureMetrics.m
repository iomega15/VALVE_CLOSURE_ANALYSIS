function results = computeClosureMetrics(BWopen, BWclosedInOpen, qClosed)

    BWopen = logical(BWopen);
    BWclosedInOpen = logical(BWclosedInOpen);

    [H, W] = size(BWopen); %#ok<ASGLU>

    openArea = nnz(BWopen);
    closedArea = nnz(BWclosedInOpen);

    if openArea == 0
        error('Open lumen mask is empty.');
    end

    areaObstructed_pct = 100 * (openArea - closedArea) / openArea;

    % Column-wise top and bottom boundaries for open lumen
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
        error('Could not extract open lumen boundaries.');
    end

    openHeightByCol = openBottom(validCols) - openTop(validCols) + 1;
    openHeight_px = median(openHeightByCol);

    % Closed top boundary: top of residual open lumen
    closedTop = nan(1, W);

    if closedArea > 0
        for c = 1:W
            rows = find(BWclosedInOpen(:, c));
            if ~isempty(rows)
                closedTop(c) = rows(1);
            end
        end
    end

    % Positive value means membrane pushed downward
    downwardReach = nan(1, W);

    if closedArea > 0
        commonCols = find(~isnan(openTop) & ~isnan(closedTop));
        downwardReach(commonCols) = closedTop(commonCols) - openTop(commonCols);
    else
        commonCols = [];
    end

    % If closed lumen disappeared completely, treat as full closure
    if closedArea == 0
        maxDownwardReach_px = openHeight_px;
        maxDownwardReach_pct = 100;
        xAtMaxReach = NaN;
        yClosedAtMaxReach = NaN;
        yOpenTopAtMaxReach = NaN;

    else
        validReachCols = find(~isnan(downwardReach));

        if isempty(validReachCols)
            % No overlapping residual lumen columns inside the open lumen
            maxDownwardReach_px = openHeight_px;
            maxDownwardReach_pct = 100;
            xAtMaxReach = NaN;
            yClosedAtMaxReach = NaN;
            yOpenTopAtMaxReach = NaN;

        else
            validReachVals = downwardReach(validReachCols);
            [maxDownwardReach_px, localIdx] = max(validReachVals);

            xAtMaxReach = validReachCols(localIdx);
            yClosedAtMaxReach = closedTop(xAtMaxReach);
            yOpenTopAtMaxReach = openTop(xAtMaxReach);
            maxDownwardReach_pct = 100 * maxDownwardReach_px / openHeight_px;
        end
    end

    results = struct();
    results.openArea_px = openArea;
    results.closedArea_px = closedArea;
    results.areaObstructed_pct = areaObstructed_pct;

    results.openTop = openTop;
    results.openBottom = openBottom;
    results.closedTop = closedTop;
    results.validCols = validCols;
    results.downwardReach = downwardReach;

    results.openHeight_px = openHeight_px;
    results.maxDownwardReach_px = maxDownwardReach_px;
    results.maxDownwardReach_pctOfOpenHeight = maxDownwardReach_pct;

    results.xAtMaxReach = xAtMaxReach;
    results.yClosedAtMaxReach = yClosedAtMaxReach;
    results.yOpenTopAtMaxReach = yOpenTopAtMaxReach;

    results.closedSegmentationStatus = qClosed.status;
    results.closedSegmentationValid = qClosed.lumen_valid;
end