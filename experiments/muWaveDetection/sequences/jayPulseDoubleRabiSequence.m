function jayPulseDoubleRabiSequence(makePlot)

if ~exist('makePlot', 'var')
    makePlot = true;
end
script = java.io.File(mfilename('fullpath'));
path = char(script.getParentFile().getParentFile().getParentFile().getParent());
addpath([path '/common/src'],'-END');
addpath([path '/common/src/util/'],'-END');

temppath = [char(script.getParent()) '\'];
path = 'U:\AWG\Rabi\';
jayPulsePath = 'U:\Blake\outputX.dat';
basename = 'jayDoubleRabi';

fixedPt = 6000;
cycleLength = 10000;
numsteps = 80;
stepsize = 200;

% load config parameters from file
parent_path = char(script.getParentFile.getParent());
cfg_path = [parent_path '/cfg/'];
load([cfg_path 'pulseParams.mat'], 'T', 'delay', 'measDelay', 'bufferDelay', 'bufferReset', 'bufferPadding', 'offset', 'piAmp', 'pi2Amp', 'sigma', 'pulseType', 'delta', 'buffer', 'pulseLength');
load([cfg_path 'pulseParams.mat'], 'T2', 'delay2', 'bufferDelay2', 'bufferReset2', 'bufferPadding2', 'offset2', 'piAmp2', 'pi2Amp2', 'sigma2', 'pulseType2', 'delta2', 'buffer2', 'pulseLength2');

arbDelta = 1.0;
pulseType = 'arbitrary';
pulseLength = 144;

pg = PatternGen('dPiAmp', piAmp, 'dPiOn2Amp', pi2Amp, 'dSigma', sigma, 'dPulseType', pulseType, 'dDelta', arbDelta, 'correctionT', T, 'dBuffer', buffer, 'dPulseLength', pulseLength, 'cycleLength', cycleLength);
pg2 = PatternGen('dPiAmp', piAmp2, 'dPiOn2Amp', pi2Amp2, 'dSigma', sigma2, 'dPulseType', pulseType2, 'dDelta', delta2, 'correctionT', T2, 'dBuffer', buffer2, 'dPulseLength', pulseLength2, 'cycleLength', cycleLength);

amps = 0:stepsize:(numsteps/2-1)*stepsize;
%amps = 0:stepsize:(numsteps-1)*stepsize;
patseq = {pg.pulse('Xtheta', 'amp', amps, 'arbfname', jayPulsePath), pg.pulse('QId', 'width', pulseLength2)};
patseq2{1} = {pg2.pulse('QId')};
patseq2{2} = {pg2.pulse('Xp'), pg2.pulse('QId', 'width', pulseLength), pg2.pulse('Xp')};

% pre-allocate space
ch1 = zeros(numsteps, cycleLength);
ch2 = ch1; ch3 = ch1; ch4 = ch1;
ch1m1 = ch1; ch1m2 = ch1; ch2m1 = ch1; ch2m2 = ch1;
ch3m1 = ch1; ch3m2 = ch1; ch4m1 = ch1; ch4m2 = ch1;

for n = 1:numsteps;
	[patx paty] = pg.getPatternSeq(patseq, mod(n-1,numsteps/2)+1, delay, fixedPt);
	ch1(n, :) = patx + offset;
	ch2(n, :) = paty + offset;
    ch3m1(n, :) = pg.bufferPulse(patx, paty, 0, bufferPadding, bufferReset, bufferDelay);
    
    [patx paty] = pg2.getPatternSeq(patseq2{fix(2*(n-1)/numsteps)+1}, 1, delay2, fixedPt);
	ch3(n, :) = patx + offset2;
	ch4(n, :) = paty + offset2;
    ch4m1(n, :) = pg2.bufferPulse(patx, paty, 0, bufferPadding2, bufferReset2, bufferDelay2);
end

% trigger at fixedPt-500
% measure from (fixedPt:fixedPt+measLength)
measLength = 3000;
measSeq = {pg.pulse('M', 'width', measLength)};
for n = 1:numsteps;
	ch1m1(n,:) = pg.makePattern([], fixedPt-500, ones(100,1), cycleLength);
	ch1m2(n,:) = int32(pg.getPatternSeq(measSeq, n, measDelay, fixedPt+measLength));
end

if makePlot
    myn = 80;
    figure
    plot(ch1(myn,:))
    hold on
    plot(ch2(myn,:), 'r')
    plot(ch3(myn,:), ':')
    plot(ch4(myn,:),'r:')
    plot(5000*ch1m2(myn,:), 'g')
    plot(1000*ch3m1(myn,:), 'r')
    plot(5000*ch1m1(myn,:),'.')
    grid on
    hold off
end

% add offsets to unused channels
%ch1 = ch1 + offset;
%ch2 = ch2 + offset;
%ch3 = ch3 + offset2;
%ch4 = ch4 + offset2;

% make TekAWG file
options = struct('m21_high', 2.0, 'm41_high', 2.0);
TekPattern.exportTekSequence(temppath, basename, ch1, ch1m1, ch1m2, ch2, ch2m1, ch2m2, ch3, ch3m1, ch3m2, ch4, ch4m1, ch4m2, options);
disp('Moving AWG file to destination');
movefile([temppath basename '.awg'], [path basename '.awg']);
end