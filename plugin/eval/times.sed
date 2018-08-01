# Used to format time measurements from Coq
s/[.]\([0-9][0-9][1-9]\) /\1 /;
s/[.]\([0-9][1-9]\) /\10 /;
s/[.]\([0-9]\) /\100 /;
s/[.] /000 /;
s/^0*\([1-9][0-9]*\) secs/\1ms/;
s/^0* secs/0ms/;
