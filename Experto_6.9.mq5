//+------------------------------------------------------------------+
//|                                     Experto_6.9.mq5              |
//| Estrategia mejorada con gestion de riesgo y volumen en H1        |
//| Tendencia en H1 basada en cruce de EMA 20/50 y pendiente de EMA 20 |
//| Cierre automatico de operaciones en positivo los viernes a las 14:00 (Quito) |
//| Bloqueo de nuevas operaciones los viernes a partir de las 14:00 (Quito)      |
//| Break Even a 5 pips, Trailing Stop a 5 pips con 2 pips de paso     |
//| Bloqueo 30 min antes/despues de noticias de alto impacto, cierre en positivo 5 min antes |
//| Pares expandidos: USDJPY, USDCHF, XAUUSD, USDMXN, USDZAR, EURTRY |
//| Filtros dinamicos para spread y ATR por par                      |
//| Seguimiento mejorado: logs detallados, CSV, niveles H1, alertas   |
//| Lote 0.01 para pares de alta volatilidad (XAUUSD, USDMXN, USDZAR, GBPJPY, NZDJPY, EURTRY) |
//| Solucion: Maxima estabilidad para evitar desaparicion en EURUSD     |
//| Nueva funcionalidad: Soportes y Resistencias en M5 para entradas y ajuste de TP |
//| ATR como filtro dinamico y TP basado en ATR * 1.5              |
//| Correlacion: Evitar operar pares con correlacion > 0.7           |
//| Mejoras: Verificacion de datos, gestion de operaciones preexistentes |
//| Nueva funcionalidad: Permitir nuevas operaciones si las existentes estan protegidas con Break Even o Trailing Stop |
//| NUEVA: Cierre inmediato de operaciones cuando EMAs cambian de dirección en H1 |
//+------------------------------------------------------------------+

#property copyright "Leonardo"
#property version     "6.9"
#property strict

// Manual definitions for constants if standard include files are missing
#define TERMINAL_WEB_REQUESTS_ALLOWED 22 // ENUM_TERMINAL_INFO_INTEGER for web requests
#define FILE_ADD 512 // Flag for appending data to a file in FileOpen
#define BE_TRIGGER_PIPS 5     // Break Even at 5 pips
#define BE_OFFSET_PIPS 1      // SL to entry + 1 pip
#define TRAILING_START_PIPS 5 // Trailing Stop at 5 pips
#define TRAILING_STEP_PIPS 2  // Step of 2 pips
#define SR_PROXIMITY_PIPS 5   // Proximity to support/resistance in pips
#define ATR_THRESHOLD_MULTIPLIER 2.0 // Threshold for max ATR to block trading

#include <Trade\Trade.mqh>
#include <Object.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\DealInfo.mqh>

CTrade trade;
CPositionInfo m_position_info;

input string SymbolsList = "EURUSD,EURJPY,EURAUD,GBPUSD,GBPJPY,EURGBP,AUDUSD,AUDJPY,USDCAD,CADJPY,NZDUSD,NZDJPY,EURNZD,USDJPY,USDCHF,XAUUSD,USDMXN,USDZAR,EURTRY";
input ENUM_TIMEFRAMES TimeFrame_Main = PERIOD_M5;
input ENUM_TIMEFRAMES TimeFrame_H1    = PERIOD_H1;
input double LotSize          = 0.2;         // Lot for standard pairs
input double HighVolLotSize = 0.01;      // Lot for high volatility pairs
input int Slippage            = 5;
input int RSIPeriod          = 14;
input double RSIOverbought     = 70.0;      // Ajustado a 70 para sobrecompra
input double RSIOversold     = 30.0;      // Ajustado a 30 para sobreventa
input int MACDFastEMA         = 12;
input int MACDSlowEMA         = 26;
input int MACDSignalSMA       = 9;
input int BlockStartHourLocal = 14; // Block start hour (Quito, UTC-5)
input int BlockEndHourLocal     = 20; // Block end hour (Quito)
input long MinRealVolume_Asia = 500;
input long MinRealVolume_London = 1000;
input long MinRealVolume_NY = 1500;
input long MinTickVolume_Asia = 200;
input long MinTickVolume_London = 400;
input long MinTickVolume_NY = 600;
input double CorrelationThreshold = 0.7;
input long TimeZoneOffsetHours = -5; // Quito, UTC-5

// Correlation matrix for 19 pairs (fallback)
double CorrelationMatrix[][19] = {
    {1.0,0.85,0.75,0.80,0.70,-0.20,0.65,0.60,-0.60,0.55,0.60,0.55,-0.30,0.55,-0.65,0.20,0.30,0.25,0.15},
    {0.85,1.0,0.65,0.60,0.80,-0.30,0.50,0.70,-0.50,0.65,0.50,0.75,-0.25,0.90,-0.50,0.15,0.25,0.20,0.10},
    {0.75,0.65,1.0,0.55,0.50,-0.10,0.80,0.75,-0.45,0.40,0.70,0.65,0.20,0.45,-0.40,0.25,0.20,0.30,0.10},
    {0.80,0.60,0.55,1.0,0.85,0.50,0.60,0.55,-0.55,0.50,0.65,0.60,-0.20,0.50,-0.60,0.20,0.25,0.20,0.15},
    {0.70,0.80,0.50,0.85,1.0,0.30,0.45,0.65,-0.50,0.60,0.50,0.80,-0.15,0.80,-0.40,0.10,0.20,0.15,0.10},
    {-0.20,-0.30,-0.10,0.50,0.30,1.0,-0.05,-0.15,0.05,-0.10,-0.10,-0.15,0.80,-0.10,0.05,-0.05,0.05,0.05,0.60},
    {0.65,0.50,0.80,0.60,0.45,-0.05,1.0,0.85,-0.55,0.50,0.85,0.75,-0.40,0.40,-0.50,0.20,0.30,0.35,0.10},
    {0.60,0.70,0.75,0.55,0.65,-0.15,0.85,1.0,-0.50,0.60,0.80,0.85,-0.35,0.70,-0.45,0.15,0.25,0.30,0.10},
    {-0.60,-0.50,-0.45,-0.55,-0.50,0.05,-0.55,-0.50,1.0,-0.65,-0.60,-0.55,0.30,-0.60,0.60,-0.25,0.35,0.30,0.05},
    {0.55,0.65,0.40,0.50,0.60,-0.10,0.50,0.65,-0.65,1.0,0.45,0.70,-0.20,0.65,-0.40,0.10,0.20,0.15,0.05},
    {0.60,0.50,0.70,0.65,0.50,-0.10,0.85,0.80,-0.60,0.45,1.0,0.80,-0.45,0.40,-0.50,0.20,0.30,0.35,0.10},
    {0.55,0.75,0.65,0.60,0.80,-0.15,0.75,0.85,-0.55,0.70,0.80,1.0,-0.30,0.85,-0.45,0.15,0.25,0.20,0.10},
    {-0.30,-0.25,0.20,-0.20,-0.15,0.80,-0.40,-0.35,0.30,-0.20,-0.45,-0.30,1.0,-0.25,0.20,-0.10,0.05,0.05,0.50},
    {0.55,0.90,0.45,0.50,0.80,-0.10,0.40,0.70,-0.60,0.65,0.40,0.85,-0.25,1.0,-0.50,-0.30,0.25,0.20,0.10},
    {-0.65,-0.50,-0.40,-0.60,-0.40,0.05,-0.50,-0.45,0.60,-0.40,-0.50,-0.45,0.20,-0.50,1.0,-0.25,0.30,0.25,0.05},
    {0.20,0.15,0.25,0.20,0.10,-0.05,0.20,0.15,-0.25,0.10,0.20,0.15,-0.10,0.25,-0.25,1.0,0.15,0.20,0.05},
    {0.30,0.25,0.20,0.25,0.20,0.05,0.30,0.25,0.35,0.20,0.30,0.25,0.05,0.20,0.25,0.20,0.40,1.0,0.05},
    {0.25,0.20,0.30,0.20,0.15,0.05,0.35,0.30,0.30,0.15,0.35,0.20,0.05,0.20,0.25,0.20,0.40,1.0,0.05},
    {0.15,0.10,0.10,0.15,0.10,0.60,0.10,0.10,0.05,0.05,0.10,0.10,0.50,0.10,0.05,0.05,0.05,0.05,1.0}
};

// Global variables
string activeSymbols[];
int symbolCount;
double adjustedLotSize;
double adjustedHighVolLotSize;
bool tradeOpenedThisTick = false;
struct NewsEvent {
    datetime time;
    string currency;
    string description;
    string impact;
};
NewsEvent newsEvents[];
datetime lastNewsCheck = 0;
const int NEWS_CHECK_INTERVAL = 900;
bool webRequestFailed = false;
datetime lastTickTime = 0;
const int TICK_TIMEOUT_SECONDS = 60;
bool criticalError = false;
string lastErrorMessage = "";
int indicatorHandles[];
int maxHandles = 100;
bool managingPreexistingPositions = true;
datetime lastH1BarTime[];

// Auto-recovery globals
const int RECOVERY_RETRY_INTERVAL_SECONDS = 60;
datetime lastRecoveryAttempt = 0;

// Correlación dinámica
double dynamicCorrelationMatrix[][19];
datetime lastCorrelationUpdate = 0;
const int CORRELATION_UPDATE_INTERVAL_SECONDS = 900;

