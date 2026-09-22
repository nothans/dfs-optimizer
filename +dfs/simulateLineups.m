function [frequency, lineups, draws] = simulateLineups(players, numDraws, opts)
%SIMULATELINEUPS Monte Carlo: re-solve the lineup under sampled projections.
%   frequency = dfs.simulateLineups(players, M) draws M projection scenarios
%   (each player's points sampled around their projection), solves the
%   optimal lineup for each draw, and returns how often every player made
%   the optimal lineup. A player who is optimal in 80% of scenarios is a
%   robust play; one who is optimal only at the point estimate is fragile.
%
%   [frequency, lineups, draws] = dfs.simulateLineups(...) also returns the
%   distinct lineups found (with how many draws produced each) and the
%   sampled projection matrix (players x draws) for your own analysis.
%
%   Uncertainty model
%     StdDev column in `players`   used directly when present
%     Volatility                   otherwise, per-position coefficient of
%                                  variation (std / mean). Default struct:
%                                  QB 0.35, RB 0.45, WR 0.50, TE 0.55,
%                                  DST 0.60. These are working priors, not
%                                  measured values; tune them or supply a
%                                  StdDev column from your own data.
%     Distribution   "normal" (default) or "lognormal"; draws are clipped at 0
%     Seed           rng seed
%     ProgressFcn    f(k, M, info) called after each draw; return true to stop
%
%   Every other name-value pair passes through to dfs.optimizeLineup, so
%   stacks, locks, and site rules apply to every scenario.
%
%   Example
%       F = dfs.simulateLineups(players, 200, Seed=1, StackSize=1);
%       head(F, 15)

arguments
    players table
    numDraws (1,1) double {mustBeInteger, mustBePositive} = 100
    opts.Volatility struct = struct("QB", 0.35, "RB", 0.45, "WR", 0.50, "TE", 0.55, "DST", 0.60)
    opts.Distribution (1,1) string {mustBeMember(opts.Distribution, ["normal", "lognormal"])} = "normal"
    opts.Seed = []
    opts.ProgressFcn = []
    opts.Site = "DraftKings"
    opts.SalaryCap (1,1) double = NaN
    opts.MinSalary (1,1) double = 0
    opts.MaxPerTeam (1,1) double = NaN
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

if ~isempty(opts.Seed)
    rng(opts.Seed, "twister");
end
n = height(players);
mu = players.Projection(:);

if ismember("StdDev", players.Properties.VariableNames)
    sigma = players.StdDev(:);
else
    pos = string(players.Position);
    cv = zeros(n, 1);
    for p = string(fieldnames(opts.Volatility))'
        cv(pos == p) = opts.Volatility.(p);
    end
    sigma = cv .* mu;
end
sigma(isnan(sigma)) = 0;

switch opts.Distribution
    case "normal"
        draws = mu + sigma .* randn(n, numDraws);
    case "lognormal"
        % Match mean and variance of the normal case, but keep draws positive.
        v = log(1 + (sigma ./ max(mu, eps)).^2);
        m = log(max(mu, eps)) - v / 2;
        draws = exp(m + sqrt(v) .* randn(n, numDraws));
end
draws = max(draws, 0);

solverOpts = rmfield(opts, ["Volatility", "Distribution", "Seed", "ProgressFcn"]);

counts = zeros(n, 1);
keys = strings(0, 1);
keyCounts = zeros(0, 1);
keyLineups = {};
keyPoints = zeros(0, 1);
done = 0;
for k = 1:numDraws
    args = solverOpts;
    args.Objective = draws(:, k);
    argCell = namedargs2cell(args);
    [L, info] = dfs.optimizeLineup(players, argCell{:});
    done = done + 1;
    counts = counts + info.Selected;

    key = join(string(find(info.Selected)'), ",");
    hit = find(keys == key, 1);
    if isempty(hit)
        keys(end+1, 1) = key; %#ok<AGROW>
        keyCounts(end+1, 1) = 1; %#ok<AGROW>
        keyLineups{end+1, 1} = L; %#ok<AGROW>
        keyPoints(end+1, 1) = sum(L.Projection); %#ok<AGROW>
    else
        keyCounts(hit) = keyCounts(hit) + 1;
    end

    if ~isempty(opts.ProgressFcn) && opts.ProgressFcn(k, numDraws, info)
        break
    end
end

Draws = counts;
Frequency = 100 * counts / done;
frequency = [players(:, ["Name", "Position", "Team", "Salary", "Projection", "Ownership"]), table(Draws, Frequency)];
frequency.Leverage = frequency.Frequency - frequency.Ownership;
frequency = sortrows(frequency, ["Draws", "Projection"], ["descend", "descend"]);
frequency = frequency(frequency.Draws > 0, :);

[keyCounts, order] = sort(keyCounts, "descend");
lineups = table((1:numel(order))', keyCounts, 100 * keyCounts / done, keyPoints(order), keyLineups(order), ...
    VariableNames=["Rank", "Draws", "Share", "Points", "Lineup"]);
end
