//+------------------------------------------------------------------+
//|                                                    SuperEstrategias.mq5 |
//|                                               Autor: Súper Estrategias |
//+------------------------------------------------------------------+
#property copyright   "Usuario"
#property version     "1.01"
#property strict

#include <Trade/Trade.mqh>

// ============================== Inputs ===============================
input string  InpSymbolsCsv = "EURUSD,GBPUSD,USDJPY,USDCHF,USDCAD,AUDUSD,NZDUSD,EURJPY,GBPJPY,AUDJPY,CADJPY,CHFJPY,EURGBP,EURAUD,EURNZD,GBPAUD,GBPCAD,GBPCHF,EURCAD,NZDCAD";
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_H1;    // Señales en H1
input ENUM_TIMEFRAMES InpEntryTimeframe  = PERIOD_M5;    // Entradas en M5
input double InpInitialLots = 0.02;                      // Lote inicial
input uint   InpMagicNumber = 552211;                    // Magic Number
input int    InpMaxPositionsPerSymbol = 1;               // Máximo posiciones por símbolo

// ATR SL/TP y Gestión
input int    InpAtrPeriod = 14;
input ENUM_TIMEFRAMES InpAtrTf = PERIOD_H1;
input double InpSL_ATR_Mult = 1.5;
input double InpTP_ATR_Mult = 3.0;
input bool   InpUseBreakEven = true;
input double InpBE_ATR_Mult = 0.75;     // activar BE al alcanzar esta distancia
input double InpBE_OffsetPoints = 2;    // mover SL a BE + offset
input bool   InpUseTrailingStop = true;
input double InpTS_ATR_Mult = 1.0;

// Filtros
input bool   InpUseSessions = true;
input string InpAsiaSession   = "23:00-07:00";
input string InpLondonSession = "07:00-16:00";
input string InpNYSession     = "13:00-21:00";
input bool   InpUseNewsFilter = true;
input string InpNewsFileName  = "news.csv"; // Ubicado en Common Files
input int    InpNewsMinutesBuffer = 30;     // minutos antes/después
input int    InpMaxSpreadPoints = 30;

// Confirmaciones y tendencia mayor
input int    InpEmaPeriodTrend = 200;   // EMA para dirección de tendencia H1
input int    InpRsiPeriod = 14;

// Timer
input int    InpTimerSeconds = 20;

// ============================== Globals ==============================
CTrade trade;

struct NewsEvent
{
  datetime when;
  string   currency;
  string   description;
  string   impact; // esperado "High"
};

struct SymbolState
{
  string  symbol;
  bool    inMarketWatch;
  ulong   lastTicket;
  datetime lastSignalTime;
  int     lastSignalDirection; // 1 buy, -1 sell, 0 none
};

#define DIR_NONE 0
#define DIR_BUY  1
#define DIR_SELL -1

// Storage
string gSymbols[200];
int    gSymbolsCount = 0;
SymbolState gStates[200];
NewsEvent gNews[1000];
int gNewsCount = 0;
datetime gLastNewsLoad = 0;

// ============================ Utilities ==============================
string Trim(string s)
{
  StringTrimLeft(s);
  StringTrimRight(s);
  return s;
}

bool SplitCsvSymbols(const string csv, string &outArr[], int &outCount, const int maxCount=200)
{
  outCount = 0;
  string parts[];
  int n = StringSplit(csv, ',', parts);
  if(n<=0) return false;
  for(int i=0;i<n && outCount<maxCount;i++)
  {
    string s = Trim(parts[i]);
    if(s!="")
    {
      outArr[outCount++] = s;
    }
  }
  return (outCount>0);
}

bool EnsureInMarketWatch(const string symbol)
{
  if(SymbolSelect(symbol, true))
    return true;
  return false;
}

bool GetBaseQuote(const string symbol, string &base, string &quote)
{
  base = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
  quote = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
  if(base=="" || quote=="") return false;
  return true;
}

bool IsWithinRange(datetime nowTime, datetime eventTime, int minutesBuffer)
{
  long diff = (long)MathAbs((long)(nowTime - eventTime));
  return (diff <= minutesBuffer*60);
}

