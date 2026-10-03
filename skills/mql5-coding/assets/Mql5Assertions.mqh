#ifndef MQL5_TOOLKIT_ASSERTIONS_MQH
#define MQL5_TOOLKIT_ASSERTIONS_MQH
// Small reporting structure. Expected behavior belongs to each project.
class CMql5Assertions
  {
private:
   int m_checked;
   int m_failed;
public:
   CMql5Assertions(void) { m_checked=0; m_failed=0; }
   void Check(const bool condition,const string label)
     {
      m_checked++;
      if(!condition) { m_failed++; Print("MQL5_TEST_FAIL:",label); }
     }
   bool Passed(void) { return(m_checked>0 && m_failed==0); }
   void Report(void) { Print("MQL5_TEST_COUNTS:checked=",m_checked,",failed=",m_failed); }
  };
#endif
