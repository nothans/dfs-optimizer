%% Quick start: one lineup, then a tournament lineup
% Works from any folder: the repo root is added to the path below.

root = fileparts(fileparts(mfilename("fullpath")));
addpath(root);
players = dfs.loadProjections(fullfile(root, "data", "sample_DFF_NFL.csv"));

%% The cash-game lineup: maximize projected points, nothing else
[cash, cashInfo] = dfs.optimizeLineup(players);
disp(cash(:, ["Slot", "Name", "Team", "Opp", "Salary", "Projection", "Ownership"]))
fprintf("Cash: %.1f pts, $%d, %.0f%% summed ownership\n\n", ...
    cashInfo.ProjectedPoints, cashInfo.TotalSalary, cashInfo.Ownership);

%% The tournament lineup: correlate, and fade the chalk a little
% StackSize=2      QB plus two of his own WR/TE
% BringBack=1      one RB/WR/TE from the QB's opponent (a game stack)
% AvoidQBvsDST     never a defense against your own QB
% OwnershipWeight  each 1% of projected ownership costs 0.05 points
[gpp, gppInfo] = dfs.optimizeLineup(players, StackSize=2, BringBack=1, ...
    AvoidQBvsDST=true, OwnershipWeight=0.05);
disp(gpp(:, ["Slot", "Name", "Team", "Opp", "Salary", "Projection", "Ownership"]))
fprintf("GPP: %.1f pts (%.1f given up), %.0f%% summed ownership (%.0f%% less)\n", ...
    gppInfo.ProjectedPoints, cashInfo.ProjectedPoints - gppInfo.ProjectedPoints, ...
    gppInfo.Ownership, cashInfo.Ownership - gppInfo.Ownership);

%% Audit the answer without the solver
[ok, problems] = dfs.validateLineup(gpp, "DraftKings");
assert(ok, join(problems, newline));