// Function declarations
string GetDeinitReasonText(int reason);
string ConcatenateSymbols(const string &symArray[], string separator);
string Trim(string s);
double GetMaxSpreadPoints(string symbol);
double GetATRMultiplier(string symbol);
double GetATRMultiplierTP(string symbol);
double GetSpread(string symbol);
double GetRSI(string symbol);
int CheckMACDSignal(string symbol);
double GetRecentHigh(string symbol);
double GetRecentLow(string symbol);
double GetATR(string symbol);
void AddIndicatorHandle(int handle);
void ReleaseIndicatorHandles();
bool FetchNewsFromWeb();
string ExtractHTMLTag(string text, string tag);
void FetchNewsFromCSV();
void FetchNewsEvents();
bool IsNewsHighImpactSoon(string symbol);
void ClosePositionsBeforeNews(string symbol);
bool IsLowLiquidityPeriod();
bool IsAllowedToOpenTrade(string symbol);
bool IsMarketOpen(string symbol);
bool IsVolumeSufficient(string symbol);
long GetEffectiveVolume(string symbol);
bool IsVolumeValid(string symbol);
long GetH1MarketDirection(string symbol);
void ManageBreakEven(string symbol);
void ManageTrailingStop(string symbol);
void ClosePositionsOnFriday();
void OpenPosition(string symbol, int direction);
void WriteToCSV(string csvLine);
void LogTrade(string time_str, string symbol, string action, string price_str, string lot_str, string sl_str, string tp_str, string reason);
void ManageOpenPositions(string symbol);
bool HasOpenPosition(string symbol);
void CloseAllPositivePositions();
double GetSupportM5(string symbol);
double GetResistanceM5(string symbol);
bool IsNearSupportM5(string symbol, double price);
bool IsNearResistanceM5(string symbol, double price);
double GetEMASlope(string symbol, int period, int bars);
bool AreAllDataAvailable(string symbol);
bool HasPreexistingPositions();
void SetPreexistingPositionsManaged();
bool CheckCorrelation(string symbol);
bool IsPositionProtected(string symbol, ulong ticket);
double GetMinEMASlope(string symbol);

// Auto-recovery
bool AreMinDataAvailable(string symbol);
bool AreMinDataAvailableAllSymbols();
bool TryRecoverFromCriticalError();

// Correlación dinámica
void UpdateCorrelationMatrix();
double CalculateCorrelation(string symbolA, string symbolB);

// ATR dinámico (nuevas)
double GetATRHistoricalAverageH1(string symbol, int bars);
bool PassesDynamicATRFilter(string symbol);

// Nueva función para verificar cambio de dirección de EMAs en H1
void CheckAndClosePositionsOnEMACross(string symbol);

// NUEVAS: Volumen real H1
long GetEffectiveRealVolume(string symbol);
bool HasRealVolume(string symbol);

// EA Initialization
int OnInit() {
    Print("Inicializando Experto 6.9 en ", _Symbol, " a las ", TimeToString(TimeCurrent()));
    criticalError = false;
    lastErrorMessage = "";
    
    // Check if the current symbol is in the list of managed symbols
    bool symbolInList = false;
    string initialSymbols[];
    StringSplit(SymbolsList, ',', initialSymbols);
    
    for(int i = 0; i < ArraySize(initialSymbols); i++) {
        if (Trim(initialSymbols[i]) == _Symbol) {
            symbolInList = true;
            break;
        }
    }
    
    // Create the activeSymbols array, adding the current symbol if not in the list
    if(!symbolInList) {
        ArrayResize(activeSymbols, ArraySize(initialSymbols) + 1);
        ArrayCopy(activeSymbols, initialSymbols);
        activeSymbols[ArraySize(initialSymbols)] = _Symbol;
        Print("Advertencia: El EA se esta ejecutando en un par que no esta en la lista de simbolos. Se ajustara la lista para incluirlo.");
    } else {
        ArrayResize(activeSymbols, ArraySize(initialSymbols));
        ArrayCopy(activeSymbols, initialSymbols);
    }
    
    symbolCount = ArraySize(activeSymbols);

    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
        lastErrorMessage = "ERROR CRITICO: AutoTrading desactivado en el terminal. Active 'Permitir Trading Automatico' en MT5.";
        Print(lastErrorMessage);
        Comment(lastErrorMessage);
        Alert(lastErrorMessage);
        return INIT_FAILED;
    }

    if (!TerminalInfoInteger((ENUM_TERMINAL_INFO_INTEGER)TERMINAL_WEB_REQUESTS_ALLOWED)) {
        lastErrorMessage = "ADVERTENCIA: Las peticiones web no estan habilitadas. Necesarias para noticias. El EA continuara sin noticias en linea.";
        Print(lastErrorMessage);
        Comment(lastErrorMessage);
    }
    
    int selectAttempts = 0;
    const int MAX_SELECT_ATTEMPTS = 5;
    bool eurUsdSelected = false;
    while (!SymbolSelect("EURUSD", true) && selectAttempts < MAX_SELECT_ATTEMPTS) {
        Print("Advertencia: Intento ", IntegerToString(selectAttempts + 1), " de seleccionar EURUSD fallo. Reintentando...");
        Sleep(1000);
        selectAttempts++;
    }
    if (SymbolSelect("EURUSD", true)) {
        eurUsdSelected = true;
    } else {
        lastErrorMessage = "ERROR CRITICO: No se pudo seleccionar EURUSD tras " + IntegerToString(MAX_SELECT_ATTEMPTS) + " intentos. Asegurese de que EURUSD este en la Observacion de Mercado.";
        Print(lastErrorMessage);
        Comment(lastErrorMessage);
        Alert(lastErrorMessage);
        return INIT_FAILED;
    }
    
    double tickSize = SymbolInfoDouble("EURUSD", SYMBOL_TRADE_TICK_SIZE);
    if (tickSize == 0.0) {
        lastErrorMessage = "ERROR CRITICO: No se pudieron obtener datos de mercado (tick size) para EURUSD. Verifique conexion y Observacion de Mercado.";
        Print(lastErrorMessage);
        Comment(lastErrorMessage);
        Alert(lastErrorMessage);
        return INIT_FAILED;
    }
    
    double minLot = SymbolInfoDouble("EURUSD", SYMBOL_VOLUME_MIN);
    if (minLot == 0.0) {
        lastErrorMessage = "ERROR CRITICO: No se pudo obtener lote minimo para EURUSD. Verifique conexion y Observacion de Mercado.";
        Print(lastErrorMessage);
        Comment(lastErrorMessage);
        Alert(lastErrorMessage);
        return INIT_FAILED;
    }
    
    adjustedLotSize = LotSize;
    adjustedHighVolLotSize = HighVolLotSize;
    
    if (LotSize < minLot) {
        Print("Advertencia: LotSize ", DoubleToString(LotSize, 2), " es menor que el lote minimo ", DoubleToString(minLot, 2), " para EURUSD. Ajustando al minimo.");
        adjustedLotSize = minLot;
    }
    
    for (int i = 0; i < symbolCount; i++) {
        string currentSymbol = Trim(activeSymbols[i]);
        selectAttempts = 0;
        bool symbolSuccessfullySelected = false;

        while (!SymbolSelect(currentSymbol, true) && selectAttempts < MAX_SELECT_ATTEMPTS) {
            Print("Advertencia: Intento ", IntegerToString(selectAttempts + 1), " de seleccionar ", currentSymbol, " fallo. Reintentando...");
            Sleep(1000);
            selectAttempts++;
        }

        if (SymbolSelect(currentSymbol, true)) {
            symbolSuccessfullySelected = true;
        } else {
            Print("Advertencia: No se pudo seleccionar " + currentSymbol + ". Ignorado.");
            Comment("Advertencia: No se pudo seleccionar " + currentSymbol + ". Ignorado.");
            string tempActiveSymbols[];
            int tempCount = 0;
            for(int j = 0; j < symbolCount; j++) {
                if(j != i) {
                    ArrayResize(tempActiveSymbols, tempCount + 1);
                    tempActiveSymbols[tempCount] = activeSymbols[j];
                    tempCount++;
                }
            }
            ArrayFree(activeSymbols);
            ArrayCopy(activeSymbols, tempActiveSymbols);
            symbolCount = ArraySize(activeSymbols);
            i--;
            continue;
        }

        double symbolMinLot = SymbolInfoDouble(currentSymbol, SYMBOL_VOLUME_MIN);
        if (symbolMinLot == 0.0) {
            Print("Advertencia: No se pudo obtener lote minimo para " + currentSymbol + ". Usando 0.1.");
            symbolMinLot = 0.1;
        }
        
        bool isHighVolSymbol = (currentSymbol == "USDMXN" || currentSymbol == "USDZAR" || currentSymbol == "GBPJPY" ||
                                currentSymbol == "NZDJPY" || currentSymbol == "XAUUSD" || currentSymbol == "EURTRY");
        if (isHighVolSymbol && HighVolLotSize < symbolMinLot) {
            Print("Advertencia: HighVolLotSize ", DoubleToString(HighVolLotSize, 2), " es menor que el lote minimo ", DoubleToString(symbolMinLot, 2), " para ", currentSymbol, ". Ajustando al minimo.");
            adjustedHighVolLotSize = MathMax(adjustedHighVolLotSize, symbolMinLot);
        } else if (!isHighVolSymbol && LotSize < symbolMinLot) {
            Print("Advertencia: LotSize ", DoubleToString(LotSize, 2), " es menor que el lote minimo ", DoubleToString(minLot, 2), " para ", currentSymbol, ". Ajustando al minimo.");
            adjustedLotSize = MathMax(adjustedLotSize, symbolMinLot);
        }
    }
    
    if (symbolCount == 0) {
        lastErrorMessage = "ERROR CRITICO: Ningun simbolo inicializado correctamente. Verifique lista de simbolos y Observacion de Mercado.";
        Print(lastErrorMessage);
        Comment(lastErrorMessage);
        Alert(lastErrorMessage);
        return INIT_FAILED;
    }
    
    ArrayResize(indicatorHandles, 0);
    FetchNewsEvents();
    
    ArrayResize(lastH1BarTime, symbolCount);
    for(int i = 0; i < symbolCount; i++) {
        MqlRates rates[];
        if (CopyRates(activeSymbols[i], PERIOD_H1, 0, 1, rates) > 0) {
            lastH1BarTime[i] = rates[0].time;
        } else {
            lastH1BarTime[i] = 0;
        }
    }

    // Init dynamic correlation matrix
    ArrayResize(dynamicCorrelationMatrix, symbolCount);
    for (int i = 0; i < symbolCount; i++) {
        for (int j = 0; j < 19; j++) dynamicCorrelationMatrix[i][j] = 0.0;
    }
    lastCorrelationUpdate = 0;
    UpdateCorrelationMatrix();

    Print("Inicializacion completada. Simbolos: ", IntegerToString(symbolCount), ", LotSize: ", DoubleToString(adjustedLotSize, 2), ", HighVolLotSize: ", DoubleToString(adjustedHighVolLotSize, 2));
    lastTickTime = TimeCurrent();
    Comment("Experto 6.9: Inicializacion exitosa. Trading activo.");
    Alert("Experto 6.9: Inicializacion exitosa. Trading activo.");
    return INIT_SUCCEEDED;
}

