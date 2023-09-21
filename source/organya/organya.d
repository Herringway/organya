module organya.organya;

import core.time;
import std.algorithm.comparison;
import std.exception;
import std.experimental.logger;
import std.math;

import simplesoftermix.interpolation;
import simplesoftermix.mixer;
import organya.pixtone;

public import simplesoftermix.interpolation : InterpolationMethod;

private enum maxTrack = 16;
private enum maxMelody = 8;

private enum panDummy = 0xFF;
private enum volDummy = 0xFF;
private enum keyDummy = 0xFF;

private enum allocNote = 4096;

// Below are Organya song data structures
private struct NoteList {
	NoteList *from;	// Previous address
	NoteList *to;	// Next address

	int x;	// Position
	ubyte length;	// Sound length
	ubyte y = keyDummy;	// Sound height
	ubyte volume = volDummy;	// Volume
	ubyte pan = panDummy;
}

// Track data * 8
private struct TrackData {
	ushort freq;	// Frequency (1000 is default)
	ubyte waveNumber;
	byte pipi;

	NoteList[] notePosition;
	NoteList *noteList;
}

// Unique information held in songs
public struct MusicInfo {
	ushort wait;
	ubyte line;	// Number of lines in one measure
	ubyte dot;	// Number of dots per line
	ushort allocatedNotes;
	int repeatX;	// Repeat
	int endX;	// End of song (Return to repeat)
	TrackData[maxTrack] trackData;
}

// Wave playing and loading
private struct OctaveWave {
	short waveSize;
	short octavePar;
	short octaveSize;
}

private immutable OctaveWave[8] octaveWaves = [
	{ 256,  1,  4 }, // 0 Oct
	{ 256,  2,  8 }, // 1 Oct
	{ 128,  4, 12 }, // 2 Oct
	{ 128,  8, 16 }, // 3 Oct
	{  64, 16, 20 }, // 4 Oct
	{  32, 32, 24 }, // 5 Oct
	{  16, 64, 28 }, // 6 Oct
	{   8,128, 32 }, // 7 Oct
];


private immutable short[12] frequencyTable = [262, 277, 294, 311, 330, 349, 370, 392, 415, 440, 466, 494];

private immutable short[13] panTable = [0, 43, 86, 129, 172, 215, 256, 297, 340, 383, 426, 469, 512];


// 波形データをロード (Load waveform data)
private immutable byte[0x100][100] waveData = initWaveData(cast(immutable(ubyte)[])import("Wave.dat"));

private byte[0x100][100] initWaveData(const(ubyte)[] data) @safe {
	byte[0x100][100] result;
	foreach (x1, ref x2; result) {
		foreach (idx, ref y; x2) {
			y = cast(byte)data[x1 * 0x100 + idx];
		}
	}
	return result;
}

struct Organya {
	private size_t[2][8][8] allocatedSounds;
	private size_t[512] secondaryAllocatedSounds;
	private Mixer mixer;
	private MusicInfo info;
	private const(PixtoneParameter)[] pixtoneParameters;

	// Play data
	private int playPosition;
	private NoteList*[maxTrack] np;
	private int[maxMelody] nowLength;