bool ParseTimeRange(const string range, int &startMinutes, int &endMinutes)
{
  // "HH:MM-HH:MM" -> minutes from 00:00
  string parts[]; int n = StringSplit(range, '-', parts);
  if(n!=2) return false;
  string p1 = parts[0], p2 = parts[1];
  string p1s[]; StringSplit(p1, ':', p1s);
  string p2s[]; StringSplit(p2, ':', p2s);
  if(ArraySize(p1s)!=2 || ArraySize(p2s)!=2) return false;
  int h1=(int)StringToInteger(p1s[0]), m1=(int)StringToInteger(p1s[1]);
  int h2=(int)StringToInteger(p2s[0]), m2=(int)StringToInteger(p2s[1]);
  startMinutes = h1*60+m1;
  endMinutes   = h2*60+m2;
  return true;
}

int MinutesOfDay(datetime t)
{
  MqlDateTime dt; TimeToStruct(t, dt);
  return dt.hour*60 + dt.min;
}

bool TimeInSession(datetime now, const string range)
{
  int startM, endM;
  if(!ParseTimeRange(range, startM, endM)) return true;
  int cur = MinutesOfDay(now);
  if(startM<=endM) return (cur>=startM && cur<=endM);
  // overnight session
  return (cur>=startM || cur<=endM);
}

bool IsWithinAnyTradingSession(datetime now)
{
  return ( TimeInSession(now, InpAsiaSession) || TimeInSession(now, InpLondonSession) || TimeInSession(now, InpNYSession) );
}