// Deinitialization
void OnDeinit(const int reason) {
    Print("Desinicializando Experto 6.9. Motivo: ", IntegerToString(reason), " (", GetDeinitReasonText(reason), ")");
    Print("Ultimo error: ", lastErrorMessage);
    Comment("");
    ReleaseIndicatorHandles();
    ArrayFree(activeSymbols);
    ArrayFree(newsEvents);
    Print("Recursos liberados. EA detenido.");
}

// Get deinitialization reason text
string GetDeinitReasonText(int reason) {
    switch (reason) {
        case REASON_PROGRAM:      return "EA detenido por el usuario";
        case REASON_REMOVE:       return "EA removido del grafico";
        case REASON_RECOMPILE:    return "EA recompilado";
        case REASON_CHARTCHANGE:  return "Cambio en propiedades del grafico";
        case REASON_CHARTCLOSE:   return "Grafico cerrado";
        case REASON_PARAMETERS:   return "Cambio en parametros de entrada";
        case REASON_ACCOUNT:      return "Cambio de cuenta";
        case REASON_TEMPLATE:     return "Cambio de plantilla";
        case REASON_INITFAILED:   return "Fallo en inicializacion";
        case REASON_CLOSE:        return "Terminal cerrado";
        default:                  return "Motivo desconocido (" + IntegerToString(reason) + ")";
    }
}

// Concatenate symbols
string ConcatenateSymbols(const string &symArray[], string separator) {
    string result = "";
    for (int i = 0; i < ArraySize(symArray); i++) {
        result += symArray[i];
        if (i < ArraySize(symArray) - 1) result += separator;
    }
    return result;
}

// Trim whitespace
string Trim(string s) {
    int start = 0;
    while (start < StringLen(s) && (ushort)s[start] <= ' ') start++;
    int end = StringLen(s) - 1;
    while (end > start && (ushort)s[end] <= ' ') end--;
    return StringSubstr(s, start, end - start + 1);
}

// Dynamic spread filter
double GetMaxSpreadPoints(string symbol) {
    if (symbol == "USDMXN") return 30.0;
    if (symbol == "USDZAR") return 35.0;
    if (symbol == "EURTRY") return 50.0;
    if (symbol == "GBPJPY" || symbol == "NZDJPY" || symbol == "XAUUSD") return 25.0;
    return 20.0;
}

// Dynamic ATR multiplier
double GetATRMultiplier(string symbol) {
    if (symbol == "USDMXN") return 1.5;
    if (symbol == "USDZAR") return 1.5;
    if (symbol == "GBPJPY") return 1.5;
    if (symbol == "NZDJPY") return 1.5;
    if (symbol == "XAUUSD") return 1.5;
    if (symbol == "EURTRY") return 2.0;
    return 1.2;
}

// Dynamic ATR multiplier for Take Profit
double GetATRMultiplierTP(string symbol) {
    if (symbol == "EURUSD") return 1.0;
    if (symbol == "GBPUSD") return 1.2;
    if (symbol == "USDJPY") return 1.0;
    if (symbol == "AUDUSD") return 1.0;
    if (symbol == "NZDUSD") return 1.0;
    if (symbol == "USDCAD") return 1.0;
    if (symbol == "USDCHF") return 1.0;
    if (symbol == "EURJPY") return 1.2;
    if (symbol == "GBPJPY") return 1.5;
    if (symbol == "EURGBP") return 1.0;
    if (symbol == "XAUUSD") return 1.5;
    if (symbol == "EURAUD") return 1.2;
    if (symbol == "AUDJPY") return 1.2;
    if (symbol == "CADJPY") return 1.2;
    if (symbol == "NZDJPY") return 1.5;
    if (symbol == "EURNZD") return 1.2;
    if (symbol == "USDMXN") return 2.0;
    if (symbol == "USDZAR") return 2.0;
    if (symbol == "EURTRY") return 2.5;
    return 1.0;
}

// Spread calculation
double GetSpread(string symbol) {
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if (point == 0.0 || ask == 0.0 || bid == 0.0) {
        lastErrorMessage = "ERROR: Market data (ask/bid/point) not available for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 20.0;
    }
    return (ask - bid) / point;
}

// Get RSI on M5
double GetRSI(string symbol) {
    int handle = iRSI(symbol, TimeFrame_Main, RSIPeriod, PRICE_CLOSE);
    if (handle == INVALID_HANDLE) {
        lastErrorMessage = "ERROR: Could not create RSI handle for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 50.0;
    }
    double buffer[];
    if (CopyBuffer(handle, 0, 0, 1, buffer) <= 0) {
        lastErrorMessage = "ERROR: Could not get RSI data for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        IndicatorRelease(handle);
        criticalError = true;
        return 50.0;
    }
    AddIndicatorHandle(handle);
    return buffer[0];
}

// MACD Signal on M5
int CheckMACDSignal(string symbol) {
    int handle = iMACD(symbol, TimeFrame_Main, MACDFastEMA, MACDSlowEMA, MACDSignalSMA, PRICE_CLOSE);
    if (handle == INVALID_HANDLE) {
        lastErrorMessage = "ERROR: Could not create MACD handle for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0;
    }
    double macd[], signal[];
    if (CopyBuffer(handle, 0, 0, 1, macd) <= 0 || CopyBuffer(handle, 1, 0, 1, signal) <= 0) {
        lastErrorMessage = "ERROR: Could not get MACD data for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        IndicatorRelease(handle);
        criticalError = true;
        return 0;
    }
    AddIndicatorHandle(handle);
    if (macd[0] > signal[0]) return 1;
    if (macd[0] < signal[0]) return -1;
    return 0;
}

// Recent high on M5
double GetRecentHigh(string symbol) {
    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_Main, 0, 50, rates) < 50) {
        lastErrorMessage = "ERROR: Could not get 50 M5 candles for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0.0;
    }
    double maxHigh = rates[0].high;
    for (int i = 1; i < 50; i++) {
        if (rates[i].high > maxHigh) maxHigh = rates[i].high;
    }
    return maxHigh;
}

// Recent low on M5
double GetRecentLow(string symbol) {
    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_Main, 0, 50, rates) < 50) {
        lastErrorMessage = "ERROR: Could not get 50 M5 candles for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0.0;
    }
    double minLow = rates[0].low;
    for (int i = 1; i < 50; i++) {
        if (rates[i].low < minLow) minLow = rates[i].low;
    }
    return minLow;
}

// ATR for volatility on H1
double GetATR(string symbol) {
    int handle = iATR(symbol, TimeFrame_H1, 14);
    if (handle == INVALID_HANDLE) {
        lastErrorMessage = "ERROR: Could not create ATR handle for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0.0;
    }
    double buffer[];
    if (CopyBuffer(handle, 0, 0, 1, buffer) <= 0) {
        lastErrorMessage = "ERROR: Could not get ATR data for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        IndicatorRelease(handle);
        criticalError = true;
        return 0.0;
    }
    AddIndicatorHandle(handle);
    return buffer[0];
}

// Get M5 support level
double GetSupportM5(string symbol) {
    bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
                            symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY");
    int barsToUse = isHighVolSymbol ? 20 : 50;
    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_Main, 0, barsToUse, rates) < barsToUse) {
        lastErrorMessage = "ERROR: Could not get " + IntegerToString(barsToUse) + " M5 candles for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0.0;
    }
    double support = rates[0].low;
    for (int i = 1; i < barsToUse; i++) {
        if (rates[i].low < support) support = rates[i].low;
    }
    return support;
}

// Get M5 resistance level
double GetResistanceM5(string symbol) {
    bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
                            symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY");
    int barsToUse = isHighVolSymbol ? 20 : 50;
    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_Main, 0, barsToUse, rates) < barsToUse) {
        lastErrorMessage = "ERROR: Could not get " + IntegerToString(barsToUse) + " M5 candles for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0.0;
    }
    double resistance = rates[0].high;
    for (int i = 1; i < barsToUse; i++) {
        if (rates[i].high > resistance) resistance = rates[i].high;
    }
    return resistance;
}

