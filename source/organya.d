module organya;

import core.time;
import std.experimental.logger;
import std.algorithm.comparison;

import pixtone;
import smixer;

enum MAXTRACK = 16;
enum MAXMELODY = 8;
enum MAXDRAM = 8;


enum PANDUMMY = 0xFF;
enum VOLDUMMY = 0xFF;
enum KEYDUMMY = 0xFF;

enum ALLOCNOTE = 4096;

enum DEFVOLUME = 200;//255はVOLDUMMY。MAXは254
enum DEFPAN = 6;

//曲情報をセットする時のフラグ
enum SETALL = 0xffffffff;//全てをセット
enum SETWAIT = 0x00000001;
enum SETGRID = 0x00000002;
enum SETALLOC = 0x00000004;
enum SETREPEAT = 0x00000008;
enum SETFREQ = 0x00000010;
enum SETWAVE = 0x00000020;
enum SETPIPI = 0x00000040;

// Below are Organya song data structures
struct NOTELIST {
	NOTELIST *from;	// Previous address
	NOTELIST *to;	// Next address

	int x;	// Position
	ubyte length_;	// Sound length
	ubyte y;	// Sound height
	ubyte volume;	// Volume
	ubyte pan;
}

// Track data * 8
struct TRACKDATA {
	ushort freq;	// Frequency (1000 is default)
	ubyte wave_no;	// Waveform No.
	byte pipi;

	NOTELIST *note_p;
	NOTELIST *note_list;
}

// Unique information held in songs
struct MUSICINFO {
	ushort wait;
	ubyte line;	// Number of lines in one measure
	ubyte dot;	// Number of dots per line
	ushort alloc_note;	// Number of allocated notes
	int repeat_x;	// Repeat
	int end_x;	// End of song (Return to repeat)
	TRACKDATA[MAXTRACK] tdata;
}


/////////////////////////////////////////////
//■オルガーニャ■■■■■■■■■■■■/////// (Organya)
/////////////////////

// Wave playing and loading
struct OCTWAVE {
	short wave_size;
	short oct_par;
	short oct_size;
}

immutable OCTWAVE[8] oct_wave = [
	{ 256,  1,  4 }, // 0 Oct
	{ 256,  2,  8 }, // 1 Oct
	{ 128,  4, 12 }, // 2 Oct
	{ 128,  8, 16 }, // 3 Oct
	{  64, 16, 20 }, // 4 Oct
	{  32, 32, 24 }, // 5 Oct
	{  16, 64, 28 }, // 6 Oct
	{   8,128, 32 }, // 7 Oct
];


immutable short[12] freq_tbl = [262, 277, 294, 311, 330, 349, 370, 392, 415, 440, 466, 494];

immutable short[13] pan_tbl = [0, 43, 86, 129, 172, 215, 256, 297, 340, 383, 426, 469, 512];


// 波形データをロード (Load waveform data)
immutable byte[0x100][100] wave_data = initWaveData(wave100);

byte[0x100][100] initWaveData(const(ubyte)[] wavedata) @safe {
	byte[0x100][100] result;
	foreach (x1, ref x2; result) {
		foreach (idx, ref y; x2) {
			y = cast(byte)wavedata[x1 * 0x100 + idx];
		}
	}
	return result;
}

immutable ubyte[] wave100 = cast(immutable(ubyte)[])import("Wave.dat");

struct Organya {
	Mixer_Sound*[2][8][8] lpORGANBUFFER;
	Mixer_Sound*[512] lpSECONDARYBUFFER;
	SoftwareMixer backend;
	MUSICINFO info;
	char track;
	char[MAXTRACK] mute;
	ubyte def_pan;
	ubyte def_volume;
	uint ExactTime = 13;	// 最小精度 (Minimum accuracy)
	uint TimerID;
	bool bTimer;

	// Play data
	int PlayPos;	// Called 'play_p' in the source code release
	NOTELIST*[MAXTRACK] np;
	int[MAXMELODY] now_leng;

