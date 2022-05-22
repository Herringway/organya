module organya.organya;

import core.time;
import std.experimental.logger;
import std.algorithm.comparison;
import std.math;

import organya.pixtone;

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
	ubyte y;	// Sound height
	ubyte volume;	// Volume
	ubyte pan;
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
	private MixerSound*[2][8][8] allocatedSounds;
	package MixerSound*[512] secondaryAllocatedSounds;
	private MixerSound* activeSoundList;
	private MusicInfo info;
	private const(PIXTONEPARAMETER)[] pixtoneParameters;

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
	public void initialize(uint outputFrequency) @safe {
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

		if (!noteAlloc(info.allocatedNotes)) {
			error("Note allocation failed");
		}
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
	private bool noteAlloc(ushort alloc) @safe {
		int i,j;

		for (j = 0; j < maxTrack; j++) {
			info.trackData[j].waveNumber = 0;
			info.trackData[j].noteList = null;
			info.trackData[j].notePosition = new NoteList[](alloc);
			if (info.trackData[j].notePosition == null) {
				for (i = 0; i < maxTrack; i++) {
					if (info.trackData[i].notePosition != null) {
						info.trackData[i].notePosition = null;
					}
				}

				return false;
			}

			for (i = 0; i < alloc; i++) {
				info.trackData[j].notePosition[i].from = null;
				info.trackData[j].notePosition[i].to = null;
				info.trackData[j].notePosition[i].length = 0;
				info.trackData[j].notePosition[i].pan = panDummy;
				info.trackData[j].notePosition[i].volume = volDummy;
				info.trackData[j].notePosition[i].y = keyDummy;
			}
		}

		for (j = 0; j < maxMelody; j++) {
			makeOrganyaWave(cast(byte)j, info.trackData[j].waveNumber, info.trackData[j].pipi);
		}

		return true;
	}
	// NoteDataを開放 (Release NoteData)
	private void releaseNote() @safe {
		for (int i = 0; i < maxTrack; i++) {
			if (info.trackData[i].notePosition != null) {
				info.trackData[i].notePosition = null;
			}
		}
	}

	//// 以下は再生 (The following is playback)
	private void playData() @safe nothrow {
		int i;

		// Handle fading out
		if (fading && globalVolume) {
			globalVolume -= 2;
		}
		if (globalVolume < 0) {
			globalVolume = 0;
		}

		// メロディの再生 (Play melody)
		for (i = 0; i < maxMelody; i++) {
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
		for (i = maxMelody; i < maxTrack; i++) {
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
	public bool loadMusic(const(ubyte)[] p) @system
		in(p, "No organya data")
	{
		static ushort readLE16(ref const(ubyte)[] p) { scope(exit) p = p[2 .. $]; return ((p[1] << 8) | p[0]); }
		static uint readLE32(ref const(ubyte)[] p) { scope(exit) p = p[4 .. $]; return ((p[3] << 24) | (p[2] << 16) | (p[1] << 8) | p[0]); }

		NoteList *np;
		int i,j;
		char ver = 0;
		ushort[maxTrack] noteCounts;

		if (p == null) {
			return false;
		}

		if(p[0 .. 6] == pass) {
			ver = 1;
		}
		if(p[0 .. 6] == pass2) {
			ver = 2;
		}
		p = p[6 .. $];

		if(ver == 0) {
			return false;
		}

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
			np = &info.trackData[j].notePosition[0];
			info.trackData[j].noteList = &info.trackData[j].notePosition[0];
			assert(np);
			np.from = null;
			np.to = (np + 1);
			np++;

			for (i = 1; i < noteCounts[j]; i++) {
				np.from = (np - 1);
				np.to = (np + 1);
				np++;
			}

			// 最後の音符のtoはNULL (The last note to is NULL)
			np--;
			np.to = null;

			// 内容を代入 (Assign content)
			np = &info.trackData[j].notePosition[0];	// Ｘ座標 (X coordinate)
			for (i = 0; i < noteCounts[j]; i++) {
				np.x = readLE32(p);
				np++;
			}

			np = &info.trackData[j].notePosition[0];	// Ｙ座標 (Y coordinate)
			for (i = 0; i < noteCounts[j]; i++) {
				np.y = p[0];
				p = p[1 .. $];
				np++;
			}

			np = &info.trackData[j].notePosition[0];	// 長さ (Length)
			for (i = 0; i < noteCounts[j]; i++) {
				np.length = p[0];
				p = p[1 .. $];
				np++;
			}

			np = &info.trackData[j].notePosition[0];	// ボリューム (Volume)
			for (i = 0; i < noteCounts[j]; i++) {
				np.volume = p[0];
				p = p[1 .. $];
				np++;
			}

			np = &info.trackData[j].notePosition[0];	// パン (Pan)
			for (i = 0; i < noteCounts[j]; i++) {
				np.pan = p[0];
				p = p[1 .. $];
				np++;
			}
		}

		// データを有効に (Enable data)
		for (j = 0; j < maxMelody; j++) {
			makeOrganyaWave(cast(byte)j,info.trackData[j].waveNumber, info.trackData[j].pipi);
		}

		setPlayPointer(0);	// 頭出し (Cue)

		globalVolume = 100;
		fading = 0;
		return true;
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
	private bool makeSoundObject8(const byte[] wavep, byte track, byte pipi) @safe {
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

				if(wp == null)	{// j = se_no
					return false;
				}


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

				allocatedSounds[track][j][k] = createSound(22050, wp[0 .. dataSize]);

				if (allocatedSounds[track][j][k] == null) {
					return false;
				}

				allocatedSounds[track][j][k].seek(0);
			}
		}

		return true;
	}
	private void changeOrganFrequency(ubyte key, byte track, int a) @safe nothrow {
		for (int j = 0; j < 8; j++) {
			for (int i = 0; i < 2; i++) {
				allocatedSounds[track][j][i].frequency = cast(uint)(((octaveWaves[j].waveSize * frequencyTable[key]) * octaveWaves[j].octavePar) / 8 + (a - 1000));	// 1000を+αのデフォルト値とする (1000 is the default value for + α)
			}
		}
	}
	private void changeOrganPan(ubyte key, ubyte pan, byte track) @safe nothrow {	// 512がMAXで256がﾉｰﾏﾙ (512 is MAX and 256 is normal)
		if (playingSounds[track] != keyDummy) {
			allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]].pan = (panTable[pan] - 0x100) * 10;
		}
	}

	private void changeOrganVolume(int no, int volume, byte track) @safe nothrow {	// 300がMAXで300がﾉｰﾏﾙ (300 is MAX and 300 is normal)
		if (playingSounds[track] != keyDummy) {
			allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]].volume = cast(short)((volume - 0xFF) * 8);
		}
	}

	// サウンドの再生 (Play sound)
	private void playOrganObject(ubyte key, int mode, byte track, int freq) @safe nothrow {
		if (allocatedSounds[track][key / 12][keyTwin[track]] !is null) {
			switch (mode) {
				case 0:	// 停止 (Stop)
					if (playingSounds[track] != 0xFF) {
						allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]].stop();
						allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]].seek(0);
					}
					break;

				case 1: // 再生 (Playback)
					break;

				case 2:	// 歩かせ停止 (Stop playback)
					if (playingSounds[track] != 0xFF) {
						allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]].play(false);
						playingSounds[track] = 0xFF;
					}
					break;

				case -1:
					if (playingSounds[track] == 0xFF) {	// 新規鳴らす (New sound)
						changeOrganFrequency(key % 12, track, freq);	// 周波数を設定して (Set the frequency)
						allocatedSounds[track][key / 12][keyTwin[track]].play(true);
						playingSounds[track] = key;
						keyOn[track] = 1;
					}
					else if (keyOn[track] == 1 && playingSounds[track] == key) {	// 同じ音 (Same sound)
						// 今なっているのを歩かせ停止 (Stop playback now)
						allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]].play(false);
						keyTwin[track]++;
						if (keyTwin[track] > 1) {
							keyTwin[track] = 0;
						}
						allocatedSounds[track][key / 12][keyTwin[track]].play(true);
					}
					else {	// 違う音を鳴らすなら (If you make a different sound)
						allocatedSounds[track][playingSounds[track] / 12][keyTwin[track]].play(false);	// 今なっているのを歩かせ停止 (Stop playback now)
						keyTwin[track]++;
						if (keyTwin[track] > 1) {
							keyTwin[track] = 0;
						}
						changeOrganFrequency(key % 12, track, freq);	// 周波数を設定して (Set the frequency)
						allocatedSounds[track][key / 12][keyTwin[track]].play(true);
						playingSounds[track] = key;
					}

					break;
				default: break;
			}
		}
	}
	// オルガーニャオブジェクトを開放 (Open Organya object)
	private void releaseOrganyaObject(byte track) @safe {
		for (int i = 0; i < 8; i++) {
			if (allocatedSounds[track][i][0] !is null) {
				destroySound(*allocatedSounds[track][i][0]);
				allocatedSounds[track][i][0] = null;
			}
			if (allocatedSounds[track][i][1] !is null) {
				destroySound(*allocatedSounds[track][i][1]);
				allocatedSounds[track][i][1] = null;
			}
		}
	}
	// 波形を１００個の中から選択して作成 (Select from 100 waveforms to create)
	private bool makeOrganyaWave(byte track, byte waveNumber, byte pipi) @safe {
		if (waveNumber > 99) {
			return false;
		}

		releaseOrganyaObject(track);
		makeSoundObject8(waveData[waveNumber], track, pipi);

		return true;
	}
	/////////////////////////////////////////////
	//■オルガーニャドラムス■■■■■■■■/////// (Organya drums)
	/////////////////////

	private void changeDrumFrequency(ubyte key, byte track) @safe nothrow {
		secondaryAllocatedSounds[150 + track].frequency = key * 800 + 100;
	}

	private void changeDrumPan(ubyte pan, byte track) @safe nothrow {
		secondaryAllocatedSounds[150 + track].pan = (panTable[pan] - 0x100) * 10;
	}

	private void changeDrumVolume(int volume, byte track) @safe nothrow
	in(secondaryAllocatedSounds[150 + track] !is null)
	{
		secondaryAllocatedSounds[150 + track].volume = cast(short)((volume - 0xFF) * 8);
	}

	// サウンドの再生 (Play sound)
	private void playDrumObject(ubyte key, int mode, byte track) @safe nothrow {
		if (secondaryAllocatedSounds[150 + track] !is null) {
			switch (mode) {
				case 0:	// 停止 (Stop)
					secondaryAllocatedSounds[150 + track].stop();
					secondaryAllocatedSounds[150 + track].seek(0);
					break;

				case 1:	// 再生 (Playback)
					secondaryAllocatedSounds[150 + track].stop();
					secondaryAllocatedSounds[150 + track].seek(0);
					changeDrumFrequency(key, track);	// 周波数を設定して (Set the frequency)
					secondaryAllocatedSounds[150 + track].play(false);
					break;

				case 2:	// 歩かせ停止 (Stop playback)
					break;

				case -1:
					break;
				default: break;
			}
		}
	}
	public bool changeVolume(int volume) @safe {
		if (volume < 0 || volume > 100) {
			return false;
		}

		globalVolume = volume;
		return true;
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

	public void endOrganya() @safe {
		setMusicTimer(0);

		// Release everything related to org
		releaseNote();

		for (int i = 0; i < maxMelody; i++) {
			playOrganObject(0, 0, cast(byte)i, 0);
			releaseOrganyaObject(cast(byte)i);
		}
	}
	public void fillBuffer(scope short[] finalBuffer) nothrow @safe {
		int[0x800 * 2] buffer;
		int[] stream = buffer[0 .. finalBuffer.length];

		if (masterTimer == 0) {
			mixSounds(stream);
		} else {
			uint framesDone = 0;

			while (framesDone != stream.length / 2) {
				static ulong callbackTimer;

				if (callbackTimer == 0) {
					callbackTimer = masterTimer;
					playData();
				}

				const ulong framesToDo = min(callbackTimer, stream.length / 2 - framesDone);

				mixSounds(stream[framesDone * 2 .. framesDone * 2 + framesToDo * 2]);

				framesDone += framesToDo;
				callbackTimer -= framesToDo;
			}
		}
		for (size_t i = 0; i < finalBuffer.length; ++i) {
			finalBuffer[i] = cast(short)clamp(buffer[i], short.min, short.max);
		}
	}
	public void loadData(const(ubyte)[] data) @safe {
		import std.file : read;
		pixtoneParameters = cast(const(PIXTONEPARAMETER)[])(data[0 .. ($ / PIXTONEPARAMETER.sizeof) * PIXTONEPARAMETER.sizeof]);
		int pixtoneSize = 0;
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[0 .. 2], 32);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[2 .. 4], 33);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[4 .. 6], 34);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[6 .. 7], 15);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[7 .. 8], 24);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[8 .. 9], 23);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[9 .. 11], 50);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[11 .. 13], 51);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[33 .. 34], 1);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[38 .. 39], 2);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[56 .. 57], 29);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[61 .. 62], 43);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[62 .. 65], 44);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[65 .. 66], 45);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[66 .. 67], 46);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[68 .. 69], 47);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[49 .. 52], 35);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[52 .. 55], 39);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[13 .. 15], 52);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[28 .. 30], 53);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[15 .. 17], 70);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[17 .. 19], 71);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[19 .. 21], 72);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[30 .. 31], 5);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[32 .. 33], 11);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[35 .. 36], 4);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[46 .. 48], 25);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[48 .. 49], 27);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[54 .. 56], 28);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[39 .. 40], 14);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[23 .. 25], 16);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[25 .. 28], 17);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[34 .. 35], 18);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[36 .. 38], 20);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[31 .. 32], 22);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[41 .. 43], 26);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[43 .. 44], 21);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[44 .. 46], 12);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[57 .. 59], 38);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[59 .. 60], 31);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[60 .. 61], 42);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[69 .. 70], 48);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[70 .. 72], 49);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[72 .. 73], 100);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[73 .. 76], 101);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[76 .. 78], 54);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[78 .. 80], 102);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[80 .. 82], 103);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[81 .. 82], 104);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[82 .. 83], 105);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[83 .. 85], 106);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[85 .. 86], 107);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[86 .. 87], 30);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[87 .. 88], 108);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[88 .. 89], 109);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[89 .. 90], 110);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[90 .. 91], 111);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[91 .. 92], 112);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[92 .. 93], 113);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[93 .. 95], 114);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[95 .. 97], 150);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[97 .. 99], 151);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[99 .. 100], 152);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[100 .. 101], 153);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[101 .. 103], 154);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[111 .. 113], 155);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[103 .. 105], 56);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[105 .. 107], 40);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[105 .. 107], 41);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[107 .. 109], 37);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[109 .. 111], 57);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[113 .. 116], 115);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[116 .. 117], 104);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[117 .. 120], 116);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[120 .. 122], 58);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[122 .. 124], 55);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[124 .. 126], 117);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[126 .. 127], 59);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[127 .. 128], 60);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[128 .. 129], 61);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[129 .. 131], 62);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[131 .. 133], 63);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[133 .. 135], 64);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[135 .. 136], 65);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[136 .. 137], 3);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[137 .. 138], 6);
		pixtoneSize += MakePixToneObject(this, pixtoneParameters[138 .. 139], 7);
	}
	void setMusicTimer(uint milliseconds) @safe {
		masterTimer = (milliseconds * outputFrequency) / 1000;
	}
	MixerSound* createSound(uint frequency, const(ubyte)[] samples) @safe {
		MixerSound* sound = new MixerSound();

		sound.samples = new byte[](samples.length + 1);

		foreach (idx, ref sample; sound.samples[0 .. $ - 1]) {
			sample = samples[idx] - 0x80;
		}

		sound.playing = false;
		sound.position = 0;
		sound.positionSubsample = 0;

		sound.frequency = frequency;
		sound.volume = 0;
		sound.pan = 0;

		sound.next = activeSoundList;
		activeSoundList = sound;

		return sound;
	}

	void destroySound(ref MixerSound sound) @safe {
		for (MixerSound** soundPointer = &activeSoundList; *soundPointer != null; soundPointer = &(*soundPointer).next) {
			if (**soundPointer == sound) {
				*soundPointer = sound.next;
				break;
			}
		}
	}

	void mixSounds(scope int[] stream) @safe nothrow {
		for (MixerSound* sound = activeSoundList; sound != null; sound = sound.next) {
			if (sound.playing) {
				int[] streamPointer = stream;

				for (size_t framesDone = 0; framesDone < stream.length / 2; ++framesDone) {
					// Perform linear interpolation
					const ubyte interpolationScale = sound.positionSubsample >> 8;

					const byte outputSample = cast(byte)((sound.samples[sound.position] * (0x100 - interpolationScale)
									                                 + sound.samples[sound.position + 1] * interpolationScale) >> 8);

					// Mix, and apply volume

					streamPointer[0] += outputSample * sound.volumeL;
					streamPointer[1] += outputSample * sound.volumeR;
					streamPointer = streamPointer[2 .. $];

					// Increment sample
					const uint nextPositionSubsample = sound.positionSubsample + sound.advanceDelta / outputFrequency;
					sound.position += nextPositionSubsample >> 16;
					sound.positionSubsample = nextPositionSubsample & 0xFFFF;

					// Stop or loop sample once it's reached its end
					if (sound.position >= (sound.samples.length - 1)) {
						if (sound.looping) {
							sound.position %= sound.samples.length - 1;
						} else {
							sound.playing = false;
							sound.position = 0;
							sound.positionSubsample = 0;
							break;
						}
					}
				}
			}
		}
	}
}