// Check if price is near M5 support
bool IsNearSupportM5(string symbol, double price) {
    double support = GetSupportM5(symbol);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if (point == 0.0) {
        lastErrorMessage = "ERROR: Point for " + symbol + " is 0 in IsNearSupportM5. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }
    double proximity = SR_PROXIMITY_PIPS * 10 * point;
    return MathAbs(price - support) <= proximity;
}

// Check if price is near M5 resistance
bool IsNearResistanceM5(string symbol, double price) {
    double resistance = GetResistanceM5(symbol);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if (point == 0.0) {
        lastErrorMessage = "ERROR: Point for " + symbol + " is 0 in IsNearResistanceM5. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }
    double proximity = SR_PROXIMITY_PIPS * 10 * point;
    return MathAbs(price - resistance) <= proximity;
}

// Add indicator handle
void AddIndicatorHandle(int handle) {
    for (int i = 0; i < ArraySize(indicatorHandles); i++) {
        if (indicatorHandles[i] == handle) return;
    }
    int size = ArraySize(indicatorHandles);
    if (size >= maxHandles) {
        lastErrorMessage = "ADVERTENCIA: Indicator handle limit reached (" + IntegerToString(maxHandles) + "). Releasing oldest.";
        Print(lastErrorMessage);
        IndicatorRelease(indicatorHandles[0]);
        for (int i = 0; i < size - 1; i++) {
            indicatorHandles[i] = indicatorHandles[i + 1];
        }
        size--;
    }
    ArrayResize(indicatorHandles, size + 1);
    indicatorHandles[size] = handle;
}

// Release indicator handles
void ReleaseIndicatorHandles() {
    for (int i = 0; i < ArraySize(indicatorHandles); i++) {
        if (indicatorHandles[i] != INVALID_HANDLE) {
            IndicatorRelease(indicatorHandles[i]);
        }
    }
    ArrayFree(indicatorHandles);
}

// Fetch news from Myfxbook
bool FetchNewsFromWeb() {
    string url = "https://www.myfxbook.com/forex-economic-calendar";
    string headers = "";
    char post[], result[];
    int timeout = 5000;
    int res = WebRequest("GET", url, headers, timeout, post, result, headers);
    if (res != 200) {
        lastErrorMessage = "ADVERTENCIA: WebRequest error: Code=" + IntegerToString(res) + ". Using news.csv as fallback.";
        Print(lastErrorMessage);
        webRequestFailed = true;
        return false;
    }
    string html = CharArrayToString(result);
    string lines[];
    StringSplit(html, '\n', lines);
    int eventCount = 0;
    for (int i = 0; i < ArraySize(lines); i++) {
        if (StringFind(lines[i], "high-impact", 0) >= 0) {
            NewsEvent event;
            string line_content = lines[i];
            string date_str = "";
            string time_str = "";
            string currency_str = "";
            string description_str = "";
            int pos_date = StringFind(line_content, "data-date=\"", 0);
            if(pos_date != -1) date_str = StringSubstr(line_content, pos_date + StringLen("data-date=\""), 10);
            int pos_time = StringFind(line_content, "data-time=\"", 0);
            if(pos_time != -1) time_str = StringSubstr(line_content, pos_time + StringLen("data-time=\""), 5);
            int pos_currency = StringFind(line_content, "data-currency=\"", 0);
            if(pos_currency != -1) currency_str = StringSubstr(line_content, pos_currency + StringLen("data-currency=\""), 3);
            int pos_desc = StringFind(line_content, "data-event-title=\"", 0);
            if(pos_desc != -1) description_str = StringSubstr(line_content, pos_desc + StringLen("data-event-title=\""), StringFind(line_content, "\"", pos_desc + StringLen("data-event-title=\"")) - (pos_desc + StringLen("data-event-title=\"")));
            if (date_str != "" && time_str != "" && currency_str != "" && description_str != "") {
                string dateTimeStr = date_str + " " + time_str;
                event.time = StringToTime(dateTimeStr);
                if (event.time == 0) continue;
                event.currency = currency_str;
                event.description = description_str;
                event.impact = "High";
                ArrayResize(newsEvents, eventCount + 1);
                newsEvents[eventCount] = event;
                eventCount++;
            }
        }
    }
    Print("High impact news loaded from web (UTC): ", IntegerToString(eventCount), " events.");
    webRequestFailed = (eventCount == 0);
    return eventCount > 0;
}

// Extract HTML tag
string ExtractHTMLTag(string text, string tag) {
    string startTag = "<" + tag + ">";
    string endTag = "</" + tag + ">";
    int start = StringFind(text, startTag, 0) + StringLen(startTag);
    int end = StringFind(text, endTag, start);
    if (start >= 0 && end > start) {
        return Trim(StringSubstr(text, start, end - start));
    }
    return "";
}

// Fetch news from CSV
void FetchNewsFromCSV() {
    ArrayResize(newsEvents, 0); // Limpiar el array
    int handle = FileOpen("news.csv", FILE_READ | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
    if (handle == INVALID_HANDLE) {
        lastErrorMessage = "ADVERTENCIA: Error abriendo news.csv: " + IntegerToString(GetLastError()) + ". Verifica la ubicación en Common\\Files.";
        Print(lastErrorMessage);
        return;
    }
    
    // Leer el encabezado
    string header = FileReadString(handle);
    if (header == "" || StringFind(header, "Date") < 0) {
        lastErrorMessage = "ADVERTENCIA: Encabezado inválido en news.csv. Se esperaba: Date. Encontrado: " + header;
        Print(lastErrorMessage);
        FileClose(handle);
        return;
    }
    // Descargar el resto del encabezado
    for (int i = 0; i < 4; i++) {
        FileReadString(handle); // Time, Currency, Description, Impact
    }
    Print("Encabezado leído: Date,Time,Currency,Description,Impact");
    
    string symbolCurrency1 = StringSubstr(_Symbol, 0, 3); // Ejemplo: "EUR"
    string symbolCurrency2 = StringSubstr(_Symbol, 3, 3); // Ejemplo: "USD"
    Print("Divisas del símbolo: ", symbolCurrency1, ", ", symbolCurrency2);
    
    int eventCount = 0;
    int lineCount = 0;
    
    while (!FileIsEnding(handle)) {
        string date = FileReadString(handle);
        string time = FileReadString(handle);
        string currency = FileReadString(handle);
        string description = FileReadString(handle);
        string impact = FileReadString(handle);
        lineCount++;
        
        // Verificar si la línea está vacía o incompleta
        if (date == "" || time == "" || currency == "" || description == "" || impact == "") {
            Print("Advertencia: Línea ", lineCount, " incompleta en news.csv: ", date, ",", time, ",", currency, ",", description, ",", impact);
            continue;
        }
        
        // Validar formato de fecha/hora
        if (StringLen(date) != 10 || StringFind(date, ".") != 4 || StringLen(time) != 5 || StringFind(time, ":") != 2) {
            Print("Advertencia: Formato de fecha/hora inválido en news.csv, línea ", lineCount, ": ", date, " ", time);
            continue;
        }
        
        // Convertir a datetime
        string datetimeStr = date + " " + time;
        datetime eventTime = StringToTime(datetimeStr);
        if (eventTime == 0) {
            Print("Advertencia: Conversión de fecha/hora fallida en news.csv, línea ", lineCount, ": ", datetimeStr);
            continue;
        }
        
        // Verificar si la divisa coincide
        if (StringCompare(currency, symbolCurrency1, false) == 0 || StringCompare(currency, symbolCurrency2, false) == 0) {
            NewsEvent event;
            event.time = eventTime;
            event.currency = currency;
            event.description = description;
            event.impact = impact;
                        ArrayResize(newsEvents, eventCount + 1);
            newsEvents[eventCount] = event;
            eventCount++;
            Print("Evento cargado para ", _Symbol, ", línea ", lineCount, ": ", date, " ", time, ", ", currency, ", ", description, ", ", impact, ", Timestamp: ", TimeToString(eventTime, TIME_DATE|TIME_MINUTES));
        } else {
            Print("Evento ignorado (divisa no coincide), línea ", lineCount, ": ", date, " ", time, ", ", currency, ", ", description, ", ", impact);
        }
    }
    
    FileClose(handle);
    Print("Noticias cargadas desde news.csv para ", _Symbol, " (UTC): ", IntegerToString(eventCount), " eventos de alto impacto.");
    if (eventCount == 0) {
        lastErrorMessage = "ADVERTENCIA: No se cargaron eventos de alto impacto desde news.csv para " + _Symbol + ". Verifica el contenido, fechas y divisas.";
        Print(lastErrorMessage);
    } else {
        // Imprimir eventos cargados para depuración
        for (int i = 0; i < eventCount; i++) {
            Print("Evento ", i + 1, ": ", TimeToString(newsEvents[i].time, TIME_DATE|TIME_MINUTES), ", ", newsEvents[i].currency, ", ", newsEvents[i].description, ", ", newsEvents[i].impact);
        }
    }
}

// Fetch news events
void FetchNewsEvents() {
    ArrayFree(newsEvents);
    if (!FetchNewsFromWeb()) {
        Print("Failed to get news from web. Using news.csv.");
        FetchNewsFromCSV();
    }
    if (ArraySize(newsEvents) == 0) {
        lastErrorMessage = "ADVERTENCIA: Could not get high impact news data. EA sin noticias.";
        Print(lastErrorMessage);
    }
}

// Check for high impact news
bool IsNewsHighImpactSoon(string symbol) {
    datetime now = TimeCurrent();
    if (now == 0) {
        lastErrorMessage = "ERROR: TimeCurrent() failed in IsNewsHighImpactSoon. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }
    for (int i = 0; i < ArraySize(newsEvents); i++) {
        if (newsEvents[i].impact != "High") continue;
        string baseCurrency = StringSubstr(symbol, 0, 3);
        string quoteCurrency = StringSubstr(symbol, 3, 3);
        if (newsEvents[i].currency == baseCurrency || newsEvents[i].currency == quoteCurrency) {
            long timeDiff = (long)newsEvents[i].time - (long)now;
            if (MathAbs(timeDiff) <= 1800) {
                if (timeDiff <= 300 && timeDiff >= 0) {
                    Print("High impact event within 5 min: ", newsEvents[i].description, " at ", TimeToString(newsEvents[i].time));
                    ClosePositionsBeforeNews(symbol);
                }
                return true;
            }
        }
    }
    return false;
}

// Close positions before news
void ClosePositionsBeforeNews(string symbol) {
    datetime now = TimeCurrent();
    if (now == 0) {
        lastErrorMessage = "ERROR: TimeCurrent() failed in ClosePositionsBeforeNews. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return;
    }
    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
            long type = m_position_info.PositionType();
            double price_open = m_position_info.PriceOpen();
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            if (bid == 0.0 || ask == 0.0) {
                lastErrorMessage = "ERROR: Prices not available for " + symbol + ". EA stopped.";
                Print(lastErrorMessage);
                criticalError = true;
                continue;
            }
            bool isPositive = (type == POSITION_TYPE_BUY && bid > price_open) ||
                              (type == POSITION_TYPE_SELL && ask < price_open);
            if (isPositive) {
                if (!trade.PositionClose(ticket)) {
                    lastErrorMessage = "ERROR: Error closing position: Symbol=" + symbol + ", Ticket=" + StringFormat("%I64u", ticket) + ", Error=" + IntegerToString(GetLastError()) + ". EA stopped.";
                    Print(lastErrorMessage);
                    criticalError = true;
                } else {
                    Print("Positive position closed before news: Symbol=", symbol, ", Ticket=", StringFormat("%I64u", ticket));
                    LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                             symbol,
                             (type == POSITION_TYPE_BUY ? "BuyClose" : "SellClose"),
                             DoubleToString((type == POSITION_TYPE_BUY ? bid : ask), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.Volume(), 2),
                             DoubleToString(m_position_info.StopLoss(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             "Closed Before News");
                }
            }
        }
    }
}

// Check low liquidity period
bool IsLowLiquidityPeriod() {
    datetime now = TimeCurrent();
    if (now == 0) {
        lastErrorMessage = "ERROR: TimeCurrent() failed in IsLowLiquidityPeriod. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }
    MqlDateTime tm;
    TimeToStruct(now, tm);
    tm.hour += (int)TimeZoneOffsetHours;
    if (tm.hour < 0) { tm.hour += 24; tm.day--; }
    return (tm.day_of_week == 0 && tm.hour < 22);
}

// Check if trading is allowed
bool IsAllowedToOpenTrade(string symbol) {
    if (!IsMarketOpen(symbol)) {
        if (criticalError) return false;
        lastErrorMessage = "Market closed for " + symbol + ". Trading blocked.";
        Print(lastErrorMessage);
        return false;
    }
    if (ArraySize(newsEvents) == 0) {
        lastErrorMessage = "ADVERTENCIA: No news data loaded for " + symbol + ". EA sin noticias.";
        Print(lastErrorMessage);
        return true;
    }
    datetime now = TimeCurrent();
    if (now == 0) {
        lastErrorMessage = "ERROR: TimeCurrent() failed in IsAllowedToOpenTrade. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }
    MqlDateTime tm;
    TimeToStruct(now, tm);
    tm.hour += (int)TimeZoneOffsetHours;
    if (tm.hour < 0) { tm.hour += 24; tm.day--; }
    long localHour = (long)tm.hour;
    if (tm.day_of_week == 5 && localHour >= BlockStartHourLocal) return false;
    if (localHour >= BlockStartHourLocal && localHour < BlockEndHourLocal) return false;
    if (IsLowLiquidityPeriod()) {
        if (criticalError) return false;
        return false;
    }
    if (IsNewsHighImpactSoon(symbol)) {
        if (criticalError) return false;
        return false;
    }
    return true;
}

// Check market status
bool IsMarketOpen(string symbol) {
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    if (bid == 0.0 || ask == 0.0) {
        lastErrorMessage = "ERROR: Market closed or Ask/Bid not available for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }
    return true;
}

// Is volume sufficient (H1 real volume if available, else tick volume with session thresholds)
bool IsVolumeSufficient(string symbol) {
    long tickVolume = GetEffectiveVolume(symbol);
    long realVolume = GetEffectiveRealVolume(symbol);
    bool useReal = (realVolume > 0);

    datetime now = TimeCurrent();
    MqlDateTime tm;
    TimeToStruct(now, tm);
    tm.hour += (int)TimeZoneOffsetHours;
    if (tm.hour < 0) { tm.hour += 24; tm.day--; }
    
    if (tm.hour >= 2 && tm.hour < 9) { // Asia
        if (useReal) {
            if (realVolume < MinRealVolume_Asia) return false;
        } else {
            if (tickVolume < MinTickVolume_Asia) return false;
        }
    } else if (tm.hour >= 9 && tm.hour < 16) { // London
        if (useReal) {
            if (realVolume < MinRealVolume_London) return false;
        } else {
            if (tickVolume < MinTickVolume_London) return false;
        }
    } else if (tm.hour >= 16 && tm.hour < 22) { // NY
        if (useReal) {
            if (realVolume < MinRealVolume_NY) return false;
        } else {
            if (tickVolume < MinTickVolume_NY) return false;
        }
    }
    return true;
}

// Get effective volume (H1 tick volume)
long GetEffectiveVolume(string symbol) {
    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_H1, 0, 1, rates) < 1) {
        return 0;
    }
    long tickVolume = rates[0].tick_volume;
    return tickVolume;
}

// Check if volume is valid
bool IsVolumeValid(string symbol) {
    long volume = GetEffectiveVolume(symbol);
    return volume > 0;
}

// Get H1 market direction
long GetH1MarketDirection(string symbol) {
    int ema20_handle = iMA(symbol, TimeFrame_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int ema50_handle = iMA(symbol, TimeFrame_H1, 50, 0, MODE_EMA, PRICE_CLOSE);

    if (ema20_handle == INVALID_HANDLE || ema50_handle == INVALID_HANDLE) {
        Print("ERROR: No se pudo crear el handle de EMA para ", symbol);
        return 0;
    }

    double ema20[], ema50[];
    if (CopyBuffer(ema20_handle, 0, 0, 2, ema20) < 2 || CopyBuffer(ema50_handle, 0, 0, 2, ema50) < 2) {
        Print("ERROR: No se pudieron copiar los datos de EMA para ", symbol);
        IndicatorRelease(ema20_handle);
        IndicatorRelease(ema50_handle);
        return 0;
    }
    
    IndicatorRelease(ema20_handle);
    IndicatorRelease(ema50_handle);

    // Filtrar cruces en los primeros 5 minutos de la vela H1
    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_H1, 0, 1, rates) < 1) {
        Print("ERROR: No se pudo obtener la vela H1 para ", symbol);
        return 0;
    }
    
    if (rates[0].time + PeriodSeconds(PERIOD_H1) < TimeCurrent()) {
        Print("ADVERTENCIA: Datos H1 desactualizados para ", symbol);
        return 0;
    }
    
    datetime current_bar_time = rates[0].time;
    long bar_age_seconds = TimeCurrent() - current_bar_time;

    // Obtener pendiente de la EMA 20
    double slope = GetEMASlope(symbol, 20, 1);
    
    // Obtener pendiente mínima según el símbolo
    double min_slope = GetMinEMASlope(symbol);

    string logMessage = StringFormat("EMA Trend Check for %s: EMA20[0]=%f, EMA50[0]=%f, Slope=%f, MinSlope=%f",
                                     symbol, ema20[0], ema50[0], slope, min_slope);
    Print(logMessage);

    // Interpretación de la pendiente
    if (bar_age_seconds < 300) { // 5 minutos
        Print("INFO: Ignorando cruces en la vela H1 en formacion para ", symbol);
        if (ema20[1] > ema50[1] && slope > min_slope) {
            Print("Tendencia alcista confirmada (vela en formación) para ", symbol);
            return 1; // Tendencia alcista
        } else if (ema20[1] < ema50[1] && slope < -min_slope) {
            Print("Tendencia bajista confirmada (vela en formación) para ", symbol);
            return -1; // Tendencia bajista
        }
        return 0; // Sin tendencia clara
    }

    // Tendencia confirmada con cruce de EMAs y pendiente
    if (ema20[0] > ema50[0] && slope > min_slope) {
        Print("Tendencia alcista confirmada para ", symbol);
        return 1; // Tendencia alcista
    } else if (ema20[0] < ema50[0] && slope < -min_slope) {
        Print("Tendencia bajista confirmada para ", symbol);
        return -1; // Tendencia bajista
    } else if (MathAbs(slope) <= min_slope) {
        Print("Sin tendencia clara (rango/lateral) para ", symbol);
        return 0; // Sin tendencia clara
    }

    return 0; // Sin tendencia clara por defecto
}

// Get minimum EMA slope
double GetMinEMASlope(string symbol) {
    if (symbol == "EURUSD") return 0.0004;
    if (symbol == "GBPUSD") return 0.0005;
    if (symbol == "USDJPY") return 0.04;
    if (symbol == "AUDUSD") return 0.0004;
    if (symbol == "NZDUSD") return 0.0004;
    if (symbol == "USDCAD") return 0.0004;
    if (symbol == "USDCHF") return 0.0003;
    if (symbol == "EURJPY") return 0.05;
    if (symbol == "GBPJPY") return 0.07;
    if (symbol == "EURGBP") return 0.0003;
    if (symbol == "XAUUSD") return 1.5;
    if (symbol == "EURAUD") return 0.0005;
    if (symbol == "AUDJPY") return 0.05;
    if (symbol == "CADJPY") return 0.05;
    if (symbol == "NZDJPY") return 0.05;
    if (symbol == "EURNZD") return 0.0006;
    if (symbol == "USDMXN") return 0.0100;
    if (symbol == "USDZAR") return 0.0150;
    if (symbol == "EURTRY") return 0.0250;
    return 0.0004; // Valor por defecto
}

// Manage Break Even - MODIFICADO: Siempre activar a 5 pips y SL a entrada + 1 pip
void ManageBreakEven(string symbol) {
    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
            long type = m_position_info.PositionType();
            double price_open = m_position_info.PriceOpen();
            double current_sl = m_position_info.StopLoss();
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            double profit_pips = 0;
            double new_sl_level = 0;

            if (bid == 0.0 || ask == 0.0 || point == 0.0) {
                lastErrorMessage = "ERROR: Precios o punto no disponibles para " + symbol + ". EA stopped.";
                Print(lastErrorMessage);
                criticalError = true;
                continue;
            }

            if (type == POSITION_TYPE_BUY) {
                profit_pips = (bid - price_open) / point;
                new_sl_level = price_open + BE_OFFSET_PIPS * point;
            } else if (type == POSITION_TYPE_SELL) {
                profit_pips = (price_open - ask) / point;
                new_sl_level = price_open - BE_OFFSET_PIPS * point;
            }

            // Break Even siempre a 5 pips exactos
            if (profit_pips >= BE_TRIGGER_PIPS && (current_sl == 0.0 || 
                (type == POSITION_TYPE_BUY && new_sl_level > current_sl) || 
                (type == POSITION_TYPE_SELL && new_sl_level < current_sl))) {
                if (trade.PositionModify(ticket, new_sl_level, m_position_info.TakeProfit())) {
                    Print("Break Even activado para ", symbol, ". SL movido a ", DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
                    LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                             symbol,
                             "BE",
                             DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.Volume(), 2),
                             DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             "Break Even Triggered");
                }
            }
        }
    }
}

