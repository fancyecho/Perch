#pragma once

/// Streams Now Playing state as JSON lines on stdout and runs media commands read from stdin,
/// one per line: play, pause, toggle, next, previous, seek <seconds>, state.
/// Never returns; exits when stdin closes.
void perch_media_stream(void);
