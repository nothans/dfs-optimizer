function players = makeSampleData(outFile, opts)
%MAKESAMPLEDATA Generate a synthetic NFL slate in the Daily Fantasy Fuel CSV layout.
%   makeSampleData() writes data/sample_DFF_NFL.csv next to this repo's data
%   folder. makeSampleData(outFile) writes to the given path. The output uses
%   the exact 20-column header of a Daily Fantasy Fuel "cheatsheet" export so
%   the same loader, app, and tests work on real downloads.
%
%   players = makeSampleData(...) also returns the generated table.
%
%   The slate is fictional: made-up names, 13 games, DraftKings-style
%   salaries. Projections track salary with noise plus a Vegas bump so the
%   optimizer has a realistic value landscape (2 to 4 points per $1k).
%   Ownership is a softmax over value, so chalk clusters the way it does in
%   real GPPs. Seeded so the file is reproducible.
%
%   Example
%       players = makeSampleData("data/sample_DFF_NFL.csv");

arguments
    outFile (1,1) string = defaultOutFile()
    opts.Seed (1,1) double = 2026
    opts.Week (1,1) double = 3
end

rng(opts.Seed, "twister");

% 26 of 32 teams play on a 13-game main slate.
teams = ["ARI","ATL","BAL","BUF","CAR","CHI","CIN","CLE","DAL","DEN","DET","GB", ...
         "HOU","IND","JAX","KC","LAC","LAR","LV","MIA","MIN","NE","NO","NYG","NYJ","PHI"];
teams = teams(randperm(numel(teams)));
nGames = numel(teams) / 2;

% Game lines: spread from the home team's view, totals 38 to 54.
gameOU = round(2 * (38 + 16 * rand(nGames, 1))) / 2;
gameSpread = round(2 * (-10 + 20 * rand(nGames, 1))) / 2;

firstNames = ["Avery","Blake","Cameron","Dakota","Elliot","Finley","Gray","Hayden", ...
    "Indigo","Jules","Kai","Lennox","Marlow","Nico","Oakley","Parker","Quinn","Reese", ...
    "Sawyer","Tatum","Umber","Vale","Wren","Xavi","Yael","Zion","Arlo","Bodhi","Cruz", ...
    "Dashiell","Ezra","Flynn","Gideon","Hollis","Ira","Jett","Knox","Lorcan","Mace"];
lastNames = ["Abernathy","Baskerville","Calloway","Delacroix","Everhart","Fairbanks", ...
    "Galloway","Hargrove","Ironwood","Jessup","Kingsley","Lockhart","Montclair","Northcott", ...
    "Okafor","Pemberton","Quillon","Ravenscroft","Sinclair","Thackeray","Underhill","Vandermeer", ...
    "Whitlock","Yardley","Zimmerman","Ashcombe","Blackwood","Carrington","Dunmore","Ellery", ...
    "Fenwick","Greaves","Halloran","Ingram","Kestrel","Lindqvist","Marchetti","Oduya","Pryce", ...
    "Radcliffe","Stroud","Tanaka","Vasquez","Winslow"];

% Position plan per team: [count, salary low, salary high, points-per-$1k low/high]
plan = struct( ...
    "QB",  struct("n", 2, "sal", [4000 8500], "ppk", [2.4 3.6]), ...
    "RB",  struct("n", 3, "sal", [3000 9000], "ppk", [1.9 3.4]), ...
    "WR",  struct("n", 5, "sal", [3000 9500], "ppk", [1.9 3.3]), ...
    "TE",  struct("n", 2, "sal", [2500 7500], "ppk", [1.7 3.1]), ...
    "DST", struct("n", 1, "sal", [2000 4500], "ppk", [1.8 3.4]));
positions = string(fieldnames(plan))';