// Manage Trailing Stop - MODIFICADO: Siempre activar a 5 pips y mover con pasos de 2 pips
void ManageTrailingStop(string symbol) {
    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
            long type = m_position_info.PositionType();
            double price_open = m_position_info.PriceOpen();
            double current_sl = m_position_info.StopLoss();
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            double profit_pips = 0;
            double new_sl_level = 0;

            if (bid == 0.0 || ask == 0.0 || point == 0.0) {
                lastErrorMessage = "ERROR: Precios o punto no disponibles para " + symbol + ". EA stopped.";
                Print(lastErrorMessage);
                criticalError = true;
                continue;
            }

            if (type == POSITION_TYPE_BUY) {
                profit_pips = (bid - price_open) / point;
                new_sl_level = bid - TRAILING_STEP_PIPS * point;
            } else if (type == POSITION_TYPE_SELL) {
                profit_pips = (price_open - ask) / point;
                new_sl_level = ask + TRAILING_STEP_PIPS * point;
            }

            // Trailing Stop siempre a 5 pips exactos con pasos de 2 pips
            if (profit_pips >= TRAILING_START_PIPS && ((type == POSITION_TYPE_BUY && new_sl_level > current_sl) || 
                (type == POSITION_TYPE_SELL && new_sl_level < current_sl))) {
                if (trade.PositionModify(ticket, new_sl_level, m_position_info.TakeProfit())) {
                    Print("Trailing Stop activado para ", symbol, ". SL movido a ", DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
                    LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                             symbol,
                             "TS",
                             DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.Volume(), 2),
                             DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             "Trailing Stop Triggered");
                }
            }
        }
    }
}

