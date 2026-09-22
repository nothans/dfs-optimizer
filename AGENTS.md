# Working on this repo with a coding agent

This file is for AI coding agents (Claude Code, Copilot, Codex, Gemini CLI, Amp) and the people driving them.
It pairs with the [MATLAB Agentic Toolkit](https://github.com/matlab/matlab-agentic-toolkit), which gives your agent a live MATLAB session (the MATLAB MCP Server) and MathWorks-curated skills.
The README's [Use it with a coding agent](README.md#use-it-with-a-coding-agent) section covers setup.

## What this is

A DFS (daily fantasy sports) NFL lineup optimizer in MATLAB.
A pure function library (`+dfs/`) does the work; a uifigure app (`DFSOptimizerApp.m`) is a thin view over it.
Lineups come from `intlinprog` through the problem-based Optimization Toolbox interface.

## Map

| Path | What it does |
| --- | --- |
| `+dfs/loadProjections.m` | CSV to a canonical player table (Name, Position, Team, Opp, Game, Salary, Projection, Value, Ownership, Injury, plus every original column) |
| `+dfs/siteRules.m` | DraftKings and FanDuel roster rules as a struct; accepts a custom struct |
| `+dfs/optimizeLineup.m` | One lineup. All strategy levers are name-value options (stack, bring-back, ownership, locks, uniqueness) |
| `+dfs/generateLineups.m` | N lineups with exposure caps, pairwise uniqueness, optional randomness, progress/cancel callback |
| `+dfs/simulateLineups.m` | Monte Carlo: re-solve under sampled projections, report player frequency |
| `+dfs/validateLineup.m` | Solver-independent audit of a lineup against the rules |
| `+dfs/exportLineups.m` | CSV in site upload order (QB,RB,RB,WR,WR,WR,TE,FLEX,DST) |
| `DFSOptimizerApp.m` | Explorer app: sidebar of levers, tabs for lineups, pool, exposure, Monte Carlo. Public methods: `loadFile`, `optimize`, `simulate`, `lockPlayers`, `excludePlayers`, `exportTo`, `currentOptions`, `asCode` |
| `dfs.m` | The original one-screen script, now calling the library |
| `data/sample_DFF_NFL.csv` | Synthetic 13-game slate in the exact Daily Fantasy Fuel header (`tools/makeSampleData.m` regenerates it) |
| `tests/tDfsOptimizer.m` | Unit tests for everything above; `tests/fixtures/` holds a real DFF header |
| `examples/` | `quickstart.m`, `tournamentPortfolio.m` |

## How to run

```matlab
% from the repo root
players = dfs.loadProjections("data/sample_DFF_NFL.csv");
[lineup, info] = dfs.optimizeLineup(players, StackSize=1, AvoidQBvsDST=true);
runtests("tests")          % 23 tests, about a minute
DFSOptimizerApp            % the explorer
```

Through the MATLAB MCP Server: `run_matlab_test_file` on `tests/tDfsOptimizer.m`, `check_matlab_code` on any file, `evaluate_matlab_code` for experiments.

## Rules for changes

- **Validate every solve.** `optimizeLineup` checks the exit flag and then re-audits the lineup with `validateLineup`. Keep that shape: a new constraint gets a validator clause and a test.
- **Keep the library pure.** No UI code in `+dfs/`. The app calls the library; the library never calls the app.
- **Problem-based by default.** New constraints are `optimconstr`/expression rows on the `x` vector, vectorized (indicator matrices, not loops). See the MILP block in the README for the notation.
- **Name-value options flow through.** A new lever on `optimizeLineup` also needs to be listed in the `arguments` blocks of `generateLineups` and `simulateLineups`, and (if user-facing) in the app sidebar plus `currentOptions`/`asCode`.
- **Never guess solver options.** Check with `optimoptions("intlinprog")` in the live session.
- **Tests must pass before you claim done.** Run the suite; paste the numbers.
- **Flag unverified numbers.** Volatility priors in `simulateLineups` and correlation claims in the README are labeled as working assumptions. Keep them labeled.
- **Style.** `arguments` blocks on every public function, `string` over `char`, no em dashes in prose.

## Skills that help

Install these skill groups from the MATLAB Agentic Toolkit (fewer is better; agents trigger skills more reliably with a short list):

| Skill | Use it for |
| --- | --- |
| `matlab-solve-optimization` (Math and Optimization) | Adding constraints, tuning `intlinprog`, validating results |
| `matlab-build-app` (MATLAB App Building) | Editing `DFSOptimizerApp.m`: grid layout, callbacks, components |
| `matlab-write-tests` / `matlab-run-tests` (MATLAB Core) | Extending `tests/tDfsOptimizer.m` |
| `matlab-import-export-data` (Data Import and Analysis) | Teaching `loadProjections` a new export format |

## Prompts that work

- "Load `data/sample_DFF_NFL.csv`, build 20 DraftKings GPP lineups with a 2-man stack and 40% max exposure, and tell me the five players where my exposure is furthest above projected ownership."
- "Add a `MaxFromPosition` style option to `dfs.optimizeLineup` (for example, cap salary spent on RBs), with a validator clause and a test. Use the same indicator-matrix pattern as `MaxPerTeam` and `MaxFromGame`."
- "Compare the cash lineup and the GPP lineup on the sample slate and explain, in points and ownership, what the stack costs."
- "Run 200 Monte Carlo draws with lognormal volatility and list players who are optimal in over 30% of draws but projected under 10% ownership."
- "The optimizer says infeasible with my locks. Diagnose which constraint conflicts and propose the smallest change."
