% Copyright 2010 Raytheon BBN Technologies
%
% Licensed under the Apache License, Version 2.0 (the "License");
% you may not use this file except in compliance with the License.
% You may obtain a copy of the License at
%
%     http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS,
% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% See the License for the specific language governing permissions and
% limitations under the License.
%
% File: optimize_mixer_ampPhase.m
%
% Description: Searches for optimal amplitude and phase correction on an
% I/Q mixer.

function T = optimize_mixer_ampPhase(obj, i_offset, q_offset)
    % unpack constants from cfg file
    ExpParams = obj.inputStructure.ExpParams;
    spec_analyzer_span = ExpParams.SpecAnalyzer.span;
    spec_resolution_bw = ExpParams.SpecAnalyzer.resolution_bw;
    spec_sweep_points = ExpParams.SpecAnalyzer.sweep_points;
    awg_I_channel = ExpParams.Mixer.I_channel;
    awg_Q_channel = ExpParams.Mixer.Q_channel;
    fssb = ExpParams.SSBFreq; % SSB modulation frequency (usually 10 MHz)

    simul_amp = 1.0;
    simul_phase = 0.0;

    verbose = obj.inputStructure.verbose;
    simulate = obj.testMode;
    
    % initialize instruments
    if ~simulate
        % grab instrument objects
        sa = obj.sa;
        awg = obj.awg;
        
        awg_amp = awg.(['chan_' num2str(awg_I_channel)]).Amplitude;

        sa.center_frequency = obj.specgen.frequency * 1e9 - fssb;
        sa.span = spec_analyzer_span;
        sa.sweep_mode = 'single';
        sa.resolution_bw = spec_resolution_bw;
        sa.sweep_points = spec_sweep_points;
        sa.video_averaging = 0;
        sa.sweep();
        sa.peakAmplitude();

        awgfile = ExpParams.SSBAWGFile;
        awg.openConfig(awgfile);
        awg.runMode = 'CONT';
        awg.(['chan_' num2str(awg_I_channel)]).offset = i_offset;
        awg.(['chan_' num2str(awg_Q_channel)]).offset = q_offset;
        obj.setInstrument(awg_amp, 0);
        switch class(awg)
            case 'deviceDrivers.Tek5014'
                awg.(['chan_' num2str(awg_I_channel)]).Enabled = 1;
                awg.(['chan_' num2str(awg_Q_channel)]).Enabled = 1;
            case 'deviceDrivers.APS'
                awg.(['chan_' num2str(awg_I_channel)]).enabled = 1;
                awg.(['chan_' num2str(awg_Q_channel)]).enabled = 1;
        end
        awg.run();
        awg.waitForAWGtoStartRunning();
    else
        awg_amp = 1.0;
    end
    
    phaseScale = 10.0;
    % initial guess has no amplitude or phase correction
    x0 = [awg_amp, 0];
    % options for Levenberg-Marquardt
    if verbose
        displayMode = 'iter';
    else
        displayMode = 'none';
    end
    
    fprintf('\nStarting search for optimal amp/phase\n');

    % Leven-Marquardt search
    options = optimset(...
        'TolX', 1e-3, ... %2e-3
        'TolFun', 1e-4, ...
        'MaxFunEvals', 100, ...
        'OutputFcn', @obj.LMStoppingCondition, ...
        'DiffMinChange', 1e-3, ... %1e-4 worked well in simulation
        'Jacobian', 'off', ... % use finite-differences to compute Jacobian
        'Algorithm', {'levenberg-marquardt',1e-1}, ... % starting value for lambda = 1e-1
        'ScaleProblem', 'Jacobian', ... % 'Jacobian' or 'none'
        'Display', displayMode);
    [x0, optPower] = lsqnonlin(@SSBObjectiveFcn,x0,[],[],options);

    % commented out section for fminunc search
%     options = optimset(...
%         'TolX', 1e-3, ... %2e-3
%         'TolFun', 1e-4, ...
%         'MaxFunEvals', 100, ...
%         'DiffMinChange', 5e-4, ... %1e-4 worked well in simulation
%         'LargeScale', 'off',...
%         'Display', displayMode);
%     [x0, optPower] = fminunc(@SSBObjectiveFcn,x0,options);
%     optPower = optPower^2;

    % Nelder-Meade Simplex search
%     options = optimset(...
%         'TolX', 1e-3, ... %2e-3
%         'TolFun', 1e-4, ...
%         'MaxFunEvals', 100, ...
%         'Display', displayMode);
%     [x0, optPower] = fminsearch(@SSBObjectiveFcn,x0,options);
%     optPower = optPower^2;
    
    ampFactor = x0(1)/awg_amp;
    skew = x0(2)*phaseScale;
    fprintf('Optimal amp/phase parameters:\n');
    fprintf('a: %.3g, skew: %.3g degrees\n', [ampFactor, skew]);
    fprintf('SSB power: %.2f\n', 10*log10(optPower));
    
    % correction transformation
    T = [ampFactor ampFactor*tand(skew); 0 secd(skew)];
    
    % restore instruments to a normal state
    if ~simulate
        sa.center_frequency = obj.specgen.frequency * 1e9;
        sa.span = 25e6;
        sa.sweep_mode = 'cont';
        sa.resolution_bw = 'auto';
        sa.sweep_points = 800;
        sa.video_averaging = 1;
        sa.sweep();
        sa.peakAmplitude();
        
        awg.(['chan_' num2str(awg_I_channel)]).offset = i_offset;
        awg.(['chan_' num2str(awg_Q_channel)]).offset = q_offset;
        %obj.setInstrument(awg_amp, 0);
    end
    
    % local functions
    function cost = SSBObjectiveFcn(x)
        phase = x(2)*phaseScale;
        if verbose, fprintf('amp: %.3f, x(2): %.3f, phase: %.3g\n', x(1), x(2), phase); end
        if ~simulate
            obj.setInstrument(x(1), phase);
            pause(0.01);
        else
            simul_amp = x(1);
            simul_phase = phase;
        end
        power = readPower();
        cost = 10^(power/20);
        if verbose, fprintf('Power: %.3f, Cost: %.3f \n', power, cost); end
    end

    function power = readPower()
        if ~simulate
            sa.sweep();
            power = sa.peakAmplitude();
        else
            best_amp = 1.05;
            ampError = simul_amp/best_amp;
            best_phase = 7.1;
            phaseError = simul_phase - best_phase;
            errorVec = [ampError - cosd(phaseError); sind(phaseError)];

            power = 20*log10(norm(errorVec));
        end
    end
end
