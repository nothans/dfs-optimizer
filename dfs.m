% Enter a salary cap
salaryCap = 50000

% Logical indices for each player position
iQB = DFF_data.position == 'QB';
iRB = DFF_data.position == 'RB';
iWR = DFF_data.position == 'WR';
iTE = DFF_data.position == 'TE';
iDST = DFF_data.position == 'DST';

%% Define upper and lower bounds

% Every player is picked or not picked
nPlayers = height(DFF_data);
lb = zeros(nPlayers,1);
ub = ones(nPlayers,1);

%% Create equality constraints

Aeq = [];
beq = [];

% Exactly one QB
Aeq = [Aeq; iQB'];
beq = [beq; 1];

% Exactly one Defense
Aeq = [Aeq; iDST'];
beq = [beq; 1];

% Total among RB+WR+TE is exactly 6
Aeq = [Aeq; (iRB | iWR | iTE)'];
beq = [beq; 7];

%% Create inequality constraints

A = [];
b = [];

% Between 2 and 3 RBs
A = [A; iRB'];
b = [b; 3];
A = [A; -iRB'];
b = [b; -2];

% Between 3 and 4 WRs
A = [A; iWR'];
b = [b; 4];
A = [A; -iWR'];
b = [b; -3];

% Between 1 and 2 TEs
A = [A; iTE'];
b = [b; 2];
A = [A; -iTE'];
b = [b; -1];

% Total salary less than or equal to salaryCap
A = [A; DFF_data.salary'];
b = [b; salaryCap];

%% Define cost function

fun = -DFF_data.ppg_projection';

%% Optimize

[x,fval] = intlinprog(fun,1:nPlayers,A,b,Aeq,beq,lb,ub);
     
%% Display Optimal Team

OptimalTeam = DFF_data(logical(x),:)