rows = {};
usedNames = strings(0, 1);
for g = 1:nGames
    home = teams(2*g - 1);
    away = teams(2*g);
    ou = gameOU(g);
    spread = gameSpread(g);              % negative = home favored
    homeImplied = (ou - spread) / 2;
    awayImplied = (ou + spread) / 2;

    for side = 1:2
        if side == 1
            team = home; opp = away; implied = homeImplied; teamSpread = spread;
        else
            team = away; opp = home; implied = awayImplied; teamSpread = -spread;
        end
        % Vegas bump: teams implied above 24 points get a mild projection lift.
        vegasBump = 1 + 0.02 * (implied - 24);

        for p = positions
            spec = plan.(p);
            % Depth chart: first player is the starter, salaries fall with depth.
            depthScale = linspace(1, 0.35, spec.n);
            for d = 1:spec.n
                salSpan = spec.sal(2) - spec.sal(1);
                salary = spec.sal(1) + salSpan * (depthScale(d) * (0.75 + 0.25 * rand));
                salary = 100 * round(salary / 100);
                ppk = spec.ppk(1) + diff(spec.ppk) * rand;
                proj = (salary / 1000) * ppk * vegasBump;
                proj = max(0, proj + randn * 0.08 * proj);
                if p == "DST"
                    name = team;
                    first = ""; last = team;
                else
                    [first, last, usedNames] = pickName(firstNames, lastNames, usedNames);
                    name = first + " " + last;
                end
                if d == spec.n && p ~= "DST" && rand < 0.6
                    % Deep-depth players project near zero, like a real export.
                    proj = proj * 0.15;
                end
                injury = "";
                r = rand;
                if r < 0.03
                    injury = "O"; proj = 0;
                elseif r < 0.09
                    injury = "Q";
                end
                rows(end+1, :) = {first, last, p, injury, team, opp, teamSpread, ou, ...
                    implied, salary, proj, name}; %#ok<AGROW>
            end
        end
    end
end

T = cell2table(rows, "VariableNames", ["first_name","last_name","position","injury_status", ...
    "team","opp","spread","over_under","implied_team_score","salary","ppg_projection","name"]);

n = height(T);
T.ppg_projection = round(T.ppg_projection, 1);
T.value_projection = round(T.ppg_projection ./ (T.salary / 1000), 2);

% Ownership: softmax over value within position, scaled so the slate sums to
% about 900% (9 roster spots times 100%). Injured-out players get 0.
own = zeros(n, 1);
for p = positions
    idx = T.position == p & T.ppg_projection > 0;
    v = T.value_projection(idx);
    w = exp(3 * (v - max(v)));
    own(idx) = w / sum(w);
end
slots = struct("QB", 1, "RB", 2.5, "WR", 3.5, "TE", 1, "DST", 1);
for p = positions
    idx = T.position == p;
    own(idx) = own(idx) * slots.(p) * 100;
end
T.ownership_projection = round(own, 1);

% History columns: noisy versions of the projection, some blanks for rookies.
noisy = @(s) round(max(0, T.ppg_projection .* (1 + s * randn(n, 1))), 1);
T.L5_fppg_avg = noisy(0.35);
T.L10_fppg_avg = noisy(0.25);
T.szn_fppg_avg = noisy(0.20);
blank = rand(n, 1) < 0.12;
T.szn_fppg_avg(blank) = NaN;
blank = rand(n, 1) < 0.05;
T.L5_fppg_avg(blank) = NaN;
T.L10_fppg_avg(blank) = NaN;
T.L5_dvp_rank = randi(32, n, 1);

T.week = repmat(opts.Week, n, 1);
T.game_date = repmat("2026-09-27", n, 1);
T.slate = repmat("Main", n, 1);

% Exact Daily Fantasy Fuel column order.
order = ["first_name","last_name","position","injury_status","week","game_date","slate", ...
    "team","opp","spread","over_under","implied_team_score","salary","L5_dvp_rank", ...
    "L5_fppg_avg","L10_fppg_avg","szn_fppg_avg","ppg_projection","value_projection", ...
    "ownership_projection"];
T = T(:, order);

% Spread as a signed string with the sign always present, as DFF writes it.
T.spread = arrayfun(@(s) string(sprintf("%+.1f", s)), T.spread);

outDir = fileparts(outFile);
if outDir ~= "" && ~isfolder(outDir)
    mkdir(outDir);
end
writetable(T, outFile);
players = T;
fprintf("Wrote %d players across %d games to %s\n", n, nGames, outFile);
end

function f = defaultOutFile()
here = fileparts(mfilename("fullpath"));
f = fullfile(here, "..", "data", "sample_DFF_NFL.csv");
end

function [first, last, used] = pickName(firsts, lasts, used)
for attempt = 1:200
    first = firsts(randi(numel(firsts)));
    last = lasts(randi(numel(lasts)));
    key = first + " " + last;
    if ~any(used == key)
        used(end+1, 1) = key; %#ok<AGROW>
        return
    end
end
error("makeSampleData:names", "Ran out of unique names.");
end