private immutable pass = "Org-01";
private immutable pass2 = "Org-02";	// Pipi

struct MixerSound {
	private byte[] samples;
	private size_t position;
	private ushort positionSubsample;
	private uint advanceDelta;
	private bool playing;
	private bool looping;
	private short volumeShared;
	private short panL;
	private short panR;
	private short volumeL;
	private short volumeR;

	MixerSound* next;
	void pan(int val) @safe nothrow {
		panL = millibelToScale(-val);
		panR = millibelToScale(val);

		volumeL = cast(short)((panL * volumeShared) >> 8);
		volumeR = cast(short)((panR * volumeShared) >> 8);
	}
	void volume(short val) @safe nothrow {
		volumeShared = millibelToScale(val);

		volumeL = cast(short)((panL * volumeShared) >> 8);
		volumeR = cast(short)((panR * volumeShared) >> 8);
	}
	void frequency(uint val) @safe nothrow {
		advanceDelta = val << 16;
	}
	void play(bool loop) @safe nothrow {
		playing = true;
		looping = loop;

		samples[$ - 1] = loop ? samples[0] : 0;
	}
	void stop() @safe nothrow {
		playing = false;
	}
	void seek(size_t position) @safe nothrow {
		this.position = position;
		positionSubsample = 0;
	}
}

private ushort millibelToScale(int volume) @safe pure @nogc nothrow {
	// Volume is in hundredths of a decibel, from 0 to -10000
	volume = clamp(volume, -10000, 0);
	return cast(ushort)(pow(10.0, volume / 2000.0) * 256.0);
}
