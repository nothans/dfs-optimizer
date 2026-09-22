%% Tournament portfolio: 20 distinct lineups, exposure-capped, then stress-tested
% Works from any folder: the repo root is added to the path below.

root = fileparts(fileparts(mfilename("fullpath")));
addpath(root);
players = dfs.loadProjections(fullfile(root, "data", "sample_DFF_NFL.csv"));

%% Build the portfolio
% MaxExposure=0.4   nobody appears in more than 40% of lineups
% MinUnique=3       every pair of lineups differs by at least 3 players
% Randomness=0.1    jitter projections ~10% per lineup so the set spreads
[lineups, summary, exposure] = dfs.generateLineups(players, 20, ...
    MaxExposure=0.4, MinUnique=3, Randomness=0.1, Seed=7, ...
    StackSize=1, BringBack=1, AvoidQBvsDST=true, OwnershipWeight=0.03);

disp(summary(:, ["Lineup", "Points", "Salary", "Ownership", "QB", "Stack"]))

%% Where am I over- or under-exposed versus the field?
% Leverage = your exposure % minus projected field ownership %.
disp(head(sortrows(exposure, "Leverage", "descend"), 10))
disp(head(sortrows(exposure, "Leverage", "ascend"), 5))

%% Which players hold up when projections are noisy?
% Each draw perturbs every projection (per-position volatility), re-solves,
% and counts who made the optimal lineup. High frequency = robust play.
[frequency, simLineups] = dfs.simulateLineups(players, 100, Seed=7, StackSize=1, AvoidQBvsDST=true);
disp(head(frequency, 15))
fprintf("%d distinct optimal lineups across 100 draws; the modal lineup showed up %d times.\n", ...
    height(simLineups), simLineups.Draws(1));

%% Export in site upload order
dfs.exportLineups(lineups, "lineups.csv");
