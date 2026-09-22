function T = exportLineups(lineups, outFile, opts)
%EXPORTLINEUPS Write lineups as one row per lineup in roster-slot order.
%   T = dfs.exportLineups(lineups, "lineups.csv") writes a CSV with columns
%   QB, RB, RB, WR, WR, WR, TE, FLEX, DST (the DraftKings and FanDuel upload
%   order) followed by Points, Salary and Ownership. `lineups` is a lineup
%   table from dfs.optimizeLineup or the cell array from
%   dfs.generateLineups.
%
%   Sites match uploaded players by their own player IDs, which projection
%   exports do not carry, so this file is for your records and for pasting
%   names. Pass IdColumn="ID" if your player table has the site's ID column
%   and you want "Name (ID)" cells instead.
%
%   T = dfs.exportLineups(lineups) returns the table without writing.

arguments
    lineups
    outFile (1,1) string = ""
    opts.IdColumn (1,1) string = ""
end

if istable(lineups)
    lineups = {lineups};
end
m = numel(lineups);
slots = ["QB", "RB", "RB", "WR", "WR", "WR", "TE", "FLEX", "DST"];
cells = strings(m, numel(slots));
Points = zeros(m, 1); Salary = zeros(m, 1); Ownership = zeros(m, 1);
for k = 1:m
    L = lineups{k};
    slotNames = string(L.Slot);
    for s = unique(slots, "stable")
        rows = find(slotNames == s);
        cols = find(slots == s);
        for j = 1:min(numel(rows), numel(cols))
            label = L.Name(rows(j));
            if opts.IdColumn ~= "" && ismember(opts.IdColumn, L.Properties.VariableNames)
                label = label + " (" + string(L.(opts.IdColumn)(rows(j))) + ")";
            end
            cells(k, cols(j)) = label;
        end
    end
    Points(k) = sum(L.Projection);
    Salary(k) = sum(L.Salary);
    Ownership(k) = sum(L.Ownership);
end

T = array2table(cells, VariableNames=matlab.lang.makeUniqueStrings(slots));
T.Points = Points;
T.Salary = Salary;
T.Ownership = Ownership;

if outFile ~= ""
    % Write the header with repeated slot names (QB,RB,RB,WR,...) the way the
    % sites lay out their upload sheets; writetable would rename duplicates.
    fid = fopen(outFile, "w");
    if fid < 0
        error("dfs:exportFailed", "Could not open %s for writing.", outFile);
    end
    cleanup = onCleanup(@() fclose(fid));
    fprintf(fid, "%s\n", join([slots, "Points", "Salary", "Ownership"], ","));
    for k = 1:m
        fprintf(fid, "%s,%.2f,%d,%.1f\n", join(cells(k, :), ","), Points(k), Salary(k), Ownership(k));
    end
end
end