bool IsSpreadOk(const string symbol)
{
  int spread = (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
  return (spread <= InpMaxSpreadPoints);
}

// ============================ Data/Indicators =============================
bool CopyBarsOHLC(const string symbol, ENUM_TIMEFRAMES tf, int bars, double &o[], double &h[], double &l[], double &c[])
{
  ArraySetAsSeries(o,true); ArraySetAsSeries(h,true); ArraySetAsSeries(l,true); ArraySetAsSeries(c,true);
  if(CopyOpen(symbol, tf, 0, bars, o) != bars) return false;
  if(CopyHigh(symbol, tf, 0, bars, h) != bars) return false;
  if(CopyLow(symbol, tf, 0, bars, l) != bars) return false;
  if(CopyClose(symbol, tf, 0, bars, c) != bars) return false;
  return true;
}

double GetATR(const string symbol, ENUM_TIMEFRAMES tf, int period, int shift=0)
{
  int handle = iATR(symbol, tf, period);
  if(handle==INVALID_HANDLE) return 0.0;
  double atr[];
  ArraySetAsSeries(atr,true);
  if(CopyBuffer(handle, 0, 0, shift+2, atr) < shift+1)
  {
    IndicatorRelease(handle);
    return 0.0;
  }
  double v = atr[shift];
  IndicatorRelease(handle);
  return v;
}

double GetEMA(const string symbol, ENUM_TIMEFRAMES tf, int period, int shift=0)
{
  int handle = iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return 0.0;
  double ema[];
  ArraySetAsSeries(ema,true);
  if(CopyBuffer(handle, 0, 0, shift+2, ema) < shift+1)
  {
    IndicatorRelease(handle);
    return 0.0;
  }
  double v = ema[shift];
  IndicatorRelease(handle);
  return v;
}

int GetTrendDirectionH1(const string symbol)
{
  double ema0 = GetEMA(symbol, InpSignalTimeframe, InpEmaPeriodTrend, 0);
  double ema1 = GetEMA(symbol, InpSignalTimeframe, InpEmaPeriodTrend, 1);
  double price = SymbolInfoDouble(symbol, SYMBOL_BID);
  if(ema0==0 || ema1==0) return DIR_NONE;
  if(ema0 > ema1 && price > ema0) return DIR_BUY;
  if(ema0 < ema1 && price < ema0) return DIR_SELL;
  return DIR_NONE;
}

// ============================ Candlestick Patterns =========================
// Helpers
bool IsBullCandle(double o, double c) { return c>o; }
bool IsBearCandle(double o, double c) { return c<o; }
double Body(double o, double c) { return MathAbs(c-o); }
double UpperWick(double o, double h, double c) { return h - MathMax(o,c); }
double LowerWick(double o, double l, double c) { return MathMin(o,c) - l; }
double Range(double h, double l) { return h-l; }

bool IsBullishEngulfing(const double &o[], const double &h[], const double &l[], const double &c[])
{
  // c[1] previous, c[0] current
  if(!IsBearCandle(o[1],c[1])) return false;
  if(!IsBullCandle(o[0],c[0])) return false;
  return (c[0] > o[1] && o[0] < c[1]);
}

bool IsBearishEngulfing(const double &o[], const double &h[], const double &l[], const double &c[])
{
  if(!IsBullCandle(o[1],c[1])) return false;
  if(!IsBearCandle(o[0],c[0])) return false;
  return (c[0] < o[1] && o[0] > c[1]);
}

bool IsHammer(const double &o[], const double &h[], const double &l[], const double &c[])
{
  double r = Range(h[0], l[0]);
  if(r<=0) return false;
  double body = Body(o[0], c[0]);
  double lw = LowerWick(o[0], l[0], c[0]);
  double uw = UpperWick(o[0], h[0], c[0]);
  return (lw >= 2*body && uw <= body && IsBullCandle(o[0],c[0]));
}

bool IsShootingStar(const double &o[], const double &h[], const double &l[], const double &c[])
{
  double r = Range(h[0], l[0]);
  if(r<=0) return false;
  double body = Body(o[0], c[0]);
  double lw = LowerWick(o[0], l[0], c[0]);
  double uw = UpperWick(o[0], h[0], c[0]);
  return (uw >= 2*body && lw <= body && IsBearCandle(o[0],c[0]));
}

bool IsMorningStar(const double &o[], const double &h[], const double &l[], const double &c[])
{
  // [2]=bear, [1]=small indecision, [0]=strong bull
  if(!IsBearCandle(o[2],c[2])) return false;
  if(Body(o[1],c[1]) > Body(o[2],c[2])*0.5) return false;
  if(!IsBullCandle(o[0],c[0])) return false;
  return (c[0] > (o[2]+c[2])/2.0);
}

bool IsEveningStar(const double &o[], const double &h[], const double &l[], const double &c[])
{
  if(!IsBullCandle(o[2],c[2])) return false;
  if(Body(o[1],c[1]) > Body(o[2],c[2])*0.5) return false;
  if(!IsBearCandle(o[0],c[0])) return false;
  return (c[0] < (o[2]+c[2])/2.0);
}

bool IsTweezerBottoms(const double &h[], const double &l[])
{
  return (MathAbs(l[0]-l[1]) <= (Range(h[0],l[0])*0.1));
}

bool IsTweezerTops(const double &h[], const double &l[])
{
  return (MathAbs(h[0]-h[1]) <= (Range(h[0],l[0])*0.1));
}

bool IsInsideBar(const double &h[], const double &l[])
{
  return (h[0] <= h[1] && l[0] >= l[1]);
}

bool IsThreeWhiteSoldiers(const double &o[], const double &c[])
{
  return (IsBullCandle(o[0],c[0]) && IsBullCandle(o[1],c[1]) && IsBullCandle(o[2],c[2]) &&
          c[0]>c[1] && c[1]>c[2] && o[0]>o[1] && o[1]>o[2]);
}

bool IsThreeBlackCrows(const double &o[], const double &c[])
{
  return (IsBearCandle(o[0],c[0]) && IsBearCandle(o[1],c[1]) && IsBearCandle(o[2],c[2]) &&
          c[0]<c[1] && c[1]<c[2] && o[0]<o[1] && o[1]<o[2]);
}

int DetectCandlestickSignal(const string symbol, ENUM_TIMEFRAMES tf, string &outName)
{
  double o[],h[],l[],c[];
  if(!CopyBarsOHLC(symbol, tf, 5, o,h,l,c)) return DIR_NONE;

  // Use last completed bar(s): shift=1,2,3...
  // Build small arrays indexing [0] as most recent completed bar
  double O2[3],H2[3],L2[3],C2[3];
  for(int i=0;i<3;i++){ O2[i]=o[i+1]; H2[i]=h[i+1]; L2[i]=l[i+1]; C2[i]=c[i+1]; }

  // 1-bar patterns use O2[0],H2[0],L2[0],C2[0] etc
  // Engulfing (requires two bars)
  double Oeng[2]={O2[0],O2[1]}, Heng[2]={H2[0],H2[1]}, Leng[2]={L2[0],L2[1]}, Ceng[2]={C2[0],C2[1]};

  if(IsBullishEngulfing(Oeng,Heng,Leng,Ceng)){ outName="Bullish Engulfing"; return DIR_BUY; }
  if(IsBearishEngulfing(Oeng,Heng,Leng,Ceng)){ outName="Bearish Engulfing"; return DIR_SELL; }

  if(IsHammer(O2,H2,L2,C2)){ outName="Hammer"; return DIR_BUY; }
  if(IsShootingStar(O2,H2,L2,C2)){ outName="Shooting Star"; return DIR_SELL; }

  // Morning/Evening Star use 3 bars
  if(IsMorningStar(O2,H2,L2,C2)){ outName="Morning Star"; return DIR_BUY; }
  if(IsEveningStar(O2,H2,L2,C2)){ outName="Evening Star"; return DIR_SELL; }

  if(IsTweezerBottoms(H2,L2)){ outName="Tweezer Bottoms"; return DIR_BUY; }
  if(IsTweezerTops(H2,L2)){ outName="Tweezer Tops"; return DIR_SELL; }

  if(IsInsideBar(H2,L2))
  {
    // trend-following breakout bias via EMA
    int trend = GetTrendDirectionH1(symbol);
    outName="Inside Bar";
    return trend;
  }

  if(IsThreeWhiteSoldiers(O2,C2)){ outName="Three White Soldiers"; return DIR_BUY; }
  if(IsThreeBlackCrows(O2,C2)){ outName="Three Black Crows"; return DIR_SELL; }

  outName="";
  return DIR_NONE;
}

// ============================ Structure Patterns (simplificado) =============
// Nota: Implementaciones básicas usando swings recientes.
// Las funciones se pueden enriquecer fácilmente.

int DetectDoubleTopBottom(const string symbol, ENUM_TIMEFRAMES tf, string &outName)
{
  // Busca dos swings recientes con niveles similares (usando High/Low recientes)
  double h[], l[];
  if(CopyHigh(symbol, tf, 0, 200, h)<100) return DIR_NONE;
  if(CopyLow(symbol, tf, 0, 200, l)<100) return DIR_NONE;
  ArraySetAsSeries(h,true); ArraySetAsSeries(l,true);

  // Encuentra máximos/mínimos locales básicos
  int peak1=-1, peak2=-1, trough1=-1, trough2=-1;
  for(int i=5; i<50; i++)
  {
    if(h[i]>h[i+1] && h[i]>h[i-1])
    {
      if(peak1==-1) peak1=i;
      else { peak2=i; break; }
    }
  }
  for(int i=5; i<50; i++)
  {
    if(l[i]<l[i+1] && l[i]<l[i-1])
    {
      if(trough1==-1) trough1=i;
      else { trough2=i; break; }
    }
  }

  if(peak1>0 && peak2>0 && MathAbs(h[peak1]-h[peak2]) <= (MathMax(h[peak1],h[peak2])*0.001))
  {
    outName="Doble Techo";
    return DIR_SELL;
  }
  if(trough1>0 && trough2>0 && MathAbs(l[trough1]-l[trough2]) <= (MathMax(l[trough1],l[trough2])*0.001))
  {
    outName="Doble Suelo";
    return DIR_BUY;
  }
  outName="";
  return DIR_NONE;
}

int DetectHeadAndShoulders(const string symbol, ENUM_TIMEFRAMES tf, string &outName)
{
  // Búsqueda muy simplificada con 5 swings: LS - H - RS
  double h[], l[];
  if(CopyHigh(symbol, tf, 0, 300, h)<150) return DIR_NONE;
  if(CopyLow(symbol, tf, 0, 300, l)<150) return DIR_NONE;
  ArraySetAsSeries(h,true); ArraySetAsSeries(l,true);

  // Encuentra 5 picos
  int peaks[10]; ArrayInitialize(peaks,-1); int pc=0;
  for(int i=5; i<120 && pc<5; i++)
  {
    if(h[i]>h[i+1] && h[i]>h[i-1]) peaks[pc++]=i;
  }
  if(pc<3){ outName=""; return DIR_NONE; }

  // Tomar tres primeros picos como LS,H,RS candidatos
  int ls=peaks[0], head=peaks[1], rs=peaks[2];
  if(ls<0 || head<0 || rs<0){ outName=""; return DIR_NONE; }

  bool hsBear = (h[head]>h[ls] && h[head]>h[rs] && MathAbs(h[ls]-h[rs]) <= h[head]*0.002);
  bool hsInv  = false;

  // Invertido: usar valles (simetría rápida)
  int troughs[10]; ArrayInitialize(troughs,-1); int tc=0;
  for(int i=5; i<120 && tc<5; i++)
  {
    if(l[i]<l[i+1] && l[i]<l[i-1]) troughs[tc++]=i;
  }
  if(tc>=3)
  {
    int ls2=troughs[0], head2=troughs[1], rs2=troughs[2];
    hsInv = (l[head2]<l[ls2] && l[head2]<l[rs2] && MathAbs(l[ls2]-l[rs2]) <= MathAbs(l[head2])*0.002);
  }

  if(hsBear){ outName="Hombro-Cabeza-Hombro"; return DIR_SELL; }
  if(hsInv){ outName="Hombro-Cabeza-Hombro Invertido"; return DIR_BUY; }

  outName="";
  return DIR_NONE;
}

int DetectRectangleRangeBreakout(const string symbol, ENUM_TIMEFRAMES tf, string &outName)
{
  // Detecta rango lateral reciente y su ruptura
  double h[], l[], c[];
  if(CopyHigh(symbol, tf, 0, 100, h)<50) return DIR_NONE;
  if(CopyLow(symbol, tf, 0, 100, l)<50) return DIR_NONE;
  if(CopyClose(symbol, tf, 0, 100, c)<50) return DIR_NONE;
  ArraySetAsSeries(h,true); ArraySetAsSeries(l,true); ArraySetAsSeries(c,true);

  double maxR= -DBL_MAX, minR= DBL_MAX;
  for(int i=10;i<=30;i++){ maxR=MathMax(maxR,h[i]); minR=MathMin(minR,l[i]); }
  double rangeH = maxR - minR;
  if(rangeH <= 0) return DIR_NONE;
  double lastClose = c[1];
  if(lastClose > maxR){ outName="Rectángulo - Ruptura Alcista"; return DIR_BUY; }
  if(lastClose < minR){ outName="Rectángulo - Ruptura Bajista"; return DIR_SELL; }
  outName=""; return DIR_NONE;
}

// Placeholders ampliables para otros patrones (Bandera, Triángulos, Canal Tendencial)
int DetectFlagTriangleChannel(const string symbol, ENUM_TIMEFRAMES tf, string &outName)
{
  outName="";
  return DIR_NONE;
}

// ============================ Zonas/Confirmaciones ==========================
bool IsNearRecentSwingSR(const string symbol, ENUM_TIMEFRAMES tf, int lookbackBars, double atrMultThreshold)
{
  double h[], l[], c[];
  if(CopyHigh(symbol, tf, 0, lookbackBars+10, h) < lookbackBars) return false;
  if(CopyLow(symbol, tf, 0, lookbackBars+10, l) < lookbackBars) return false;
  if(CopyClose(symbol, tf, 0, 5, c) < 2) return false;
  ArraySetAsSeries(h,true); ArraySetAsSeries(l,true); ArraySetAsSeries(c,true);

  double lastClose = c[1];
  double atr = GetATR(symbol, tf, InpAtrPeriod, 1);
  if(atr<=0) return false;

  // Buscar swing high/low más cercano
  double nearestDist = DBL_MAX;
  for(int i=3; i<lookbackBars; i++)
  {
    if(h[i]>h[i+1] && h[i]>h[i-1])
      nearestDist = MathMin(nearestDist, MathAbs(lastClose - h[i]));
    if(l[i]<l[i+1] && l[i]<l[i-1])
      nearestDist = MathMin(nearestDist, MathAbs(lastClose - l[i]));
  }
  return (nearestDist <= atr*atrMultThreshold);
}

bool RsiBullishDivergence(const string symbol, ENUM_TIMEFRAMES tf)
{
  int handle = iRSI(symbol, tf, InpRsiPeriod, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return false;
  double rsi[];
  ArraySetAsSeries(rsi,true);
  if(CopyBuffer(handle, 0, 0, 100, rsi)<50){ IndicatorRelease(handle); return false; }
  IndicatorRelease(handle);

  double l[]; ArraySetAsSeries(l,true);
  if(CopyLow(symbol, tf, 0, 100, l)<50) return false;

  // Encuentra dos valles en precio y compara RSI
  int t1=-1,t2=-1;
  for(int i=5;i<60;i++)
  {
    if(l[i]<l[i+1] && l[i]<l[i-1])
    {
      if(t1==-1) t1=i;
      else { t2=i; break; }
    }
  }
  if(t1<0 || t2<0) return false;
  // Divergencia alcista: precio hace mínimo más bajo pero RSI hace mínimo más alto
  if(l[t1]>l[t2] && rsi[t1] < rsi[t2]) return true;
  return false;
}

bool RsiBearishDivergence(const string symbol, ENUM_TIMEFRAMES tf)
{
  int handle = iRSI(symbol, tf, InpRsiPeriod, PRICE_CLOSE);
  if(handle==INVALID_HANDLE) return false;
  double rsi[];
  ArraySetAsSeries(rsi,true);
  if(CopyBuffer(handle, 0, 0, 100, rsi)<50){ IndicatorRelease(handle); return false; }
  IndicatorRelease(handle);

  double h[]; ArraySetAsSeries(h,true);
  if(CopyHigh(symbol, tf, 0, 100, h)<50) return false;

  int p1=-1,p2=-1;
  for(int i=5;i<60;i++)
  {
    if(h[i]>h[i+1] && h[i]>h[i-1])
    {
      if(p1==-1) p1=i;
      else { p2=i; break; }
    }
  }
  if(p1<0 || p2<0) return false;
  // Divergencia bajista: precio hace máximo más alto pero RSI hace máximo más bajo
  if(h[p1]<h[p2] && rsi[p1] > rsi[p2]) return true;
  return false;
}

// ============================ News Filter ==============================
int SplitFlexible(const string line, string &parts[])
{
  int n = StringSplit(line, ',', parts);
  if(n<5) n = StringSplit(line, ';', parts);
  return n;
}

bool LoadNewsFromCommonFiles(const string fileName)
{
  gNewsCount = 0;
  int h = FileOpen(fileName, FILE_READ|FILE_TXT|FILE_COMMON);
  if(h==INVALID_HANDLE) return false;

  // Espera encabezado: Date,Time,Currency,Description,Impact
  // Ej: 2025.08.12,07:30,USD,CPI,High
  bool first=true;
  while(!FileIsEnding(h) && gNewsCount < ArraySize(gNews))
  {
    string line = FileReadString(h);
    if(line=="") { if(FileIsEnding(h)) break; else continue; }

    string parts[];
    int n=SplitFlexible(line, parts);
    if(n<5) continue;

    if(first)
    {
      string head = Trim(parts[0]);
      if(StringCompare(head,"Date",false)==0){ first=false; continue; }
    }
    first=false;

    string dateStr = Trim(parts[0]); // YYYY.MM.DD
    string timeStr = Trim(parts[1]); // HH:MM
    string curr    = Trim(parts[2]);
    string desc    = Trim(parts[3]);
    string imp     = Trim(parts[4]);

    string dtStr = dateStr + " " + timeStr;
    datetime when = StringToTime(dtStr);
    if(when==0) continue;
    if(StringCompare(imp,"High",false)!=0) continue;

    gNews[gNewsCount].when = when;
    gNews[gNewsCount].currency = curr;
    gNews[gNewsCount].description = desc;
    gNews[gNewsCount].impact = imp;
    gNewsCount++;
  }
  FileClose(h);
  gLastNewsLoad = TimeCurrent();
  return (gNewsCount>=0);
}

bool IsBlockedByNews(const string symbol, datetime now)
{
  if(!InpUseNewsFilter) return false;
  // recargar cada 60 min por si cambia el archivo
  if(now - gLastNewsLoad > 3600) LoadNewsFromCommonFiles(InpNewsFileName);

  string base,quote;
  if(!GetBaseQuote(symbol, base, quote)) return false;
  for(int i=0;i<gNewsCount;i++)
  {
    if(gNews[i].currency==base || gNews[i].currency==quote)
    {
      if(IsWithinRange(now, gNews[i].when, InpNewsMinutesBuffer)) return true;
    }
  }
  return false;
}

// ============================ Trading / Orders =============================
bool HasOpenPositions(const string symbol, int &count, bool &allProtected)
{
  count = 0;
  allProtected = true;
  if(PositionSelect(symbol))
  {
    count = 1;
    double sl = PositionGetDouble(POSITION_SL);
    double price = PositionGetDouble(POSITION_PRICE_OPEN);
    long type = PositionGetInteger(POSITION_TYPE);
    if(type==POSITION_TYPE_BUY)
    {
      if(sl < price && sl!=0.0) allProtected=false;
    }
    else if(type==POSITION_TYPE_SELL)
    {
      if(sl > price && sl!=0.0) allProtected=false;
    }
  }
  return (count>0);
}

bool PlaceOrder(const string symbol, int dir, double atr)
{
  if(dir==DIR_NONE) return false;
  trade.SetExpertMagicNumber(InpMagicNumber);
  trade.SetAsyncMode(false);

  double price = (dir==DIR_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int    digits= (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double minVol  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double maxVol  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

  double lots = InpInitialLots;
  // ajustar a pasos
  lots = MathMax(minVol, MathMin(maxVol, MathFloor(lots/volStep)*volStep));

  double sl, tp;
  double slDist = atr * InpSL_ATR_Mult;
  double tpDist = atr * InpTP_ATR_Mult;

  bool ok=false;
  if(dir==DIR_BUY)
  {
    sl = NormalizeDouble(price - slDist, digits);
    tp = NormalizeDouble(price + tpDist, digits);
    ok = trade.Buy(lots, symbol, 0.0, sl, tp);
  }
  else
  {
    sl = NormalizeDouble(price + slDist, digits);
    tp = NormalizeDouble(price - tpDist, digits);
    ok = trade.Sell(lots, symbol, 0.0, sl, tp);
  }
  return ok;
}

void ManagePositionTrailingAndTP(const string symbol)
{
  if(!PositionSelect(symbol)) return;

    long type = PositionGetInteger(POSITION_TYPE);
    double open = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl   = PositionGetDouble(POSITION_SL);
    double tp   = PositionGetDouble(POSITION_TP);
    double price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double atr = GetATR(symbol, InpAtrTf, InpAtrPeriod, 0);
    if(atr<=0) continue;

    // Break Even
    if(InpUseBreakEven)
    {
      double beTrigger = atr * InpBE_ATR_Mult;
      if(type==POSITION_TYPE_BUY)
      {
        if(price - open >= beTrigger)
        {
          double newSL = MathMax(sl, NormalizeDouble(open + InpBE_OffsetPoints*SymbolInfoDouble(symbol, SYMBOL_POINT), digits));
          if(newSL > sl) trade.PositionModify(symbol, newSL, tp);
        }
      }
      else
      {
        if(open - price >= beTrigger)
        {
          double newSL = MathMin(sl, NormalizeDouble(open - InpBE_OffsetPoints*SymbolInfoDouble(symbol, SYMBOL_POINT), digits));
          if(newSL < sl || sl==0.0) trade.PositionModify(symbol, newSL, tp);
        }
      }
    }

    // Trailing Stop por ATR
    if(InpUseTrailingStop)
    {
      double tsDist = atr * InpTS_ATR_Mult;
      if(type==POSITION_TYPE_BUY)
      {
        double desiredSL = NormalizeDouble(price - tsDist, digits);
        if(desiredSL > sl) trade.PositionModify(symbol, desiredSL, tp);
      }
      else
      {
        double desiredSL = NormalizeDouble(price + tsDist, digits);
        if(sl==0.0 || desiredSL < sl) trade.PositionModify(symbol, desiredSL, tp);
      }
    }

    // Empujar TP con tendencia mayor
    int trend = GetTrendDirectionH1(symbol);
    if(trend==DIR_BUY && type==POSITION_TYPE_BUY)
    {
      double desiredTP = NormalizeDouble(price + atr*InpTP_ATR_Mult, digits);
      if(desiredTP > tp || tp==0.0) trade.PositionModify(symbol, sl, desiredTP);
    }
    else if(trend==DIR_SELL && type==POSITION_TYPE_SELL)
    {
      double desiredTP = NormalizeDouble(price - atr*InpTP_ATR_Mult, digits);
      if(tp==0.0 || desiredTP < tp) trade.PositionModify(symbol, sl, desiredTP);
    }
  }
}

// ============================ Strategy Orchestration ========================
bool PassesGlobalFilters(const string symbol, datetime now)
{
  if(!IsSpreadOk(symbol)) return false;
  if(InpUseSessions && !IsWithinAnyTradingSession(now)) return false;
  if(IsBlockedByNews(symbol, now)) return false;
  return true;
}

int DetectAnySignalH1(const string symbol, string &why)
{
  string name;
  // 1) Price Action Velas
  int dir = DetectCandlestickSignal(symbol, InpSignalTimeframe, name);
  if(dir!=DIR_NONE)
  {
    // Relevancia de zona y confirmaciones
    bool nearZone = IsNearRecentSwingSR(symbol, InpSignalTimeframe, 80, 1.5);
    bool divOK = (dir==DIR_BUY) ? RsiBullishDivergence(symbol, InpSignalTimeframe) : RsiBearishDivergence(symbol, InpSignalTimeframe);
    if(nearZone || divOK)
    {
      why = "Candlestick: " + name + (nearZone ? " + Zona" : "") + (divOK ? " + Divergencia RSI" : "");
      return dir;
    }
  }

  // 2) Estructuras
  int dir2 = DetectDoubleTopBottom(symbol, InpSignalTimeframe, name);
  if(dir2!=DIR_NONE)
  {
    why = "Estructura: " + name;
    return dir2;
  }

  int dir3 = DetectHeadAndShoulders(symbol, InpSignalTimeframe, name);
  if(dir3!=DIR_NONE)
  {
    why = "Estructura: " + name;
    return dir3;
  }

  int dir4 = DetectRectangleRangeBreakout(symbol, InpSignalTimeframe, name);
  if(dir4!=DIR_NONE)
  {
    why = "Estructura: " + name;
    return dir4;
  }

  int dir5 = DetectFlagTriangleChannel(symbol, InpSignalTimeframe, name);
  if(dir5!=DIR_NONE)
  {
    why = "Estructura: " + name;
    return dir5;
  }

  why = "";
  return DIR_NONE;
}

bool EntryOnM5AlignAndExecute(const string symbol, int dir, string why)
{
  // Confirmación ligera en M5: mismo sesgo de EMA en H1
  int tfTrend = GetTrendDirectionH1(symbol);
  if(dir!=tfTrend && tfTrend!=DIR_NONE) return false;

  double atr = GetATR(symbol, InpAtrTf, InpAtrPeriod, 0);
  if(atr<=0) return false;

  return PlaceOrder(symbol, dir, atr);
}

// ============================ EA Lifecyle ==============================
int OnInit()
{
  trade.SetExpertMagicNumber(InpMagicNumber);
  if(!SplitCsvSymbols(InpSymbolsCsv, gSymbols, gSymbolsCount))
  {
    Print("No hay símbolos para operar. Verifique InpSymbolsCsv");
    return INIT_FAILED;
  }

  for(int i=0;i<gSymbolsCount;i++)
  {
    gStates[i].symbol = gSymbols[i];
    gStates[i].inMarketWatch = EnsureInMarketWatch(gSymbols[i]);
    gStates[i].lastTicket = 0;
    gStates[i].lastSignalTime = 0;
    gStates[i].lastSignalDirection = DIR_NONE;
  }

  if(InpUseNewsFilter)
  {
    bool ok=LoadNewsFromCommonFiles(InpNewsFileName);
    if(!ok) Print("Advertencia: no se pudo leer noticias desde Common Files: ", InpNewsFileName);
  }

  EventSetTimer(InpTimerSeconds);
  Print("EA 'Súper Estrategias' iniciado. Símbolos: ", gSymbolsCount);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  EventKillTimer();
}

void OnTick()
{
  // Gestionar trailing/BE por símbolo activo del gráfico también
  const string chartSymbol = _Symbol;
  ManagePositionTrailingAndTP(chartSymbol);
}

void OnTimer()
{
  datetime now = TimeCurrent();

  for(int i=0;i<gSymbolsCount;i++)
  {
    const string symbol = gStates[i].symbol;
    if(!SymbolInfoInteger(symbol, SYMBOL_SELECT)) continue; // debe estar en Market Watch

    // Gestión de posiciones existentes
    ManagePositionTrailingAndTP(symbol);

    // Reglas de una sola operación por par (y protección si se desea más)
    int openCount=0; bool allProtected=true;
    bool hasPos = HasOpenPositions(symbol, openCount, allProtected);
    if(hasPos && openCount >= InpMaxPositionsPerSymbol) continue;
    if(hasPos && !allProtected && openCount>0 && InpMaxPositionsPerSymbol>1) continue;

    // Filtros globales
    if(!PassesGlobalFilters(symbol, now)) continue;

    // Señal H1
    string why=""; int dir = DetectAnySignalH1(symbol, why);
    if(dir==DIR_NONE) continue;

    // Evitar múltiple entrada en misma barra
    datetime barTime[];
    ArraySetAsSeries(barTime,true);
    if(CopyTime(symbol, InpSignalTimeframe, 0, 2, barTime)<2) continue;
    datetime lastCompletedBar = barTime[1];
    if(gStates[i].lastSignalTime == lastCompletedBar && gStates[i].lastSignalDirection == dir)
      continue;

    // Ejecutar en M5
    if(EntryOnM5AlignAndExecute(symbol, dir, why))
    {
      gStates[i].lastSignalTime = lastCompletedBar;
      gStates[i].lastSignalDirection = dir;
      Print("Entrada ", (dir==DIR_BUY?"BUY":"SELL"), " en ", symbol, " | Motivo: ", why);
    }
  }
}