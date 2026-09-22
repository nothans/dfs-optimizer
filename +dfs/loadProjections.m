function players = loadProjections(source, opts)
%LOADPROJECTIONS Read a projections CSV into the canonical player table.
%   players = dfs.loadProjections("DFF_NFL_cheatsheet.csv") reads a Daily
%   Fantasy Fuel export (or any CSV with recognizable columns) and returns a
%   table with one row per player and these canonical columns first:
%
%     Name        "First Last" (defense rows use the team code)
%     Position    categorical: QB RB WR TE DST
%     Team, Opp   team codes
%     Game        game key shared by both teams, e.g. "BUF-LAC"
%     Salary      dollars
%     Projection  projected fantasy points (the objective)
%     Value       points per $1k salary
%     Ownership   projected ownership in percent (0 when the file has none)
%     Injury      injury status code ("" when healthy)
%
%   Every original column is kept after those, so nothing from the export is
%   lost. Column matching is case-insensitive and tolerant of the common
%   aliases (DraftKings salary exports, FanDuel exports, hand-made sheets).
%
%   players = dfs.loadProjections(T) accepts a table you already read.
%
%   Name-value options
%     ExcludeInjury   status codes to drop (default ["O" "IR" "D"])
%     DropZeroProjection  drop players projected at 0 (default true)
%     Site            "DraftKings" or "FanDuel"; only used to pick which
%                     salary column to read when a file carries both
%
%   Example
%       players = dfs.loadProjections("data/sample_DFF_NFL.csv");
%       lineup = dfs.optimizeLineup(players);

arguments
    source
    opts.ExcludeInjury (1,:) string = ["O", "IR", "D"]
    opts.DropZeroProjection (1,1) logical = true
    opts.Site (1,1) string = "DraftKings"
end

if istable(source)
    raw = source;
else
    file = string(source);
    if ~isfile(file)
        error("dfs:fileNotFound", "Projections file not found: %s", file);
    end
    io = detectImportOptions(file, "TextType", "string", "VariableNamingRule", "preserve");
    % Force id-like text columns to text so team codes such as "NE" survive.
    for v = ["first_name", "last_name", "position", "team", "opp", "injury_status", "slate", "spread"]
        if any(io.VariableNames == v)
            io = setvartype(io, v, "string");
        end
    end
    raw = readtable(file, io);
end

names = string(raw.Properties.VariableNames);
lowerNames = lower(strtrim(names));

    function col = pick(aliases, required)
        % First alias present in the file, or "" when none.
        col = "";
        for a = aliases
            hit = find(lowerNames == lower(a), 1);
            if ~isempty(hit)
                col = names(hit);
                return
            end
        end
        if required
            error("dfs:missingColumn", ...
                "Could not find a %s column. Looked for: %s", aliases(1), join(aliases, ", "));
        end
    end

n = height(raw);

% ---- Name
firstCol = pick(["first_name", "first name", "firstname"], false);
lastCol = pick(["last_name", "last name", "lastname"], false);
nameCol = pick(["name", "player", "player_name", "player name", "nickname"], false);
if firstCol ~= "" && lastCol ~= ""
    first = string(raw.(firstCol)); first(ismissing(first)) = "";
    last = string(raw.(lastCol)); last(ismissing(last)) = "";
    Name = strtrim(first + " " + last);
elseif nameCol ~= ""
    Name = strtrim(string(raw.(nameCol)));
else
    error("dfs:missingColumn", "Could not find a player name column (first_name/last_name or Name).");
end

% ---- Position
posCol = pick(["position", "pos", "roster position", "roster_position"], true);
Position = upper(strtrim(string(raw.(posCol))));
Position(ismember(Position, ["D", "DEF", "DST", "D/ST", "DEFENSE"])) = "DST";
% A player listed with FLEX eligibility, e.g. "RB/FLEX", keeps the base position.
Position = extractBefore(Position + "/", "/");
Position = categorical(Position, ["QB", "RB", "WR", "TE", "DST"]);

% ---- Team / opponent
teamCol = pick(["team", "teamabbrev", "team abbrev", "tm"], true);
Team = upper(strtrim(string(raw.(teamCol))));
oppCol = pick(["opp", "opponent", "opp team", "opp_team"], false);
if oppCol ~= ""
    Opp = upper(strtrim(string(raw.(oppCol))));
    Opp = erase(Opp, ["@", "VS", "vs", " "]);
