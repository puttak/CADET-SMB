function objective = simulatedMovingBed(iter, intermediate_feed, varargin)
% =============================================================================
% Main function, which is in charge of switching to achieve CSS
%
% Binary separations (conventional four-zone scheme) and ternary separations
% (cascade, five-zone or eight zone schemes) are available in this program.
% As for the specific column configurations, I refer your to our paper.
% =============================================================================


    global string stringSet structID dummyProfile startingPointIndex;

    tTotal = tic;

    % Generate alphabet strings to name columns
    stringSet = SMB.stringGeneration();

    % Read operating parameters of SMB unit
    [opt, interstVelocity, Feed, Desorbent] = getParameters(iter, varargin{:});
    % If SMA isotherm, salt is considered as a component
    if strcmp('StericMassActionBinding', opt.BindingModel), opt.nComponents = opt.nComponents + 1; end

    % Check interstitial velocities in SMB optimization
    flag = SMB.interstVelocityCheck(interstVelocity, opt);
    % If flag is true (anyone is negative), assign a big objective value to get rid of
    if flag == 1, objective = 1e5; return; end

    if ~isfield(opt, 'structID'), opt.structID = structID; end

    if opt.enable_CSTR && opt.enable_DPFR
        error('It is not allowed have both the CSTR and DPFR in the simulation \n');
    end

    if opt.nColumn > length(stringSet)
        error('The simulation of %3g-column case in %3g-zone is not finished so far \n', opt.nColumn, opt.nZone);
    end


%   Preallocation
%----------------------------------------------------------------------------------------
    % Generate an initial alphabet string set to identify positions of SMB unit.
    % The position after desorbent node is, by default, marked as "a" (first one)
    string = char(stringSet(1:opt.nColumn));

    % Simulations follow the string sequence (starting from desorbent node)
    % To change starting simulation position, shift num to corresponding value
    string = circshift(string, 0);
    % Be aware, in eight-zone case, simulations cannot begain after feed2 node
    startingPointIndex = SMB.nodeIndexing(opt, string(1));

    % pre-allocate memory to currentData matrix, which is the profile matrix of columns
    currentData = cell(1, opt.nColumn);
    for k = 1:opt.nColumn
        currentData{k}.outlet.time = linspace(0, opt.switch, opt.timePoints);
        currentData{k}.outlet.concentration = zeros(length(Feed.time), opt.nComponents);
        currentData{k}.lastState = cell(1,2);

        if opt.enable_DPFR
            currentData{k}.lastState_DPFR = cell(1,2);
            currentData{k}.lastState_DPFR{1} = zeros(opt.nComponents, opt.DPFR_nCells); % DPFR before
            currentData{k}.lastState_DPFR{2} = zeros(opt.nComponents, opt.DPFR_nCells); % DPFR after
        end
    end

    % Generate arabic numbers to identify columns
    columnNumber = cell(1, opt.nColumn);
    for k = 1:opt.nColumn
        if k == 1, columnNumber{1} = opt.nColumn; else columnNumber{k} = k-1; end
    end
    % Combine alphabet string with arabic numbers for switching sake
    sequence = cell2struct( columnNumber, stringSet(1:opt.nColumn), 2 );

    % Specify the column for the convergence checking. The column after the Feed is usually adopted
    convergIndx = sum(opt.structID(1:2));

    % convergPrevious is used for stopping criterion
    convergPrevious = currentData{convergIndx}.outlet.concentration;
    % The profile of last column in terms of sequence is stored as dummyProfile
    dummyProfile    = currentData{sequence.(string(end))}.outlet;

    % plotData (columnNumber x switches), monitoring instant profile of each column in one iteration
    plotData = cell(opt.nColumn,opt.nColumn);

    % dyncData is used for generating trajectories of withdrawn ports
    dyncData = cell(2, opt.nMaxIter);


