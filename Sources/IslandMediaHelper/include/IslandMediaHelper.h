#ifndef ISLAND_MEDIA_HELPER_H
#define ISLAND_MEDIA_HELPER_H

/// Entry point called from /usr/bin/perl via DynaLoader (an XSUB, so the two
/// arguments are perl's interpreter and CV pointers; they are ignored).
/// Streams Now Playing info as JSON lines on stdout and reads commands from
/// stdin. Never returns; exits when stdin closes (the app quit).
void islandmedia_run(void *unused1, void *unused2);

#endif
