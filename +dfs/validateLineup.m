function [ok, problems] = validateLineup(lineup, rules, opts)
%VALIDATELINEUP Check a lineup against site rules without using the solver.
%   [ok, problems] = dfs.validateLineup(lineup, rules) returns true when the
%   lineup table (rows from the player pool) satisfies the roster shape,
%   salary cap, per-team cap, and the min-teams / min-games rules in
%   `rules` (see dfs.siteRules). `problems` lists every violation as text.
%
%   This is deliberately independent of dfs.optimizeLineup so it can be used
%   to audit solver output, hand-built lineups, or lineups from other tools.
%
%   Name-value options
%     MinSalary   lineup must spend at least this much (default 0)
%     Throw       error instead of returning false (default false)

arguments
    lineup table
    rules = "DraftKings"
    opts.MinSalary (1,1) double = 0
    opts.Throw (1,1) logical = false
end

rules = dfs.siteRules(rules);
problems = strings(0, 1);

if height(lineup) ~= rules.RosterSize
    problems(end+1) = sprintf("Roster has %d players, needs %d.", height(lineup), rules.RosterSize);
end

pos = string(lineup.Position);
for k = 1:numel(rules.Positions)
    c = sum(pos == rules.Positions(k));
    if c < rules.MinCount(k) || c > rules.MaxCount(k)
        problems(end+1) = sprintf("%s count is %d, allowed %d to %d.", ...
            rules.Positions(k), c, rules.MinCount(k), rules.MaxCount(k)); %#ok<AGROW>
    end
end
unknown = ~ismember(pos, rules.Positions);
if any(unknown)
    problems(end+1) = "Unknown positions: " + join(unique(pos(unknown)), ", ");
end

totalSalary = sum(lineup.Salary);
if totalSalary > rules.SalaryCap
    problems(end+1) = sprintf("Salary %d exceeds cap %d.", totalSalary, rules.SalaryCap);
end
if totalSalary < opts.MinSalary
    problems(end+1) = sprintf("Salary %d is under the minimum %d.", totalSalary, opts.MinSalary);
end

[teams, ~, ti] = unique(string(lineup.Team));
perTeam = accumarray(ti, 1);
if any(perTeam > rules.MaxPerTeam)
    over = teams(perTeam > rules.MaxPerTeam);
    problems(end+1) = sprintf("More than %d players from %s.", rules.MaxPerTeam, join(over, ", "));
end
if numel(teams) < rules.MinTeams
    problems(end+1) = sprintf("Lineup spans %d teams, needs %d.", numel(teams), rules.MinTeams);
end
if ismember("Game", lineup.Properties.VariableNames)
    nGames = numel(unique(string(lineup.Game)));
    if nGames < rules.MinGames
        problems(end+1) = sprintf("Lineup spans %d games, needs %d.", nGames, rules.MinGames);
    end
end

if numel(unique(lineup.Name)) ~= height(lineup)
    problems(end+1) = "Lineup contains a duplicate player.";
end

ok = isempty(problems);
if ~ok && opts.Throw
    error("dfs:invalidLineup", "Invalid lineup:\n  %s", join(problems, newline + "  "));
end
end
