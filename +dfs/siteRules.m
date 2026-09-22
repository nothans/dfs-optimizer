function rules = siteRules(site)
%SITERULES Roster and salary rules for a DFS site's NFL classic contest.
%   rules = dfs.siteRules("DraftKings") returns a struct describing the
%   DraftKings NFL Classic roster: 9 spots, $50,000 cap, QB/RB/RB/WR/WR/WR/
%   TE/FLEX/DST, players from at least two games.
%
%   rules = dfs.siteRules("FanDuel") returns the FanDuel NFL rules: 9 spots,
%   $60,000 cap, same shape, at most 4 players from one team, at least 3
%   different teams.
%
%   rules = dfs.siteRules(customStruct) validates and returns a struct you
%   built yourself (same fields), so other sites or house leagues work too.
%
%   Fields
%     Site        display name
%     SalaryCap   dollars
%     RosterSize  total players (9)
%     Positions   ["QB" "RB" "WR" "TE" "DST"]
%     MinCount    per position, base slots
%     MaxCount    per position, base slots plus FLEX where eligible
%     FlexPositions  positions eligible for the FLEX spot
%     MaxPerTeam  max players from one team (Inf when the site has no cap)
%     MinTeams    lineup must span at least this many teams
%     MinGames    lineup must span at least this many games
%
%   The FLEX spot is not modeled as its own slot. Instead RB, WR and TE each
%   get a range (MinCount to MaxCount) and RosterSize pins the total, which is
%   exactly equivalent and keeps the integer program small.

arguments
    site = "DraftKings"
end

if isstruct(site)
    rules = validateRules(site);
    return
end

site = string(site);
switch lower(site)
    case {"draftkings", "dk"}
        rules.Site = "DraftKings";
        rules.SalaryCap = 50000;
        rules.MaxPerTeam = Inf;       % DK has no per-team cap; the 2-game rule bites instead
        rules.MinTeams = 2;
        rules.MinGames = 2;
    case {"fanduel", "fd"}
        rules.Site = "FanDuel";
        rules.SalaryCap = 60000;
        rules.MaxPerTeam = 4;
        rules.MinTeams = 3;
        rules.MinGames = 1;
    otherwise
        error("dfs:unknownSite", ...
            "Unknown site ""%s"". Use ""DraftKings"", ""FanDuel"", or pass a rules struct.", site);
end
rules.RosterSize = 9;
rules.Positions = ["QB", "RB", "WR", "TE", "DST"];
rules.MinCount = [1 2 3 1 1];
rules.MaxCount = [1 3 4 2 1];
rules.FlexPositions = ["RB", "WR", "TE"];
rules = orderfields(rules, ["Site", "SalaryCap", "RosterSize", "Positions", "MinCount", ...
    "MaxCount", "FlexPositions", "MaxPerTeam", "MinTeams", "MinGames"]);
end

function rules = validateRules(rules)
required = ["SalaryCap", "RosterSize", "Positions", "MinCount", "MaxCount"];
for f = required
    if ~isfield(rules, f)
        error("dfs:badRules", "Rules struct is missing the field ""%s"".", f);
    end
end
rules.Positions = string(rules.Positions);
if numel(rules.MinCount) ~= numel(rules.Positions) || numel(rules.MaxCount) ~= numel(rules.Positions)
    error("dfs:badRules", "MinCount and MaxCount must have one entry per position.");
end
if any(rules.MinCount > rules.MaxCount)
    error("dfs:badRules", "MinCount cannot exceed MaxCount.");
end
if sum(rules.MinCount) > rules.RosterSize || sum(rules.MaxCount) < rules.RosterSize
    error("dfs:badRules", "RosterSize %d is not reachable from MinCount/MaxCount.", rules.RosterSize);
end
if ~isfield(rules, "Site"), rules.Site = "Custom"; end
if ~isfield(rules, "FlexPositions"), rules.FlexPositions = rules.Positions(rules.MaxCount > rules.MinCount); end
if ~isfield(rules, "MaxPerTeam"), rules.MaxPerTeam = Inf; end
if ~isfield(rules, "MinTeams"), rules.MinTeams = 1; end
if ~isfield(rules, "MinGames"), rules.MinGames = 1; end
rules.Site = string(rules.Site);
rules.FlexPositions = string(rules.FlexPositions);
end
