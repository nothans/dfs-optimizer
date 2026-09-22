function [lineup, info] = optimizeLineup(players, opts)
%OPTIMIZELINEUP Build the highest-scoring legal lineup with integer programming.
%   lineup = dfs.optimizeLineup(players) picks the DraftKings NFL Classic
%   lineup (QB, RB, RB, WR, WR, WR, TE, FLEX, DST under $50,000) that
%   maximizes total projected points, using intlinprog through the
%   problem-based Optimization Toolbox interface. `players` is the table from
%   dfs.loadProjections.
%
%   [lineup, info] = dfs.optimizeLineup(players, Name=Value, ...) also returns
%   solve diagnostics and accepts strategy options:
%
%   Rules
%     Site             "DraftKings" (default), "FanDuel", or a rules struct
%     SalaryCap        override the site's cap
%     MinSalary        spend at least this much (default 0)
%     MaxPerTeam       override the site's per-team cap
%
%   Objective
%     Objective        column name to maximize (default "Projection"), or a
%                      numeric vector with one weight per player
%     OwnershipWeight  lambda: maximize Projection - lambda * Ownership
%                      (leverage for GPPs; 0 = ignore ownership)
%
%   Player picks
%     Lock             names that must be in the lineup
%     Exclude          names that must not be
%     MaxOwnership     lineup-level cap on summed projected ownership (%)
%     MaxPlayerOwnership  drop any player above this ownership (%)
%
%   Correlation (GPP structure)
%     StackSize        require k WR/TE from the QB's team (0 = off)
%     BringBack        require b RB/WR/TE from the QB's opponent (0 = off)
%     AvoidQBvsDST     never pair a QB with the defense he plays against
%     AvoidRBvsDST     same for RBs (a game-script hedge some players use)
%
%   Portfolio (used by dfs.generateLineups)
%     PreviousLineups  logical matrix, one row per earlier lineup
%     MinUnique        each new lineup differs from every earlier one by at
%                      least this many players (default 1)
%
%   Solver
%     Options          optimoptions("intlinprog") object
%
%   `lineup` is the chosen rows of `players` with a Slot column (QB, RB, WR,
%   TE, FLEX, DST) in roster order. `info` carries ProjectedPoints,
%   TotalSalary, SalaryRemaining, Ownership, ExitFlag, Message, SolveTime,
%   Selected (logical index into players), Rules and the optimproblem.
%
%   The solve is validated twice: intlinprog's exit flag is checked, and the
%   result is re-checked by dfs.validateLineup independently of the solver.
%
%   Example: a 3-man game stack that fades chalk
%       players = dfs.loadProjections("data/sample_DFF_NFL.csv");
%       [L, info] = dfs.optimizeLineup(players, StackSize=2, BringBack=1, ...
%           AvoidQBvsDST=true, OwnershipWeight=0.05);

arguments
    players table
    opts.Site = "DraftKings"
    opts.SalaryCap (1,1) double = NaN
    opts.MinSalary (1,1) double = 0
    opts.MaxPerTeam (1,1) double = NaN
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
    opts.PreviousLineups logical = false(0, 0)
    opts.MinUnique (1,1) double {mustBeInteger, mustBeNonnegative} = 1
    opts.Options = []
end

t0 = tic;
rules = dfs.siteRules(opts.Site);
if ~isnan(opts.SalaryCap), rules.SalaryCap = opts.SalaryCap; end
if ~isnan(opts.MaxPerTeam), rules.MaxPerTeam = opts.MaxPerTeam; end

n = height(players);
if n == 0
    error("dfs:emptyPool", "The player pool is empty.");
end
pos = string(players.Position);
team = string(players.Team);
opp = string(players.Opp);
game = string(players.Game);
salary = players.Salary(:);
own = players.Ownership(:);

% ---- Objective weights
if isnumeric(opts.Objective)
    w = double(opts.Objective(:));
    if numel(w) ~= n
        error("dfs:badObjective", "Objective vector must have one weight per player (%d).", n);
    end
    objectiveName = "custom";
else
    objectiveName = string(opts.Objective);
    if ~ismember(objectiveName, players.Properties.VariableNames)
        error("dfs:badObjective", "Objective column ""%s"" is not in the player table.", objectiveName);
    end
    w = double(players.(objectiveName)(:));
end
w(isnan(w)) = 0;
if opts.OwnershipWeight > 0
    w = w - opts.OwnershipWeight * own;
end

% ---- Fixed choices become bounds
lb = zeros(n, 1);
ub = ones(n, 1);
lockIdx = matchNames(players.Name, opts.Lock, "Lock");
excludeIdx = matchNames(players.Name, opts.Exclude, "Exclude");
lb(lockIdx) = 1;
ub(excludeIdx) = 0;
ub(own > opts.MaxPlayerOwnership) = 0;
if any(lb > ub)
    error("dfs:conflict", "A locked player is also excluded or filtered out.");
end

x = optimvar("x", n, Type="integer", LowerBound=lb, UpperBound=ub);
prob = optimproblem(Objective=sum(w .* x), ObjectiveSense="maximize");

