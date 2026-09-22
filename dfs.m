%% DFS Lineup Optimizer - quick script
% Builds the highest-projected legal NFL lineup from a projections CSV.
%
% 1. Download projections from Daily Fantasy Fuel
%    (https://www.dailyfantasyfuel.com/nfl/projections/) with the
%    "Download CSV" link and save the file next to this script as DFF_data.csv.
%    No file? The bundled sample slate in data/ runs instead.
% 2. Set the salary cap below (50,000 for DraftKings, 60,000 for FanDuel).
% 3. Run. The lineup prints with slots, salary, and projected points.
%
% Want stacks, ownership leverage, 20 distinct tournament lineups, or a
% Monte Carlo view of which players hold up? Open the explorer app:
%
%     DFSOptimizerApp
%
% Every lever in the app is also a name-value option on dfs.optimizeLineup
% and dfs.generateLineups. See README.md.

salaryCap = 50000;
site = "DraftKings";            % or "FanDuel"

projectionsFile = "DFF_data.csv";
if ~isfile(projectionsFile)
    projectionsFile = fullfile(fileparts(mfilename("fullpath")), "data", "sample_DFF_NFL.csv");
    fprintf("No DFF_data.csv found, using the sample slate: %s\n", projectionsFile);
end

%% Load the player pool
% Injured-out players and zero projections are dropped. Every original
% column from the CSV is kept after the canonical ones.
players = dfs.loadProjections(projectionsFile, Site=site);
fprintf("%d players across %d games\n", height(players), numel(unique(players.Game)));

%% Optimize
% One binary variable per player, maximize projected points subject to the
% site's roster shape, salary cap, and game/team rules. Solved with
% intlinprog through the problem-based Optimization Toolbox interface.
[OptimalTeam, info] = dfs.optimizeLineup(players, Site=site, SalaryCap=salaryCap);

%% Display the optimal team
disp(OptimalTeam(:, ["Slot", "Name", "Position", "Team", "Opp", "Salary", "Projection", "Ownership"]))
fprintf("Projected points: %.1f | Salary: $%d of $%d | Solve: %.2f s | %s\n", ...
    info.ProjectedPoints, info.TotalSalary, salaryCap, info.SolveTime, info.Message);

%% Next: a tournament stack
% Uncomment to require the QB's WR/TE, a bring-back from the opponent, and
% no defense against your own QB, while fading heavily owned players.
% [GppTeam, gppInfo] = dfs.optimizeLineup(players, Site=site, SalaryCap=salaryCap, ...
%     StackSize=1, BringBack=1, AvoidQBvsDST=true, OwnershipWeight=0.05);
% disp(GppTeam(:, ["Slot", "Name", "Team", "Salary", "Projection", "Ownership"]))
