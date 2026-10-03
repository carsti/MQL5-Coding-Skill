#property strict
#property version "1.00"
#property description "Nontrading example with independently specified boundary and transition cases."
#include "Mql5Assertions.mqh"
input string TestNonce="";

// Specification: clamp integer x into closed interval [-2,3].
int ClampExample(const int x)
  {
   if(x< -2) return(-2);
   if(x>3) return(3);
   return(x);
  }
// Specification: idle(0) -> armed(1) -> done(2); fault(3) is absorbing.
int StepExample(const int state,const bool fault)
  {
   if(fault || state==3) return(3);
   if(state==0) return(1);
   if(state==1) return(2);
   return(state);
  }
bool ValidNonce(const string nonce)
  {
   int length=StringLen(nonce);
   if(length<32 || length>64) return(false);
   for(int i=0;i<length;i++)
     {
      ushort c=StringGetCharacter(nonce,i);
      if(!((c>='0' && c<='9') || (c>='a' && c<='f') || (c>='A' && c<='F'))) return(false);
     }
   return(true);
  }
int OnInit(void)
  {
   if(!MQLInfoInteger(MQL_TESTER) || !ValidNonce(TestNonce)) return(INIT_FAILED);
   CMql5Assertions test;
   test.Check(ClampExample(-9)== -2,"below interval");
   test.Check(ClampExample(-2)== -2,"lower boundary");
   test.Check(ClampExample(0)==0,"interior zero");
   test.Check(ClampExample(3)==3,"upper boundary");
   test.Check(ClampExample(9)==3,"above interval");
   test.Check(StepExample(0,false)==1,"arm from idle");
   test.Check(StepExample(1,false)==2,"finish from armed");
   test.Check(StepExample(2,false)==2,"done remains done");
   test.Check(StepExample(0,true)==3,"fault from idle");
   test.Check(StepExample(1,true)==3,"fault from armed");
   test.Check(StepExample(3,false)==3,"fault remains fault");
   test.Report();
   if(!test.Passed()) return(INIT_FAILED);
   Print("MQL5_CODING_PASS:",TestNonce,":toolkit-selftest");
   return(INIT_SUCCEEDED);
  }
void OnTick(void) {}
