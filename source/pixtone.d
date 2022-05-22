module pixtone;

import std.random;
import std.math;
import organya;

align(1) struct PIXTONEPARAMETER2
{
	align(1):
	int model;
	double num;
	int top;
	int offset;
}

align(1) struct PIXTONEPARAMETER
{
	align(1):
	int use;
	int size;
	PIXTONEPARAMETER2 oMain;
	PIXTONEPARAMETER2 oPitch;
	PIXTONEPARAMETER2 oVolume;
	int initial;
	int pointAx;
	int pointAy;
	int pointBx;
	int pointBy;
	int pointCx;
	int pointCy;
}

immutable gWaveModelTable = MakeWaveTables();

private byte[0x100][6] MakeWaveTables() @safe {
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
		table[5][i] = cast(byte)uniform(0, 127, rng);
	}
	return table;
}

//BOOL wave_tables_made;

bool MakePixelWaveData(const PIXTONEPARAMETER ptp, ubyte[] pData) @safe {
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
	while (i < ptp.pointAx)
	{
		envelopeTable[i] = cast(byte)dEnvelope;
		dEnvelope = ((cast(double)ptp.pointAy - ptp.initial) / ptp.pointAx) + dEnvelope;
		++i;
	}

	dEnvelope = ptp.pointAy;
	while (i < ptp.pointBx)
	{
		envelopeTable[i] = cast(byte)dEnvelope;
		dEnvelope = ((cast(double)ptp.pointBy - ptp.pointAy) / cast(double)(ptp.pointBx - ptp.pointAx)) + dEnvelope;
		++i;
	}

	dEnvelope = ptp.pointBy;
	while (i < ptp.pointCx)
	{
		envelopeTable[i] = cast(byte)dEnvelope;
		dEnvelope = (cast(double)ptp.pointCy - ptp.pointBy) / cast(double)(ptp.pointCx - ptp.pointBx) + dEnvelope;
		++i;
	}

	dEnvelope = ptp.pointCy;
	while (i < 0x100)
	{
		envelopeTable[i] = cast(byte)dEnvelope;
		dEnvelope = dEnvelope - (ptp.pointCy / cast(double)(0x100 - ptp.pointCx));
		++i;
	}

	dPitch = ptp.oPitch.offset;
	dMain = ptp.oMain.offset;
	dVolume = ptp.oVolume.offset;

	if (ptp.oMain.num == 0.0)
		d1 = 0.0;
	else
		d1 = 256.0 / (ptp.size / ptp.oMain.num);

	if (ptp.oPitch.num == 0.0)
		d2 = 0.0;
	else
		d2 = 256.0 / (ptp.size / ptp.oPitch.num);

	if (ptp.oVolume.num == 0.0)
		d3 = 0.0;
	else
		d3 = 256.0 / (ptp.size / ptp.oVolume.num);

	for (i = 0; i < ptp.size; ++i)
	{
		a = cast(int)dMain % 0x100;
		b = cast(int)dPitch % 0x100;
		c = cast(int)dVolume % 0x100;
		d = cast(int)(cast(double)(i * 0x100) / ptp.size);
		pData[i] = cast(ubyte)(gWaveModelTable[ptp.oMain.model][a]
		         * ptp.oMain.top
		         / 64
		         * (((gWaveModelTable[ptp.oVolume.model][c] * ptp.oVolume.top) / 64) + 64)
		         / 64
		         * envelopeTable[d]
		         / 64
		         + 128);

		if (gWaveModelTable[ptp.oPitch.model][b] < 0)
			dMain += d1 - d1 * 0.5 * -cast(int)gWaveModelTable[ptp.oPitch.model][b] * ptp.oPitch.top / 64.0 / 64.0;
		else
			dMain += d1 + d1 * 2.0 * gWaveModelTable[ptp.oPitch.model][b] * ptp.oPitch.top / 64.0 / 64.0;

		dPitch += d2;
		dVolume += d3;
	}

	return true;
}

int MakePixToneObject(ref Organya org, const(PIXTONEPARAMETER)[] ptp, int no) @safe {
	int sample_count;
	int i, j;
	ubyte[] pcm_buffer;
	ubyte[] mixed_pcm_buffer;

	sample_count = 0;

	for (i = 0; i < ptp.length; i++)
	{
		if (ptp[i].size > sample_count) {
			sample_count = ptp[i].size;
		}
	}

	pcm_buffer = mixed_pcm_buffer = null;

	pcm_buffer = new ubyte[](sample_count);
	mixed_pcm_buffer = new ubyte[](sample_count);

	if (pcm_buffer == null || mixed_pcm_buffer == null)
	{
		return -1;
	}

	pcm_buffer[0 .. sample_count] = 0x80;
	mixed_pcm_buffer[0 .. sample_count] = 0x80;

	for (i = 0; i < ptp.length; i++)
	{
		if (!MakePixelWaveData(ptp[i], pcm_buffer))
		{
			return -1;
		}

		for (j = 0; j < ptp[i].size; j++)
		{
			if (pcm_buffer[j] + mixed_pcm_buffer[j] - 0x100 < -0x7F)
				mixed_pcm_buffer[j] = 0;
			else if (pcm_buffer[j] + mixed_pcm_buffer[j] - 0x100 > 0x7F)
				mixed_pcm_buffer[j] = 0xFF;
			else
				mixed_pcm_buffer[j] = cast(ubyte)(mixed_pcm_buffer[j] + pcm_buffer[j] - 0x80);
		}
	}

	// This is self-assignment, so redundant. Maybe this used to be something to prevent audio popping ?
	mixed_pcm_buffer[0] = mixed_pcm_buffer[0];
	mixed_pcm_buffer[sample_count - 1] = mixed_pcm_buffer[sample_count - 1];

	//TODO:
	org.lpSECONDARYBUFFER[no] = org.backend.createSound(22050, mixed_pcm_buffer[0 .. sample_count]);

	if (org.lpSECONDARYBUFFER[no] == null)
		return -1;

	return sample_count;
}
