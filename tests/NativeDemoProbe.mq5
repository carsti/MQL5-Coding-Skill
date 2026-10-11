#property strict
#property description "Development-only account identity probe; contains no trading calls."

input string ExpectedLogin="";
input string ExpectedServer="";
input string ProbeNonce="";

void OnStart()
{
   if(MQLInfoInteger(MQL_TESTER) || StringToInteger(ExpectedLogin)<=0 || ProbeNonce=="")
   {
      Print("MQL5_DEMO_PROBE:invalid-context");
      return;
   }
   for(int attempt=0;attempt<360;attempt++)
   {
      if(TerminalInfoInteger(TERMINAL_CONNECTED))
      {
         if(AccountInfoInteger(ACCOUNT_LOGIN)!=StringToInteger(ExpectedLogin) ||
            AccountInfoString(ACCOUNT_SERVER)!=ExpectedServer ||
            AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
         {
            Print("MQL5_DEMO_PROBE:account-rejected");
            return;
         }
         Print("MQL5_CODING_PASS:",ProbeNonce,":dedicated-demo-account");
         return;
      }
      Sleep(500);
   }
   Print("MQL5_DEMO_PROBE:connection-unavailable");
}
