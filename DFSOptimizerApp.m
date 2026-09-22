classdef DFSOptimizerApp < handle
    %DFSOPTIMIZERAPP Explore DFS lineup optimization options interactively.
    %   app = DFSOptimizerApp opens the explorer with the bundled sample
    %   slate. app = DFSOptimizerApp("DFF_NFL_cheatsheet.csv") opens it on
    %   your own Daily Fantasy Fuel export.
    %
    %   Left sidebar: the levers (site, salary, objective, stacking,
    %   ownership, portfolio size, exposure, uniqueness, randomness).
    %   Right side: the lineups, the player pool (lock or exclude anyone),
    %   exposure versus field ownership, and a Monte Carlo view of which
    %   players survive projection noise.
    %
    %   The app is a thin view over the +dfs package. Everything it does is
    %   one function call away for scripts and coding agents:
    %   dfs.loadProjections, dfs.optimizeLineup, dfs.generateLineups,
    %   dfs.simulateLineups, dfs.exportLineups.
    %
    %   Standalone programmatic uifigure app (no App Designer dependency),
    %   laid out with uigridlayout so it resizes cleanly, including in
    %   MATLAB Online.

    properties (SetAccess = private)
        Players table = table()      % player pool from dfs.loadProjections
        SourceFile string = ""       % where the pool came from
        Lineups cell = {}            % lineup tables from the last optimize
        Summary table = table()      % one row per lineup
        Exposure table = table()     % player exposure across lineups
        Frequency table = table()    % Monte Carlo player frequency
        SimLineups table = table()   % Monte Carlo distinct lineups
        Figure                       % the uifigure (for exportapp, tests)
    end

    properties (Access = private)
        Status
        % sidebar
        Mode
        SiteDD
        SalaryCap
        MinSalary
        Objective
        OwnershipWeight
        MaxOwnership
        StackSize
        BringBack
        AvoidQBvsDST
        AvoidRBvsDST
        MaxPerTeam
        NumLineups
        MaxExposure
        MinUnique
        Randomness
        Seed
        NumDraws
        OptimizeBtn
        SimulateBtn
        ExportBtn
        FileLabel
        % main area
        Tabs
        LineupHeader
        SummaryTable
        LineupTable
        PoolFilter
        PoolPosition
        PoolTable
        ExposureAxes
        ScatterAxes
        FrequencyTable
        FrequencyAxes
        % state
        Locks string = strings(1, 0)
        Excludes string = strings(1, 0)
    end

    methods
        function app = DFSOptimizerApp(source)
            arguments
                source = ""
            end
            app.buildUI();
            if source == ""
                source = fullfile(fileparts(mfilename("fullpath")), "data", "sample_DFF_NFL.csv");
            end
            if isfile(source)
                app.loadFile(source);
            else
                app.setStatus("Load a projections CSV to begin.");
            end
        end

        function delete(app)
            if ~isempty(app.Figure) && isvalid(app.Figure)
                delete(app.Figure);
            end
        end

        function loadFile(app, file)
            %LOADFILE Load a projections CSV into the pool.
            try
                players = dfs.loadProjections(file);
            catch err
                uialert(app.Figure, err.message, "Could not load projections");
                return
            end
            if isempty(players)
                uialert(app.Figure, "The file loaded but every player was filtered out " + ...
                    "(injured, or no projection). Check the export.", "Empty player pool");
                return
            end
            app.Players = players;
            app.SourceFile = string(file);
            app.Locks = strings(1, 0);
            app.Excludes = strings(1, 0);
            app.Lineups = {};
            app.Summary = table();
            app.Exposure = table();
            app.Frequency = table();
            [~, name, ext] = fileparts(file);
            app.FileLabel.Text = sprintf("%s%s  (%d players, %d games)", name, ext, ...
                height(players), numel(unique(players.Game)));
            app.refreshObjectiveItems();
            app.refreshPool();
            app.refreshLineups();
            app.refreshExposure();
            app.refreshSimulation();
            app.setStatus(sprintf("Loaded %d players. Set your levers and press Optimize.", height(players)));
        end

        function opts = currentOptions(app)
            %CURRENTOPTIONS The sidebar as a struct of dfs.* name-value options.
            opts = struct();
            opts.Site = string(app.SiteDD.Value);
            opts.SalaryCap = app.SalaryCap.Value;
            opts.MinSalary = app.MinSalary.Value;
            opts.Objective = string(app.Objective.Value);
            opts.OwnershipWeight = app.OwnershipWeight.Value;
            if app.MaxOwnership.Value > 0
                opts.MaxOwnership = app.MaxOwnership.Value;
            end
            opts.StackSize = app.StackSize.Value;
            opts.BringBack = app.BringBack.Value;
            opts.AvoidQBvsDST = app.AvoidQBvsDST.Value;
            opts.AvoidRBvsDST = app.AvoidRBvsDST.Value;
            if app.MaxPerTeam.Value > 0
                opts.MaxPerTeam = app.MaxPerTeam.Value;
            end
            opts.Lock = app.Locks;
            opts.Exclude = app.Excludes;
        end

        function code = asCode(app)
            %ASCODE The current settings as a runnable dfs.generateLineups call.
            o = app.currentOptions();
            parts = strings(1, 0);
            f = string(fieldnames(o))';
            for k = f
                v = o.(k);
                if isstring(v) && isscalar(v)
                    parts(end+1) = sprintf("%s=""%s""", k, v); %#ok<AGROW>
                elseif isstring(v)
                    if isempty(v), continue; end
                    parts(end+1) = sprintf("%s=[%s]", k, join("""" + v + """", " ")); %#ok<AGROW>
                elseif islogical(v)
                    parts(end+1) = sprintf("%s=%s", k, string(v)); %#ok<AGROW>
                else
                    parts(end+1) = sprintf("%s=%g", k, v); %#ok<AGROW>
                end
            end
            parts(end+1) = sprintf("MaxExposure=%g", app.MaxExposure.Value / 100);
            parts(end+1) = sprintf("MinUnique=%d", app.MinUnique.Value);
            parts(end+1) = sprintf("Randomness=%g", app.Randomness.Value / 100);
            parts(end+1) = sprintf("Seed=%d", app.Seed.Value);
            code = sprintf("players = dfs.loadProjections(""%s"");\n[lineups, summary, exposure] = dfs.generateLineups(players, %d, ...\n    %s);", ...
                app.SourceFile, app.NumLineups.Value, join(parts, ", "));
        end
    end

    %% ---------------------------------------------------------------- UI
    methods (Access = private)
        function buildUI(app)
            app.Figure = uifigure("Name", "DFS Lineup Optimizer", "Position", [80 80 1280 800]);
            app.Figure.CloseRequestFcn = @(~, ~) delete(app);

            root = uigridlayout(app.Figure, [2 2]);
            root.RowHeight = {'1x', 26};
            root.ColumnWidth = {320, '1x'};
            root.Padding = [0 0 0 0];
            root.RowSpacing = 0;
            root.ColumnSpacing = 0;

            app.buildSidebar(root);
            app.buildMain(root);

            app.Status = uilabel(root, "Text", "", "FontColor", [0.3 0.3 0.3]);
            app.Status.Layout.Row = 2;
            app.Status.Layout.Column = [1 2];
            app.Status.HorizontalAlignment = "left";
        end

        function buildSidebar(app, root)
            panel = uipanel(root, "Title", "Levers");
            panel.Layout.Row = 1;
            panel.Layout.Column = 1;

            g = uigridlayout(panel, [30 2]);
            g.ColumnWidth = {'1x', 96};
            g.RowHeight = repmat({'fit'}, 1, 30);
            g.Padding = [10 8 10 8];
            g.RowSpacing = 4;
            g.Scrollable = "on";

            % --- Data
            app.sectionLabel(g, "Data");
            b = uibutton(g, "Text", "Load CSV...", "ButtonPushedFcn", @(~, ~) app.onLoad());
            b.Layout.Column = 1;
            b2 = uibutton(g, "Text", "Sample slate", "ButtonPushedFcn", @(~, ~) app.onSample());
            b2.Layout.Column = 2;
            app.FileLabel = uilabel(g, "Text", "No file loaded", "WordWrap", "on", "FontSize", 11);
            app.FileLabel.Layout.Column = [1 2];

            % --- Mode preset
            app.sectionLabel(g, "Contest");
            uilabel(g, "Text", "Preset");
            app.Mode = uidropdown(g, "Items", {'Custom', 'Cash game', 'Tournament (GPP)'}, ...
                "Value", 'Custom', "ValueChangedFcn", @(~, ~) app.onPreset());
            uilabel(g, "Text", "Site");
            app.SiteDD = uidropdown(g, "Items", {'DraftKings', 'FanDuel'}, "Value", 'DraftKings', ...
                "ValueChangedFcn", @(~, ~) app.onSiteChanged());
            uilabel(g, "Text", "Salary cap");
            app.SalaryCap = uieditfield(g, "numeric", "Value", 50000, "Limits", [1000 Inf], ...
                "ValueDisplayFormat", "%d", "RoundFractionalValues", "on");
            uilabel(g, "Text", "Min salary");
            app.MinSalary = uieditfield(g, "numeric", "Value", 0, "Limits", [0 Inf], ...
                "ValueDisplayFormat", "%d", "RoundFractionalValues", "on");
            uilabel(g, "Text", "Max per team (0 = site)");
            app.MaxPerTeam = uispinner(g, "Value", 0, "Limits", [0 9], "Step", 1, "RoundFractionalValues", "on");

            % --- Objective
            app.sectionLabel(g, "Objective");
            uilabel(g, "Text", "Maximize");
            app.Objective = uidropdown(g, "Items", {'Projection'}, "Value", 'Projection');
            uilabel(g, "Text", "Ownership penalty");
            app.OwnershipWeight = uispinner(g, "Value", 0, "Limits", [0 2], "Step", 0.05, ...
                "ValueDisplayFormat", "%.2f");
            uilabel(g, "Text", "Max lineup own % (0 = off)");
            app.MaxOwnership = uieditfield(g, "numeric", "Value", 0, "Limits", [0 900], ...
                "ValueDisplayFormat", "%d");

            % --- Structure
            app.sectionLabel(g, "Correlation");
            uilabel(g, "Text", "QB stack (WR/TE)");
            app.StackSize = uispinner(g, "Value", 0, "Limits", [0 3], "Step", 1, "RoundFractionalValues", "on");
            uilabel(g, "Text", "Bring-back (opponent)");
            app.BringBack = uispinner(g, "Value", 0, "Limits", [0 2], "Step", 1, "RoundFractionalValues", "on");
            app.AvoidQBvsDST = uicheckbox(g, "Text", "No QB vs opposing DST", "Value", false);
            app.AvoidQBvsDST.Layout.Column = [1 2];
            app.AvoidRBvsDST = uicheckbox(g, "Text", "No RB vs opposing DST", "Value", false);
            app.AvoidRBvsDST.Layout.Column = [1 2];

            % --- Portfolio
            app.sectionLabel(g, "Portfolio");
            uilabel(g, "Text", "Lineups");
            app.NumLineups = uispinner(g, "Value", 1, "Limits", [1 150], "Step", 1, "RoundFractionalValues", "on");
            uilabel(g, "Text", "Max exposure %");
            app.MaxExposure = uispinner(g, "Value", 100, "Limits", [1 100], "Step", 5, "RoundFractionalValues", "on");
            uilabel(g, "Text", "Min unique per pair");
            app.MinUnique = uispinner(g, "Value", 2, "Limits", [0 9], "Step", 1, "RoundFractionalValues", "on");
            uilabel(g, "Text", "Randomness %");
            app.Randomness = uispinner(g, "Value", 0, "Limits", [0 50], "Step", 5, "RoundFractionalValues", "on");
            uilabel(g, "Text", "Seed");
            app.Seed = uispinner(g, "Value", 1, "Limits", [0 1e6], "Step", 1, "RoundFractionalValues", "on");

            app.OptimizeBtn = uibutton(g, "Text", "Optimize", "FontWeight", "bold", ...
                "ButtonPushedFcn", @(~, ~) app.optimize());
            app.OptimizeBtn.Layout.Column = [1 2];
            app.ExportBtn = uibutton(g, "Text", "Export lineups...", "Enable", "off", ...
                "ButtonPushedFcn", @(~, ~) app.onExport());
            app.ExportBtn.Layout.Column = [1 2];

            % --- Simulation
            app.sectionLabel(g, "Monte Carlo");
            uilabel(g, "Text", "Projection draws");
            app.NumDraws = uispinner(g, "Value", 50, "Limits", [10 1000], "Step", 10, "RoundFractionalValues", "on");
            app.SimulateBtn = uibutton(g, "Text", "Simulate", "ButtonPushedFcn", @(~, ~) app.simulate());
            app.SimulateBtn.Layout.Column = [1 2];

            c = uibutton(g, "Text", "Copy as code", "ButtonPushedFcn", @(~, ~) app.onCopyCode());
            c.Layout.Column = [1 2];
        end

        function sectionLabel(~, g, text)
            l = uilabel(g, "Text", upper(text), "FontWeight", "bold", "FontSize", 11, ...
                "FontColor", [0.35 0.35 0.35]);
            l.Layout.Column = [1 2];
        end

        function buildMain(app, root)
            app.Tabs = uitabgroup(root);
            app.Tabs.Layout.Row = 1;
            app.Tabs.Layout.Column = 2;

            % --- Lineups
            t = uitab(app.Tabs, "Title", "Lineups");
            g = uigridlayout(t, [3 1]);
            g.RowHeight = {'fit', '1x', '1x'};
            app.LineupHeader = uilabel(g, "Text", "No lineups yet.", "FontWeight", "bold", "FontSize", 14);
            app.SummaryTable = uitable(g, "SelectionType", "row", ...
                "CellSelectionCallback", @(~, evt) app.onSummarySelected(evt));
            app.LineupTable = uitable(g);

            % --- Player pool
            t = uitab(app.Tabs, "Title", "Player pool");
            g = uigridlayout(t, [2 3]);
            g.RowHeight = {'fit', '1x'};
            g.ColumnWidth = {'1x', 120, 'fit'};
            app.PoolFilter = uieditfield(g, "text", "Placeholder", "Filter by name or team", ...
                "ValueChangedFcn", @(~, ~) app.refreshPool());
            app.PoolPosition = uidropdown(g, "Items", {'All', 'QB', 'RB', 'WR', 'TE', 'DST'}, ...
                "Value", 'All', "ValueChangedFcn", @(~, ~) app.refreshPool());
            uibutton(g, "Text", "Clear locks/excludes", "ButtonPushedFcn", @(~, ~) app.onClearPicks());
            app.PoolTable = uitable(g, "CellEditCallback", @(src, evt) app.onPoolEdited(src, evt));
            app.PoolTable.Layout.Row = 2;
            app.PoolTable.Layout.Column = [1 3];

            % --- Exposure
            t = uitab(app.Tabs, "Title", "Exposure");
            g = uigridlayout(t, [1 2]);
            g.ColumnWidth = {'1x', '1x'};
            app.ExposureAxes = uiaxes(g);
            app.ScatterAxes = uiaxes(g);

            % --- Simulation
            t = uitab(app.Tabs, "Title", "Monte Carlo");
            g = uigridlayout(t, [1 2]);
            g.ColumnWidth = {'1x', '1x'};
            app.FrequencyTable = uitable(g);
            app.FrequencyAxes = uiaxes(g);
        end
    end

    %% ---------------------------------------------------------- callbacks
    methods (Access = private)
        function onLoad(app)
            [file, path] = uigetfile({'*.csv', 'Projections CSV (*.csv)'}, "Load projections");
            figure(app.Figure);
            if isequal(file, 0), return; end
            app.loadFile(fullfile(path, file));
        end

        function onSample(app)
            app.loadFile(fullfile(fileparts(mfilename("fullpath")), "data", "sample_DFF_NFL.csv"));
        end

        function onSiteChanged(app)
            rules = dfs.siteRules(app.SiteDD.Value);
            app.SalaryCap.Value = rules.SalaryCap;
        end

        function onPreset(app)
            switch app.Mode.Value
                case 'Cash game'
                    app.StackSize.Value = 0;
                    app.BringBack.Value = 0;
                    app.AvoidQBvsDST.Value = false;
                    app.OwnershipWeight.Value = 0;
                    app.MaxOwnership.Value = 0;
                    app.NumLineups.Value = 1;
                    app.Randomness.Value = 0;
                    app.setStatus("Cash preset: maximize projection, no stacking, one lineup. Floor over ceiling.");
                case 'Tournament (GPP)'
                    app.StackSize.Value = 1;
                    app.BringBack.Value = 1;
                    app.AvoidQBvsDST.Value = true;
                    app.OwnershipWeight.Value = 0.05;
                    app.NumLineups.Value = 20;
                    app.MaxExposure.Value = 50;
                    app.MinUnique.Value = 3;
                    app.Randomness.Value = 10;
                    app.setStatus("GPP preset: game stack, fade chalk a little, 20 distinct lineups, nobody in more than half.");
            end
        end

    end

    methods
        function optimize(app)
            %OPTIMIZE Build lineups with the current sidebar settings.
            if isempty(app.Players)
                uialert(app.Figure, "Load a projections file first.", "No players");
                return
            end
            opts = app.currentOptions();
            N = app.NumLineups.Value;
            dlg = uiprogressdlg(app.Figure, "Title", "Building lineups", "Message", "Solving lineup 1...", ...
                "Cancelable", "on", "Indeterminate", "off");
            cleanup = onCleanup(@() close(dlg));
            progress = @(k, total, info) app.onProgress(dlg, k, total, sprintf("Lineup %d of %d: %.1f pts", k, total, info.ProjectedPoints));
            argCell = namedargs2cell(opts);
            t0 = tic;
            try
                [lineups, summary, exposure] = dfs.generateLineups(app.Players, N, argCell{:}, ...
                    MaxExposure=app.MaxExposure.Value / 100, MinUnique=app.MinUnique.Value, ...
                    Randomness=app.Randomness.Value / 100, Seed=app.Seed.Value, ProgressFcn=progress);
            catch err
                uialert(app.Figure, err.message, "Optimization failed");
                return
            end
            if isempty(lineups)
                uialert(app.Figure, "No lineup satisfies these constraints. Loosen the stack, " + ...
                    "min salary, ownership cap, or locks.", "Infeasible");
                return
            end
            app.Lineups = lineups;
            app.Summary = summary;
            app.Exposure = exposure;
            app.refreshLineups();
            app.refreshExposure();
            app.ExportBtn.Enable = "on";
            app.Tabs.SelectedTab = app.Tabs.Children(1);
            app.setStatus(sprintf("%d lineup(s) in %.1f s. Lineup 1: %.1f pts, %s, %.0f%% summed ownership.", ...
                numel(lineups), toc(t0), summary.Points(1), money(summary.Salary(1)), summary.Ownership(1)));
        end

        function simulate(app)
            %SIMULATE Run the Monte Carlo view with the current settings.
            if isempty(app.Players)
                uialert(app.Figure, "Load a projections file first.", "No players");
                return
            end
            opts = app.currentOptions();
            opts = rmfield(opts, "Objective");    % the draws are the objective
            M = app.NumDraws.Value;
            dlg = uiprogressdlg(app.Figure, "Title", "Monte Carlo", "Message", "Draw 1...", "Cancelable", "on");
            cleanup = onCleanup(@() close(dlg));
            progress = @(k, total, ~) app.onProgress(dlg, k, total, sprintf("Draw %d of %d", k, total));
            argCell = namedargs2cell(opts);
            t0 = tic;
            try
                [freq, sims] = dfs.simulateLineups(app.Players, M, argCell{:}, Seed=app.Seed.Value, ProgressFcn=progress);
            catch err
                uialert(app.Figure, err.message, "Simulation failed");
                return
            end
            app.Frequency = freq;
            app.SimLineups = sims;
            app.refreshSimulation();
            app.Tabs.SelectedTab = app.Tabs.Children(4);
            app.setStatus(sprintf("%d draws in %.1f s: %d distinct optimal lineups; top player in %.0f%% of draws.", ...
                sum(sims.Draws), toc(t0), height(sims), freq.Frequency(1)));
        end

        function lockPlayers(app, names)
            %LOCKPLAYERS Force these players into every lineup.
            names = string(names);
            app.Locks = unique([app.Locks, names(:)']);
            app.Excludes = setdiff(app.Excludes, names);
            app.refreshPool();
        end

        function excludePlayers(app, names)
            %EXCLUDEPLAYERS Keep these players out of every lineup.
            names = string(names);
            app.Excludes = unique([app.Excludes, names(:)']);
            app.Locks = setdiff(app.Locks, names);
            app.refreshPool();
        end

        function exportTo(app, file)
            %EXPORTTO Write the current lineups to a CSV.
            if isempty(app.Lineups)
                error("dfs:noLineups", "No lineups to export. Run optimize first.");
            end
            dfs.exportLineups(app.Lineups, file);
            app.setStatus("Exported " + numel(app.Lineups) + " lineups to " + string(file));
        end
    end

    methods (Access = private)
        function stop = onProgress(~, dlg, k, total, message)
            dlg.Value = k / total;
            dlg.Message = message;
            stop = dlg.CancelRequested;
        end

        function onExport(app)
            if isempty(app.Lineups), return; end
            [file, path] = uiputfile({'*.csv', 'CSV (*.csv)'}, "Export lineups", "lineups.csv");
            figure(app.Figure);
            if isequal(file, 0), return; end
            app.exportTo(fullfile(path, file));
        end

        function onCopyCode(app)
            code = app.asCode();
            clipboard("copy", code);
            app.setStatus("Copied a dfs.generateLineups call with these settings to the clipboard.");
        end

        function onSummarySelected(app, evt)
            if isempty(evt.Indices), return; end
            app.showLineup(evt.Indices(1));
        end

        function onPoolEdited(app, src, evt)
            row = evt.Indices(1);
            col = string(src.ColumnName{evt.Indices(2)});
            name = string(src.Data{row, strcmp(src.ColumnName, "Name")});
            switch col
                case "Lock"
                    app.Locks = setdiff(app.Locks, name);
                    app.Excludes = setdiff(app.Excludes, name);
                    if evt.NewData, app.Locks(end+1) = name; end
                case "Exclude"
                    app.Excludes = setdiff(app.Excludes, name);
                    app.Locks = setdiff(app.Locks, name);
                    if evt.NewData, app.Excludes(end+1) = name; end
                otherwise
                    return
            end
            app.refreshPool();
            app.setStatus(sprintf("%d locked, %d excluded.", numel(app.Locks), numel(app.Excludes)));
        end

        function onClearPicks(app)
            app.Locks = strings(1, 0);
            app.Excludes = strings(1, 0);
            app.refreshPool();
            app.setStatus("Cleared locks and excludes.");
        end
    end

    %% ------------------------------------------------------------ refresh
    methods (Access = private)
        function refreshObjectiveItems(app)
            vars = app.Players.Properties.VariableNames;
            numericCols = vars(varfun(@isnumeric, app.Players, "OutputFormat", "uniform"));
            skip = ["Salary", "Ownership", "week", "L5_dvp_rank"];
            items = numericCols(~ismember(numericCols, skip));
            items = ["Projection", setdiff(items, "Projection", "stable")];
            app.Objective.Items = cellstr(items);
            app.Objective.Value = 'Projection';
        end

        function refreshPool(app)
            if isempty(app.Players)
                app.PoolTable.Data = {};
                return
            end
            P = app.Players(:, ["Name", "Position", "Team", "Opp", "Salary", "Projection", "Value", "Ownership", "Injury"]);
            P.Lock = ismember(P.Name, app.Locks);
            P.Exclude = ismember(P.Name, app.Excludes);
            P = movevars(P, ["Lock", "Exclude"], "Before", 1);
            q = lower(strtrim(app.PoolFilter.Value));
            if q ~= ""
                keep = contains(lower(P.Name), q) | contains(lower(P.Team), q);
                P = P(keep, :);
            end
            if ~strcmp(app.PoolPosition.Value, 'All')
                P = P(string(P.Position) == string(app.PoolPosition.Value), :);
            end
            setTableData(app.PoolTable, P);
            app.PoolTable.ColumnEditable = [true true false(1, width(P) - 2)];
        end

        function refreshLineups(app)
            if isempty(app.Lineups)
                app.LineupHeader.Text = "No lineups yet. Press Optimize.";
                app.SummaryTable.Data = {};
                app.LineupTable.Data = {};
                return
            end
            S = app.Summary(:, ["Lineup", "Points", "Salary", "Ownership", "QB", "Stack"]);
            setTableData(app.SummaryTable, S);
            app.showLineup(1);
        end

        function showLineup(app, k)
            if k < 1 || k > numel(app.Lineups), return; end
            L = app.Lineups{k};
            cols = intersect(["Slot", "Name", "Position", "Team", "Opp", "Salary", "Projection", "Value", "Ownership"], ...
                L.Properties.VariableNames, "stable");
            setTableData(app.LineupTable, L(:, cols));
            app.LineupHeader.Text = sprintf("Lineup %d of %d: %.1f projected points, %s spent (%s left), %.0f%% summed ownership", ...
                k, numel(app.Lineups), sum(L.Projection), money(sum(L.Salary)), ...
                money(app.SalaryCap.Value - sum(L.Salary)), sum(L.Ownership));
        end

        function refreshExposure(app)
            % Full reset: a plain cla keeps the categorical ruler's old
            % categories, which would leave ghost rows from the last run.
            ax = app.ExposureAxes;
            cla(ax, "reset");
            ax2 = app.ScatterAxes;
            cla(ax2, "reset");
            if isempty(app.Exposure)
                title(ax, "Exposure vs field ownership");
                title(ax2, "Salary vs projection");
                return
            end
            E = app.Exposure;
            top = E(1:min(20, height(E)), :);
            names = flipud(top.Name);
            y = categorical(names, names);
            barh(ax, y, flipud([top.Exposure, top.Ownership]));
            legend(ax, ["Your exposure %", "Projected field %"], "Location", "southeast");
            xlabel(ax, "Percent of lineups");
            title(ax, sprintf("Exposure across %d lineup(s)", numel(app.Lineups)));
            grid(ax, "on");

            P = app.Players;
            used = ismember(P.Name, E.Name);
            scatter(ax2, P.Salary(~used), P.Projection(~used), 18, [0.75 0.75 0.75], "filled");
            hold(ax2, "on");
            scatter(ax2, P.Salary(used), P.Projection(used), 36, [0.05 0.45 0.80], "filled");
            hold(ax2, "off");
            xlabel(ax2, "Salary ($)");
            ylabel(ax2, "Projected points");
            title(ax2, "Player pool (blue = used in a lineup)");
            grid(ax2, "on");
        end

        function refreshSimulation(app)
            ax = app.FrequencyAxes;
            cla(ax, "reset");
            if isempty(app.Frequency)
                app.FrequencyTable.Data = {};
                title(ax, "Run a simulation to see who survives projection noise");
                return
            end
            F = app.Frequency;
            setTableData(app.FrequencyTable, F(:, ["Name", "Position", "Team", "Salary", "Projection", "Ownership", "Frequency", "Leverage"]));
            top = F(1:min(20, height(F)), :);
            names = flipud(top.Name);
            barh(ax, categorical(names, names), flipud([top.Frequency, top.Ownership]));
            legend(ax, ["Optimal in % of draws", "Projected field %"], "Location", "southeast");
            xlabel(ax, "Percent");
            title(ax, "Robust plays: how often each player is optimal");
            grid(ax, "on");
        end

        function setStatus(app, text)
            app.Status.Text = "  " + string(text);
            drawnow limitrate
        end
    end
end

%% ---------------------------------------------------------- helpers
function s = money(x)
% $50,000 style.
s = "$" + regexprep(sprintf("%d", round(x)), "(\d)(?=(\d{3})+$)", "$1,");
end

function setTableData(uit, T)
% Show a table in a uitable as cell data so numbers display in shortG format
% (167.2, not 167.2000) and columns stay sortable. A table-typed Data
% property ignores ColumnFormat.
vars = T.Properties.VariableNames;
fmt = cell(1, numel(vars));
C = cell(height(T), numel(vars));
for k = 1:numel(vars)
    v = T.(vars{k});
    if islogical(v)
        fmt{k} = 'logical';
        C(:, k) = num2cell(v);
    elseif isnumeric(v)
        fmt{k} = 'shortG';        % 167.2 and 50000, not 167.2000 (must be char, not string)
        C(:, k) = num2cell(double(v));
    else
        fmt{k} = 'char';
        C(:, k) = cellstr(string(v));
    end
end
uit.Data = C;
uit.ColumnName = vars;
uit.ColumnFormat = fmt;
uit.ColumnSortable = true;
end