%   Simulations
%----------------------------------------------------------------------------------------
    % Interactive plotting when debug mode is enabled
    SMB.UIplot('head', opt);

    % Main loop
    for i = 1:opt.nMaxIter

        % Switch implementation by means of attaching different column to corresponding position
        sequence = cell2struct( circshift( struct2cell(sequence),-1 ), stringSet(1:opt.nColumn) );

        % Load the feed inlets of second sub-unit from the outlets of first sub-unit
        if iter == 2
            for ii = 1:opt.nComponents
                load('intermediateFeedConc.mat');
                Feed.concentration(1:end, ii) = intermediateFeedConc{i}(:,ii);
            end
            if strcmp('StericMassActionBinding', opt.BindingModel),
                Feed.concentration(:, 1) = ones(length(Feed.time), 1) .* opt.concentrationSalt(1);
            end
        end

        for k = string' % do nColumn simulations in terms of string

            % The node balance: transmission of concentration, column state, velocity and so on
            column = SMB.massConservation(currentData, interstVelocity, Feed, Desorbent, opt, sequence, k);

            if opt.enable_CSTR

                % The CSTR before the current column
                column.inlet = SMB.CSTR(column.inlet, column, opt);

                [outletProfile, lastState] = SMB.secColumn(column.inlet, column.params, column.initialState, iter, varargin{:});

                % The CSTR after the current column
                outletProfile.outlet = SMB.CSTR(outletProfile.outlet, column, opt);

            elseif opt.enable_DPFR

                % The DPFR before the current column
                [column.inlet, lastState_DPFR_pre] = SMB.DPFR(column.inlet, column.initialState_DPFR{1}, opt);

                [outletProfile, lastState] = SMB.secColumn(column.inlet, column.params, column.initialState, iter, varargin{:});

                % The DPFR after the current column
                [outletProfile.outlet, lastState_DPFR_pos] = SMB.DPFR(outletProfile.outlet, column.initialState_DPFR{2}, opt);

                currentData{sequence.(k)}.lastState_DPFR = [{lastState_DPFR_pre}, {lastState_DPFR_pos}];

            else

                % The simulation of a single column with the CADET solver
                [outletProfile, lastState] = SMB.secColumn(column.inlet, column.params, column.initialState, iter, varargin{:});

            end

            currentData{sequence.(k)}.outlet     = outletProfile.outlet;
            currentData{sequence.(k)}.colState   = outletProfile.column;
            currentData{sequence.(k)}.lastState  = lastState;

        end % for k = string'

        % Transfer the dymmyProfile, which is the profile of last column in terms of string
        dummyProfile = outletProfile.outlet;

        % The collection of the dyncData for the trajectory plotting
        dyncData{1, i} = currentData{sequence.(char(stringSet(sum(opt.structID(1:3)))))}.outlet.concentration;
        dyncData{2, i} = currentData{sequence.(char(stringSet(opt.structID(1))))}.outlet.concentration;

        % Plot internal profile of columns after nColumn simulations
        if opt.enableDebug, SMB.plotFigures(opt, currentData); end
        % Plot dynamic trajectories at withdrawn ports
        if opt.enableDebug, SMB.plotDynamic(opt, dyncData(:,1:i), i); end

        % Store the instant outlet profiles of all columns at each switching period
        index = mod(i, opt.nColumn);
        if index == 0
            plotData(:,opt.nColumn) = currentData';
        else
            plotData(:,index) = currentData';
        end

        % Convergence criterion adopted in each nColumn switches
        %   ||( C(z, t) - C(z, t + nColumn * t_s) ) / C(z, t)|| < tol, for a specific column
        if mod(i, opt.nColumn) == 0

            diffNorm = 0; stateNorm = 0;

            for k = 1:opt.nComponents
                diffNorm = diffNorm + norm( convergPrevious(:,k) - currentData{convergIndx}.outlet.concentration(:,k) );
                stateNorm = stateNorm + norm( currentData{convergIndx}.outlet.concentration(:,k) );
            end

            relativeDelta = diffNorm / stateNorm;

            % Interactive plotting when debug mode is active
            SMB.UIplot('cycle', opt, i, relativeDelta);

            if relativeDelta <= opt.tolIter
                if iter == 1 || strcmp(intermediate_feed, 'raffinate')
                    intermediateFeedConc = dyncData(1, 1:i);
                    save('intermediateFeedConc.mat', 'intermediateFeedConc');
                elseif iter == 1 && strcmp(intermediate_feed, 'extract')
                    intermediateFeedConc = dyncData(2, 1:i);
                    save('intermediateFeedConc.mat', 'intermediateFeedConc');
                end
                break
            else
                convergPrevious = currentData{convergIndx}.outlet.concentration;
            end

        end

    end % main loop


%   Post-process
%----------------------------------------------------------------------------------------
    % Compute the performance index, such Purity and Productivity
    Results = SMB.Purity_Productivity(plotData, iter);

    % Construct your own Objective Function and calculate the value
    objective = SMB.objectiveFunction(Results, opt);

    tTotal = toc(tTotal);
    % Store the final data into DATA.mat file when debug is active
    if opt.enableDebug
        fprintf('The time elapsed for reaching the Cyclic Steady State: %g sec \n', tTotal);
        SMB.concDataConvertToASCII(currentData, opt, iter);
        SMB.trajDataConvertToASCII(dyncData, opt, iter);
        save(sprintf('Performance_%03d.mat',fix(rand*100)),'Results');
        fprintf('The results about concentration profiles and the trajectories have been stored \n');
    end

end
% =============================================================================
%  SMB - The Simulated Moving Bed Chromatography for separation of
%  target compounds, either binary or ternary.
%
%      Copyright © 2008-2017: Eric von Lieres, Qiaole He
%
%      Forschungszentrum Juelich GmbH, IBG-1, Juelich, Germany.
%
%  All rights reserved. This program and the accompanying materials
%  are made available under the terms of the GNU Public License v3.0 (or, at
%  your option, any later version) which accompanies this distribution, and
%  is available at http://www.gnu.org/licenses/gpl.html
% =============================================================================
