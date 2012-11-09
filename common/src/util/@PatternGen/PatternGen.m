% Class PATTERNGEN is a utility class for defining time-domain experiments.
%
% Example usage (spin echo experiment):
% delay = 0;
% fixedPt = 1200;
% cycleLen = 1500;
% pg = PatternGen;
% echotimes = 0:1000:10;
% patseq = {pg.pulse('X90p'),...
%			pg.pulse('QId', 'width', echotimes),...
%			pg.pulse('Yp'), ...
%			pg.pulse('QId', 'width', echotimes),...
%			pg.pulse('X90p')};
% [patx paty] = PatternGen.getPatternSeq(patseq, 1, delay, fixedPt, cycleLen);

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

classdef PatternGen < handle
    properties
        pulseLength = 24;
        sigma = 6;
        piAmp = 4000;
        pi2Amp = 2000;
        pi4Amp = 1000;
        delta = -0.5;
        pulseType = 'gaussian';
        buffer = 4;
        SSBFreq = 0; % SSB modulation frequency (sign matters!!)
        % gating pulse parameters
        bufferDelay = 0;
        bufferReset = 12;
        bufferPadding = 12;
        
        cycleLength = 10000;
        samplingRate = 1.2e9; % in samples per second
        T = eye(2,2); % matrix correction matrix
        arbPulses;
        arbfname = '';
        linkListMode = false; % enable to construct link lists
        pulseCollection;
    end
    
    methods
        % constructor
        function obj = PatternGen(varargin)
            %PatternGen(varargin) - Creates a pulse generation object
            %  The first parameter can be a qubit label (e.g. 'q1'), in
            %  which case paramters will be pulled from file. Following
            %  that you can specify parameter name/value pairs (e.g.
            %  PatternGen('q1', 'cycleLength', 10000)).
            
            % intialize map containters
            obj.pulseCollection = containers.Map();
            obj.arbPulses = containers.Map();
            
            if nargin > 0 && mod(nargin, 2) == 1 && ischar(varargin{1})
                % called with a qubit name, load parameters from file
                pulseParams = jsonlab.loadjson(getpref('qlab', 'pulseParamsBundleFile'));
                qubitMap = jsonlab.loadjson(getpref('qlab','Qubit2ChannelMap'));
                
                % pull out only relevant parameters
                qubitParams = pulseParams.(varargin{1});
                chParams = pulseParams.(qubitMap.(varargin{1}).IQkey);
                % combine the two structs
                M = [fieldnames(qubitParams)' fieldnames(chParams)'; struct2cell(qubitParams)' struct2cell(chParams)'];
                % remove duplicate fields
                [~, rows] = unique(M(1,:), 'first');
                M = M(:, rows);
                params = struct(M{:});
                
                % now initialize any property with that name (or the 'd'
                % first letter variant)
                fnames = fieldnames(params);
                for ii = 1:length(fnames)
                    paramName = fnames{ii};
                    if ismember(paramName, properties('PatternGen'))
                        obj.(paramName) = params.(paramName);
                    end
                end
                
                % if there are remaining parameters, assign them
                if nargin > 1
                    obj.assignFromParamPairs(varargin{2:end});
                end
            elseif nargin > 0 && mod(nargin, 2) == 0
                % called with a parameter pair list
                obj.assignFromParamPairs(varargin{:});
            end
        end
        
        function assignFromParamPairs(obj, varargin)
            for i=1:2:nargin-1
                paramName = varargin{i};
                paramValue = varargin{i+1};
                
                if ismember(paramName, properties('PatternGen'))
                    obj.(paramName) = paramValue;
                else
                    warning('%s Ignored not a parameter of PatternGen', paramName);
                end
            end
        end
        
        % pattern generator
        function [xpat ypat] = getPatternSeq(obj, patList, n, delay, fixedPoint)
            numPatterns = size(patList,2);
            xpat = zeros(fixedPoint,1);
            ypat = zeros(fixedPoint,1);
            accumulatedPhase = 0;
            timeStep = 1/obj.samplingRate;
            
            len = 0;

            for i = 1:numPatterns
                [xpulse, ypulse, frameChange] = patList{i}(n, accumulatedPhase); % call the current pulse function;
                
                increment = length(xpulse);
                xpat(len+1:len+increment) = xpulse;
                ypat(len+1:len+increment) = ypulse;
                len = len + increment;
                accumulatedPhase = accumulatedPhase - 2*pi*obj.SSBFreq*timeStep*increment + frameChange;
            end
            
            xpat = xpat(1:len);
            ypat = ypat(1:len);
            
            xpat = int16(obj.makePattern(xpat, fixedPoint + delay, [], obj.cycleLength));
            ypat = int16(obj.makePattern(ypat, fixedPoint + delay, [], obj.cycleLength));
        end
        
        function retVal = pulse(obj, p, varargin)
            self = obj;
            
            identityPulses = {'QId' 'MId' 'ZId'};
            qubitPulses = {'Xp' 'Xm' 'X90p' 'X90m' 'X45p' 'X45m' 'Xtheta' 'Yp' 'Ym' 'Y90p' 'Y90m' 'Y45p' 'Y45m' 'Ytheta' 'Up' 'Um' 'U90p' 'U90m' 'Utheta'};
            measurementPulses = {'M'};
            fluxPulses = {'Zf' 'Zp' 'Z90p' 'Zm' 'Z90m'};
            
            % set default pulse parameters
            params.amp = 0;
            params.width = self.pulseLength;
            params.sigma = self.sigma;
            params.delta = self.delta;
            params.angle = 0; % in radians
            params.rotAngle = 0;
            params.modFrequency = self.SSBFreq;
            params.duration = params.width + self.buffer;
            if ismember(p, qubitPulses)
                params.pType = self.pulseType;
            elseif ismember(p, measurementPulses) || ismember(p, fluxPulses) || ismember(p, identityPulses)
                params.pType = 'square';
            end
            params.arbfname = self.arbfname; % for arbitrary pulse shapes
            params = parseargs(params, varargin{:});
            % if only a width was specified (not a duration), need to update the duration
            % parameter
            if ismember('width', varargin(1:2:end)) && ~ismember('duration', varargin(1:2:end))
                params.duration = params.width + self.buffer;
            end
            
            % extract additional parameters from pulse name
            
            % single qubit pulses
            xPulses = {'Xp' 'Xm' 'X90p' 'X90m' 'X45p' 'X45m' 'Xtheta'};
            yPulses = {'Yp' 'Ym' 'Y90p' 'Y90m' 'Y45p' 'Y45m' 'Ytheta'};
            if ismember(p, xPulses)
                params.angle = 0;
            elseif ismember(p, yPulses)
                params.angle = pi/2;
            end
            
            % set amplitude/rotation angle defaults
            switch p
                case {'Xp','Yp','Up','Zp'}
                    params.amp = self.piAmp;
                    params.rotAngle = pi;
                case {'Xm','Ym','Um','Zm'}
                    params.amp = -self.piAmp;
                    params.rotAngle = pi;
                case {'X90p','Y90p','U90p','Z90p'}
                    params.amp = self.pi2Amp;
                    params.rotAngle = pi/2;
                case {'X90m','Y90m','U90m','Z90m'}
                    params.amp = -self.pi2Amp;
                    params.rotAngle = pi/2;
                case {'X45p','Y45p','U45p','Z45p'}
                    params.amp = self.pi4Amp;
                    params.rotAngle = pi/4;
                case {'X45m','Y45m','U45m','Z45m'}
                    params.amp = -self.pi4Amp;
                    params.rotAngle = pi/4;
            end       
            
            if ismethod(self, [params.pType 'Pulse'])
                params.pf = eval(['@self.' params.pType 'Pulse']);
            else
                error('%s is not a valid method', [params.pType 'Pulse'] )
            end
            
            % measurement pulses
            if ismember(p, measurementPulses)
                params.amp = 1;
                params.modFrequency = 0;
            end
            
            params.samplingRate = 1.2e9;
            
            % create the Pulse object
            retVal = Pulse(p, params, obj.linkListMode);
            
            if obj.linkListMode
                % add hashed pulses to pulseCollection
                for ii = 1:length(retVal.hashKeys)
                    self.pulseCollection(retVal.hashKeys{ii}) = retVal.pulseArray{ii};
                end
            end
        end
        
        function seq = build(obj, pulseList, numsteps, delay, fixedPoint, gated)
            % function pg.build(pulseList, numsteps, delay, fixedPoint)
            % inputs:
            % pulseList - cell array of pulse functions (returned by PatternGen.pulse())
            % numsteps - number of parameters to iterate over in pulseList
            % delay - offset from fixedPoint in # of samples
            % fixedPoint - the delay at which to right align the pulse
            %     sequence, in # of samples
            % gated - boolean that determines if gating pulses should be
            %     calculated for the sequence marker channel
            % returns:
            % seq - struct(waveforms, linkLists) with hashtable of
            %   waveforms and the link list that references the hashtable

            if ~exist('gated', 'var')
                gated = 1;
            end

            numPatterns = length(pulseList);
            
            padWaveform = [0,0];
            padWaveformKey = Pulse.hash(padWaveform);
            padPulse = struct();
            padPulse.pulseArray = {padWaveform};
            padPulse.hashKeys = {padWaveformKey};
            padPulse.isTimeAmplitude = 1;
            padPulse.isZero = 1;
            obj.pulseCollection(padWaveformKey) = padWaveform;
            
            function entry = buildEntry(pulse, n)
                
                reducedIndex = 1 + mod(n-1, length(pulse.hashKeys));
                entry.key = pulse.hashKeys{reducedIndex};
                entry.length = size(pulse.pulseArray{reducedIndex},1);
                entry.repeat = 1;
                entry.isTimeAmplitude = pulse.isTimeAmplitude;
                entry.isZero = pulse.isZero || strcmp(entry.key,padWaveformKey);
                if entry.isZero
                    % remove zero pulses from pulse collection
                    if ~all(entry.key == padWaveformKey) && obj.pulseCollection.isKey(entry.key)
                        obj.pulseCollection.remove(entry.key);
                    end
                    entry.key = padWaveformKey;
                elseif entry.isTimeAmplitude
                    %Shorten up square waveforms to the first point so as
                    %not to waste waveform memory
                    tmpPulse = obj.pulseCollection(entry.key);
                    if size(tmpPulse,1) > 1
                        obj.pulseCollection(entry.key) = tmpPulse(fix(end/2),:);
                    end
                end
                entry.hasMarkerData = 0;
                entry.markerDelay = 0;
                entry.markerMode = 3; % 0 - pulse, 1 - rising, 2 - falling, 3 - none
                entry.linkListRepeat = 0;
            end
            
            LinkLists = {};
            
            for n = 1:numsteps
                % start with a padding pulse which we later expand to the
                % correct length
                LinkList = cell(numPatterns+2,1);
                LinkList{1} = buildEntry(padPulse, 1);
                
                for ii = 1:numPatterns
                    LinkList{1+ii} = buildEntry(pulseList{ii}, n);
                end

                % sum lengths
                xsum = 0;
                for ii = 1:numPatterns
                    xsum = xsum + LinkList{1+ii}.repeat * LinkList{1+ii}.length;
                end
                
                % pad left
                LinkList{1}.length = fixedPoint + delay - xsum;
                %Catch a pulse sequence is too long when the initial padding is less than zero
                if(LinkList{1}.length < 0)
                    error('Pulse sequence step %i is too long.  Try increasing the fixedpoint.',n);
                end

                xsum = xsum + LinkList{1}.length;
                
                % pad right by adding pad waveform with appropriate repeat
                LinkList{end} = buildEntry(padPulse, 1);
                
                LinkList{end}.length = obj.cycleLength - xsum;
                
                % add gating markers
                if gated
                    LinkList = obj.addGatePulses(LinkList);
                end
                
                LinkLists{n} = LinkList;
            end
            
            seq.waveforms = obj.pulseCollection;
            seq.linkLists = LinkLists;
        end
        
        function seq = addTrigger(obj, seq, delay, width)
            % adds a trigger pulse to each link list in the sequence
            % delay - delay (in samples) from the beginning of the link list to the
            %   trigger rising edge
            % width - width (in samples) of the trigger pulse
            
            for kk = 1:length(seq.linkLists)
                linkList = seq.linkLists{kk};
                time = 0;
                for ii = 1:length(linkList)
                    entry = linkList{ii};
                    entryWidth = entry.length * entry.repeat;
                    % check if rising edge falls within the current entry
                    if (time + entryWidth > delay)
                        entry.hasMarkerData = 1;
                        entry.markerDelay = delay - time;
                        entry.markerMode = 1; % 0 - pulse, 1 - rising, 2 - falling, 3 - none
                        % break from the loop, leaving time set to the delay
                        % from the end of the entry
                        time = entryWidth - entry.markerDelay;
                        linkList{ii} = entry;
                        break
                    end
                    time = time + entryWidth;
                end

                for jj = (ii+1):length(linkList)
                    entry = linkList{jj};
                    entryWidth = entry.length * entry.repeat;
                    % check if falling edge falls within the current entry
                    if time + entryWidth > width
                        entry.hasMarkerData = 1;
                        entry.markerDelay = max(width - time, 0);
                        entry.markerMode = 2; % 0 - pulse, 1 - rising, 2 - falling, 3 - none
                        if width < time
                            warning('PatternGen:addTrigger:padding', 'Trigger padded to extend over multiple entries.');
                        end
                        linkList{jj} = entry;
                        break
                    end
                    time = time + entryWidth;
                end
                
                seq.linkLists{kk} = linkList;
            end
        end
        
        function seq = addTriggerPulse(obj, seq, delay, single)
            % adds a trigger pulse to each link list in the sequence
            % delay - delay (in samples) from the beginning of the link list to the
            %   trigger pulse
            % single specifies only generation of marker at begining of LL
            if exist('single', 'var')
            single=1;
            else
            single=0;
            end
            if single
            for kk = 1
                linkList = seq.linkLists{kk};
                time = 0;
                for ii = 1:length(linkList)
                    entry = linkList{ii};
                    entryWidth = entry.length * entry.repeat;
                    % check if rising edge falls within the current entry
                    if (time + entryWidth > delay)
                        entry.hasMarkerData = 1;
                        entry.markerDelay = delay - time;
                        entry.markerMode = 0; % 0 - pulse, 1 - rising, 2 - falling, 3 - none
                        % break from the loop, leaving time set to the delay
                        % from the end of the entry
                        time = entryWidth - entry.markerDelay;
                        linkList{ii} = entry;
                        break
                    end
                    time = time + entryWidth;
                end
                
                seq.linkLists{kk} = linkList;
            end
            
            else
     
            for kk = 1:length(seq.linkLists)
                linkList = seq.linkLists{kk};
                time = 0;
                for ii = 1:length(linkList)
                    entry = linkList{ii};
                    entryWidth = entry.length * entry.repeat;
                    % check if rising edge falls within the current entry
                    if (time + entryWidth > delay)
                        entry.hasMarkerData = 1;
                        entry.markerDelay = delay - time;
                        entry.markerMode = 0; % 0 - pulse, 1 - rising, 2 - falling, 3 - none
                        % break from the loop, leaving time set to the delay
                        % from the end of the entry
                        time = entryWidth - entry.markerDelay;
                        linkList{ii} = entry;
                        break
                    end
                    time = time + entryWidth;
                end
                
                seq.linkLists{kk} = linkList;
            end
            end
        end
        
        function linkList = addGatePulses(obj, linkList)
            % uses the following class buffer parameters to add gating
            % pulses:
            %     bufferReset
            %     bufferPadding
            %     bufferDelay
            
            % The strategy is the following: we add triggers to zero
            % entries and to pulses followed by zero entries. Zero entries
            % followed by pulses get a trigger high. Pulses followed by
            % zeros get a trigger low.
            
            state = 0; % 0 = low, 1 = high
            %Time from end of previous LL entry that trigger needs to go
            %high to gate pulse
            startDelay = fix(obj.bufferPadding - obj.bufferDelay);
            assert(startDelay > 0, 'PatternGen:addGatePulses Negative gate delays');

            LLlength = length(linkList);
            for ii = 1:LLlength-1
                entryWidth = linkList{ii}.length;
                %If current state is low and next linkList is pulse, then
                %we go high in this entry.
                %If current state is high and next entry is TAZ then go low
                %in this one (but check bufferReset)
                if state == 0 && ~linkList{ii+1}.isZero
                    linkList{ii}.hasMarkerData = 1;
                    linkList{ii}.markerDelay = entryWidth - startDelay;
                    linkList{ii}.markerMode = 0;
                    state = 1;
                elseif state == 1 && linkList{ii+1}.isZero && linkList{ii+1}.length > obj.bufferReset
                    %Time from beginning of pulse LL entry that trigger needs to go
                    %low to end gate pulse
                    endDelay = fix(entryWidth + obj.bufferPadding - obj.bufferDelay);
                    if endDelay < 0
                        endDelay = 0;
                        fprintf('addGatePulses warning: fixed buffer low pulse to start of pulse\n');
                    end
                    linkList{ii}.hasMarkerData = 1;
                    linkList{ii}.markerDelay = endDelay;
                    linkList{ii}.markerMode = 0; % 0 = pulse mode
                    state = 0;
                end
            end % end for
        end
            
        function plotWaveformTable(obj,table)
            wavefrms = [];
            keys = table.keys;
            while keys.hasMoreElements()
                key = keys.nextElement();
                wavefrms = [wavefrms table.get(key)'];
            end
            plot(wavefrms)
        end
        
        function [xpattern, ypattern] = linkListToPattern(obj, linkListPattern, n)
            linkList = linkListPattern.linkLists{n};
            wfLib = linkListPattern.waveforms;
            
            xpattern = zeros(1,obj.cycleLength);
            ypattern = xpattern;
            idx = 1;
            for ct = 1:length(linkList)
                if linkList{ct}.isTimeAmplitude
                    amplitude = wfLib(linkList{ct}.key);
                    xamp = amplitude(1,1);
                    yamp = amplitude(1,2);
                    xpattern(idx:idx+linkList{ct}.length-1) = xamp * ones(1,linkList{ct}.length);
                    ypattern(idx:idx+linkList{ct}.length-1) = yamp * ones(1,linkList{ct}.length);
                    idx = idx + linkList{ct}.length;
                else
                    currWf = wfLib(linkList{ct}.key);
                    xpattern(idx:idx+linkList{ct}.repeat*length(currWf)-1) = repmat(currWf(:,1)', 1, linkList{ct}.repeat);
                    ypattern(idx:idx+linkList{ct}.repeat*length(currWf)-1) = repmat(currWf(:,2)', 1, linkList{ct}.repeat);
                    idx = idx + linkList{ct}.repeat*size(currWf,1);
                end
            end
        end
    end
    methods (Static)
        function out = print(seq)
            if iscell(seq)
                out = cellfun(@PatternGen.print, seq, 'UniformOutput', false);
            else
                out = seq.print();
            end
        end
        function out = padLeft(m, len)
            if length(m) < len
                out = [zeros(len - length(m), 1); m];
            else
                out = m;
            end
        end
        
        function out = padRight(m, len)
            if length(m) < len
                out = [m; zeros(len-length(m), 1)];
            else
                out = m;
            end
        end
        
        function out = makePattern(leftPat, fixedPt, rightPat, totalLength)
            self = PatternGen;
            if(length(leftPat) > fixedPt)
                error('Your sequence is %d too long.  Try moving the fixedPt out.', (length(leftPat)-fixedPt))
            end
            out = self.padRight([self.padLeft(leftPat, fixedPt); rightPat], totalLength);
        end
        
        %%%% pulse shapes %%%%%
        function [outx, outy] = squarePulse(params)
            amp = params.amp;
            n = params.width;
            
            outx = amp * ones(n, 1);
            outy = zeros(n, 1);
        end
        
        function [outx, outy] = gaussianPulse(params)
            amp = params.amp;
            n = params.width;
            sigma = params.sigma;
            
            midpoint = (n+1)/2;
            t = 1:n;
            baseLine = round(amp*exp(-midpoint^2/(2*sigma^2)));
            outx = round(amp * exp(-(t - midpoint).^2./(2 * sigma^2))).'- baseLine;
            outy = zeros(n, 1);
        end
        
        function [outx, outy] = gaussOnPulse(params)
            amp = params.amp;
            n = params.width;
            sigma = params.sigma;
            
            t = 1:n;
            baseLine = round(amp*exp(-n^2/(2*sigma^2)));
            outx = round(amp * exp(-(t - n).^2./(2 * sigma^2))).'- baseLine;
            outy = zeros(n, 1);
        end
        
        function [outx, outy] = gaussOffPulse(params)
            amp = params.amp;
            n = params.width;
            sigma = params.sigma;
            
            t = 1:n;
            baseLine = round(amp*exp(-n^2/(2*sigma^2)));
            outx = round(amp * exp(-(t-1).^2./(2 * sigma^2))).'- baseLine;
            outy = zeros(n, 1);
        end
        
        function [outx, outy] = tanhPulse(params)
            amp = params.amp;
            n = params.width;
            sigma = params.sigma;
            if (n < 6*sigma)
                warning('tanhPulse:params', 'Tanh pulse length is shorter than rise+fall time');
            end
            t0 = 3*sigma + 1;
            t1 = n - 3*sigma;
            t = 1:n;
            outx = round(0.5*amp * (tanh((t-t0)./sigma) + tanh(-(t-t1)./sigma))).';
            outy = zeros(n, 1);
        end
        
        function [outx, outy] = derivGaussianPulse(params)
            amp = params.amp;
            n = params.width;
            sigma = params.sigma;
            
            midpoint = (n+1)/2;
            t = 1:n;
            outx = round(amp .* (t - midpoint)./sigma^2 .* exp(-(t - midpoint).^2./(2 * sigma^2))).';
            outy = zeros(n, 1);
        end
        
        function [outx, outy] = derivGaussOnPulse(params)
           amp = params.amp;
           n = params.width;
           sigma = params.sigma;

           t = 1:n;
           outx = round(amp * (-(t-n)./sigma^2).*exp(-(t-n).^2./(2 * sigma^2))).';
           outy = zeros(n, 1);
        end

        function [outx, outy] = derivGaussOffPulse(params)
           amp = params.amp;
           n = params.width;
           sigma = params.sigma;

           t = 1:n;
           outx = round(amp * (-(t-1)./sigma^2).*exp(-(t-1).^2./(2 * sigma^2))).';
           outy = zeros(n, 1);
        end
        
        function [outx, outy] = dragPulse(params)
            self = PatternGen;
            yparams = params;
            yparams.amp = params.amp * params.delta;
            
            [outx, tmp] = self.gaussianPulse(params);
            [outy, tmp] = self.derivGaussianPulse(yparams);
        end
        
        function [outx, outy] = dragGaussOnPulse(params)
            self = PatternGen;
            derivParams = params;
            derivParams.amp = params.amp*params.delta;
            [outx, ~] = self.gaussOnPulse(params);
            [outy, ~] = self.derivGaussOnPulse(derivParams);
        end
        
        function [outx, outy] = dragGaussOffPulse(params)
            self = PatternGen;
            derivParams = params;
            derivParams.amp = params.amp*params.delta;
            [outx, ~] = self.gaussOffPulse(params);
            [outy, ~] = self.derivGaussOffPulse(derivParams);
        end
        
        function [outx, outy] = hermitePulse(params)
            %Broadband excitation pulse based on Hermite polynomials. 
            numPoints = params.width;
            timePts = linspace(-numPoints/2,numPoints/2,numPoints)';
            switch params.rotAngle
                case pi/2
                    A1 = -0.677;
                case pi
                    A1 = -0.956;
                otherwise
                    error('Unknown rotation angle for Hermite pulse.  Currently only handle pi/2 and pi.');
            end
            outx = params.amp*(1+A1*(timePts/params.sigma).^2).*exp(-((timePts/params.sigma).^2));
            outy = zeros(numPoints,1);
        end
        
        function [outx, outy, frameChange] = arbAxisDRAGPulse(params)
            
            rotAngle = params.rotAngle;
            polarAngle = params.polarAngle;
            aziAngle = params.aziAngle;
            nutFreq = params.nutFreq; %nutation frequency for 1 unit of pulse amplitude
            sampRate = params.sampRate;
            
            n = params.width;
            sigma = params.sigma;
            
            
            timePts = linspace(-0.5, 0.5, n)*(n/sigma); 
            gaussPulse = exp(-0.5*(timePts.^2)) - exp(-2);
            
            calScale = (rotAngle/2/pi)*sampRate/sum(gaussPulse);
            % calculate phase steps given the polar angle
            phaseSteps = -2*pi*cos(polarAngle)*calScale*gaussPulse/sampRate;
            % calculate DRAG correction to phase steps
            % need to convert XY DRAG parameter to Z DRAG parameter
            beta = params.delta/sampRate;
            instantaneousDetuning = beta*(2*pi*calScale*sin(polarAngle)*gaussPulse).^2;
            phaseSteps = phaseSteps + instantaneousDetuning*(1/sampRate);
            % center phase ramp around the middle of the pulse
            phaseRamp = cumsum(phaseSteps) - phaseSteps/2;
            
            frameChange = sum(phaseSteps);
            
            complexPulse = (1/nutFreq)*sin(polarAngle)*calScale*exp(1i*aziAngle)*gaussPulse.*exp(1i*phaseRamp);
            
            outx = real(complexPulse)';
            outy = imag(complexPulse)';
        end
        
        function [outx, outy] = arbitraryPulse(params)
            persistent arbPulses;
            if isempty(arbPulses)
                arbPulses = containers.Map();
            end
            amp = params.amp;
            fname = params.arbfname;
            delta = params.delta;
            
            if ~arbPulse.isKey(fname)
                % need to load the pulse from file
                % TODO check for existence of file before loading it
                arbPulses(fname) = load(fname);
            end
            pulseData = arbPulses(fname);
            outx = round(amp*pulseData(:,1));
            outy = round(delta*amp*pulseData(:,2));
        end
        
        % pulses defined in external files
        [outx, outy] = dragSqPulse(params);
        
        % buffer pulse generator
		function out = bufferPulse(patx, paty, zeroLevel, padding, reset, delay)
			self = PatternGen;
            % min reset = 1
            if reset < 1
				reset = 1;
			end

            % subtract offsets
			patx = patx(:) - zeroLevel;
            paty = paty(:) - zeroLevel;
            
            % find when either channel is high
            pat = double(patx | paty);
			
			% buffer to the left
			pat = flipud(conv( flipud(pat), ones(1+padding, 1), 'same' ));
			
			% buffer to the right
			pat = conv( pat, ones(1+padding, 1), 'same');
			
			% convert to on/off
			pat = uint8(logical(pat));
			
			% keep the pulse high if the delay is less than the reset time
            onOffPts = find(diff(pat));
            bufferSpacings = diff(onOffPts);
            if length(onOffPts) > 2
                for ii = 1:(length(bufferSpacings)/2-1)
                    if bufferSpacings(2*ii) < reset
                        pat(onOffPts(2*ii):onOffPts(2*ii+1)+1) = 1;
                    end
                end
            end
			
			% shift by delay # of points
            out = circshift(pat, delay);
        end
    end
end
