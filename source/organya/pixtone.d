module organya.pixtone;

import std.random;
import std.math;
import organya.organya;

private align(1) struct PixtoneParameter2 {
align(1):
	int model;
	double num;
	int top;
	int offset;
}

package align(1) struct PixtoneParameter {
align(1):
	int use;
	int size;
	PixtoneParameter2 oMain;
	PixtoneParameter2 oPitch;
	PixtoneParameter2 oVolume;
	int initial;
	int pointAx;
	int pointAy;
	int pointBx;
	int pointBy;
	int pointCx;
	int pointCy;
}

private immutable waveModelTable = makeWaveTables();

private byte[0x100][6] makeWaveTables() @safe {
	byte[0x100][6] table;
	int i;

	int a;
	// Sine wave
	for (i = 0; i < 0x100; ++i) {
		table[0][i] = cast(byte)(sin((i * 6.283184) / 256.0) * 64.0);
	}

	// Triangle wave
	for (a = 0, i = 0; i < 0x40; ++i) {
		// Upwards
		table[1][i] = cast(byte)((a * 0x40) / 0x40);
		++a;
	}
	for (a = 0; i < 0xC0; ++i) {
		// Downwards
		table[1][i] = cast(byte)(0x40 - ((a * 0x40) / 0x40));
		++a;
	}
	for (a = 0; i < 0x100; ++i) {
		// Back up
		table[1][i] = cast(byte)(((a * 0x40) / 0x40) - 0x40);
		++a;
	}

	// Saw up wave
	for (i = 0; i < 0x100; ++i) {
		table[2][i] = cast(byte)((i / 2) - 0x40);
	}

	// Saw down wave
	for (i = 0; i < 0x100; ++i) {
		table[3][i] = cast(byte)(0x40 - (i / 2));
	}

	// Square wave
	for (i = 0; i < 0x80; ++i) {
		table[4][i] = 0x40;
	}
	for (; i < 0x100; ++i) {
		table[4][i] = -0x40;
	}

	// White noise wave
	Random rng;
	for (i = 0; i < 0x100; ++i) {
		table[5][i] = cast(byte) uniform(0, 127, rng);
	}
	return table;
}

private void MakePixelWaveData(const PixtoneParameter ptp, ubyte[] pData) @safe {
	int i;
	int a, b, c, d;

	double dPitch;
	double dMain;
	double dVolume;

	double dEnvelope;
	byte[0x100] envelopeTable;

	double d1, d2, d3;

	envelopeTable = envelopeTable.init;

	i = 0;

	dEnvelope = ptp.initial;
	while (i < ptp.pointAx) {
		envelopeTable[i] = cast(byte) dEnvelope;
		dEnvelope = ((cast(double) ptp.pointAy - ptp.initial) / ptp.pointAx) + dEnvelope;
		++i;
	}

	dEnvelope = ptp.pointAy;
	while (i < ptp.pointBx) {
		envelopeTable[i] = cast(byte) dEnvelope;
		dEnvelope = ((cast(double) ptp.pointBy - ptp.pointAy) / cast(double)(ptp.pointBx - ptp.pointAx)) + dEnvelope;
		++i;
	}

	dEnvelope = ptp.pointBy;
	while (i < ptp.pointCx) {
		envelopeTable[i] = cast(byte) dEnvelope;
		dEnvelope = (cast(double) ptp.pointCy - ptp.pointBy) / cast(double)(ptp.pointCx - ptp.pointBx) + dEnvelope;
		++i;
	}

	dEnvelope = ptp.pointCy;
	while (i < 0x100) {
		envelopeTable[i] = cast(byte) dEnvelope;
		dEnvelope = dEnvelope - (ptp.pointCy / cast(double)(0x100 - ptp.pointCx));
		++i;
	}

	dPitch = ptp.oPitch.offset;
	dMain = ptp.oMain.offset;
	dVolume = ptp.oVolume.offset;

	if (ptp.oMain.num == 0.0) {
		d1 = 0.0;
	} else {
		d1 = 256.0 / (ptp.size / ptp.oMain.num);
	}

	if (ptp.oPitch.num == 0.0) {
		d2 = 0.0;
	} else {
		d2 = 256.0 / (ptp.size / ptp.oPitch.num);
	}

	if (ptp.oVolume.num == 0.0) {
		d3 = 0.0;
	} else {
		d3 = 256.0 / (ptp.size / ptp.oVolume.num);
	}

	for (i = 0; i < ptp.size; ++i) {
		a = cast(int) dMain % 0x100;
		b = cast(int) dPitch % 0x100;
		c = cast(int) dVolume % 0x100;
		d = cast(int)(cast(double)(i * 0x100) / ptp.size);
		pData[i] = cast(ubyte)(waveModelTable[ptp.oMain.model][a] * ptp.oMain.top / 64 * (((waveModelTable[ptp.oVolume.model][c] * ptp.oVolume.top) / 64) + 64) / 64 * envelopeTable[d] / 64 + 128);

		if (waveModelTable[ptp.oPitch.model][b] < 0) {
			dMain += d1 - d1 * 0.5 * -cast(int) waveModelTable[ptp.oPitch.model][b] * ptp.oPitch.top / 64.0 / 64.0;
		} else {
			dMain += d1 + d1 * 2.0 * waveModelTable[ptp.oPitch.model][b] * ptp.oPitch.top / 64.0 / 64.0;
		}

		dPitch += d2;
		dVolume += d3;
	}
}

package int makePixToneObject(ref Organya org, const(PixtoneParameter)[] ptp, int no) @safe {
	int sampleCount;
	int i, j;
	ubyte[] pcmBuffer;
	ubyte[] mixedPCMBuffer;

	sampleCount = 0;

	for (i = 0; i < ptp.length; i++) {
		if (ptp[i].size > sampleCount) {
			sampleCount = ptp[i].size;
		}
	}

	pcmBuffer = mixedPCMBuffer = null;

	pcmBuffer = new ubyte[](sampleCount);
	mixedPCMBuffer = new ubyte[](sampleCount);

	pcmBuffer[0 .. sampleCount] = 0x80;
	mixedPCMBuffer[0 .. sampleCount] = 0x80;

	for (i = 0; i < ptp.length; i++) {
		MakePixelWaveData(ptp[i], pcmBuffer);

		for (j = 0; j < ptp[i].size; j++) {
			if (pcmBuffer[j] + mixedPCMBuffer[j] - 0x100 < -0x7F) {
				mixedPCMBuffer[j] = 0;
			} else if (pcmBuffer[j] + mixedPCMBuffer[j] - 0x100 > 0x7F) {
				mixedPCMBuffer[j] = 0xFF;
			} else {
				mixedPCMBuffer[j] = cast(ubyte)(mixedPCMBuffer[j] + pcmBuffer[j] - 0x80);
			}
		}
	}

	org.secondaryAllocatedSounds[no] = org.createSound(22050, mixedPCMBuffer[0 .. sampleCount]);

	return sampleCount;
}