	int Volume = 100;
	int[MAXTRACK] TrackVol;
	bool bFadeout = false;
	bool[MAXTRACK] g_mute;	// Used by the debug Mute menu
	ubyte[MAXTRACK] old_key = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];	// 再生中の音 (Sound being played)
	ubyte[MAXTRACK] key_on;	// キースイッチ (Key switch)
	ubyte[MAXTRACK] key_twin;	// 今使っているキー(連続時のノイズ防止の為に二つ用意) (Currently used keys (prepared for continuous noise prevention))
	void InitOrgData() {
		track = 0;
		info.alloc_note = ALLOCNOTE;	// とりあえず10000個確保 (For the time being, secure 10,000 pieces)
		info.dot = 4;
		info.line = 4;
		info.wait = 128;
		info.repeat_x = info.dot * info.line * 0;
		info.end_x = info.dot * info.line * 255;

		for (int i = 0; i < MAXTRACK; i++) {
			info.tdata[i].freq = 1000;
			info.tdata[i].wave_no = 0;
			info.tdata[i].pipi = 0;
		}

		if (!NoteAlloc(info.alloc_note)) {
			error("Note allocation failed");
		}
		SetMusicInfo(&info, SETALL);

		def_pan = DEFPAN;
		def_volume = DEFVOLUME;
	}
	// 曲情報を取得 (Get song information)
	void GetMusicInfo(MUSICINFO *mi) @safe {
		mi.dot = info.dot;
		mi.line = info.line;
		mi.alloc_note = info.alloc_note;
		mi.wait = info.wait;
		mi.repeat_x = info.repeat_x;
		mi.end_x = info.end_x;

		for (int i = 0; i < MAXTRACK; i++) {
			mi.tdata[i].freq = info.tdata[i].freq;
			mi.tdata[i].wave_no = info.tdata[i].wave_no;
			mi.tdata[i].pipi = info.tdata[i].pipi;
		}
	}
	// 曲情報を設定。flagはアイテムを指定 (Set song information. flag specifies an item)
	bool SetMusicInfo(MUSICINFO* mi, uint flag) @safe {
		int i;

		if (flag.testFlagSet(SETGRID)) {	// グリッドを有効に (Enable grid)
			info.dot = mi.dot;
			info.line = mi.line;
		}

		if (flag.testFlagSet(SETWAIT)) {
			info.wait = mi.wait;
		}

		if (flag.testFlagSet(SETREPEAT)) {
			info.repeat_x = mi.repeat_x;
			info.end_x = mi.end_x;
		}

		if (flag.testFlagSet(SETFREQ)) {
			for (i = 0; i < MAXMELODY; i++) {
				info.tdata[i].freq = mi.tdata[i].freq;
				info.tdata[i].pipi = info.tdata[i].pipi;	 // Just sets info.tdata[i].pipi to itself (SETPIPI already sets pipi, so maybe this line shouldn't be here in the first place)
			}
		}

		if (flag.testFlagSet(SETWAVE))
			for (i = 0; i < MAXTRACK; i++)
				info.tdata[i].wave_no = mi.tdata[i].wave_no;

		if (flag.testFlagSet(SETPIPI))
			for (i = 0; i < MAXTRACK; i++)
				info.tdata[i].pipi = mi.tdata[i].pipi;

		return true;
	}
	// 指定の数だけNoteDataの領域を確保(初期化) (Allocate the specified number of NoteData areas (initialization))
	bool NoteAlloc(ushort alloc) {
		int i,j;

		for (j = 0; j < MAXTRACK; j++) {
			info.tdata[j].wave_no = 0;
			info.tdata[j].note_list = null;	// コンストラクタにやらせたい (I want the constructor to do it)
			info.tdata[j].note_p = new NOTELIST[](alloc).ptr;
			assert(info.tdata[j].note_p);
			if (info.tdata[j].note_p == null) {
				for (i = 0; i < MAXTRACK; i++) {
					if (info.tdata[i].note_p != null) {
						info.tdata[i].note_p = null;
					}
				}

				return false;
			}

			for (i = 0; i < alloc; i++) {
				(info.tdata[j].note_p + i).from = null;
				(info.tdata[j].note_p + i).to = null;
				(info.tdata[j].note_p + i).length_ = 0;
				(info.tdata[j].note_p + i).pan = PANDUMMY;
				(info.tdata[j].note_p + i).volume = VOLDUMMY;
				(info.tdata[j].note_p + i).y = KEYDUMMY;
			}
		}

		for (j = 0; j < MAXMELODY; j++)
			MakeOrganyaWave(cast(byte)j, info.tdata[j].wave_no, info.tdata[j].pipi);

		track = 0;	// 今はここに書いておく (Write here now)

		return true;
	}
	// NoteDataを開放 (Release NoteData)
	void ReleaseNote() {
		for (int i = 0; i < MAXTRACK; i++) {
			if (info.tdata[i].note_p != null) {
				info.tdata[i].note_p = null;
			}
		}
	}

	//// 以下は再生 (The following is playback)
	void PlayData() @safe nothrow {
		int i;

		// Handle fading out
		if (bFadeout && Volume)
			Volume -= 2;
		if (Volume < 0)
			Volume = 0;

		// メロディの再生 (Play melody)
		for (i = 0; i < MAXMELODY; i++) {
			if (np[i] != null && PlayPos == np[i].x) {
				if (!g_mute[i] && np[i].y != KEYDUMMY) {	// 音が来た。 (The sound has come.)
					PlayOrganObject(np[i].y, -1, cast(byte)i, info.tdata[i].freq);
					now_leng[i] = np[i].length_;
				}

				if (np[i].pan != PANDUMMY)
					ChangeOrganPan(np[i].y, np[i].pan, cast(byte)i);
				if (np[i].volume != VOLDUMMY)
					TrackVol[i] = np[i].volume;

				np[i] = np[i].to;	// 次の音符を指す (Points to the next note)
			}

			if (now_leng[i] == 0)
				PlayOrganObject(0, 2, cast(byte)i, info.tdata[i].freq);

			if (now_leng[i] > 0)
				now_leng[i]--;

			if (np[i])
				ChangeOrganVolume(np[i].y, TrackVol[i] * Volume / 0x7F, cast(byte)i);
		}

		// ドラムの再生 (Drum playback)
		for (i = MAXMELODY; i < MAXTRACK; i++) {
			if (np[i] != null && PlayPos == np[i].x) {	// 音が来た。 (The sound has come.)
				if (np[i].y != KEYDUMMY && !g_mute[i])	// ならす (Tame)
					PlayDramObject(np[i].y, 1, cast(byte)(i - MAXMELODY));

				if (np[i].pan != PANDUMMY)
					ChangeDramPan(np[i].pan, cast(byte)(i - MAXMELODY));
				if (np[i].volume != VOLDUMMY)
					TrackVol[i] = np[i].volume;

				np[i] = np[i].to;	// 次の音符を指す (Points to the next note)
			}

			if (np[i])
				ChangeDramVolume(TrackVol[i] * Volume / 0x7F, cast(byte)(i - MAXMELODY));
		}

		// Looping
		PlayPos++;
		if (PlayPos >= info.end_x) {
			PlayPos = info.repeat_x;
			SetPlayPointer(PlayPos);
		}
	}

	void SetPlayPointer(int x) @safe nothrow {
		for (int i = 0; i < MAXTRACK; i++) {
			np[i] = info.tdata[i].note_list;
			while (np[i] != null && np[i].x < x)
				np[i] = np[i].to;	// 見るべき音符を設定 (Set note to watch)
		}

		PlayPos = x;
	}
	//// 以下はファイル関係 (The following are related to files)
	bool InitMusicData(const(ubyte)[] p) {
		static ushort READ_LE16(ref const(ubyte)[] p) { scope(exit) p = p[2 .. $]; return ((p[1] << 8) | p[0]); }
		static uint READ_LE32(ref const(ubyte)[] p) { scope(exit) p = p[4 .. $]; return ((p[3] << 24) | (p[2] << 16) | (p[1] << 8) | p[0]); }

		NOTELIST *np;
		int i,j;
		char[6] pass_check;
		char ver = 0;
		ushort[MAXTRACK] note_num;

		if (p == null)
			return false;

		if(p[0 .. 6] == pass)
			ver = 1;
		if(p[0 .. 6] == pass2)
			ver = 2;
		p = p[6 .. $];

		if(ver == 0)
			return false;

		// 曲の情報を設定 (Set song information)
		info.wait = READ_LE16(p);
		info.line = p[0];
		p = p[1 .. $];
		info.dot = p[0];
		p = p[1 .. $];
		info.repeat_x = READ_LE32(p);
		info.end_x = READ_LE32(p);

		for (i = 0; i < MAXTRACK; i++) {
			info.tdata[i].freq = READ_LE16(p);

			info.tdata[i].wave_no = p[0];
			p = p[1 .. $];

			if (ver == 1)
				info.tdata[i].pipi = 0;
			else
				info.tdata[i].pipi = p[0];

			p = p[1 .. $];

			note_num[i] = READ_LE16(p);
		}

		// 音符のロード (Loading notes)
		for (j = 0; j < MAXTRACK; j++) {
			// 最初の音符はfromがNULLとなる (The first note has from as NULL)
			if (note_num[j] == 0) {
				info.tdata[j].note_list = null;
				continue;
			}

			// リストを作る (Make a list)
			np = cast(NOTELIST*)info.tdata[j].note_p;
			info.tdata[j].note_list = info.tdata[j].note_p;
			assert(np);
			np.from = null;
			np.to = (np + 1);
			np++;

			for (i = 1; i < note_num[j]; i++) {
				np.from = (np - 1);
				np.to = (np + 1);
				np++;
			}

			// 最後の音符のtoはNULL (The last note to is NULL)
			np--;
			np.to = null;

			// 内容を代入 (Assign content)
			np = cast(NOTELIST*)info.tdata[j].note_p;	// Ｘ座標 (X coordinate)
			for (i = 0; i < note_num[j]; i++) {
				np.x = READ_LE32(p);
				np++;
			}

			np = cast(NOTELIST*)info.tdata[j].note_p;	// Ｙ座標 (Y coordinate)
			for (i = 0; i < note_num[j]; i++) {
				np.y = p[0];
				p = p[1 .. $];
				np++;
			}

			np = cast(NOTELIST*)info.tdata[j].note_p;	// 長さ (Length)
			for (i = 0; i < note_num[j]; i++) {
				np.length_ = p[0];
				p = p[1 .. $];
				np++;
			}

			np = cast(NOTELIST*)info.tdata[j].note_p;	// ボリューム (Volume)
			for (i = 0; i < note_num[j]; i++) {
				np.volume = p[0];
				p = p[1 .. $];
				np++;
			}

			np = cast(NOTELIST*)info.tdata[j].note_p;	// パン (Pan)
			for (i = 0; i < note_num[j]; i++) {
				np.pan = p[0];
				p = p[1 .. $];
				np++;
			}
		}

		// データを有効に (Enable data)
		for (j = 0; j < MAXMELODY; j++)
			MakeOrganyaWave(cast(byte)j,info.tdata[j].wave_no, info.tdata[j].pipi);

		// Pixel ripped out some code so he could use PixTone sounds as drums, but he left this dead code
		for (j = MAXMELODY; j < MAXTRACK; j++) {
			i = info.tdata[j].wave_no;
			//InitDramObject(dram_name[i], j - MAXMELODY);
		}

		SetPlayPointer(0);	// 頭出し (Cue)

		return true;
	}
	// Start and end organya
	void initialize() @trusted {
		InitOrgData();

		backend.setMusicCallback(&OrganyaCallback);
	}
	// Load organya file
	bool LoadOrganya(const(ubyte)[] data) @trusted
		in(data, "No organya data")
	{
		if (!InitMusicData(data))
			return false;

		Volume = 100;
		bFadeout = 0;

		return true;
	}
	void SetOrganyaPosition(uint x) @trusted {
		SetPlayPointer(x);
		Volume = 100;
		bFadeout = false;
	}

	uint GetOrganyaPosition() @trusted {
		return PlayPos;
	}

	void PlayOrganyaMusic() @trusted {
		backend.setMusicTimer(info.wait);
	}
	bool MakeSoundObject8(const byte[] wavep, byte track, byte pipi) @safe {
		uint i,j,k;
		uint wav_tp;	// WAVテーブルをさすポインタ (Pointer to WAV table)
		uint wave_size;	// 256;
		uint data_size;
		ubyte[] wp;
		ubyte[] wp_sub;
		int work;

		for (j = 0; j < 8; j++) {
			for (k = 0; k < 2; k++) {
				wave_size = oct_wave[j].wave_size;

				if (pipi)
					data_size = wave_size * oct_wave[j].oct_size;
				else
					data_size = wave_size;

				wp = new ubyte[](data_size);

				if(wp == null)	// j = se_no
					return false;


				// Get wave data
				wp_sub = wp;
				wav_tp = 0;

				for (i = 0; i < data_size; i++) {
					work = wavep[wav_tp];
					work += 0x80;

					wp_sub[0] = cast(ubyte)work;

					wav_tp += 0x100 / wave_size;
					if (wav_tp > 0xFF)
						wav_tp -= 0x100;

					wp_sub = wp_sub[1 .. $];
				}

				lpORGANBUFFER[track][j][k] = backend.createSound(22050, wp[0 .. data_size]);

				if (lpORGANBUFFER[track][j][k] == null) {
					return false;
				}

				backend.seek(*lpORGANBUFFER[track][j][k], 0);
			}
		}

		return true;
	}
	void ChangeOrganFrequency(ubyte key, byte track, int a) @safe nothrow {
		for (int j = 0; j < 8; j++)
			for (int i = 0; i < 2; i++)
				backend.setFrequency(*lpORGANBUFFER[track][j][i], cast(uint)(((oct_wave[j].wave_size * freq_tbl[key]) * oct_wave[j].oct_par) / 8 + (a - 1000)));	// 1000を+αのデフォルト値とする (1000 is the default value for + α)
	}
	void ChangeOrganPan(ubyte key, ubyte pan, byte track) @safe nothrow {	// 512がMAXで256がﾉｰﾏﾙ (512 is MAX and 256 is normal)
		if (old_key[track] != KEYDUMMY)
			backend.setPan(*lpORGANBUFFER[track][old_key[track] / 12][key_twin[track]], (pan_tbl[pan] - 0x100) * 10);
	}

	void ChangeOrganVolume(int no, int volume, byte track) @safe nothrow {	// 300がMAXで300がﾉｰﾏﾙ (300 is MAX and 300 is normal)
		if (old_key[track] != KEYDUMMY)
			backend.setVolume(*lpORGANBUFFER[track][old_key[track] / 12][key_twin[track]], cast(int)((volume - 0xFF) * 8));
	}

	// サウンドの再生 (Play sound)
	void PlayOrganObject(ubyte key, int mode, byte track, int freq) @safe nothrow {
		if (lpORGANBUFFER[track][key / 12][key_twin[track]] !is null) {
			switch (mode) {
				case 0:	// 停止 (Stop)
					if (old_key[track] != 0xFF) {
						backend.stop(*lpORGANBUFFER[track][old_key[track] / 12][key_twin[track]]);
						backend.seek(*lpORGANBUFFER[track][old_key[track] / 12][key_twin[track]], 0);
					}
					break;

				case 1: // 再生 (Playback)
					break;

				case 2:	// 歩かせ停止 (Stop playback)
					if (old_key[track] != 0xFF) {
						backend.play(*lpORGANBUFFER[track][old_key[track] / 12][key_twin[track]], SoundPlayFlags.normal);
						old_key[track] = 0xFF;
					}
					break;

				case -1:
					if (old_key[track] == 0xFF) {	// 新規鳴らす (New sound)
						ChangeOrganFrequency(key % 12, track, freq);	// 周波数を設定して (Set the frequency)
						backend.play(*lpORGANBUFFER[track][key / 12][key_twin[track]], SoundPlayFlags.looping);
						old_key[track] = key;
						key_on[track] = 1;
					}
					else if (key_on[track] == 1 && old_key[track] == key) {	// 同じ音 (Same sound)
						// 今なっているのを歩かせ停止 (Stop playback now)
						backend.play(*lpORGANBUFFER[track][old_key[track] / 12][key_twin[track]], SoundPlayFlags.normal);
						key_twin[track]++;
						if (key_twin[track] > 1)
							key_twin[track] = 0;
						backend.play(*lpORGANBUFFER[track][key / 12][key_twin[track]], SoundPlayFlags.looping);
					}
					else {	// 違う音を鳴らすなら (If you make a different sound)
						backend.play(*lpORGANBUFFER[track][old_key[track] / 12][key_twin[track]], SoundPlayFlags.normal);	// 今なっているのを歩かせ停止 (Stop playback now)
						key_twin[track]++;
						if (key_twin[track] > 1)
							key_twin[track] = 0;
						ChangeOrganFrequency(key % 12, track, freq);	// 周波数を設定して (Set the frequency)
						backend.play(*lpORGANBUFFER[track][key / 12][key_twin[track]], SoundPlayFlags.looping);
						old_key[track] = key;
					}

					break;
				default: break;
			}
		}
	}
	private void OrganyaCallback() @safe nothrow {
		PlayData();
	}
	// オルガーニャオブジェクトを開放 (Open Organya object)
	void ReleaseOrganyaObject(byte track) @safe {
		for (int i = 0; i < 8; i++) {
			if (lpORGANBUFFER[track][i][0] !is null) {
				backend.destroySound(*lpORGANBUFFER[track][i][0]);
				lpORGANBUFFER[track][i][0] = null;
			}
			if (lpORGANBUFFER[track][i][1] !is null) {
				backend.destroySound(*lpORGANBUFFER[track][i][1]);
				lpORGANBUFFER[track][i][1] = null;
			}
		}
	}
	// 波形を１００個の中から選択して作成 (Select from 100 waveforms to create)
	bool MakeOrganyaWave(byte track, byte wave_no, byte pipi) @safe {
		if (wave_no > 99)
			return false;

		ReleaseOrganyaObject(track);
		MakeSoundObject8(wave_data[wave_no], track, pipi);

		return true;
	}
	/////////////////////////////////////////////
	//■オルガーニャドラムス■■■■■■■■/////// (Organya drums)
	/////////////////////

	void ChangeDramFrequency(ubyte key, byte track) @safe nothrow {
		backend.setFrequency(*lpSECONDARYBUFFER[150 + track], key * 800 + 100);
	}

	void ChangeDramPan(ubyte pan, byte track) @safe nothrow {
		backend.setPan(*lpSECONDARYBUFFER[150 + track], (pan_tbl[pan] - 0x100) * 10);
	}

	void ChangeDramVolume(int volume, byte track) @safe nothrow
	in(lpSECONDARYBUFFER[150 + track] !is null)
	{
		backend.setVolume(*lpSECONDARYBUFFER[150 + track], cast(int)((volume - 0xFF) * 8));
	}

	// サウンドの再生 (Play sound)
	void PlayDramObject(ubyte key, int mode, byte track) @safe nothrow {
		if (lpSECONDARYBUFFER[150 + track] !is null) {
			switch (mode) {
				case 0:	// 停止 (Stop)
					backend.stop(*lpSECONDARYBUFFER[150 + track]);
					backend.seek(*lpSECONDARYBUFFER[150 + track], 0);
					break;

				case 1:	// 再生 (Playback)
					backend.stop(*lpSECONDARYBUFFER[150 + track]);
					backend.seek(*lpSECONDARYBUFFER[150 + track], 0);
					ChangeDramFrequency(key, track);	// 周波数を設定して (Set the frequency)
					backend.play(*lpSECONDARYBUFFER[150 + track], SoundPlayFlags.normal);
					break;

				case 2:	// 歩かせ停止 (Stop playback)
					break;

				case -1:
					break;
				default: break;
			}
		}
	}
	bool ChangeOrganyaVolume(int volume) @trusted {
		if (volume < 0 || volume > 100)
			return false;

		Volume = volume;
		return true;
	}

	void StopOrganyaMusic() @trusted {
		backend.setMusicTimer(0);

		// Stop notes
		for (int i = 0; i < MAXMELODY; i++)
			PlayOrganObject(0, 2, cast(byte)i, 0);

		old_key[] = 255;
		key_on = key_on.init;
		key_twin = key_twin.init;
	}

	void SetOrganyaFadeout() @trusted {
		bFadeout = true;
	}

	void EndOrganya() @trusted {
		backend.setMusicTimer(0);

		// Release everything related to org
		ReleaseNote();

		for (int i = 0; i < MAXMELODY; i++) {
			PlayOrganObject(0, 0, cast(byte)i, 0);
			ReleaseOrganyaObject(cast(byte)i);
		}
	}
	void fillBuffer(scope short[] finalBuffer) nothrow @safe {
		int[0x800 * 2] buffer;
		backend.mixSoundsAndUpdateMusic(buffer[0 .. finalBuffer.length]);
		for (size_t i = 0; i < finalBuffer.length; ++i) {
			finalBuffer[i] = cast(short)clamp(buffer[i], short.min, short.max);
		}
	}
}