else
    Opp = strings(n, 1);
end
% DraftKings salary exports have "Game Info" like "BUF@LAC 09/27/2026 01:00PM ET".
gameInfoCol = pick(["game info", "game_info", "game"], false);
if oppCol == "" && gameInfoCol ~= ""
    gi = string(raw.(gameInfoCol));
    pair = extractBefore(gi + " ", " ");
    away = extractBefore(pair, "@");
    home = extractAfter(pair, "@");
    Opp = home;
    Opp(Team == home) = away(Team == home);
end
if all(Opp == "" | ismissing(Opp))
    warning("dfs:noOpponent", "No opponent column found. Game, stacking and bring-back rules will not work.");
    Opp(ismissing(Opp)) = "";
end
% Defense rows sometimes have blank names; use the team code.
Name(Name == "" & Position == "DST") = Team(Name == "" & Position == "DST");

% ---- Salary (site-specific when both exist)
if lower(opts.Site) == "fanduel"
    salCol = pick(["fd_salary", "fanduel salary", "fanduel_salary", "salary"], true);
else
    salCol = pick(["dk_salary", "draftkings salary", "draftkings_salary", "salary"], true);
end
Salary = toNumber(raw.(salCol));

% ---- Projection
projCol = pick(["ppg_projection", "projection", "proj", "fpts", "projected points", ...
    "proj_points", "points", "avgpointspergame", "fppg"], true);
Projection = toNumber(raw.(projCol));
Projection(isnan(Projection)) = 0;

% ---- Value, ownership, injury
valCol = pick(["value_projection", "value", "value_proj"], false);
if valCol ~= ""
    Value = toNumber(raw.(valCol));
else
    Value = Projection ./ (Salary / 1000);
end
ownCol = pick(["ownership_projection", "ownership", "own", "proj_own", "projected ownership", "own%"], false);
if ownCol ~= ""
    Ownership = toNumber(raw.(ownCol));
    Ownership(isnan(Ownership)) = 0;
else
    Ownership = zeros(n, 1);
end
if ~any(Ownership > 0)
    warning("dfs:noOwnership", ...
        "No projected ownership in this file, so ownership penalties, caps, and leverage " + ...
        "will do nothing. Daily Fantasy Fuel fills its ownership column closer to kickoff.");
end
injCol = pick(["injury_status", "injury", "status", "inj"], false);
if injCol ~= ""
    Injury = upper(strtrim(string(raw.(injCol))));
    Injury(ismissing(Injury)) = "";
else
    Injury = strings(n, 1);
end

% ---- Game key: both teams sorted so each game has one id
Game = strings(n, 1);
for i = 1:n
    pair = sort([Team(i), Opp(i)]);
    Game(i) = join(pair, "-");
end

players = table(Name, Position, Team, Opp, Game, Salary, Projection, Value, Ownership, Injury);

% Keep every original column after the canonical ones, without duplicates.
canon = lower(string(players.Properties.VariableNames));
for v = names
    if any(lower(v) == canon)
        continue
    end
    players.(v) = raw.(v);
end

% ---- Filters
keep = true(n, 1);
if ~isempty(opts.ExcludeInjury)
    keep = keep & ~ismember(Injury, upper(opts.ExcludeInjury));
end
if opts.DropZeroProjection
    keep = keep & Projection > 0;
end
keep = keep & ~isundefined(Position) & Salary > 0;
players = players(keep, :);
if isempty(players)
    warning("dfs:emptyPool", ...
        "Every row was filtered out (%d of %d injured/out, %d with no projection). " + ...
        "Daily Fantasy Fuel builds its CSV from the rows shown on the page, so clear any " + ...
        "filters, pick the full slate, and let the table load before downloading. " + ...
        "To inspect this file anyway: ExcludeInjury=[] or DropZeroProjection=false.", ...
        sum(ismember(Injury, upper(opts.ExcludeInjury))), n, sum(~(Projection > 0)));
end
players = sortrows(players, ["Position", "Projection"], ["ascend", "descend"]);
players.Properties.RowNames = {};
players.Properties.Description = "DFS player pool";
end

function x = toNumber(col)
if isnumeric(col)
    x = double(col);
else
    s = string(col);
    s = erase(s, ["$", ",", "%"]);
    x = str2double(s);
end
x = x(:);
end
