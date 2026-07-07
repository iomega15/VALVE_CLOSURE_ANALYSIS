function [pass, qc] = qualityGateDeflection(results, openHeight_px, baseTag)
%QUALITYGATEDEFLECTION  Multi-criteria quality check for membrane deflection fits.
%
%   [pass, qc] = qualityGateDeflection(results, openHeight_px, baseTag)
%
%   RETURNS:
%     pass  — logical, true if the measurement is trustworthy
%     qc    — struct with individual check results and a human-readable reason
%
%   PHILOSOPHY:
%     Bad fits → NaN (discarded), NOT zero.
%     "No deflection" is a valid physical result and is handled separately
%     upstream (areaObstructed_pct <= 0.5 → reach = 0).
%     This gate only fires on cases where we DETECTED something but
%     can't trust the measurement.

    if nargin < 3, baseTag = ''; end

    qc = struct();
    qc.tag = baseTag;
    qc.reasons = {};

    %% ================================================================
    %  CHECK 1: FIT QUALITY (R²)
    %  A good membrane shape should be well-described by arc or parabola.
    %  Negative R² means the fit is worse than a horizontal line.
    %  ================================================================
    minR2_primary = 0.60;    % for whichever fit was selected
    minR2_either  = 0.40;    % at least one fit must exceed this

    bestR2 = max([results.arcR2, results.parabola_R2], [], 'omitnan');

    qc.bestR2 = bestR2;
    qc.arcR2  = results.arcR2;
    qc.paraR2 = results.parabola_R2;

    if isnan(bestR2) || bestR2 < minR2_either
        qc.reasons{end+1} = sprintf('R2_too_low (best=%.3f, need>=%.2f)', bestR2, minR2_either);
    end

    %% ================================================================
    %  CHECK 2: PHYSICALLY IMPOSSIBLE RADIUS
    %  R must be positive and larger than half the span (geometric limit).
    %  Very small R means the arc is trying to curl tighter than possible.
    %  ================================================================
    if isfinite(results.R_fit)
        W = results.spanRight - results.spanLeft;
        minR = W / 2;   % geometric minimum: semicircle

        qc.R_fit = results.R_fit;
        qc.minR  = minR;

        if results.R_fit <= 0
            qc.reasons{end+1} = sprintf('R_negative (R=%.1f)', results.R_fit);
        elseif results.R_fit < minR * 0.8
            qc.reasons{end+1} = sprintf('R_too_small (R=%.1f < %.1f)', results.R_fit, minR);
        end
    end

    %% ================================================================
    %  CHECK 3: DEPTH PROFILE SHAPE — peak should be interior, not at edges
    %  A real membrane bulges in the middle. Debris/noise creates edge spikes.
    %  ================================================================
    rc = results.reachCurve_px;
    validIdx = find(~isnan(rc));

    if numel(validIdx) >= 5
        nValid    = numel(validIdx);
        edgeFrac  = 0.10;   % outer 20% on each side = "edge zone"
        edgePx    = max(2, round(nValid * edgeFrac));

        depthVals  = rc(validIdx);
        [maxDepth, maxPos] = max(depthVals);

        isEdgePeak = (maxPos <= edgePx) || (maxPos >= nValid - edgePx + 1);

        qc.peakPosition   = maxPos;
        qc.nValidCols     = nValid;
        qc.isEdgePeak     = isEdgePeak;

        if isEdgePeak && maxDepth > 3   % only flag if nontrivial depth
            qc.reasons{end+1} = sprintf('edge_peak (pos=%d/%d)', maxPos, nValid);
        end

        %% CHECK 3b: PROFILE SYMMETRY
        %  A real membrane is roughly symmetric. Highly asymmetric profiles
        %  usually indicate debris or segmentation artifacts.
        midIdx = round(nValid / 2);
        leftHalf  = depthVals(1:midIdx);
        rightHalf = depthVals(end:-1:end-midIdx+1);
        minLen = min(numel(leftHalf), numel(rightHalf));
        leftHalf  = leftHalf(1:minLen);
        rightHalf = rightHalf(1:minLen);

        if max(depthVals) > 3  % only check symmetry for nontrivial deflections
            asymmetry = mean(abs(leftHalf - rightHalf)) / max(1, max(depthVals));
            qc.asymmetry = asymmetry;

            if asymmetry > 0.60
                qc.reasons{end+1} = sprintf('asymmetric (%.2f)', asymmetry);
            end
        end
    end

    %% ================================================================
    %  CHECK 4: OBSTRUCTION WIDTH COVERAGE
    %  Real membrane deflection spans most of the channel width.
    %  Debris is typically a small isolated blob.
    %  ================================================================
    if isfield(results, 'frontBottom') && isfield(results, 'spanLeft') && isfield(results, 'spanRight')
        spanW = results.spanRight - results.spanLeft;

        obsColsInSpan = find(~isnan(results.frontBottom));
        obsColsInSpan = obsColsInSpan(obsColsInSpan >= results.spanLeft & ...
                                       obsColsInSpan <= results.spanRight);

        if spanW > 0
            widthCoverage = numel(obsColsInSpan) / spanW;
        else
            widthCoverage = 0;
        end

        qc.widthCoverage = widthCoverage;

        minCoverage = 0.30;   % obstruction must span ≥30% of channel width
        if widthCoverage < minCoverage
            qc.reasons{end+1} = sprintf('narrow_obstruction (%.0f%% coverage, need>=%.0f%%)', ...
                widthCoverage*100, minCoverage*100);
        end
    end

    %% ================================================================
    %  CHECK 5: REACH MAGNITUDE VS NOISE FLOOR
    %  Very small reach values (a few pixels) are indistinguishable from
    %  noise in registration, thresholding, etc.
    %  ================================================================
    noiseFloor_px  = 5;      % absolute minimum detectable deflection (pixels)
    noiseFloor_pct = 3.0;    % percent of open height

    qc.reach_px  = results.maxReach_px;
    qc.reach_pct = results.reach_pct;

    reachBelowNoise = (results.maxReach_px < noiseFloor_px) && ...
                      (results.reach_pct < noiseFloor_pct);

    % Don't flag this as a failure — it's genuinely "no deflection"
    % But DO flag if the area obstruction is large but reach is tiny
    % (inconsistent → probably artifact)
    if results.areaObstructed_pct > 10 && reachBelowNoise
        qc.reasons{end+1} = sprintf('area_reach_mismatch (area=%.1f%% but reach=%.1fpx)', ...
            results.areaObstructed_pct, results.maxReach_px);
    end

    %% ================================================================
    %  CHECK 6: OBSTRUCTION MUST CONNECT TO CHANNEL TOP
    %  The membrane descends from the top of the channel. If the
    %  obstruction blob doesn't touch the top of the lumen, it's debris.
    %  ================================================================
    if isfield(results, 'obstructionMaskCompute') && isfield(results, 'openTop')
        obsMask = results.obstructionMaskCompute;
        topRow  = nan;

        % Find topmost row of obstruction
        obsRows = find(any(obsMask, 2));
        if ~isempty(obsRows)
            topObsRow = obsRows(1);

            % Find median top of lumen in the obstruction columns
            obsCols_check = find(any(obsMask, 1));
            topLumenAtObs = results.openTop(obsCols_check);
            topLumenAtObs = topLumenAtObs(~isnan(topLumenAtObs));

            if ~isempty(topLumenAtObs)
                medianTop = median(topLumenAtObs);
                gapFromTop = topObsRow - medianTop;

                qc.gapFromTop_px = gapFromTop;

                % Allow a small gap (registration jitter, threshold edge)
                maxGap_px = max(5, round(openHeight_px * 0.15));
                if gapFromTop > maxGap_px
                    qc.reasons{end+1} = sprintf('detached_from_top (gap=%dpx, max=%dpx)', ...
                        round(gapFromTop), maxGap_px);
                end
            end
        end
    end

    %% ================================================================
    %  CHECK 7: CONSTRAINED FIT VERTEX SANITY
    %  For the arc: d_fit must be positive
    %  For the parabola: a must be negative (opens downward = bulges down)
    %  ================================================================
    if isfinite(results.d_fit) && results.d_fit <= 0
        qc.reasons{end+1} = sprintf('arc_d_nonpositive (d=%.2f)', results.d_fit);
    end

    if isfinite(results.a_parabola) && results.a_parabola >= 0
        qc.reasons{end+1} = 'parabola_opens_upward';
    end

    %% ================================================================
    %  FINAL VERDICT
    %  ================================================================
    qc.nFailures = numel(qc.reasons);
    pass = (qc.nFailures == 0);

    if pass
        qc.verdict = "PASS";
    else
        qc.verdict = "FAIL: " + strjoin(qc.reasons, ' | ');
    end

    % Console output
    if ~pass
        fprintf('    QC FAIL [%s]: %s\n', baseTag, qc.verdict);
    else
        fprintf('    QC PASS [%s]\n', baseTag);
    end

end