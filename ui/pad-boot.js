// How many instruments this page wants, said before the host reads it.
//
// Its own file, and first in the list, because `host.js` asks for the count when
// it starts the engine and a value set later would arrive after the worklet had
// already been told. Sixteen: one whole Quesynth behind every cell of the grid.
window.QUESYNTH_SLOTS = 16;