	private int globalVolume = 100;
	private int[maxTrack] trackVolume;
	private bool fading = false;
	private bool[maxTrack] mutedTracks;
	private ubyte[maxTrack] playingSounds = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];	// 再生中の音 (Sound being played)
	private ubyte[maxTrack] keyOn;	// キースイッチ (Key switch)
	private ubyte[maxTrack] keyTwin;	// 今使っているキー(連続時のノイズ防止の為に二つ用意) (Currently used keys (prepared for continuous noise prevention))
	private uint masterTimer;
	private uint outputFrequency = 48000;
	public void initialize(uint outputFrequency, InterpolationMethod method) @safe {
		info.allocatedNotes = allocNote;
		info.dot = 4;
		info.line = 4;
		info.wait = 128;
		info.repeatX = info.dot * info.line * 0;
		info.endX = info.dot * info.line * 255;

		for (int i = 0; i < maxTrack; i++) {
			info.trackData[i].freq = 1000;
			info.trackData[i].waveNumber = 0;
			info.trackData[i].pipi = 0;
		}

		noteAlloc(info.allocatedNotes);
		mixer = Mixer(method, outputFrequency);
		this.outputFrequency = outputFrequency;
	}
	// 曲情報を取得 (Get song information)
	public MusicInfo getMusicInfo() @safe {
		MusicInfo mi;
		mi.dot = info.dot;
		mi.line = info.line;
		mi.allocatedNotes = info.allocatedNotes;
		mi.wait = info.wait;
		mi.repeatX = info.repeatX;
		mi.endX = info.endX;

		for (int i = 0; i < maxTrack; i++) {
			mi.trackData[i].freq = info.trackData[i].freq;
			mi.trackData[i].waveNumber = info.trackData[i].waveNumber;
			mi.trackData[i].pipi = info.trackData[i].pipi;
		}
		return mi;
	}
	// 指定の数だけNoteDataの領域を確保(初期化) (Allocate the specified number of NoteData areas (initialization))
	private void noteAlloc(ushort alloc) @safe {
		int i,j;

		for (j = 0; j < maxTrack; j++) {
			info.trackData[j].waveNumber = 0;
			info.trackData[j].noteList = null;
			info.trackData[j].notePosition = new NoteList[](alloc);

			for (i = 0; i < alloc; i++) {
				info.trackData[j].notePosition[i] = NoteList.init;
			}
		}

		for (j = 0; j < maxMelody; j++) {
			makeOrganyaWave(cast(byte)j, info.trackData[j].waveNumber, info.trackData[j].pipi);
		}
	}

	//// 以下は再生 (The following is playback)
	private void playData() @safe nothrow {
		// Handle fading out
		if (fading && globalVolume) {
			globalVolume -= 2;
		}
		if (globalVolume < 0) {
			globalVolume = 0;
		}

		// メロディの再生 (Play melody)
		for (int i = 0; i < maxMelody; i++) {
			if (np[i] != null && playPosition == np[i].x) {
				if (!mutedTracks[i] && np[i].y != keyDummy) {	// 音が来た。 (The sound has come.)
					playOrganObject(np[i].y, -1, cast(byte)i, info.trackData[i].freq);
					nowLength[i] = np[i].length;
				}

				if (np[i].pan != panDummy) {
					changeOrganPan(np[i].y, np[i].pan, cast(byte)i);
				}
				if (np[i].volume != volDummy) {
					trackVolume[i] = np[i].volume;
				}

				np[i] = np[i].to;	// 次の音符を指す (Points to the next note)
			}

			if (nowLength[i] == 0) {
				playOrganObject(0, 2, cast(byte)i, info.trackData[i].freq);
			}

			if (nowLength[i] > 0) {
				nowLength[i]--;
			}

			if (np[i]) {
				changeOrganVolume(np[i].y, trackVolume[i] * globalVolume / 0x7F, cast(byte)i);
			}
		}

		// ドラムの再生 (Drum playback)
		for (int i = maxMelody; i < maxTrack; i++) {
			if (np[i] != null && playPosition == np[i].x) {	// 音が来た。 (The sound has come.)
				if (np[i].y != keyDummy && !mutedTracks[i]) {	// ならす (Tame)
					playDrumObject(np[i].y, 1, cast(byte)(i - maxMelody));
				}

				if (np[i].pan != panDummy) {
					changeDrumPan(np[i].pan, cast(byte)(i - maxMelody));
				}
				if (np[i].volume != volDummy) {
					trackVolume[i] = np[i].volume;
				}

				np[i] = np[i].to;	// 次の音符を指す (Points to the next note)
			}

			if (np[i])
				changeDrumVolume(trackVolume[i] * globalVolume / 0x7F, cast(byte)(i - maxMelody));
		}

		// Looping
		playPosition++;
		if (playPosition >= info.endX) {
			playPosition = info.repeatX;
			setPlayPointer(playPosition);
		}
	}

	private void setPlayPointer(int x) @safe nothrow {
		for (int i = 0; i < maxTrack; i++) {
			np[i] = info.trackData[i].noteList;
			while (np[i] != null && np[i].x < x) {
				np[i] = np[i].to;	// 見るべき音符を設定 (Set note to watch)
			}
		}

		playPosition = x;
	}
	public void loadMusic(const(ubyte)[] p) @safe
		in(p, "No organya data")
	{
		static ushort readLE16(ref const(ubyte)[] p) { scope(exit) p = p[2 .. $]; return ((p[1] << 8) | p[0]); }
		static uint readLE32(ref const(ubyte)[] p) { scope(exit) p = p[4 .. $]; return ((p[3] << 24) | (p[2] << 16) | (p[1] << 8) | p[0]); }

		NoteList[] np;
		int i,j;
		char ver = 0;
		ushort[maxTrack] noteCounts;

		enforce(p != null, "No data to load");

		if(p[0 .. 6] == pass) {
			ver = 1;
		}
		if(p[0 .. 6] == pass2) {
			ver = 2;
		}
		p = p[6 .. $];

		enforce(ver != 0, "Invalid version");

		// 曲の情報を設定 (Set song information)
		info.wait = readLE16(p);
		info.line = p[0];
		p = p[1 .. $];
		info.dot = p[0];
		p = p[1 .. $];
		info.repeatX = readLE32(p);
		info.endX = readLE32(p);

		for (i = 0; i < maxTrack; i++) {
			info.trackData[i].freq = readLE16(p);

			info.trackData[i].waveNumber = p[0];
			p = p[1 .. $];

			if (ver == 1) {
				info.trackData[i].pipi = 0;
			} else {
				info.trackData[i].pipi = p[0];
			}

			p = p[1 .. $];

			noteCounts[i] = readLE16(p);
		}

		// 音符のロード (Loading notes)
		for (j = 0; j < maxTrack; j++) {
			// 最初の音符はfromがNULLとなる (The first note has from as NULL)
			if (noteCounts[j] == 0) {
				info.trackData[j].noteList = null;
				continue;
			}

			// リストを作る (Make a list)
			np = info.trackData[j].notePosition;
			info.trackData[j].noteList = &info.trackData[j].notePosition[0];
			assert(np);
			np[0].from = null;
			np[0].to = &np[1];

			for (i = 1; i < noteCounts[j] - 1; i++) {
				np[i].from = &np[i - 1];
				np[i].to = &np[i + 1];
			}

			// 最後の音符のtoはNULL (The last note to is NULL)
			np[$ - 1].to = null;

			// 内容を代入 (Assign content)
			np = info.trackData[j].notePosition;	// Ｘ座標 (X coordinate)
			for (i = 0; i < noteCounts[j]; i++) {
				np[i].x = readLE32(p);
			}

			np = info.trackData[j].notePosition;	// Ｙ座標 (Y coordinate)
			for (i = 0; i < noteCounts[j]; i++) {
				np[i].y = p[0];
				p = p[1 .. $];
			}

			np = info.trackData[j].notePosition;	// 長さ (Length)
			for (i = 0; i < noteCounts[j]; i++) {
				np[i].length = p[0];
				p = p[1 .. $];
			}

			np = info.trackData[j].notePosition;	// ボリューム (Volume)
			for (i = 0; i < noteCounts[j]; i++) {
				np[i].volume = p[0];
				p = p[1 .. $];
			}

			np = info.trackData[j].notePosition;	// パン (Pan)
			for (i = 0; i < noteCounts[j]; i++) {
				np[i].pan = p[0];
				p = p[1 .. $];
			}
		}

		// データを有効に (Enable data)
		for (j = 0; j < maxMelody; j++) {
			makeOrganyaWave(cast(byte)j,info.trackData[j].waveNumber, info.trackData[j].pipi);
		}

		setPlayPointer(0);	// 頭出し (Cue)

		globalVolume = 100;
		fading = 0;
	}
	public void setPosition(uint x) @safe {
		setPlayPointer(x);
		globalVolume = 100;
		fading = false;
	}

	public uint getPosition() @safe {
		return playPosition;
	}

	public void playMusic() @safe {
		setMusicTimer(info.wait);
	}
	private void makeSoundObject8(const byte[] wavep, byte track, byte pipi) @safe {
		uint i,j,k;
		uint waveTable;	// WAVテーブルをさすポインタ (Pointer to WAV table)
		uint waveSize;	// 256;
		uint dataSize;
		ubyte[] wp;
		ubyte[] wpSub;
		int work;

		for (j = 0; j < 8; j++) {
			for (k = 0; k < 2; k++) {
				waveSize = octaveWaves[j].waveSize;

				if (pipi) {
					dataSize = waveSize * octaveWaves[j].octaveSize;
				} else {
					dataSize = waveSize;
				}

				wp = new ubyte[](dataSize);


				// Get wave data
				wpSub = wp;
				waveTable = 0;

				for (i = 0; i < dataSize; i++) {
					work = wavep[waveTable];
					work += 0x80;

					wpSub[0] = cast(ubyte)work;

					waveTable += 0x100 / waveSize;
					if (waveTable > 0xFF) {
						waveTable -= 0x100;
					}

					wpSub = wpSub[1 .. $];
				}

				allocatedSounds[track][j][k] = mixer.createSound(22050, wp[0 .. dataSize]);

				mixer.getSound(allocatedSounds[track][j][k]).seek(0);
			}
		}
	}
	private void changeOrganFrequency(ubyte key, byte track, int a) @safe nothrow {
		for (int j = 0; j < 8; j++) {
			for (int i = 0; i < 2; i++) {
				mixer.getSound(allocatedSounds[track][j][i]).frequency = cast(uint)(((octaveWaves[j].waveSize * frequencyTable[key]) * octaveWaves[j].octavePar) / 8 + (a - 1000));	// 1000を+αのデフォルト値とする (1000 is the default value for + α)
			}
		}
	}
	private void changeOrganPan(ubyte key, ubyte pan, byte track) @safe nothrow {	// 512がMAXで256がﾉｰﾏﾙ (512 is MAX and 256 is normal)
		if (playingSounds[track] != keyDummy) {
			mixer.getSound(allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]]).pan = (panTable[pan] - 0x100) * 10;
		}
	}

	private void changeOrganVolume(int no, int volume, byte track) @safe nothrow {	// 300がMAXで300がﾉｰﾏﾙ (300 is MAX and 300 is normal)
		if (playingSounds[track] != keyDummy) {
			mixer.getSound(allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]]).volume = cast(short)((volume - 0xFF) * 8);
		}
	}

	// サウンドの再生 (Play sound)
	private void playOrganObject(ubyte key, int mode, byte track, int freq) @safe nothrow {
		switch (mode) {
			case 0:	// 停止 (Stop)
				if (playingSounds[track] != 0xFF) {
					mixer.getSound(allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]]).stop();
					mixer.getSound(allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]]).seek(0);
				}
				break;

			case 1: // 再生 (Playback)
				break;

			case 2:	// 歩かせ停止 (Stop playback)
				if (playingSounds[track] != 0xFF) {
					mixer.getSound(allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]]).play(false);
					playingSounds[track] = 0xFF;
				}
				break;

			case -1:
				if (playingSounds[track] == 0xFF) {	// 新規鳴らす (New sound)
					changeOrganFrequency(key % 12, track, freq);	// 周波数を設定して (Set the frequency)
					mixer.getSound(allocatedSounds[track][key / 12][keyTwin[track]]).play(true);
					playingSounds[track] = key;
					keyOn[track] = 1;
				}
				else if (keyOn[track] == 1 && playingSounds[track] == key) {	// 同じ音 (Same sound)
					// 今なっているのを歩かせ停止 (Stop playback now)
					mixer.getSound(allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]]).play(false);
					keyTwin[track]++;
					if (keyTwin[track] > 1) {
						keyTwin[track] = 0;
					}
					mixer.getSound(allocatedSounds[track][key / 12][keyTwin[track]]).play(true);
				}
				else {	// 違う音を鳴らすなら (If you make a different sound)
					mixer.getSound(allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]]).play(false);	// 今なっているのを歩かせ停止 (Stop playback now)
					keyTwin[track]++;
					if (keyTwin[track] > 1) {
						keyTwin[track] = 0;
					}
					changeOrganFrequency(key % 12, track, freq);	// 周波数を設定して (Set the frequency)
					mixer.getSound(allocatedSounds[track][key / 12][keyTwin[track]]).play(true);
					playingSounds[track] = key;
				}

				break;
			default: break;
		}
	}
	private void makeOrganyaWave(byte track, byte waveNumber, byte pipi) @safe {
		enforce(waveNumber <= 100, "Wave number out of range");

		makeSoundObject8(waveData[waveNumber], track, pipi);
	}
	/////////////////////////////////////////////
	//■オルガーニャドラムス■■■■■■■■/////// (Organya drums)
	/////////////////////

	private void changeDrumFrequency(ubyte key, byte track) @safe nothrow {
		mixer.getSound(secondaryAllocatedSounds[150 + track]).frequency = key * 800 + 100;
	}

	private void changeDrumPan(ubyte pan, byte track) @safe nothrow {
		mixer.getSound(secondaryAllocatedSounds[150 + track]).pan = (panTable[pan] - 0x100) * 10;
	}

	private void changeDrumVolume(int volume, byte track) @safe nothrow
	{
		mixer.getSound(secondaryAllocatedSounds[150 + track]).volume = cast(short)((volume - 0xFF) * 8);
	}

	// サウンドの再生 (Play sound)
	private void playDrumObject(ubyte key, int mode, byte track) @safe nothrow {
		switch (mode) {
			case 0:	// 停止 (Stop)
				mixer.getSound(secondaryAllocatedSounds[150 + track]).stop();
				mixer.getSound(secondaryAllocatedSounds[150 + track]).seek(0);
				break;

			case 1:	// 再生 (Playback)
				mixer.getSound(secondaryAllocatedSounds[150 + track]).stop();
				mixer.getSound(secondaryAllocatedSounds[150 + track]).seek(0);
				changeDrumFrequency(key, track);	// 周波数を設定して (Set the frequency)
				mixer.getSound(secondaryAllocatedSounds[150 + track]).play(false);
				break;

			case 2:	// 歩かせ停止 (Stop playback)
				break;

			case -1:
				break;
			default: break;
		}
	}
	public void changeVolume(int volume) @safe {
		enforce((volume >= 0) && (volume <= 100), "Volume out of range");

		globalVolume = volume;
	}

	public void stopMusic() @safe {
		setMusicTimer(0);

		// Stop notes
		for (int i = 0; i < maxMelody; i++) {
			playOrganObject(0, 2, cast(byte)i, 0);
		}

		playingSounds[] = 255;
		keyOn = keyOn.init;
		keyTwin = keyTwin.init;
	}

	public void setFadeout() @safe {
		fading = true;
	}

	public void fillBuffer(scope short[2][] finalBuffer) nothrow @safe {
		if (masterTimer == 0) {
			mixer.mixSounds(finalBuffer);
		} else {
			uint framesDone = 0;
			finalBuffer[] = [0, 0];

			while (framesDone != finalBuffer.length) {
				static ulong callbackTimer;

				if (callbackTimer == 0) {
					callbackTimer = masterTimer;
					playData();
				}

				const ulong framesToDo = min(callbackTimer, finalBuffer.length - framesDone);

				mixer.mixSounds(finalBuffer[framesDone .. framesDone + framesToDo]);

				framesDone += framesToDo;
				callbackTimer -= framesToDo;
			}
		}
	}
	public void loadData(const(ubyte)[] data) @safe {
		import std.file : read;
		pixtoneParameters = cast(const(PixtoneParameter)[])(data[0 .. ($ / PixtoneParameter.sizeof) * PixtoneParameter.sizeof]);
		int pixtoneSize = 0;
		pixtoneSize += makePixToneObject(pixtoneParameters[0 .. 2], 32);
		pixtoneSize += makePixToneObject(pixtoneParameters[2 .. 4], 33);
		pixtoneSize += makePixToneObject(pixtoneParameters[4 .. 6], 34);
		pixtoneSize += makePixToneObject(pixtoneParameters[6 .. 7], 15);
		pixtoneSize += makePixToneObject(pixtoneParameters[7 .. 8], 24);
		pixtoneSize += makePixToneObject(pixtoneParameters[8 .. 9], 23);
		pixtoneSize += makePixToneObject(pixtoneParameters[9 .. 11], 50);
		pixtoneSize += makePixToneObject(pixtoneParameters[11 .. 13], 51);
		pixtoneSize += makePixToneObject(pixtoneParameters[33 .. 34], 1);
		pixtoneSize += makePixToneObject(pixtoneParameters[38 .. 39], 2);
		pixtoneSize += makePixToneObject(pixtoneParameters[56 .. 57], 29);
		pixtoneSize += makePixToneObject(pixtoneParameters[61 .. 62], 43);
		pixtoneSize += makePixToneObject(pixtoneParameters[62 .. 65], 44);
		pixtoneSize += makePixToneObject(pixtoneParameters[65 .. 66], 45);
		pixtoneSize += makePixToneObject(pixtoneParameters[66 .. 67], 46);
		pixtoneSize += makePixToneObject(pixtoneParameters[68 .. 69], 47);
		pixtoneSize += makePixToneObject(pixtoneParameters[49 .. 52], 35);
		pixtoneSize += makePixToneObject(pixtoneParameters[52 .. 55], 39);
		pixtoneSize += makePixToneObject(pixtoneParameters[13 .. 15], 52);
		pixtoneSize += makePixToneObject(pixtoneParameters[28 .. 30], 53);
		pixtoneSize += makePixToneObject(pixtoneParameters[15 .. 17], 70);
		pixtoneSize += makePixToneObject(pixtoneParameters[17 .. 19], 71);
		pixtoneSize += makePixToneObject(pixtoneParameters[19 .. 21], 72);
		pixtoneSize += makePixToneObject(pixtoneParameters[30 .. 31], 5);
		pixtoneSize += makePixToneObject(pixtoneParameters[32 .. 33], 11);
		pixtoneSize += makePixToneObject(pixtoneParameters[35 .. 36], 4);
		pixtoneSize += makePixToneObject(pixtoneParameters[46 .. 48], 25);
		pixtoneSize += makePixToneObject(pixtoneParameters[48 .. 49], 27);
		pixtoneSize += makePixToneObject(pixtoneParameters[54 .. 56], 28);
		pixtoneSize += makePixToneObject(pixtoneParameters[39 .. 40], 14);
		pixtoneSize += makePixToneObject(pixtoneParameters[23 .. 25], 16);
		pixtoneSize += makePixToneObject(pixtoneParameters[25 .. 28], 17);
		pixtoneSize += makePixToneObject(pixtoneParameters[34 .. 35], 18);
		pixtoneSize += makePixToneObject(pixtoneParameters[36 .. 38], 20);
		pixtoneSize += makePixToneObject(pixtoneParameters[31 .. 32], 22);
		pixtoneSize += makePixToneObject(pixtoneParameters[41 .. 43], 26);
		pixtoneSize += makePixToneObject(pixtoneParameters[43 .. 44], 21);
		pixtoneSize += makePixToneObject(pixtoneParameters[44 .. 46], 12);
		pixtoneSize += makePixToneObject(pixtoneParameters[57 .. 59], 38);
		pixtoneSize += makePixToneObject(pixtoneParameters[59 .. 60], 31);
		pixtoneSize += makePixToneObject(pixtoneParameters[60 .. 61], 42);
		pixtoneSize += makePixToneObject(pixtoneParameters[69 .. 70], 48);
		pixtoneSize += makePixToneObject(pixtoneParameters[70 .. 72], 49);
		pixtoneSize += makePixToneObject(pixtoneParameters[72 .. 73], 100);
		pixtoneSize += makePixToneObject(pixtoneParameters[73 .. 76], 101);
		pixtoneSize += makePixToneObject(pixtoneParameters[76 .. 78], 54);
		pixtoneSize += makePixToneObject(pixtoneParameters[78 .. 80], 102);
		pixtoneSize += makePixToneObject(pixtoneParameters[80 .. 82], 103);
		pixtoneSize += makePixToneObject(pixtoneParameters[81 .. 82], 104);
		pixtoneSize += makePixToneObject(pixtoneParameters[82 .. 83], 105);
		pixtoneSize += makePixToneObject(pixtoneParameters[83 .. 85], 106);
		pixtoneSize += makePixToneObject(pixtoneParameters[85 .. 86], 107);
		pixtoneSize += makePixToneObject(pixtoneParameters[86 .. 87], 30);
		pixtoneSize += makePixToneObject(pixtoneParameters[87 .. 88], 108);
		pixtoneSize += makePixToneObject(pixtoneParameters[88 .. 89], 109);
		pixtoneSize += makePixToneObject(pixtoneParameters[89 .. 90], 110);
		pixtoneSize += makePixToneObject(pixtoneParameters[90 .. 91], 111);
		pixtoneSize += makePixToneObject(pixtoneParameters[91 .. 92], 112);
		pixtoneSize += makePixToneObject(pixtoneParameters[92 .. 93], 113);
		pixtoneSize += makePixToneObject(pixtoneParameters[93 .. 95], 114);
		pixtoneSize += makePixToneObject(pixtoneParameters[95 .. 97], 150);
		pixtoneSize += makePixToneObject(pixtoneParameters[97 .. 99], 151);
		pixtoneSize += makePixToneObject(pixtoneParameters[99 .. 100], 152);
		pixtoneSize += makePixToneObject(pixtoneParameters[100 .. 101], 153);
		pixtoneSize += makePixToneObject(pixtoneParameters[101 .. 103], 154);
		pixtoneSize += makePixToneObject(pixtoneParameters[111 .. 113], 155);
		pixtoneSize += makePixToneObject(pixtoneParameters[103 .. 105], 56);
		pixtoneSize += makePixToneObject(pixtoneParameters[105 .. 107], 40);
		pixtoneSize += makePixToneObject(pixtoneParameters[105 .. 107], 41);
		pixtoneSize += makePixToneObject(pixtoneParameters[107 .. 109], 37);
		pixtoneSize += makePixToneObject(pixtoneParameters[109 .. 111], 57);
		pixtoneSize += makePixToneObject(pixtoneParameters[113 .. 116], 115);
		pixtoneSize += makePixToneObject(pixtoneParameters[116 .. 117], 104);
		pixtoneSize += makePixToneObject(pixtoneParameters[117 .. 120], 116);
		pixtoneSize += makePixToneObject(pixtoneParameters[120 .. 122], 58);
		pixtoneSize += makePixToneObject(pixtoneParameters[122 .. 124], 55);
		pixtoneSize += makePixToneObject(pixtoneParameters[124 .. 126], 117);
		pixtoneSize += makePixToneObject(pixtoneParameters[126 .. 127], 59);
		pixtoneSize += makePixToneObject(pixtoneParameters[127 .. 128], 60);
		pixtoneSize += makePixToneObject(pixtoneParameters[128 .. 129], 61);
		pixtoneSize += makePixToneObject(pixtoneParameters[129 .. 131], 62);
		pixtoneSize += makePixToneObject(pixtoneParameters[131 .. 133], 63);
		pixtoneSize += makePixToneObject(pixtoneParameters[133 .. 135], 64);
		pixtoneSize += makePixToneObject(pixtoneParameters[135 .. 136], 65);
		pixtoneSize += makePixToneObject(pixtoneParameters[136 .. 137], 3);
		pixtoneSize += makePixToneObject(pixtoneParameters[137 .. 138], 6);
		pixtoneSize += makePixToneObject(pixtoneParameters[138 .. 139], 7);
	}
	void setMusicTimer(uint milliseconds) @safe {
		masterTimer = (milliseconds * outputFrequency) / 1000;
	}

	private int makePixToneObject(const(PixtoneParameter)[] ptp, int no) @safe {
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

		secondaryAllocatedSounds[no] = mixer.createSound(22050, mixedPCMBuffer[0 .. sampleCount]);

		return sampleCount;
	}
}

private immutable pass = "Org-01";
private immutable pass2 = "Org-02";	// Pipi
