clear all
clc
close all

resultsDir = 'C:\Users\rvoronov\Dropbox\MANUSCRIPTS\micromachines_valve_printing_framework\Figures\NanoClear\Sorted_ConstH5\Cutout_ConstH5_Cleaned\VALVE_CLOSURE_RESULTS';

matFile = fullfile(resultsDir, 'valve_closure_pairwise_results.mat');
S = load(matFile);

Tresults = S.Tresults;

plotComparativeClosure(Tresults, resultsDir, 'AreaObstructed_pct', ...
    'Area Obstructed', '_obstruction');

plotComparativeClosure(Tresults, resultsDir, 'MaxDownwardReach_pct', ...
    'Membrane Reach (% of Open Height)', '_reach');