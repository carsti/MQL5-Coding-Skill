#property strict
#include <Owner's.mqh>
#include <Shared.mqh>

int OnStart(void)
  {
   return OwnerProbe()+SharedProbe()-3;
  }
