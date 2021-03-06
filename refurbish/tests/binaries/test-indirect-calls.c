#include "util.h"

int g1 = 1;
int g2;
int g3;
int g4;

int f2(long l1) {
  return (int)&g2;
}

int f1(long l1) {
  long i1 = (long)&g1;
  i1 = l1 + i1;
  return (int)i1;
}

void entry() {
  long i1 = (long)&g1;
  long i2 = (long)&g2;
  long i3 = (long)&g3;
  int (*fptr)(long) = &f1;
  if(i1 > i2)
    fptr = &f2;

  g1 = fptr(i3 + i2);
}

#if defined(NOSTDLIB)
void _start() {
  entry();
  EXIT(0);
}
#else
int main() {
  entry();
  return 0;
}
#endif
