#property strict
#property version "1.00"
// Nontrading, deterministic script copied to a local terminal for export capture.
double FixtureSeries(const int seed)
  {
   double value=seed+1.0;
   for(int i=0;i<10000;i++) value=(value+1.25)/(1.00001+(i%7)*0.00001);
   return(value);
  }
double FixtureFold(const int round)
  {
   double sum=0;
   for(int i=0;i<100;i++) sum+=FixtureSeries(round+i);
   return(sum);
  }
int OnStart(void)
  {
   double checksum=0;
   for(int round=0;round<250;round++) checksum+=FixtureFold(round);
   Print("NATIVE_PROFILER_FIXTURE_COMPLETE:",checksum);
   return(0);
  }
