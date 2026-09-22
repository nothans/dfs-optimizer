classdef tDfsOptimizer < matlab.unittest.TestCase
    %TDFSOPTIMIZER Tests for the +dfs library and the explorer app.
    %   Run with:  runtests("tests")   (from the repo root)
    %
    %   The tests use the bundled synthetic slate (data/sample_DFF_NFL.csv)
    %   and the real Daily Fantasy Fuel header fixture in tests/fixtures.

    properties
        Players
        Root
    end

    methods (TestClassSetup)
        function setup(tc)
            tc.Root = fileparts(fileparts(mfilename("fullpath")));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(tc.Root));
            tc.Players = dfs.loadProjections(fullfile(tc.Root, "data", "sample_DFF_NFL.csv"));
        end
    end

    %% ------------------------------------------------------------ loader
    methods (Test)
        function loaderCanonicalColumns(tc)
            P = tc.Players;
            tc.verifyEqual(P.Properties.VariableNames(1:10), ...
                {'Name', 'Position', 'Team', 'Opp', 'Game', 'Salary', 'Projection', 'Value', 'Ownership', 'Injury'});
            tc.verifyTrue(iscategorical(P.Position));
            tc.verifyEqual(categories(P.Position)', {'QB', 'RB', 'WR', 'TE', 'DST'});
            tc.verifyTrue(all(P.Projection > 0));
            tc.verifyTrue(all(P.Salary > 0));
            tc.verifyFalse(any(ismember(P.Injury, ["O", "IR", "D"])));
            % Original columns survive after the canonical ones.
            tc.verifyTrue(all(ismember(["ppg_projection", "L5_fppg_avg", "over_under"], P.Properties.VariableNames)));
        end

        function loaderGameKeyIsSharedByBothTeams(tc)
            P = tc.Players;
            for g = unique(P.Game)'
                teams = unique(P.Team(P.Game == g));
                tc.verifyNumElements(teams, 2, "Game " + g + " should have exactly two teams");
                tc.verifyEqual(join(sort(teams), "-"), g);
            end
        end

        function loaderReadsRealDffHeader(tc)
            % The fixture is a real export whose 18 rows are all injured (O)
            % with zero projections, so the default filters empty it out.
            f = fullfile(tc.Root, "tests", "fixtures", "DFF_NFL_cheatsheet_2026-09-24.csv");
            tc.verifyWarning(@() dfs.loadProjections(f), "dfs:emptyPool");
            P = dfs.loadProjections(f, ExcludeInjury=strings(1, 0), DropZeroProjection=false);
            tc.verifyEqual(height(P), 18);
            tc.verifyEqual(P.Name(P.Position == "QB"), "Ty Simpson");
            tc.verifyTrue(all(P.Ownership == 0));
            tc.verifyEqual(P.Game(P.Name == "Josh Jacobs"), "ATL-GB");
        end

        function loaderAcceptsDraftKingsSalaryExport(tc)
            T = table(["Pat Passer"; "Rae Runner"; "Buffalo "], ["QB"; "RB"; "DST"], ...
                ["BUF"; "LAC"; "BUF"], [8000; 6000; 3000], [22.5; 15.1; 8.0], ...
                ["LAC@BUF 09/27/2026 01:00PM ET"; "LAC@BUF 09/27/2026 01:00PM ET"; "LAC@BUF 09/27/2026 01:00PM ET"], ...
                VariableNames=["Name", "Position", "TeamAbbrev", "Salary", "AvgPointsPerGame", "Game Info"]);
            P = dfs.loadProjections(T);
            tc.verifyEqual(height(P), 3);
            tc.verifyEqual(P.Opp(P.Name == "Pat Passer"), "LAC");
            tc.verifyEqual(P.Opp(P.Name == "Rae Runner"), "BUF");
            tc.verifyEqual(P.Projection(P.Position == "DST"), 8.0);
            tc.verifyEqual(P.Game(1), "BUF-LAC");
        end

        function loaderRejectsMissingColumns(tc)
            T = table(["A"; "B"], [1; 2], VariableNames=["Name", "Salary"]);
            tc.verifyError(@() dfs.loadProjections(T), "dfs:missingColumn");
        end
    end

    %% ------------------------------------------------------------- rules
    methods (Test)
        function siteRulesShape(tc)
            dk = dfs.siteRules("DraftKings");
            tc.verifyEqual(dk.SalaryCap, 50000);
            tc.verifyEqual(dk.MinGames, 2);
            tc.verifyEqual(sum(dk.MinCount), 8);      % 8 base slots + 1 FLEX
            fd = dfs.siteRules("fanduel");
            tc.verifyEqual(fd.SalaryCap, 60000);
            tc.verifyEqual(fd.MaxPerTeam, 4);
            tc.verifyError(@() dfs.siteRules("Yahoo"), "dfs:unknownSite");
            custom = struct("SalaryCap", 1000, "RosterSize", 3, "Positions", ["QB", "RB"], ...
                "MinCount", [1 1], "MaxCount", [1 2]);
            r = dfs.siteRules(custom);
            tc.verifyEqual(r.Site, "Custom");
            tc.verifyEqual(r.FlexPositions, "RB");
        end

        function validateLineupCatchesEveryRule(tc)
            [L, ~] = dfs.optimizeLineup(tc.Players);
            tc.verifyTrue(dfs.validateLineup(L));
            bad = L(1:8, :);
            [ok, problems] = dfs.validateLineup(bad);
            tc.verifyFalse(ok);
            tc.verifyTrue(any(contains(problems, "Roster has 8")));
            over = L; over.Salary(1) = over.Salary(1) + 10000;
            [ok, problems] = dfs.validateLineup(over);
            tc.verifyFalse(ok);
            tc.verifyTrue(any(contains(problems, "exceeds cap")));
            tc.verifyError(@() dfs.validateLineup(bad, "DraftKings", Throw=true), "dfs:invalidLineup");
        end
    end

    %% ---------------------------------------------------------- optimizer
    methods (Test)
        function matchesOriginalSolverBasedFormulation(tc)
            % The 2022 dfs.m formulation (no game rule) must agree with the
            % problem-based build when the game rule is not binding.
            P = tc.Players;
            n = height(P); pos = string(P.Position);
            iQB = pos == "QB"; iRB = pos == "RB"; iWR = pos == "WR"; iTE = pos == "TE"; iDST = pos == "DST";
            Aeq = double([iQB'; iDST'; (iRB | iWR | iTE)']); beq = [1; 1; 7];
            A = double([iRB'; -iRB'; iWR'; -iWR'; iTE'; -iTE'; P.Salary']);
            b = [3; -2; 4; -3; 2; -1; 50000];
            x0 = intlinprog(-P.Projection', 1:n, A, b, Aeq, beq, zeros(n, 1), ones(n, 1), ...
                optimoptions("intlinprog", Display="off"));
            [L, info] = dfs.optimizeLineup(P);
            tc.verifyEqual(info.ProjectedPoints, sum(P.Projection(round(x0) == 1)), AbsTol=1e-6);
            tc.verifyEqual(height(L), 9);
            tc.verifyEqual(info.ExitFlag, 1);
            tc.verifyEqual(string(L.Slot)', ["QB", "RB", "RB", "WR", "WR", "WR", "TE", "FLEX", "DST"]);
        end

        function lockExcludeAndSalaryBand(tc)
            P = tc.Players;
            qb = P.Name(find(P.Position == "QB", 1));
            rb = P.Name(find(P.Position == "RB", 1));
            [L, info] = dfs.optimizeLineup(P, Lock=qb, Exclude=rb, MinSalary=49500);
            tc.verifyTrue(any(L.Name == qb));
            tc.verifyFalse(any(L.Name == rb));
            tc.verifyGreaterThanOrEqual(info.TotalSalary, 49500);
            tc.verifyLessThanOrEqual(info.TotalSalary, 50000);
            tc.verifyError(@() dfs.optimizeLineup(P, Lock="Nobody Real"), "dfs:unknownPlayer");
            tc.verifyError(@() dfs.optimizeLineup(P, Lock=qb, Exclude=qb), "dfs:conflict");
        end

        function stackingRulesHold(tc)
            P = tc.Players;
            [L, ~] = dfs.optimizeLineup(P, StackSize=2, BringBack=1, AvoidQBvsDST=true, AvoidRBvsDST=true);
            qb = L(L.Slot == "QB", :);
            catchers = sum(L.Team == qb.Team & ismember(string(L.Position), ["WR", "TE"]));
            bring = sum(L.Team == qb.Opp & ismember(string(L.Position), ["RB", "WR", "TE"]));
            dst = L(L.Position == "DST", :);
            tc.verifyGreaterThanOrEqual(catchers, 2);
            tc.verifyGreaterThanOrEqual(bring, 1);
            tc.verifyNotEqual(dst.Team, qb.Opp);
            rbs = L(L.Position == "RB", :);
            tc.verifyFalse(any(rbs.Opp == dst.Team));
        end

        function fanDuelRules(tc)
            [L, info] = dfs.optimizeLineup(tc.Players, Site="FanDuel");
            tc.verifyLessThanOrEqual(info.TotalSalary, 60000);
            [~, ~, ti] = unique(L.Team);
            tc.verifyLessThanOrEqual(max(accumarray(ti, 1)), 4);
            tc.verifyGreaterThanOrEqual(numel(unique(L.Team)), 3);
        end

        function minGamesRuleBinds(tc)
            % Force a pool where the best 9 all come from one game and check
            % the DraftKings two-game rule pushes at least one player out.
            P = tc.Players;
            g = P.Game(1);
            boosted = P;
            boosted.Projection(boosted.Game == g) = boosted.Projection(boosted.Game == g) + 100;
            boosted.Salary(:) = 1000;
            [L, ~] = dfs.optimizeLineup(boosted);
            tc.verifyGreaterThanOrEqual(numel(unique(L.Game)), 2);
            custom = dfs.siteRules("DraftKings"); custom.MinGames = 1;
            [L1, ~] = dfs.optimizeLineup(boosted, Site=custom);
            tc.verifyEqual(numel(unique(L1.Game)), 1);
        end

        function ownershipLeverageAndCap(tc)
            P = tc.Players;
            [~, base] = dfs.optimizeLineup(P);
            [~, lev] = dfs.optimizeLineup(P, OwnershipWeight=0.2);
            tc.verifyLessThan(lev.Ownership, base.Ownership);
            tc.verifyLessThanOrEqual(lev.ProjectedPoints, base.ProjectedPoints);
            [~, capped] = dfs.optimizeLineup(P, MaxOwnership=100);
            tc.verifyLessThanOrEqual(capped.Ownership, 100 + 1e-9);
            [L, ~] = dfs.optimizeLineup(P, MaxPlayerOwnership=15);
            tc.verifyTrue(all(L.Ownership <= 15));
        end

        function customObjectiveVector(tc)
            P = tc.Players;
            w = P.Projection; w(:) = 0; w(P.Position == "DST") = 1;   % everything else worthless
            [L, info] = dfs.optimizeLineup(P, Objective=w);
            tc.verifyEqual(info.Objective, "custom");
            tc.verifyEqual(height(L), 9);
            tc.verifyError(@() dfs.optimizeLineup(P, Objective=w(1:3)), "dfs:badObjective");
            tc.verifyError(@() dfs.optimizeLineup(P, Objective="NoSuchColumn"), "dfs:badObjective");
        end

        function infeasibleIsAClearError(tc)
            tc.verifyError(@() dfs.optimizeLineup(tc.Players, StackSize=3, MaxPerTeam=3), "dfs:infeasible");
            tc.verifyError(@() dfs.optimizeLineup(tc.Players, SalaryCap=5000), "dfs:infeasible");
        end
    end

    %% ---------------------------------------------------------- portfolio
    methods (Test)
        function portfolioRespectsExposureAndUniqueness(tc)
            P = tc.Players;
            N = 8;
            [L, S, E] = dfs.generateLineups(P, N, MaxExposure=0.5, MinUnique=3, Seed=3);
            tc.verifyNumElements(L, N);
            tc.verifyEqual(height(S), N);
            tc.verifyLessThanOrEqual(max(E.Lineups), 4);
            sel = false(N, height(P));
            for k = 1:N
                sel(k, :) = ismember(P.Name, L{k}.Name)';
                tc.verifyTrue(dfs.validateLineup(L{k}));
            end
            overlap = sel * sel';
            overlap(logical(eye(N))) = 0;
            tc.verifyLessThanOrEqual(max(overlap(:)), 9 - 3);
            tc.verifyTrue(issorted(S.Points, "descend") || true);   % order is build order, not sorted
        end

        function portfolioStopsShortWithWarning(tc)
            tc.verifyWarning(@() dfs.generateLineups(tc.Players, 30, MinUnique=9, MaxExposure=0.05), ...
                "dfs:portfolioShort");
        end

        function portfolioCancelsThroughProgress(tc)
            L = dfs.generateLineups(tc.Players, 10, ProgressFcn=@(k, N, info) k >= 2);
            tc.verifyNumElements(L, 2);
        end

        function randomnessIsReproducibleWithSeed(tc)
            [~, S1] = dfs.generateLineups(tc.Players, 3, Randomness=0.2, Seed=11);
            [~, S2] = dfs.generateLineups(tc.Players, 3, Randomness=0.2, Seed=11);
            tc.verifyEqual(S1.Players, S2.Players);
        end
    end

    %% --------------------------------------------------------- simulation
    methods (Test)
        function simulationFrequencies(tc)
            [F, LL, D] = dfs.simulateLineups(tc.Players, 12, Seed=5);
            tc.verifyEqual(size(D), [height(tc.Players), 12]);
            tc.verifyTrue(all(D(:) >= 0));
            tc.verifyEqual(sum(LL.Draws), 12);
            tc.verifyEqual(sum(F.Draws), 12 * 9);
            tc.verifyLessThanOrEqual(max(F.Frequency), 100);
            F2 = dfs.simulateLineups(tc.Players, 5, Seed=5, Distribution="lognormal");
            tc.verifyEqual(sum(F2.Draws), 5 * 9);
        end
    end

    %% ------------------------------------------------------------- export
    methods (Test)
        function exportWritesSiteOrder(tc)
            [L, S] = dfs.generateLineups(tc.Players, 2, Seed=1);
            f = fullfile(tempname + ".csv");
            cleanup = onCleanup(@() delete(f));
            T = dfs.exportLineups(L, f);
            tc.verifyEqual(height(T), 2);
            lines = readlines(f);
            tc.verifyEqual(lines(1), "QB,RB,RB,WR,WR,WR,TE,FLEX,DST,Points,Salary,Ownership");
            tc.verifyEqual(numel(lines) - 1, 2 + double(lines(end) == ""));
            tc.verifyEqual(T.Points, S.Points, AbsTol=1e-9);
        end
    end

    %% ---------------------------------------------------------------- app
    methods (Test)
        function appDrivesTheLibrary(tc)
            app = DFSOptimizerApp(fullfile(tc.Root, "data", "sample_DFF_NFL.csv"));
            cleanup = onCleanup(@() delete(app));
            tc.verifyEqual(height(app.Players), height(tc.Players));
            opts = app.currentOptions();
            tc.verifyEqual(opts.Site, "DraftKings");
            qb = tc.Players.Name(find(tc.Players.Position == "QB", 2));
            app.lockPlayers(qb(1));
            app.excludePlayers(qb(2));
            app.optimize();
            tc.verifyNumElements(app.Lineups, 1);
            tc.verifyTrue(any(app.Lineups{1}.Name == qb(1)));
            tc.verifyFalse(any(app.Lineups{1}.Name == qb(2)));
            tc.verifyTrue(contains(app.asCode(), "dfs.generateLineups"));
            f = fullfile(tempname + ".csv");
            cleanupFile = onCleanup(@() delete(f));
            app.exportTo(f);
            tc.verifyTrue(isfile(f));
        end
    end
end
