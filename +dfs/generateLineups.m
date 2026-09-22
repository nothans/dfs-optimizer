function [lineups, summary, exposure] = generateLineups(players, numLineups, opts)
%GENERATELINEUPS Build a portfolio of distinct lineups for tournament play.
%   lineups = dfs.generateLineups(players, N) builds N lineups one after
%   another. Each solve adds a uniqueness constraint against every earlier
%   lineup and an exposure cap per player, so the portfolio spreads risk
%   instead of repeating the single optimum N times.
%
%   [lineups, summary, exposure] = dfs.generateLineups(...) also returns a
%   summary table (one row per lineup: points, salary, ownership, the QB and
%   stack partners) and an exposure table (how many lineups each player is
%   in, versus projected field ownership).
%
%   Portfolio options
%     MaxExposure   fraction of lineups a player may appear in (default 1)
%     MinUnique     every pair of lineups differs by at least this many
%                   players (default 2)
%     Randomness    fraction of projection noise applied per lineup, e.g.
%                   0.10 jitters each projection by ~10% before each solve
%                   (default 0). Set Seed for reproducibility.
%     Seed          rng seed used when Randomness > 0
%     ProgressFcn   function handle f(k, N, info) called after each lineup;
%                   return true to stop early (for cancel buttons)
%
%   Every other name-value pair (Site, StackSize, BringBack, AvoidQBvsDST,
%   OwnershipWeight, Lock, Exclude, MinSalary, MaxOwnership, ...) passes
%   straight through to dfs.optimizeLineup.
%
%   `lineups` is a cell array of lineup tables. When the constraints run out
%   of room before N lineups exist, the function warns and returns the ones
%   it found.
%
%   Example: 20 GPP lineups, nobody in more than half of them
%       [L, S, E] = dfs.generateLineups(players, 20, MaxExposure=0.5, ...
%           MinUnique=3, StackSize=1, AvoidQBvsDST=true);

arguments
    players table
    numLineups (1,1) double {mustBeInteger, mustBePositive} = 1
    opts.MaxExposure (1,1) double {mustBePositive, mustBeLessThanOrEqual(opts.MaxExposure, 1)} = 1
    opts.MinUnique (1,1) double {mustBeInteger, mustBeNonnegative} = 2
    opts.Randomness (1,1) double {mustBeNonnegative} = 0
    opts.Seed = []
    opts.ProgressFcn = []
    opts.Site = "DraftKings"
    opts.SalaryCap (1,1) double = NaN
    opts.MinSalary (1,1) double = 0
    opts.MaxPerTeam (1,1) double = NaN
    opts.MaxFromGame (1,1) double {mustBePositive} = Inf
    opts.Objective = "Projection"
    opts.OwnershipWeight (1,1) double {mustBeNonnegative} = 0
    opts.Lock (1,:) string = strings(1, 0)
    opts.Exclude (1,:) string = strings(1, 0)
    opts.MaxOwnership (1,1) double = Inf
    opts.MaxPlayerOwnership (1,1) double = Inf
    opts.StackSize (1,1) double {mustBeInteger, mustBeNonnegative} = 0
    opts.BringBack (1,1) double {mustBeInteger, mustBeNonnegative} = 0
    opts.AvoidQBvsDST (1,1) logical = false
    opts.AvoidRBvsDST (1,1) logical = false
    opts.Options = []
end

n = height(players);
if ~isempty(opts.Seed)
    rng(opts.Seed, "twister");
end

% Split portfolio options from the pass-through solver options.
portfolioFields = ["MaxExposure", "MinUnique", "Randomness", "Seed", "ProgressFcn"];
solverOpts = rmfield(opts, portfolioFields);

% Exposure cap in lineups. A locked player is always allowed.
maxCount = max(1, floor(opts.MaxExposure * numLineups));
baseWeights = objectiveWeights(players, opts.Objective);

selected = false(0, n);
lineups = {};
infos = {};
counts = zeros(n, 1);
lockIdx = ismember(lower(players.Name), lower(opts.Lock));

for k = 1:numLineups
    args = solverOpts;
    args.PreviousLineups = selected;
    args.MinUnique = opts.MinUnique;

    % Players at their exposure cap sit out this solve.
    capped = counts >= maxCount & ~lockIdx;
    if any(capped)
        args.Exclude = unique([args.Exclude, players.Name(capped)']);
    end

    if opts.Randomness > 0
        args.Objective = baseWeights .* (1 + opts.Randomness * randn(n, 1));
    end

    try
        argCell = namedargs2cell(args);
        [L, info] = dfs.optimizeLineup(players, argCell{:});
    catch err
        if err.identifier == "dfs:infeasible"
            warning("dfs:portfolioShort", ...
                "Built %d of %d lineups before the constraints ran out of room (%s).", ...
                k - 1, numLineups, "MinUnique=" + opts.MinUnique + ", MaxExposure=" + opts.MaxExposure);
            break
        end
        rethrow(err);
    end

    % Report the true projection even when the objective was jittered.
    info.ProjectedPoints = sum(L.Projection);
    lineups{end+1, 1} = L; %#ok<AGROW>
    infos{end+1, 1} = info; %#ok<AGROW>
    selected(end+1, :) = info.Selected'; %#ok<AGROW>
    counts = counts + info.Selected;

    if ~isempty(opts.ProgressFcn)
        stop = opts.ProgressFcn(k, numLineups, info);
        if stop
            break
        end
    end
end

summary = summarize(lineups, infos);
exposure = exposureTable(players, counts, numel(lineups));
end

function w = objectiveWeights(players, objective)
if isnumeric(objective)
    w = double(objective(:));
else
    w = double(players.(string(objective))(:));
end
w(isnan(w)) = 0;
end

function S = summarize(lineups, infos)
m = numel(lineups);
Lineup = (1:m)';
Points = zeros(m, 1); Salary = zeros(m, 1); Ownership = zeros(m, 1);
QB = strings(m, 1); Stack = strings(m, 1); Players = strings(m, 1);
for k = 1:m
    L = lineups{k};
    Points(k) = infos{k}.ProjectedPoints;
    Salary(k) = infos{k}.TotalSalary;
    Ownership(k) = infos{k}.Ownership;
    qb = L(L.Slot == "QB", :);
    if ~isempty(qb)
        QB(k) = qb.Name(1);
        partners = L(L.Team == qb.Team(1) & ismember(string(L.Position), ["WR", "TE"]), :);
        bring = L(L.Team == qb.Opp(1) & ismember(string(L.Position), ["RB", "WR", "TE"]), :);
        Stack(k) = sprintf("%s +%d", qb.Team(1), height(partners));
        if ~isempty(bring)
            Stack(k) = Stack(k) + sprintf(" / %s +%d", qb.Opp(1), height(bring));
        end
    end
    Players(k) = join(L.Name, ", ");
end
S = table(Lineup, Points, Salary, Ownership, QB, Stack, Players);
end

function E = exposureTable(players, counts, m)
Lineups = counts;
Exposure = 100 * counts / max(m, 1);
E = [players(:, ["Name", "Position", "Team", "Salary", "Projection", "Ownership"]), table(Lineups, Exposure)];
E.Leverage = E.Exposure - E.Ownership;
E = sortrows(E, ["Lineups", "Projection"], ["descend", "descend"]);
E = E(E.Lineups > 0, :);
end
