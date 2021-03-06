import organya;

import std.algorithm.comparison;
import std.experimental.logger;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.stdio;
import std.string;
import std.utf;
import bindbc.sdl : SDL_AudioCallback, SDL_AudioDeviceID;

bool initAudio(SDL_AudioCallback fun, ubyte channels, uint sampleRate, void* userdata = null) {
	SDL_AudioDeviceID dev;
	import bindbc.sdl;

	enforce(loadSDL() == sdlSupport);
	if (SDL_Init(SDL_INIT_AUDIO) != 0) {
		criticalf("SDL init failed: %s", SDL_GetError().fromStringz);
		return false;
	}
	SDL_AudioSpec want, have;
	want.freq = sampleRate;
	want.format = SDL_AudioFormat.AUDIO_S16;
	want.channels = channels;
	want.samples = 512;
	want.callback = fun;
	want.userdata = userdata;
	dev = SDL_OpenAudioDevice(null, 0, &want, &have, 0);
	if (dev == 0) {
		criticalf("SDL_OpenAudioDevice failed: %s", SDL_GetError().fromStringz);
		return false;
	}
	SDL_PauseAudioDevice(dev, 0);
	return true;
}

extern (C) void _sampling_func(void* user, ubyte* buf, int bufSize) nothrow {
	Organya* org = cast(Organya*) user;
	org.fillBuffer(cast(short[])(buf[0 .. bufSize]));
}

int main(string[] args) {
	enum channels = 2;
	enum sampleRate = 44100;
	if (args.length < 2) {
		return 1;
	}
	sharedLog = new FileLogger(stdout, LogLevel.trace);

	auto filePath = args[1];
	auto file = cast(ubyte[])read(args[1]);

	// organya initialization
	Organya org;
	trace("Initializing Organya");
	org.initialize(sampleRate);

	trace("Loading organya data");
	org.loadData(cast(ubyte[])read("pixtone.tbl"));

	trace("Loading organya file");
	// Load file
	org.loadMusic(file);

	// Prepare to play music
	if (!initAudio(&_sampling_func, channels, sampleRate, &org)) {
		return 1;
	}
	trace("SDL audio init success");

	org.playMusic();
	trace("Playing organya music");

	writeln("Press enter to exit");
	readln();

	return 0;
}