// Close positions on Friday
void ClosePositionsOnFriday() {
    datetime now = TimeCurrent();
    if (now == 0) {
        lastErrorMessage = "ERROR: TimeCurrent() failed in ClosePositionsOnFriday. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return;
    }
    MqlDateTime tm;
    TimeToStruct(now, tm);
    tm.hour += (int)TimeZoneOffsetHours;
    if (tm.hour < 0) { tm.hour += 24; tm.day--; }
    if (tm.day_of_week == 5 && tm.hour >= BlockStartHourLocal) {
        CloseAllPositivePositions();
    }
}

// Open position
void OpenPosition(string symbol, int direction) {
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double atr = GetATR(symbol);
    if (point == 0.0 || atr == 0.0 || ask == 0.0 || bid == 0.0) {
        lastErrorMessage = "ERROR: Market data not available for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return;
    }
    
    bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
                            symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY");
    double lot = isHighVolSymbol ? adjustedHighVolLotSize : adjustedLotSize;

    double tp_points_atr = atr * GetATRMultiplierTP(symbol) / point;
    if (isHighVolSymbol) {
        tp_points_atr = atr * GetATRMultiplierTP(symbol) * 0.3 / point;
    }

    if (direction == 1) { // Buy
        double resistance = GetResistanceM5(symbol);
        double level_pips = (resistance > ask) ? (resistance - ask) / point : tp_points_atr;
        double chosen_pips = MathMin(tp_points_atr, level_pips);
        double tp = ask + chosen_pips * point;

        if (!trade.Buy(lot, symbol, ask, 0.0, tp)) {
            lastErrorMessage = "ERROR: Buy order failed for " + symbol + ". Error=" + IntegerToString(GetLastError());
            Print(lastErrorMessage);
            return;
        }
        Print("Buy order placed for ", symbol, " at ", DoubleToString(ask, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
        LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                 symbol,
                 "Buy",
                 DoubleToString(ask, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                 DoubleToString(lot, 2),
                 "0.0",
                 DoubleToString(tp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                 "Open Buy");
    } else if (direction == -1) { // Sell
        double support = GetSupportM5(symbol);
        double level_pips = (support < bid) ? (bid - support) / point : tp_points_atr;
        double chosen_pips = MathMin(tp_points_atr, level_pips);
        double tp = bid - chosen_pips * point;

        if (!trade.Sell(lot, symbol, bid, 0.0, tp)) {
            lastErrorMessage = "ERROR: Sell order failed for " + symbol + ". Error=" + IntegerToString(GetLastError());
            Print(lastErrorMessage);
            return;
        }
        Print("Sell order placed for ", symbol, " at ", DoubleToString(bid, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
        LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                 symbol,
                 "Sell",
                 DoubleToString(bid, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                 DoubleToString(lot, 2),
                 "0.0",
                 DoubleToString(tp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                 "Open Sell");
    }
    tradeOpenedThisTick = true;
}

// Write to CSV
void WriteToCSV(string csvLine) {
    int handle = FileOpen("TradeLog.csv", FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ADD, ',');
    if (handle == INVALID_HANDLE) {
        lastErrorMessage = "ERROR: Could not open TradeLog.csv: " + IntegerToString(GetLastError());
        Print(lastErrorMessage);
        return;
    }
    FileWrite(handle, csvLine);
    FileClose(handle);
}

// Log trade
void LogTrade(string time_str, string symbol, string action, string price_str, string lot_str, string sl_str, string tp_str, string reason) {
    string csvLine = time_str + "," + symbol + "," + action + "," + price_str + "," + lot_str + "," + sl_str + "," + tp_str + "," + reason;
    WriteToCSV(csvLine);
    Print("Log: ", csvLine);
}

// Manage open positions
void ManageOpenPositions(string symbol) {
    ManageBreakEven(symbol);
    ManageTrailingStop(symbol);
}

// Check if there are open positions
bool HasOpenPosition(string symbol) {
    int total = PositionsTotal();
    for (int i = 0; i < total; i++) {
        ulong ticket = PositionGetTicket(i);
        if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
            return true;
        }
    }
    return false;
}

// Close all positive positions
void CloseAllPositivePositions() {
    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (m_position_info.SelectByTicket(ticket)) {
            string symbol = m_position_info.Symbol();
            long type = m_position_info.PositionType();
            double price_open = m_position_info.PriceOpen();
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            if (bid == 0.0 || ask == 0.0) {
                lastErrorMessage = "ERROR: Prices not available for " + symbol + ". EA stopped.";
                Print(lastErrorMessage);
                criticalError = true;
                continue;
            }
            bool isPositive = (type == POSITION_TYPE_BUY && bid > price_open) ||
                              (type == POSITION_TYPE_SELL && ask < price_open);
            if (isPositive) {
                if (!trade.PositionClose(ticket)) {
                    lastErrorMessage = "ERROR: Error closing position: Symbol=" + symbol + ", Ticket=" + StringFormat("%I64u", ticket) + ", Error=" + IntegerToString(GetLastError());
                    Print(lastErrorMessage);
                } else {
                    Print("Positive position closed: Symbol=", symbol, ", Ticket=", StringFormat("%I64u", ticket));
                    LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                             symbol,
                             (type == POSITION_TYPE_BUY ? "BuyClose" : "SellClose"),
                             DoubleToString((type == POSITION_TYPE_BUY ? bid : ask), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.Volume(), 2),
                             DoubleToString(m_position_info.StopLoss(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                             "Closed on Friday");
                }
            }
        }
    }
}

// Get EMA slope
double GetEMASlope(string symbol, int period, int bars) {
    int handle = iMA(symbol, TimeFrame_H1, period, 0, MODE_EMA, PRICE_CLOSE);
    if (handle == INVALID_HANDLE) {
        lastErrorMessage = "ERROR: Could not create EMA handle for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0.0;
    }
    double ema[];
    if (CopyBuffer(handle, 0, 0, bars + 1, ema) < bars + 1) {
        lastErrorMessage = "ERROR: Could not get EMA data for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        IndicatorRelease(handle);
        criticalError = true;
        return 0.0;
    }
    IndicatorRelease(handle);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if (point == 0.0) {
        lastErrorMessage = "ERROR: Point for " + symbol + " is 0 in GetEMASlope. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return 0.0;
    }
    return (ema[0] - ema[1]) / point;
}

// Check if all data is available
bool AreAllDataAvailable(string symbol) {
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double atr = GetATR(symbol);
    if (bid == 0.0 || ask == 0.0 || point == 0.0 || atr == 0.0) {
        lastErrorMessage = "ERROR: Market data not available for " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }
    return true;
}

// Check if there are preexisting positions
bool HasPreexistingPositions() {
    return PositionsTotal() > 0;
}

// Set preexisting positions as managed
void SetPreexistingPositionsManaged() {
    managingPreexistingPositions = false;
}

// Check correlation (uses dynamic matrix)
bool CheckCorrelation(string symbol) {
    int symbolIndex = -1;
    for (int i = 0; i < ArraySize(activeSymbols); i++) {
        if (activeSymbols[i] == symbol) {
            symbolIndex = i;
            break;
        }
    }
    if (symbolIndex == -1) return true;

    int total = PositionsTotal();
    bool allProtected = true;
    for (int i = 0; i < total; i++) {
        ulong ticket = PositionGetTicket(i);
        if (m_position_info.SelectByTicket(ticket)) {
            string posSymbol = m_position_info.Symbol();
            int posSymbolIndex = -1;
            for (int j = 0; j < ArraySize(activeSymbols); j++) {
                if (activeSymbols[j] == posSymbol) {
                    posSymbolIndex = j;
                    break;
                }
            }
            if (posSymbolIndex != -1) {
                double corr = 0.0;
                if (ArraySize(dynamicCorrelationMatrix) >= symbolCount) {
                    corr = dynamicCorrelationMatrix[symbolIndex][posSymbolIndex];
                } else {
                    corr = CorrelationMatrix[symbolIndex][posSymbolIndex];
                }
                if (MathAbs(corr) > CorrelationThreshold) {
                    if (!IsPositionProtected(posSymbol, ticket)) {
                        allProtected = false;
                        break;
                    }
                }
            }
        }
    }
    return allProtected;
}

// Check if position is protected
bool IsPositionProtected(string symbol, ulong ticket) {
    if (!m_position_info.SelectByTicket(ticket) || m_position_info.Symbol() != symbol) return false;
    
    long type = m_position_info.PositionType();
    double price_open = m_position_info.PriceOpen();
    double current_sl = m_position_info.StopLoss();
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    
    if (bid == 0.0 || ask == 0.0 || point == 0.0) {
        lastErrorMessage = "ERROR: Precios o punto no disponibles para " + symbol + ". EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        return false;
    }

    if (current_sl == 0.0) return false;

    if (type == POSITION_TYPE_BUY) {
        double profit_pips = (bid - price_open) / point;
        double be_level = price_open + BE_OFFSET_PIPS * point;
        double ts_level = bid - TRAILING_STEP_PIPS * point;
        return (profit_pips >= BE_TRIGGER_PIPS && current_sl >= be_level) || 
               (profit_pips >= TRAILING_START_PIPS && current_sl >= ts_level);
    } else if (type == POSITION_TYPE_SELL) {
        double profit_pips = (price_open - ask) / point;
        double be_level = price_open - BE_OFFSET_PIPS * point;
        double ts_level = ask + TRAILING_STEP_PIPS * point;
        return (profit_pips >= BE_TRIGGER_PIPS && current_sl <= be_level) || 
               (profit_pips >= TRAILING_START_PIPS && current_sl <= ts_level);
    }
    return false;
}

// Auto-recovery: minimal data availability for one symbol
bool AreMinDataAvailable(string symbol) {
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if (bid == 0.0 || ask == 0.0 || point == 0.0) return false;

    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_H1, 0, 1, rates) < 1) return false;

    return true;
}

// Auto-recovery: validate all symbols
bool AreMinDataAvailableAllSymbols() {
    for (int i = 0; i < symbolCount; i++) {
        if (!AreMinDataAvailable(activeSymbols[i])) return false;
    }
    return true;
}

// Auto-recovery: timed retry to clear criticalError when data is back
bool TryRecoverFromCriticalError() {
    datetime now = TimeCurrent();
    if (now == 0) return false;
    if (now - lastRecoveryAttempt < RECOVERY_RETRY_INTERVAL_SECONDS) return false;

    lastRecoveryAttempt = now;
    bool ok = AreMinDataAvailableAllSymbols();
    if (ok) {
        criticalError = false;
        lastErrorMessage = "";
        Print("INFO: Datos de mercado restaurados. EA reactivado automaticamente a ", TimeToString(now, TIME_DATE|TIME_MINUTES|TIME_SECONDS));
        Comment("Experto 6.9: Datos restaurados. Trading reactivado.");
        Alert("Experto 6.9: Datos restaurados. Trading reactivado.");
        return true;
    } else {
        Print("ADVERTENCIA: Intento de recuperacion fallido. Datos aun no disponibles (", TimeToString(now, TIME_DATE|TIME_MINUTES|TIME_SECONDS), ")");
        return false;
    }
}

// Update dynamic correlation matrix (every 15 minutes)
void UpdateCorrelationMatrix() {
    datetime now = TimeCurrent();
    if (now == 0) return;
    if (now - lastCorrelationUpdate < CORRELATION_UPDATE_INTERVAL_SECONDS) return;

    for (int i = 0; i < symbolCount; i++) {
        for (int j = i; j < symbolCount; j++) {
            double corr = 1.0;
            if (i == j) {
                corr = 1.0;
            } else {
                corr = CalculateCorrelation(activeSymbols[i], activeSymbols[j]);
            }
            dynamicCorrelationMatrix[i][j] = corr;
            dynamicCorrelationMatrix[j][i] = corr;
        }
        // Zero out unused columns beyond symbolCount (keep fixed second dim 19)
        for (int k = symbolCount; k < 19; k++) {
            dynamicCorrelationMatrix[i][k] = 0.0;
        }
    }
    lastCorrelationUpdate = now;
    Print("Matriz de correlacion dinamica actualizada a ", TimeToString(now, TIME_DATE|TIME_MINUTES));
}

// Pearson correlation on last 100 H1 bars (simple returns)
double CalculateCorrelation(string symbolA, string symbolB) {
    const int barsNeeded = 101; // 100 returns
    double closesA[], closesB[];

    int gotA = CopyClose(symbolA, PERIOD_H1, 0, barsNeeded, closesA);
    int gotB = CopyClose(symbolB, PERIOD_H1, 0, barsNeeded, closesB);
    if (gotA < barsNeeded || gotB < barsNeeded) return 0.0;

    int N = MathMin(gotA, gotB) - 1;
    if (N < 10) return 0.0;

    double meanA = 0.0, meanB = 0.0;
    static double retA[200], retB[200];
    for (int i = 0; i < N; i++) {
        double rA = (closesA[i] - closesA[i+1]) / closesA[i+1];
        double rB = (closesB[i] - closesB[i+1]) / closesB[i+1];
        retA[i] = rA;
        retB[i] = rB;
        meanA += rA;
        meanB += rB;
    }
    meanA /= N;
    meanB /= N;

    double cov = 0.0, varA = 0.0, varB = 0.0;
    for (int i = 0; i < N; i++) {
        double da = retA[i] - meanA;
        double db = retB[i] - meanB;
        cov += da * db;
        varA += da * da;
        varB += db * db;
    }
    if (varA <= 0.0 || varB <= 0.0) return 0.0;

    double corr = cov / MathSqrt(varA * varB);
    if (corr > 1.0) corr = 1.0;
    if (corr < -1.0) corr = -1.0;
    return corr;
}

// ATR histórico promedio (H1): media de las últimas 'bars' lecturas del buffer de ATR(14)
double GetATRHistoricalAverageH1(string symbol, int bars) {
    int handle = iATR(symbol, PERIOD_H1, 14);
    if (handle == INVALID_HANDLE) {
        Print("ADVERTENCIA: No se pudo crear handle ATR para promedio en ", symbol);
        return 0.0;
    }
    if (bars < 1) bars = 1;
    double buf[];
    int got = CopyBuffer(handle, 0, 0, bars, buf);
    IndicatorRelease(handle);
    if (got < bars) {
        Print("ADVERTENCIA: No se pudieron copiar ", IntegerToString(bars), " valores ATR para ", symbol, ". got=", IntegerToString(got));
        return 0.0;
    }
    double sum = 0.0;
    for (int i = 0; i < bars; i++) sum += buf[i];
    return (sum / bars);
}

// Filtro ATR dinámico en H1: true si se permite operar, false si se bloquea por volatilidad extrema
bool PassesDynamicATRFilter(string symbol) {
    // ATR actual
    double atrCurrent = GetATR(symbol);
    if (criticalError) return false;
    if (atrCurrent <= 0.0) return false;

    // ATR promedio histórico (50 velas H1)
    const int ATR_AVG_BARS = 50;
    double atrAvg = GetATRHistoricalAverageH1(symbol, ATR_AVG_BARS);
    if (atrAvg <= 0.0) {
        // Si no hay dato promedio, no bloquear para no paralizar el EA (ya hay validaciones previas)
        Print("INFO: ATR promedio no disponible para ", symbol, ". Se omite bloqueo por ATR.");
        return true;
    }

    // Factor por sesión (Quito)
    datetime now = TimeCurrent();
    MqlDateTime tm;
    TimeToStruct(now, tm);
    tm.hour += (int)TimeZoneOffsetHours;
    if (tm.hour < 0) { tm.hour += 24; tm.day--; }
    double sessionFactor = 1.0; // Base
    if (tm.hour >= 2 && tm.hour < 9) { // Asia: más estricto
        sessionFactor = 0.9;
    } else if (tm.hour >= 9 && tm.hour < 16) { // Londres: más flexible
        sessionFactor = 1.10;
    } else if (tm.hour >= 16 && tm.hour < 22) { // NY: aún más flexible
        sessionFactor = 1.15;
    }

    // Relajar umbral si hay tendencia clara en H1
    long trendDir = GetH1MarketDirection(symbol); // 1/-1/0
    double trendRelax = (trendDir != 0 ? 1.10 : 1.0);

    // Ajuste por par (volatilidad específica)
    double pairMult = GetATRMultiplier(symbol);

    // Umbral dinámico final
    double thresholdATR = atrAvg * ATR_THRESHOLD_MULTIPLIER * pairMult * sessionFactor * trendRelax;

    bool pass = (atrCurrent <= thresholdATR);
    if (!pass) {
        Print("ATR filter: bloqueo por alta volatilidad en ", symbol,
              ". ATR actual=", DoubleToString(atrCurrent, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
              " > umbral=", DoubleToString(thresholdATR, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
              " [avg=", DoubleToString(atrAvg, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
              ", pairMult=", DoubleToString(pairMult, 2),
              ", sesion=", DoubleToString(sessionFactor, 2),
              ", trendRelax=", DoubleToString(trendRelax, 2), "]");
    }
    return pass;
}

// NUEVA FUNCIÓN: Verificar y cerrar posiciones cuando las EMAs cambien de dirección en H1
void CheckAndClosePositionsOnEMACross(string symbol) {
    int ema20_handle = iMA(symbol, TimeFrame_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int ema50_handle = iMA(symbol, TimeFrame_H1, 50, 0, MODE_EMA, PRICE_CLOSE);

    if (ema20_handle == INVALID_HANDLE || ema50_handle == INVALID_HANDLE) {
        Print("ERROR: No se pudo crear el handle de EMA para verificar cruce en ", symbol);
        return;
    }

    double ema20[], ema50[];
    if (CopyBuffer(ema20_handle, 0, 0, 2, ema20) < 2 || CopyBuffer(ema50_handle, 0, 0, 2, ema50) < 2) {
                Print("ERROR: No se pudieron copiar los datos de EMA para verificar cruce en ", symbol);
        IndicatorRelease(ema20_handle);
        IndicatorRelease(ema50_handle);
        return;
    }
    
    IndicatorRelease(ema20_handle);
    IndicatorRelease(ema50_handle);

    // Verificar si hay cambio de dirección en las EMAs
    bool ema20_above_ema50_current = (ema20[0] > ema50[0]);
    bool ema20_above_ema50_previous = (ema20[1] > ema50[1]);
    
    // Si hay cambio de dirección, cerrar posiciones opuestas
    if (ema20_above_ema50_current != ema20_above_ema50_previous) {
        int total = PositionsTotal();
        for (int i = total - 1; i >= 0; i--) {
            ulong ticket = PositionGetTicket(i);
            if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
                long type = m_position_info.PositionType();
                bool shouldClose = false;
                string closeReason = "";
                
                // Si EMA20 cruza por encima de EMA50 (tendencia alcista), cerrar ventas
                if (ema20_above_ema50_current && type == POSITION_TYPE_SELL) {
                    shouldClose = true;
                    closeReason = "EMA Cross: EMA20 > EMA50 (Tendencia Alcista)";
                }
                // Si EMA20 cruza por debajo de EMA50 (tendencia bajista), cerrar compras
                else if (!ema20_above_ema50_current && type == POSITION_TYPE_BUY) {
                    shouldClose = true;
                    closeReason = "EMA Cross: EMA20 < EMA50 (Tendencia Bajista)";
                }
                
                if (shouldClose) {
                    if (trade.PositionClose(ticket)) {
                        Print("Posición cerrada por cambio de dirección de EMAs en H1: ", symbol, 
                              ", Ticket: ", StringFormat("%I64u", ticket), 
                              ", Tipo: ", (type == POSITION_TYPE_BUY ? "Compra" : "Venta"),
                              ", Razón: ", closeReason);
                        
                        double closePrice = (type == POSITION_TYPE_BUY) ? 
                            SymbolInfoDouble(symbol, SYMBOL_BID) : 
                            SymbolInfoDouble(symbol, SYMBOL_ASK);
                            
                        LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                                 symbol,
                                 (type == POSITION_TYPE_BUY ? "BuyClose" : "SellClose"),
                                 DoubleToString(closePrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                                 DoubleToString(m_position_info.Volume(), 2),
                                 DoubleToString(m_position_info.StopLoss(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                                 DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                                 closeReason);
                    } else {
                        Print("ERROR: No se pudo cerrar posición por cambio de EMAs: ", symbol, 
                              ", Ticket: ", StringFormat("%I64u", ticket), 
                              ", Error: ", IntegerToString(GetLastError()));
                    }
                }
            }
        }
    }
}

// NUEVAS: Volumen real H1
long GetEffectiveRealVolume(string symbol) {
    MqlRates rates[];
    if (CopyRates(symbol, TimeFrame_H1, 0, 1, rates) < 1) {
        return 0;
    }
    long realVol = (long)rates[0].real_volume;
    return realVol;
}

bool HasRealVolume(string symbol) {
    return (GetEffectiveRealVolume(symbol) > 0);
}

// OnTick function
void OnTick() {
    datetime now = TimeCurrent();

    // Si hubo error crítico, intentar recuperarse de forma temporizada
    if (criticalError) {
        if (TryRecoverFromCriticalError()) {
            // Recuperado, continuar flujo normal
        } else {
            if (now != 0 && now - lastTickTime > TICK_TIMEOUT_SECONDS) {
                Print("ADVERTENCIA: No ticks received for ", IntegerToString(TICK_TIMEOUT_SECONDS), " seconds. Last tick: ", TimeToString(lastTickTime));
            }
            Comment("EA detenido: ", lastErrorMessage, " | Recuperacion en curso...");
            return;
        }
    }

    if (now == 0) {
        lastErrorMessage = "ERROR: TimeCurrent() failed in OnTick. EA stopped.";
        Print(lastErrorMessage);
        criticalError = true;
        Comment(lastErrorMessage);
        return;
    }

    if (now - lastTickTime > TICK_TIMEOUT_SECONDS) {
        lastErrorMessage = "ADVERTENCIA: No ticks received for " + IntegerToString(TICK_TIMEOUT_SECONDS) + " seconds. Last tick: " + TimeToString(lastTickTime);
        Print(lastErrorMessage);
    }
    lastTickTime = now;

    if (now - lastNewsCheck >= NEWS_CHECK_INTERVAL) {
        FetchNewsEvents();
        lastNewsCheck = now;
    }

    // Actualizar matriz de correlación dinámica
    UpdateCorrelationMatrix();

    for (int i = 0; i < symbolCount; i++) {
        string symbol = activeSymbols[i];
        if (!AreAllDataAvailable(symbol)) continue;

        MqlRates rates[];
        if (CopyRates(symbol, TimeFrame_H1, 0, 1, rates) < 1) continue;
        if (rates[0].time > lastH1BarTime[i]) {
            lastH1BarTime[i] = rates[0].time;
            ClosePositionsOnFriday();
        }

        // NUEVA FUNCIÓN: Verificar y cerrar posiciones por cambio de dirección de EMAs en H1
        CheckAndClosePositionsOnEMACross(symbol);

        ManageOpenPositions(symbol);

        if (managingPreexistingPositions && HasPreexistingPositions()) {
            SetPreexistingPositionsManaged();
        }

        // Filtros obligatorios previos a condiciones de entrada
        if (!IsAllowedToOpenTrade(symbol)) continue;
        if (GetSpread(symbol) > GetMaxSpreadPoints(symbol)) continue;
        if (!IsVolumeSufficient(symbol)) continue;
        if (!CheckCorrelation(symbol)) continue;
        // Eliminado el bloqueo genérico por posición abierta en el mismo par:
        // if (HasOpenPosition(symbol)) continue;

        // Filtro de ATR dinámico en H1 (bloqueo por picos de volatilidad)
        if (!PassesDynamicATRFilter(symbol)) continue;

        // Señales M5: S/R + RSI + MACD obligatorios
        double rsi = GetRSI(symbol);
        if (criticalError) return;

        int macdSignal = CheckMACDSignal(symbol);
        if (criticalError) return;

        double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
        if (bid == 0.0 || ask == 0.0) continue;

        // Compra: cerca de soporte M5 + RSI<=30 + MACD alcista
        if (IsNearSupportM5(symbol, bid) && rsi <= RSIOversold && macdSignal == 1) {
            OpenPosition(symbol, 1);
            if (criticalError) return;
        }
        // Venta: cerca de resistencia M5 + RSI>=70 + MACD bajista
        else if (IsNearResistanceM5(symbol, ask) && rsi >= RSIOverbought && macdSignal == -1) {
            OpenPosition(symbol, -1);
            if (criticalError) return;
        }
    }
}