% ---- Roster shape
prob.Constraints.roster = sum(x) == rules.RosterSize;
P = rules.Positions;
isPos = pos == P;                         % n x nPos indicator
prob.Constraints.posMin = (isPos' * x) >= rules.MinCount(:);
prob.Constraints.posMax = (isPos' * x) <= rules.MaxCount(:);

% ---- Salary
prob.Constraints.cap = sum(salary .* x) <= rules.SalaryCap;
if opts.MinSalary > 0
    prob.Constraints.minSalary = sum(salary .* x) >= opts.MinSalary;
end

% ---- Teams and games
[teams, ~, teamId] = unique(team);
isTeam = sparse(1:n, teamId, 1, n, numel(teams));   % n x nTeams
if isfinite(rules.MaxPerTeam) && rules.MaxPerTeam < rules.RosterSize
    prob.Constraints.maxPerTeam = (isTeam' * x) <= rules.MaxPerTeam;
end
if rules.MinTeams > 1
    tUsed = optimvar("tUsed", numel(teams), Type="integer", LowerBound=0, UpperBound=1);
    prob.Constraints.teamLink = tUsed <= isTeam' * x;   % a team counts only if someone is picked
    prob.Constraints.minTeams = sum(tUsed) >= rules.MinTeams;
end
[games, ~, gameId] = unique(game);
if rules.MinGames > 1
    isGame = sparse(1:n, gameId, 1, n, numel(games));
    gUsed = optimvar("gUsed", numel(games), Type="integer", LowerBound=0, UpperBound=1);
    prob.Constraints.gameLink = gUsed <= isGame' * x;
    prob.Constraints.minGames = sum(gUsed) >= rules.MinGames;
end

% ---- Ownership budget
if isfinite(opts.MaxOwnership)
    prob.Constraints.maxOwnership = sum(own .* x) <= opts.MaxOwnership;
end

% ---- Correlation rules, all written per candidate QB so they only bind
%      when that QB is chosen: sum(partners) >= k * x_qb.
qbIdx = find(pos == "QB");
isCatcher = pos == "WR" | pos == "TE";
isSkill = pos == "RB" | pos == "WR" | pos == "TE";
if opts.StackSize > 0 && ~isempty(qbIdx)
    M = double(team(qbIdx) == team' & isCatcher');      % nQB x n
    prob.Constraints.stack = M * x >= opts.StackSize * x(qbIdx);
end
if opts.BringBack > 0 && ~isempty(qbIdx)
    M = double(opp(qbIdx) == team' & isSkill');
    prob.Constraints.bringBack = M * x >= opts.BringBack * x(qbIdx);
end
if opts.AvoidQBvsDST && ~isempty(qbIdx)
    M = double(opp(qbIdx) == team' & (pos == "DST")');
    prob.Constraints.qbVsDst = x(qbIdx) + M * x <= 1;
end
rbIdx = find(pos == "RB");
if opts.AvoidRBvsDST && ~isempty(rbIdx)
    M = double(opp(rbIdx) == team' & (pos == "DST")');
    prob.Constraints.rbVsDst = x(rbIdx) + M * x <= 1;
end

% ---- Uniqueness against earlier lineups
prev = opts.PreviousLineups;
if ~isempty(prev)
    if size(prev, 2) ~= n
        error("dfs:badPrevious", "PreviousLineups must have one column per player (%d).", n);
    end
    prob.Constraints.unique = double(prev) * x <= rules.RosterSize - opts.MinUnique;
end

% ---- Solve
if isempty(opts.Options)
    solverOpts = optimoptions("intlinprog", Display="off");
else
    solverOpts = opts.Options;
end
[sol, fval, exitflag, output] = solve(prob, Options=solverOpts);
exitflag = double(exitflag);

if exitflag <= 0
    error("dfs:infeasible", ...
        "No lineup satisfies the constraints (intlinprog exit flag %d: %s). " + ...
        "Loosen locks, stack size, min salary, uniqueness, or ownership caps.", ...
        exitflag, strtrim(output.message));
end

selected = round(sol.x) == 1;
lineup = players(selected, :);
lineup = assignSlots(lineup, rules);

% Independent audit of the solver's answer.
[ok, problems] = dfs.validateLineup(lineup, rules, MinSalary=opts.MinSalary);
if ~ok
    error("dfs:invalidLineup", "Solver returned an illegal lineup:\n  %s", join(problems, newline + "  "));
end

info.ProjectedPoints = sum(lineup.Projection);
info.TotalSalary = sum(lineup.Salary);
info.SalaryRemaining = rules.SalaryCap - info.TotalSalary;
info.Ownership = sum(lineup.Ownership);
info.Objective = objectiveName;
info.ObjectiveValue = fval;
info.ExitFlag = exitflag;
info.Message = strtrim(extractBefore(string(output.message) + newline, newline));
info.SolveTime = toc(t0);
info.Selected = selected;
info.Rules = rules;
info.Problem = prob;
end

function idx = matchNames(names, wanted, label)
idx = false(numel(names), 1);
for k = 1:numel(wanted)
    hit = strcmpi(names, strtrim(wanted(k)));
    if ~any(hit)
        error("dfs:unknownPlayer", "%s: no player named ""%s"" in the pool.", label, wanted(k));
    end
    idx = idx | hit;
end
end

function lineup = assignSlots(lineup, rules)
% Order rows as the site displays them and label the FLEX.
pos = string(lineup.Position);
slot = pos;
order = zeros(height(lineup), 1);
rank = 0;
for k = 1:numel(rules.Positions)
    p = rules.Positions(k);
    rows = find(pos == p);
    [~, byProj] = sort(lineup.Projection(rows), "descend");
    rows = rows(byProj);
    base = rules.MinCount(k);
    for j = 1:numel(rows)
        rank = rank + 1;
        if j > base
            slot(rows(j)) = "FLEX";
            order(rows(j)) = 1000 + rank;   % FLEX rows sort after base slots
        else
            order(rows(j)) = rank;
        end
    end
end
% Keep DST last even though FLEX sorts after the base slots.
order(pos == "DST") = 2000;
[~, i] = sort(order);
lineup = lineup(i, :);
lineup = addvars(lineup, categorical(slot(i), [rules.Positions(1:end-1), "FLEX", rules.Positions(end)]), ...
    Before=1, NewVariableNames="Slot");
end