immutable pass = "Org-01";
immutable pass2 = "Org-02";	// Pipi

bool testFlagSet(T)(const T val, T flag) {
	return !!(val & flag);
}


__gshared const(PIXTONEPARAMETER)[] gPtpTable;
void loadData(ref Organya organya) {
	import std.file : read;
	gPtpTable = cast(PIXTONEPARAMETER[])(read("pixtone.tbl")[0 .. ($ / PIXTONEPARAMETER.sizeof) * PIXTONEPARAMETER.sizeof]);
	int pt_size = 0;
	pt_size += MakePixToneObject(organya, gPtpTable[0 .. 2], 32);
	pt_size += MakePixToneObject(organya, gPtpTable[2 .. 4], 33);
	pt_size += MakePixToneObject(organya, gPtpTable[4 .. 6], 34);
	pt_size += MakePixToneObject(organya, gPtpTable[6 .. 7], 15);
	pt_size += MakePixToneObject(organya, gPtpTable[7 .. 8], 24);
	pt_size += MakePixToneObject(organya, gPtpTable[8 .. 9], 23);
	pt_size += MakePixToneObject(organya, gPtpTable[9 .. 11], 50);
	pt_size += MakePixToneObject(organya, gPtpTable[11 .. 13], 51);
	pt_size += MakePixToneObject(organya, gPtpTable[33 .. 34], 1);
	pt_size += MakePixToneObject(organya, gPtpTable[38 .. 39], 2);
	pt_size += MakePixToneObject(organya, gPtpTable[56 .. 57], 29);
	pt_size += MakePixToneObject(organya, gPtpTable[61 .. 62], 43);
	pt_size += MakePixToneObject(organya, gPtpTable[62 .. 65], 44);
	pt_size += MakePixToneObject(organya, gPtpTable[65 .. 66], 45);
	pt_size += MakePixToneObject(organya, gPtpTable[66 .. 67], 46);
	pt_size += MakePixToneObject(organya, gPtpTable[68 .. 69], 47);
	pt_size += MakePixToneObject(organya, gPtpTable[49 .. 52], 35);
	pt_size += MakePixToneObject(organya, gPtpTable[52 .. 55], 39);
	pt_size += MakePixToneObject(organya, gPtpTable[13 .. 15], 52);
	pt_size += MakePixToneObject(organya, gPtpTable[28 .. 30], 53);
	pt_size += MakePixToneObject(organya, gPtpTable[15 .. 17], 70);
	pt_size += MakePixToneObject(organya, gPtpTable[17 .. 19], 71);
	pt_size += MakePixToneObject(organya, gPtpTable[19 .. 21], 72);
	pt_size += MakePixToneObject(organya, gPtpTable[30 .. 31], 5);
	pt_size += MakePixToneObject(organya, gPtpTable[32 .. 33], 11);
	pt_size += MakePixToneObject(organya, gPtpTable[35 .. 36], 4);
	pt_size += MakePixToneObject(organya, gPtpTable[46 .. 48], 25);
	pt_size += MakePixToneObject(organya, gPtpTable[48 .. 49], 27);
	pt_size += MakePixToneObject(organya, gPtpTable[54 .. 56], 28);
	pt_size += MakePixToneObject(organya, gPtpTable[39 .. 40], 14);
	pt_size += MakePixToneObject(organya, gPtpTable[23 .. 25], 16);
	pt_size += MakePixToneObject(organya, gPtpTable[25 .. 28], 17);
	pt_size += MakePixToneObject(organya, gPtpTable[34 .. 35], 18);
	pt_size += MakePixToneObject(organya, gPtpTable[36 .. 38], 20);
	pt_size += MakePixToneObject(organya, gPtpTable[31 .. 32], 22);
	pt_size += MakePixToneObject(organya, gPtpTable[41 .. 43], 26);
	pt_size += MakePixToneObject(organya, gPtpTable[43 .. 44], 21);
	pt_size += MakePixToneObject(organya, gPtpTable[44 .. 46], 12);
	pt_size += MakePixToneObject(organya, gPtpTable[57 .. 59], 38);
	pt_size += MakePixToneObject(organya, gPtpTable[59 .. 60], 31);
	pt_size += MakePixToneObject(organya, gPtpTable[60 .. 61], 42);
	pt_size += MakePixToneObject(organya, gPtpTable[69 .. 70], 48);
	pt_size += MakePixToneObject(organya, gPtpTable[70 .. 72], 49);
	pt_size += MakePixToneObject(organya, gPtpTable[72 .. 73], 100);
	pt_size += MakePixToneObject(organya, gPtpTable[73 .. 76], 101);
	pt_size += MakePixToneObject(organya, gPtpTable[76 .. 78], 54);
	pt_size += MakePixToneObject(organya, gPtpTable[78 .. 80], 102);
	pt_size += MakePixToneObject(organya, gPtpTable[80 .. 82], 103);
	pt_size += MakePixToneObject(organya, gPtpTable[81 .. 82], 104);
	pt_size += MakePixToneObject(organya, gPtpTable[82 .. 83], 105);
	pt_size += MakePixToneObject(organya, gPtpTable[83 .. 85], 106);
	pt_size += MakePixToneObject(organya, gPtpTable[85 .. 86], 107);
	pt_size += MakePixToneObject(organya, gPtpTable[86 .. 87], 30);
	pt_size += MakePixToneObject(organya, gPtpTable[87 .. 88], 108);
	pt_size += MakePixToneObject(organya, gPtpTable[88 .. 89], 109);
	pt_size += MakePixToneObject(organya, gPtpTable[89 .. 90], 110);
	pt_size += MakePixToneObject(organya, gPtpTable[90 .. 91], 111);
	pt_size += MakePixToneObject(organya, gPtpTable[91 .. 92], 112);
	pt_size += MakePixToneObject(organya, gPtpTable[92 .. 93], 113);
	pt_size += MakePixToneObject(organya, gPtpTable[93 .. 95], 114);
	pt_size += MakePixToneObject(organya, gPtpTable[95 .. 97], 150);
	pt_size += MakePixToneObject(organya, gPtpTable[97 .. 99], 151);
	pt_size += MakePixToneObject(organya, gPtpTable[99 .. 100], 152);
	pt_size += MakePixToneObject(organya, gPtpTable[100 .. 101], 153);
	pt_size += MakePixToneObject(organya, gPtpTable[101 .. 103], 154);
	pt_size += MakePixToneObject(organya, gPtpTable[111 .. 113], 155);
	pt_size += MakePixToneObject(organya, gPtpTable[103 .. 105], 56);
	pt_size += MakePixToneObject(organya, gPtpTable[105 .. 107], 40);
	pt_size += MakePixToneObject(organya, gPtpTable[105 .. 107], 41);
	pt_size += MakePixToneObject(organya, gPtpTable[107 .. 109], 37);
	pt_size += MakePixToneObject(organya, gPtpTable[109 .. 111], 57);
	pt_size += MakePixToneObject(organya, gPtpTable[113 .. 116], 115);
	pt_size += MakePixToneObject(organya, gPtpTable[116 .. 117], 104);
	pt_size += MakePixToneObject(organya, gPtpTable[117 .. 120], 116);
	pt_size += MakePixToneObject(organya, gPtpTable[120 .. 122], 58);
	pt_size += MakePixToneObject(organya, gPtpTable[122 .. 124], 55);
	pt_size += MakePixToneObject(organya, gPtpTable[124 .. 126], 117);
	pt_size += MakePixToneObject(organya, gPtpTable[126 .. 127], 59);
	pt_size += MakePixToneObject(organya, gPtpTable[127 .. 128], 60);
	pt_size += MakePixToneObject(organya, gPtpTable[128 .. 129], 61);
	pt_size += MakePixToneObject(organya, gPtpTable[129 .. 131], 62);
	pt_size += MakePixToneObject(organya, gPtpTable[131 .. 133], 63);
	pt_size += MakePixToneObject(organya, gPtpTable[133 .. 135], 64);
	pt_size += MakePixToneObject(organya, gPtpTable[135 .. 136], 65);
	pt_size += MakePixToneObject(organya, gPtpTable[136 .. 137], 3);
	pt_size += MakePixToneObject(organya, gPtpTable[137 .. 138], 6);
	pt_size += MakePixToneObject(organya, gPtpTable[138 .. 139], 7);
}
