#property strict
string Banner="AB C D";
#include "Header  Name.mqh"
#include "Shared.mqh"
int OnInit(void) { return HeaderValue()+SharedValue()-9; }
void OnTick(void) {}
