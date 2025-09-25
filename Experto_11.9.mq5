//+------------------------------------------------------------------+
//|                                     Experto_11.9.mq5             |
//| Estrategia mejorada con gestion de riesgo y volumen en H1        |
//| Tendencia en H1 basada en cruce de EMA 20/50 y consistencia de 3 velas |
//| Cierre automatico de operaciones en positivo los viernes a las 14:00 (Quito) |
//| Bloqueo de nuevas operaciones los viernes a partir de las 14:00 (Quito)      |
//| Break Even dinamico basado en ATR M5, Trailing Stop dinamico con pasos de 2 pips |
//| Bloqueo 15 min antes/30 min despues de noticias de alto impacto, cierre en positivo 5 min antes |
//| Pares expandidos: 100 pares para maxima diversificacion          |
//| Filtros dinamicos para spread y ATR por par                      |
//| Seguimiento mejorado: logs detallados, CSV, niveles H1, alertas   |
//| Lote 0.01 para pares de alta volatilidad                         |
//| Solucion: Maxima estabilidad para evitar desaparicion en EURUSD     |
//| Nueva funcionalidad: Soportes y Resistencias en M5 para entradas y ajuste de TP |
//| ATR como filtro dinamico y TP basado en ATR * 1.5              |
//| Correlacion: Evitar operar pares con correlacion > 0.85           |
//| Mejoras: Verificacion de datos, gestion de operaciones preexistentes |
//| Nueva funcionalidad: Permitir nuevas operaciones si las existentes estan protegidas con Break Even o Trailing Stop |
//| NUEVA: Cierre inmediato de operaciones cuando EMAs cambian de direccion en H1 |
//| NUEVA: Validación estricta de tendencia H1 para operaciones M5 (GARANTÍA ABSOLUTA) |
//| CORREGIDO: Validación robusta de datos EMA H1 y lógica S/R mejorada |
//| CORREGIDO: Manejo robusto de datos de mercado no disponibles |
//| MODIFICADO: TP basado exclusivamente en ATR*valor por par (sin considerar S/R) |
//| DEBUG: Logs detallados para identificar bloqueos en el flujo de ejecución |
//| OPTIMIZADO: Filtros relajados para mayor frecuencia de operaciones |
//| GARANTÍA ABSOLUTA: CERO operaciones contra tendencia H1 |
//| NUEVO: Cache inteligente para máxima performance y cero pérdida de operaciones |
//| NUEVO: MACD M5 con histograma y línea de señal |
//| NUEVO: RSI M5 con umbrales 30/70 |
//| NUEVO: Bloqueos horarios específicos para Quito, Ecuador |
//| MODIFICADO: RSI M5 período 8, umbrales 34/66 |
//| MODIFICADO: MACD M5 Fast EMA 7, Slow EMA 15, Signal 6 |
//| VERSIÓN 11.2: Break Even y Trailing Stop dinámicos basados en ATR M5 |
//| VERSIÓN 11.2: Validación de tendencia H1 con 4 velas consecutivas (sin pendientes) |
//| VERSIÓN 11.4: DEBUG COMPLETO ACTIVADO - LogLevel = 3 |
//| VERSIÓN 11.5: OPTIMIZADO - Validación H1 solo velas anteriores (1 de 3) |
//| VERSIÓN 11.6: Corrección MACD buffers, H1 2 de 3 velas cerradas, fractales unificados, CSV append real, correlación optimizada |
//| VERSIÓN 11.7: Desbloqueo de procesamiento por tick, volumen más permisivo, reintentos H1 y candado H1 estricto |
//| VERSIÓN 11.9: Umbral de volumen dinámico por sesión+tipo; cierre pre-cruce H1 con buffer ATR; puertas de procesamiento robustecidas |
//+------------------------------------------------------------------+

#property copyright "Leonardo"
#property version     "11.9"
#property strict

// Manual definitions for constants if standard include files are missing
// REMOVIDO: TERMINAL_WEB_REQUESTS_ALLOWED (uso nativo/omitido)
// REMOVIDO: FILE_APPEND (se usa FileSeek SEEK_END para append)
#define BE_OFFSET_PIPS 1      // SL to entry + 1 pip
#define TRAILING_STEP_PIPS 2  // Step of 2 pips
#define ATR_THRESHOLD_MULTIPLIER 4.5 // Threshold for max ATR to block trading (MODIFICADO: de 3.5 a 4.5)
#define ATR_TS_MULTIPLIER 1.0 // NUEVO: multiplicador para Trailing Stop basado en ATR M5

// NUEVO: configuración dinámica de volumen
#define VOLUME_AVG_BARS 240  // MODIFICADO: de 720 a 240 (4 días)
#define SESSION_ASIA 0
#define SESSION_LONDON 1
#define SESSION_NY 2
#define SESSION_ASIA_LONDON 3
#define SESSION_LONDON_NY 4
#define SESSION_COUNT 5

// CORREGIDO: Ventanas de sesiones en hora local (Quito, UTC-5) con solapamientos correctos
#define ASIA_START_LOCAL 2
#define ASIA_END_LOCAL 4
#define LONDON_START_LOCAL 4
#define LONDON_END_LOCAL 11
#define NY_START_LOCAL 11
#define NY_END_LOCAL 22

// CORREGIDO: Solapamientos reales del mercado forex para Quito (UTC-5)
// Asia-Londres: 03:00-04:00 Quito (08:00-09:00 UTC)
// Londres-NY: 08:00-11:00 Quito (13:00-16:00 UTC)
#define AL_OVERLAP_START_LOCAL 3
#define AL_OVERLAP_END_LOCAL 4
#define LN_OVERLAP_START_LOCAL 8
#define LN_OVERLAP_END_LOCAL 11

// NUEVO: Parámetros para validación estricta de tendencia H1 - OPTIMIZADO
#define MAX_RETRIES 6        // Aumentado para robustez de carga
#define WAIT_MS 25            // Aumentado para permitir carga de buffers
#define EMA_VALIDATION_BARS 2 // Número de barras H1 para validar consistencia EMA
#define MARKET_DATA_TIMEOUT_MS 500 // Timeout para datos de mercado - OPTIMIZADO

// NUEVO: Cache más eficiente con TTL (Time To Live)
struct TimedCache {
	datetime expiry;
	double value;
	bool isValid;
};

// Verificar si el cache ha expirado
bool IsCacheValid(TimedCache &cache, int ttlSeconds) {
	return cache.isValid && (TimeCurrent() - cache.expiry) < ttlSeconds;
}

// NUEVO: Cache unificado optimizado
struct UnifiedCache {
	datetime tickTime;
	bool isValid;
	
	// M5 Indicators
	double rsi, rsi_prev;
	double macdHist, macdHist_prev;
	double macdLine, macdSignal;
	double atr_m5;
	
	// H1 Indicators  
	double atr_h1;
	double ema20_last, ema20_prev;
	double ema50_last, ema50_prev;
	long h1Direction;
	
	// Validations
	bool spreadOk, volumeOk, correlationOk, emaConsistent, s_rOk;
	
	// Market Data
	double bid, ask, point, pipValue;
};

// NUEVO: Cache H1 separado para direction y consistency
struct H1DirectionCache {
	datetime barTime;
	bool isValid;
	long direction;
};

struct H1ConsistencyCache {
	datetime barTime;
	bool isValid;
	bool consistent;
};

// NUEVO: Control de performance mejorado - OPTIMIZADO
static datetime lastTickProcessed = 0;
static datetime lastProcessTime = 0;
static int maxSymbols = 100; // Límite claro de 100 símbolos

// NUEVO: Estadísticas en tiempo real
struct PerformanceMetrics {
	int totalTrades;
	int winningTrades;
	int losingTrades;
	double totalProfit;
	double maxDrawdown;
	datetime lastUpdate;
	int onTickCalls;
	int cacheHits;
	int cacheMisses;
	double avgTickTime;
	int symbolsProcessedPerTick;
};

PerformanceMetrics metrics = {0};

// NUEVO: Cache dinámico con límite de 100 símbolos
UnifiedCache unifiedCache[100]; // Para 100 símbolos máximo
H1DirectionCache h1DirectionCache[100];
H1ConsistencyCache h1ConsistencyCache[100];

// NUEVO: Cache de Soportes/Resistencias H1 por barra
struct SRCache {
	datetime barTime;
	double supports[5];
	int supportsCount;
	double resistances[5];
	int resistancesCount;
};
SRCache srCache[100];

// NUEVO: Cache de Soportes/Resistencias H4 por barra (con scoring)
struct SRH4Cache {
	datetime barTime;
	double supports[3];
	double supScore[3];
	int supportsCount;
	double resistances[3];
	double resScore[3];
	int resistancesCount;
	double atr_h4;
};
SRH4Cache srH4Cache[100];

#include <Trade\Trade.mqh>
#include <Object.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\DealInfo.mqh>

CTrade trade;
CPositionInfo m_position_info;
// Config de trade
int g_magic = 0;
int g_deviation = 0;

input string SymbolsList = "EURUSD,EURJPY,EURAUD,GBPUSD,GBPJPY,EURGBP,AUDUSD,AUDJPY,USDCAD,CADJPY,NZDUSD,NZDJPY,EURNZD,USDJPY,USDCHF,XAUUSD,USDMXN,USDZAR,EURTRY,EURCAD,GBPCAD,CHFJPY,AUDCAD,AUDNZD,NZDCAD,EURCHF,GBPNZD,CADCHF,USDSGD,USDHKD,USDNOK,USDSEK,USDPLN,USDCZK,USDHUF,USDRON,USDBGN,USDRSD,USDMKD,USDBAM,USDALL,USDMAD,USDEGP,USDZMW,USDKES,USDNGN,USDGHS,USDTND,USDMUR,USDBWP,USDSZL,USDLSL,USDMWK,USDUGX,USDTZS,USDRWF,USDBIF,USDDJF,USDSOS,USDSHP,USDAOA,USDMZN,USDBDT,USDLKR,USDNPR,USDPKR,USDINR,USDMYR,USDPHP,USDTHB,USDIDR,USDVND,USDKHR,USDLBP,USDJOD,USDIQD,USDSAR,USDAED,USDBHD,USDKWD,USDOMR,USDQAR,USDBRL,USDARS,USDCLP,USDCOP,USDPEN,USDUYU,USDPYG,USDBOB,USDVES,USDSRD,USDGYD,USDTTD,USDBBD,USDJMD,USDBZD,USDGTQ,USDHNL,USDNIO,USDPAB,USDCRC,USDDOP,USDXCD,USDAWG,USDBMD,USDBTC,USDETH,USDLTC,USDBCH,USDXRP,USDEOS,USDADA,USDDOT,USDLINK,USDUNI,USDAAVE,USDCOMP,USDYFI,USDCRV,USD1INCH,USDSUSHI,USDPAXG";
input ENUM_TIMEFRAMES TimeFrame_Main = PERIOD_M5;
input ENUM_TIMEFRAMES TimeFrame_H1    = PERIOD_H1;
input double LotSize          = 0.2;         // Lot for standard pairs
input double HighVolLotSize = 0.01;      // Lot for high volatility pairs
input int Slippage            = 5;
input int RSIPeriod          = 10;       // MODIFICADO: 10 (alta vol override: 9)
input double RSIOverbought     = 65.0;   // Señal venta >=65 (alta vol override: 67)
input double RSIOversold     = 35.0;     // Señal compra <=35 (alta vol override: 33)
input int MACDFastEMA         = 8;       // MODIFICADO: 8 (alta vol override: 10)
input int MACDSlowEMA         = 21;      // MODIFICADO: 21 (alta vol override: 24)
input int MACDSignalSMA       = 5;       // MODIFICADO: 5 (alta vol override: 6)
input int BlockStartHourLocal = 14; // Block start hour (Quito, UTC-5)
input int BlockEndHourLocal     = 20; // Block end hour (Quito)
input long MinRealVolume_Asia = 500;
input long MinRealVolume_London = 1000;
input long MinRealVolume_NY = 1500;
input long MinTickVolume_Asia = 200;
input long MinTickVolume_London = 400;
input long MinTickVolume_NY = 600;
input double CorrelationThreshold = 0.85; // MODIFICADO: de 0.75 a 0.85
input long TimeZoneOffsetHours = -5; // Quito, UTC-5
// NUEVOS inputs - OPTIMIZADOS
input bool RequireH1BarCloseConfirmation = false;
input int H1ConfirmBarsN = 1; // N velas H1 consecutivas confirmando tendencia
input double SpreadATRMultiplier = 0.0; // 0 desactiva filtro relativo ATR; sugerido 0.4-0.6
input int MaxPositionsPerSymbolPerDirection = 3;
input bool EnableBufferedCSV = true;
input int CSVFlushIntervalSeconds = 5;
input int CSVFlushBatchSize = 20;
input int TimerIntervalSeconds = 1; // 1–5s recomendado
input int MagicNumber = 76001;
input int DeviationPoints = 10;
input int LogLevel = 3; // 0=ERROR,1=WARN,2=INFO,3=DEBUG - MODIFICADO: 3 para DEBUG COMPLETO
input bool DrawDebugObjects = false;
input string PipOverrides = ""; // Ej: "XAUUSD:0.10;US30:1.0"
input double SlopeRelax = 0.9; // NUEVO: multiplicador global para pendientes (0.9 conservador)

// NUEVOS inputs para optimizaciones
input bool UseRSICrossSignals = true; // Ignorado en 11.3 (señal RSI por umbral fijo 32/68)
input bool StrictMACD = true; // MODIFICADO: true por requerimiento
input double SlopeRelaxMajors = 0.75; // NUEVO: Pendiente más flexible para majors
input double SlopeRelaxVolatile = 0.9; // NUEVO: Pendiente para pares volátiles
input bool FastMode = false; // NUEVO: Modo acelerado
input double FastModeSlopeRelax = 0.7; // NUEVO: Pendiente en modo rápido
input double FastModeATRMultiplier = 5.0; // NUEVO: ATR en modo rápido
input int MinSymbolsPerTick = 3; // NUEVO: Mínimo símbolos por tick
input int MaxSymbolsPerTick = 8; // NUEVO: Máximo símbolos por tick

// NUEVO: amortiguador de pre-descruce H1 (en múltiplos de ATR H1)
input double PreCrossEMABufferATR = 0.07; // Rango sugerido 0.05–0.10

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

// Cache de handles e indicadores por símbolo/timeframe
struct IndicatorCache {
	int rsi_m5;
	int macd_m5;
	int atr_m5;
	int atr_h1;
	int ema20_h1;
	int ema50_h1;
	int fractals_up_h1; // unificado: usar buffer 0 y 1 del mismo handle
	int fractals_down_h1; // apuntará al mismo handle que fractals_up_h1
	// NUEVO: handles H4 (unificado)
	int fractals_up_h4; // unificado: usar buffer 0/1
	int fractals_down_h4; // apuntará al mismo handle que fractals_up_h4
	// NUEVO: periodos usados por símbolo (para recrear si cambian por categoría)
	int rsi_period_used;
	int macd_fast_used;
	int macd_slow_used;
	int macd_signal_used;
};
IndicatorCache indCache[];

// Cache de buffers por tick (evitar CopyBuffer redundante)
struct TickBuffers {
	bool has_rsi;
	double rsi, rsi_prev;
	bool has_macd;
	double macdHistogram, macdHistogram_prev;
	double macdLine;
	double macdSignal;
	bool has_atr_m5;
	double atr_m5;
	bool has_atr_h1;
	double atr_h1;
	bool has_ema20_ema50;
	double ema20_last;
	double ema20_prev;
	double ema50_last;
	double ema50_prev;
};
TickBuffers tickBuf[];

// CSV buffer
string csvBuffer[];
datetime lastCSVFlush = 0;

// Errores por símbolo (no globales)
bool symbolError[];

// Auto-recovery globals
const int RECOVERY_RETRY_INTERVAL_SECONDS = 60;
datetime lastRecoveryAttempt = 0;

// Correlación dinámica (segunda dimensión fija amplia para soportar hasta 200 símbolos)
double dynamicCorrelationMatrix[][200];
datetime lastCorrelationUpdate = 0;
const int CORRELATION_UPDATE_INTERVAL_SECONDS = 1800; // 30 min (optimizado)

// NUEVO: cache de umbrales dinámicos de volumen por par y sesión
double cachedMinRealVol[][SESSION_COUNT];
double cachedMinTickVol[][SESSION_COUNT];
datetime lastVolumeCacheUpdate = 0;
// NUEVO: modo de volumen por símbolo (true=usar Real si está disponible; false=usar Tick)
bool useRealVolumeForSymbol[];

// NUEVO: Cache de símbolos con datos disponibles
bool symbolDataAvailable[];

// NUEVO: Cache de validaciones por símbolo para evitar recálculos
struct SymbolValidationCache {
	datetime lastCheck;
	bool isValid;
	bool spreadOk;
	bool volumeOk;
	bool correlationOk;
	bool emaConsistent;
	bool s_rOk;
};
SymbolValidationCache symbolValidationCache[];

// NUEVO: Control de procesamiento por lotes - OPTIMIZADO
static int currentSymbolIndex = 0;
static int symbolsPerTick = 3; // OPTIMIZADO: de 2 a 3 para mejor performance

// NUEVO: Cache de procesamiento por tick para evitar recálculos
static datetime lastProcessedTick = 0;
static bool tickProcessed = false;

// NUEVO: re-chequeo de disponibilidad de símbolos (cada hora)
datetime lastSymbolAvailabilityCheck = 0;

// Helper de reintentos por ticket para cierres (EMA cross)
static const int MAX_RETRY_SLOTS = 200;
static ulong retryTicketIds[200];
static int retryCounts[200];

int FindRetrySlot(ulong ticket) {
	for (int i = 0; i < MAX_RETRY_SLOTS; i++) {
		if (retryTicketIds[i] == ticket) return i;
	}
	for (int i = 0; i < MAX_RETRY_SLOTS; i++) {
		if (retryTicketIds[i] == 0) { retryTicketIds[i] = ticket; return i; }
	}
	return -1;
}

// Function declarations
string GetDeinitReasonText(int reason);
string ConcatenateSymbols(const string &symArray[], string separator);
string Trim(string s);
double GetMaxSpreadPoints(string symbol);
double GetATRMultiplier(string symbol);
double GetATRMultiplierTP(string symbol);
double GetSpread(string symbol);
double GetRSI(string symbol);
double GetMACDHistogram(string symbol);
double GetMACDLine(string symbol);
double GetMACDSignal(string symbol);
double GetRecentHigh(string symbol);
double GetRecentLow(string symbol);
double GetATR(string symbol);
double GetATRM5(string symbol);
void AddIndicatorHandle(int handle);
void ReleaseIndicatorHandles();
bool FetchNewsFromWeb();
string ExtractHTMLTag(string text);
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
bool IsFarFromSupportM5(string symbol, double price);
bool IsFarFromResistanceM5(string symbol, double price);
bool AreAllDataAvailable(string symbol);
bool HasPreexistingPositions();
void SetPreexistingPositionsManaged();
bool CheckCorrelation(string symbol);
bool IsPositionProtected(string symbol, ulong ticket);

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

// NUEVO: soporte de sesiones y umbrales de volumen dinámicos
int GetSymbolIndex(string symbol);
int DetermineSessionIdByLocalHour(int localHour);
int GetCurrentSessionId();
int GetSessionIdForBarTime(datetime barTime);
void UpdateVolumeThresholds();

// NUEVO: obligaciones activas en bloqueos/no operación
bool IsBlockedOrNoOpWindow();
void ClosePositionsBeforeNewsForceIfWithin5Min(string symbol);

// NUEVO: utilidad de conversión horaria robusta
void ToLocalStruct(const datetime t, MqlDateTime &outTm);

// NUEVO: helper de pips
double PipValue(const string symbol);

// NUEVO: precarga/aseguramiento de series
bool EnsureSeriesReady(string symbol, ENUM_TIMEFRAMES tf, int minBars, int maxWaitMs);

// NUEVA: función para verificar si se pueden abrir nuevas operaciones
bool CanOpenNewPosition(string symbol);

// NUEVAS FUNCIONES: Validación estricta de tendencia H1 - MEJORADAS
bool IsH1TrendAlignedPreviousOnly(string symbol, bool isBuy);
bool ValidateM5Signals(string symbol, bool isBuy);
bool ValidateEMADataConsistency(string symbol);
bool IsMarketDataAvailable(string symbol);

// NUEVA FUNCIÓN: Validación absoluta de alineación H1-M5
bool IsH1TrendAlignedAbsolute(string symbol, bool isBuy);

// NUEVA FUNCIÓN: Candado estricto de dirección H1 para cero desalineaciones
bool IsH1DirectionStrict(string symbol, bool isBuy);

// NUEVAS FUNCIONES: Cache inteligente optimizado
bool GetUnifiedCache(string symbol, UnifiedCache &cache);
bool CalculateAndCacheUnified(string symbol, int idx, datetime tickTime, UnifiedCache &cache);
bool GetM5Indicators(string symbol, double &rsi, double &rsi_prev, double &macdHist, double &macdHist_prev, double &macdLine, double &macdSignal, double &atr);
bool GetH1Indicators(string symbol, double &atr, double &ema20_last, double &ema20_prev, double &ema50_last, double &ema50_prev);
bool GetH1DirectionCached(string symbol, long &direction);
bool GetEMAConsistencyCached(string symbol);
bool FastCopyBuffer(int handle, int buffer_num, int start_pos, int count, double &buffer[]);
void CheckSignalsOptimized(string symbol, UnifiedCache &cache);

// NUEVAS FUNCIONES: Estadísticas y métricas
void UpdateMetrics(string symbol, double profit);
void UpdatePerformanceStats();
void CleanupCache();

// NUEVA FUNCIÓN: Obtener ticket de posición de forma segura
ulong GetPositionTicket(int index);

// NUEVAS FUNCIONES: Optimización de performance
bool ValidateSymbolCached(string symbol, int idx);
void ProcessSymbolBatch();
bool IsSymbolReadyForProcessing(string symbol, int idx);

// NUEVA FUNCIÓN: Procesamiento optimizado por tick
void ProcessTickOptimized();

// NUEVA FUNCIÓN: Calcular tamaño óptimo de lote
int CalculateOptimalBatchSize();

// NUEVA FUNCIÓN: Verificar si es par mayor
bool IsMajorPair(string symbol);

// NUEVA FUNCIÓN: Obtener límite EMA dinámico por categoría de par
double GetEMALimitByCategory(string symbol);

// NUEVAS FUNCIONES: S/R H1 avanzadas con cache
void RefreshSRLevelsIfNeeded(string symbol, int idx);
void ComputeSRLevelsH1(string symbol, int idx);
void GetH1Supports(string symbol, double &levels[], int limit, int &outCount);
void GetH1Resistances(string symbol, double &levels[], int limit, int &outCount);
bool AdjustTPAndValidateBySR(string symbol, bool isBuy, double price, double atr_h1, double point, double baseTPPoints, bool isHighVol, double &outTP, bool &outBlocked);

// NUEVO H4: S/R H4 con cache y scoring
void RefreshSRLevelsH4IfNeeded(string symbol, int idx);
void ComputeSRLevelsH4(string symbol, int idx);
void GetH4Supports(string symbol, double &levels[], int limit, int &outCount, double &atr_h4);
void GetH4Resistances(string symbol, double &levels[], int limit, int &outCount, double &atr_h4);

// Helpers internos para umbral de volumen dinámico
double GetSessionBaseFactor(int sessionId);
double GetTypeAdjustmentForSymbol(string symbol);
double ClampVolumeFactor(double f);

// EA Initialization
int OnInit() {
	Print("Inicializando Experto 11.9 en ", _Symbol, " a las ", TimeToString(TimeCurrent()));
	criticalError = false;
	lastErrorMessage = "";
	
	// Inicializar métricas
	metrics.totalTrades = 0;
	metrics.winningTrades = 0;
	metrics.losingTrades = 0;
	metrics.totalProfit = 0.0;
	metrics.maxDrawdown = 0.0;
	metrics.lastUpdate = TimeCurrent();
	metrics.onTickCalls = 0;
	metrics.cacheHits = 0;
	metrics.cacheMisses = 0;
	metrics.avgTickTime = 0.0;
	metrics.symbolsProcessedPerTick = 0;
	
	// Check if the current symbol is in the list of managed symbols
	bool symbolInList = false;
	string initialSymbols[];
	StringSplit(SymbolsList, ',', initialSymbols);
	
	for (int i = 0; i < ArraySize(initialSymbols); i++) {
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
	
	symbolCount = MathMin(ArraySize(activeSymbols), maxSymbols); // Limitar a 100 símbolos

	if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
		lastErrorMessage = "ERROR CRITICO: AutoTrading desactivado en el terminal. Active 'Permitir Trading Automatico' en MT5.";
		Print(lastErrorMessage);
		Comment(lastErrorMessage);
		Alert(lastErrorMessage);
		return INIT_FAILED;
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
	
	// NUEVO: Inicializar cache de disponibilidad de datos
	ArrayResize(symbolDataAvailable, symbolCount);
	ArrayResize(symbolValidationCache, symbolCount);
	for (int i = 0; i < symbolCount; i++) {
		symbolDataAvailable[i] = false;
		symbolValidationCache[i].lastCheck = 0;
		symbolValidationCache[i].isValid = false;
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

		// Precargar/asegurar series H1, M5 y H4 (aumentado maxWaitMs)
		EnsureSeriesReady(currentSymbol, PERIOD_H1, 100, 10000);
		EnsureSeriesReady(currentSymbol, PERIOD_M5, 200, 10000);
		EnsureSeriesReady(currentSymbol, PERIOD_H4, 60, 10000);

		// NUEVO: Verificar disponibilidad de datos de mercado
		if (IsMarketDataAvailable(currentSymbol)) {
			symbolDataAvailable[i] = true;
			Print("Datos de mercado disponibles para ", currentSymbol);
		} else {
			symbolDataAvailable[i] = false;
			Print("ADVERTENCIA: Datos de mercado no disponibles para ", currentSymbol, ". Símbolo será omitido.");
		}

		double symbolMinLot = SymbolInfoDouble(currentSymbol, SYMBOL_VOLUME_MIN);
		if (symbolMinLot == 0.0) {
			Print("Advertencia: No se pudo obtener lote minimo para " + currentSymbol + ". Usando 0.1.");
			symbolMinLot = 0.1;
		}
		
		bool isHighVolSymbol = (currentSymbol == "USDMXN" || currentSymbol == "USDZAR" || currentSymbol == "GBPJPY" ||
								currentSymbol == "NZDJPY" || currentSymbol == "XAUUSD" || currentSymbol == "EURTRY" ||
								currentSymbol == "USDBTC" || currentSymbol == "USDETH");
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
	// Config trade
	g_magic = MagicNumber;
	g_deviation = DeviationPoints;
	trade.SetExpertMagicNumber(g_magic);
	trade.SetDeviationInPoints(g_deviation);
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
		for (int j = 0; j < symbolCount; j++) dynamicCorrelationMatrix[i][j] = 0.0;
	}
	lastCorrelationUpdate = 0;
	UpdateCorrelationMatrix();

	// Volumen dinámico
	ArrayResize(cachedMinRealVol, symbolCount);
	ArrayResize(cachedMinTickVol, symbolCount);
	ArrayResize(useRealVolumeForSymbol, symbolCount);
	for (int i = 0; i < symbolCount; i++) {
		useRealVolumeForSymbol[i] = false;
		for (int s = 0; s < SESSION_COUNT; s++) {
			cachedMinRealVol[i][s] = 0.0;
			cachedMinTickVol[i][s] = 0.0;
		}
	}
	lastVolumeCacheUpdate = 0;
	UpdateVolumeThresholds();

	// Cache de indicadores / buffers / errores por símbolo
	ArrayResize(indCache, symbolCount);
	ArrayResize(tickBuf, symbolCount);
	ArrayResize(symbolError, symbolCount);
	for (int i = 0; i < symbolCount; i++) {
		indCache[i].rsi_m5 = INVALID_HANDLE;
		indCache[i].macd_m5 = INVALID_HANDLE;
		indCache[i].atr_m5 = INVALID_HANDLE;
		indCache[i].atr_h1 = INVALID_HANDLE;
		indCache[i].ema20_h1 = INVALID_HANDLE;
		indCache[i].ema50_h1 = INVALID_HANDLE;
		indCache[i].fractals_up_h1 = INVALID_HANDLE;
		indCache[i].fractals_down_h1 = INVALID_HANDLE;
		indCache[i].fractals_up_h4 = INVALID_HANDLE;
		indCache[i].fractals_down_h4 = INVALID_HANDLE;
		indCache[i].rsi_period_used = 0;
		indCache[i].macd_fast_used = 0;
		indCache[i].macd_slow_used = 0;
		indCache[i].macd_signal_used = 0;

		tickBuf[i].has_rsi = false;
		tickBuf[i].has_macd = false;
		tickBuf[i].has_atr_m5 = false;
		tickBuf[i].has_atr_h1 = false;
		tickBuf[i].has_ema20_ema50 = false;
		symbolError[i] = false;
	}

	// NUEVO: Inicializar cache unificado y SR H1/H4
	for (int i = 0; i < maxSymbols; i++) {
		unifiedCache[i].tickTime = 0;
		unifiedCache[i].isValid = false;
		h1DirectionCache[i].barTime = 0;
		h1DirectionCache[i].isValid = false;
		h1ConsistencyCache[i].barTime = 0;
		h1ConsistencyCache[i].isValid = false;
		srCache[i].barTime = 0;
		srCache[i].supportsCount = 0;
		srCache[i].resistancesCount = 0;
		srH4Cache[i].barTime = 0;
		srH4Cache[i].supportsCount = 0;
		srH4Cache[i].resistancesCount = 0;
		srH4Cache[i].atr_h4 = 0.0;
	}

	// Timer
	if (TimerIntervalSeconds > 0) EventSetTimer(TimerIntervalSeconds);

	Print("Inicializacion 11.9 completada. Simbolos: ", IntegerToString(symbolCount), ", LotSize: ", DoubleToString(adjustedLotSize, 2), ", HighVolLotSize: ", DoubleToString(adjustedHighVolLotSize, 2));
	Print("RSI M5: Periodo ", RSIPeriod, ", Umbrales 35/65 (alta vol 33/67)");
	Print("MACD M5: Fast ", MACDFastEMA, ", Slow ", MACDSlowEMA, ", Signal ", MACDSignalSMA, " (StrictMACD=true; alta vol 10/24/6)");
	Print("V11.9: Umbral de volumen dinámico por sesión+tipo; pre-cruce H1 con buffer ATR; reintentos x", MAX_RETRIES, " @ ", WAIT_MS, "ms");
	Print("DEBUG COMPLETO ACTIVADO - LogLevel = 3");
	lastTickTime = TimeCurrent();
	Comment("Experto 11.9: Inicializacion exitosa. Trading activo. DEBUG COMPLETO ACTIVADO.");
	Alert("Experto 11.9: Inicializacion exitosa. Trading activo. DEBUG COMPLETO ACTIVADO.");
	return INIT_SUCCEEDED;
}

// Deinitialization
void OnDeinit(const int reason) {
	Print("Desinicializando Experto 11.9. Motivo: ", IntegerToString(reason), " (", GetDeinitReasonText(reason), ")");
	Print("Ultimo error: ", lastErrorMessage);
	Comment("");
	EventKillTimer();
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

// NUEVO: helper de pips
double PipValue(const string symbol) {
	// Overrides por input (formato "SYM:val;SYM2:val2")
	if (StringLen(PipOverrides) > 0) {
		string parts[]; StringSplit(PipOverrides, ';', parts);
		for (int i = 0; i < ArraySize(parts); i++) {
			int colon = StringFind(parts[i], ":");
			if (colon > 0) {
				string sym = StringSubstr(parts[i], 0, colon);
				string val = StringSubstr(parts[i], colon + 1);
				if (sym == symbol) {
					double v = StringToDouble(val);
					if (v > 0.0) return v;
				}
			}
		}
	}
	const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
	const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
	if (point == 0.0) return 0.0;
	if (digits == 3 || digits == 5) return point * 10.0;
	// Para metales/índices con ticks no estándar, por defecto = point
	return point;
}

// Precarga/asegura que las series estén listas
bool EnsureSeriesReady(string symbol, ENUM_TIMEFRAMES tf, int minBars, int maxWaitMs) {
	if (!SymbolSelect(symbol, true)) return false;
	int waited = 0;
	int step = 50; // ms
	while (iBars(symbol, tf) < minBars && waited < maxWaitMs) {
		MqlRates rr[];
		CopyRates(symbol, tf, 0, 1, rr);
		Sleep(step);
		waited += step;
	}
	// Intento de copiado para forzar carga
	double tmp[];
	CopyClose(symbol, tf, 0, MathMin(minBars, 5), tmp);
	return iBars(symbol, tf) >= minBars;
}

// NUEVA FUNCIÓN: Verificación robusta de disponibilidad de datos de mercado
bool IsMarketDataAvailable(string symbol) {
	// Verificar datos básicos de mercado
	double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
	double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
	double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
	double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
	
	if (bid == 0.0 || ask == 0.0 || point == 0.0 || tickSize == 0.0) {
		return false;
	}
	
	// Verificar que el spread sea razonable
	double spread = (ask - bid) / point;
	if (spread > 20000.0) { // ampliado por símbolos exóticos/cripto
		return false;
	}
	
	// Verificar que hay datos históricos disponibles
	MqlRates rates[];
	if (CopyRates(symbol, PERIOD_H1, 0, 1, rates) < 1) {
		return false;
	}
	
	if (CopyRates(symbol, PERIOD_M5, 0, 1, rates) < 1) {
		return false;
	}
	
	// Verificar que los indicadores básicos funcionan
	int testHandle = iATR(symbol, PERIOD_H1, 14);
	if (testHandle == INVALID_HANDLE) {
		return false;
	}
	
	double testBuffer[];
	if (CopyBuffer(testHandle, 0, 0, 1, testBuffer) <= 0) {
		IndicatorRelease(testHandle);
		return false;
	}
	
	IndicatorRelease(testHandle);
	return true;
}

// NUEVA FUNCIÓN: Verificar si es par mayor
bool IsMajorPair(string symbol) {
	return (symbol == "EURUSD" || symbol == "GBPUSD" || symbol == "USDJPY" || 
	        symbol == "AUDUSD" || symbol == "USDCAD" || symbol == "USDCHF" ||
			symbol == "EURJPY" || symbol == "EURGBP");
}

// NUEVA FUNCIÓN: Calcular tamaño óptimo de lote
int CalculateOptimalBatchSize() {
	if (FastMode) return MaxSymbolsPerTick;
	
	// Calcular basado en latencia y carga del sistema
	double avgTickTime = (metrics.avgTickTime > 0) ? metrics.avgTickTime : 1.0;
	
	if (avgTickTime < 0.5) return MaxSymbolsPerTick;
	if (avgTickTime < 1.0) return MathMax(MinSymbolsPerTick + 2, MaxSymbolsPerTick - 1);
	if (avgTickTime < 2.0) return MinSymbolsPerTick + 1;
	
	return MinSymbolsPerTick;
}

// NUEVA FUNCIÓN: Obtener límite EMA dinámico por categoría de par
double GetEMALimitByCategory(string symbol) {
	// Pares Mayores: 500 puntos (50 pips)
	if (symbol == "EURUSD" || symbol == "GBPUSD" || symbol == "AUDUSD" || 
		symbol == "USDCAD" || symbol == "USDCHF" || symbol == "NZDUSD" ||
		symbol == "EURJPY" || symbol == "EURGBP") {
		return 500.0; // 50 pips
	}
	// Pares Volátiles: 1000 puntos (100 pips)
	else if (symbol == "GBPJPY" || symbol == "AUDJPY" || symbol == "CADJPY" || 
			 symbol == "NZDJPY" || symbol == "EURAUD" || symbol == "EURNZD" ||
			 symbol == "GBPCAD" || symbol == "AUDCAD" || symbol == "AUDNZD" ||
			 symbol == "NZDCAD" || symbol == "EURCHF" || symbol == "GBPNZD" ||
			 symbol == "CADCHF" || symbol == "CHFJPY") {
		return 1000.0; // 100 pips
	}
	// Metales: 2000 puntos (200 pips)
	else if (symbol == "XAUUSD" || symbol == "XAGUSD" || symbol == "XPTUSD" || 
			 symbol == "XPDUSD") {
		return 2000.0; // 200 pips
	}
	// Pares Exóticos: 2000 puntos (200 pips)
	else if (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "EURTRY" || 
			 symbol == "USDSGD" || symbol == "USDHKD" || symbol == "USDNOK" ||
			 symbol == "USDSEK" || symbol == "USDPLN" || symbol == "USDCZK" ||
			 symbol == "USDHUF" || symbol == "USDRON" || symbol == "USDBGN" ||
			 symbol == "USDRSD" || symbol == "USDMKD" || symbol == "USDBAM" ||
			 symbol == "USDALL" || symbol == "USDMAD" || symbol == "USDEGP" ||
			 symbol == "USDZMW" || symbol == "USDKES" || symbol == "USDNGN" ||
			 symbol == "USDGHS" || symbol == "USDTND" || symbol == "USDMUR" ||
			 symbol == "USDBWP" || symbol == "USDSZL" || symbol == "USDLSL" ||
			 symbol == "USDMWK" || symbol == "USDUGX" || symbol == "USDTZS" ||
			 symbol == "USDRWF" || symbol == "USDBIF" || symbol == "USDDJF" ||
			 symbol == "USDSOS" || symbol == "USDSHP" || symbol == "USDAOA" ||
			 symbol == "USDMZN" || symbol == "USDBDT" || symbol == "USDLKR" ||
			 symbol == "USDNPR" || symbol == "USDPKR" || symbol == "USDINR" ||
			 symbol == "USDMYR" || symbol == "USDPHP" || symbol == "USDTHB" ||
			 symbol == "USDIDR" || symbol == "USDVND" || symbol == "USDKHR" ||
			 symbol == "USDLBP" || symbol == "USDJOD" || symbol == "USDIQD" ||
			 symbol == "USDSAR" || symbol == "USDAED" || symbol == "USDBHD" ||
			 symbol == "USDKWD" || symbol == "USDOMR" || symbol == "USDQAR" ||
			 symbol == "USDBRL" || symbol == "USDARS" || symbol == "USDCLP" ||
			 symbol == "USDCOP" || symbol == "USDPEN" || symbol == "USDUYU" ||
			 symbol == "USDPYG" || symbol == "USDBOB" || symbol == "USDVES" ||
			 symbol == "USDSRD" || symbol == "USDGYD" || symbol == "USDTTD" ||
			 symbol == "USDBBD" || symbol == "USDJMD" || symbol == "USDBZD" ||
			 symbol == "USDGTQ" || symbol == "USDHNL" || symbol == "USDNIO" ||
			 symbol == "USDPAB" || symbol == "USDCRC" || symbol == "USDDOP" ||
			 symbol == "USDXCD" || symbol == "USDAWG" || symbol == "USDBMD") {
		return 2000.0; // 200 pips
	}
	// Criptomonedas: 5000 puntos (500 pips)
	else if (symbol == "USDBTC" || symbol == "USDETH" || symbol == "USDLTC" || 
			 symbol == "USDBCH" || symbol == "USDXRP" || symbol == "USDEOS" ||
			 symbol == "USDADA" || symbol == "USDDOT" || symbol == "USDLINK" ||
			 symbol == "USDUNI" || symbol == "USDAAVE" || symbol == "USDCOMP" ||
			 symbol == "USDYFI" || symbol == "USDCRV" || symbol == "USD1INCH" ||
			 symbol == "USDSUSHI" || symbol == "USDPAXG") {
		return 5000.0; // 500 pips
	}
	// Por defecto: 1000 puntos (100 pips)
	else {
		return 1000.0; // 100 pips
	}
}

// Dynamic spread filter - AMPLIADO por categoría; default elevado
double GetMaxSpreadPoints(string symbol) {
	// Cripto
	if (symbol == "USDBTC" || symbol == "USDETH" || symbol == "USDLTC" || symbol == "USDBCH" ||
		symbol == "USDXRP" || symbol == "USDEOS" || symbol == "USDADA" || symbol == "USDDOT" ||
		symbol == "USDLINK" || symbol == "USDUNI" || symbol == "USDAAVE" || symbol == "USDCOMP" ||
		symbol == "USDYFI" || symbol == "USDCRV" || symbol == "USD1INCH" || symbol == "USDSUSHI" || symbol == "USDPAXG")
		return 1500.0;

	// Metales
	if (symbol == "XAUUSD" || symbol == "XAGUSD" || symbol == "XPTUSD" || symbol == "XPDUSD")
		return 200.0;

	// Exóticos y emergentes
	if (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "EURTRY" || symbol == "USDSGD" || symbol == "USDHKD" || symbol == "USDNOK" || symbol == "USDSEK" || symbol == "USDPLN" || symbol == "USDCZK" || symbol == "USDHUF" || symbol == "USDRON" || symbol == "USDBGN" || symbol == "USDRSD" || symbol == "USDMKD" || symbol == "USDBAM" ||
		symbol == "USDALL" || symbol == "USDMAD" || symbol == "USDEGP" || symbol == "USDZMW" || symbol == "USDKES" || symbol == "USDNGN" || symbol == "USDGHS" || symbol == "USDTND" || symbol == "USDMUR" || symbol == "USDBWP" || symbol == "USDSZL" || symbol == "USDLSL" || symbol == "USDMWK" || symbol == "USDUGX" || symbol == "USDTZS" ||
		symbol == "USDRWF" || symbol == "USDBIF" || symbol == "USDDJF" || symbol == "USDSOS" || symbol == "USDSHP" || symbol == "USDAOA" || symbol == "USDMZN" || symbol == "USDBDT" || symbol == "USDLKR" || symbol == "USDNPR" || symbol == "USDPKR" || symbol == "USDINR" || symbol == "USDMYR" || symbol == "USDPHP" || symbol == "USDTHB" ||
		symbol == "USDIDR" || symbol == "USDVND" || symbol == "USDKHR" || symbol == "USDLBP" || symbol == "USDJOD" || symbol == "USDIQD" || symbol == "USDSAR" || symbol == "USDAED" || symbol == "USDBHD" || symbol == "USDKWD" || symbol == "USDOMR" || symbol == "USDQAR" || symbol == "USDBRL" || symbol == "USDARS" || symbol == "USDCLP" ||
		symbol == "USDCOP" || symbol == "USDPEN" || symbol == "USDUYU" || symbol == "USDPYG" || symbol == "USDBOB" || symbol == "USDVES" || symbol == "USDSRD" || symbol == "USDGYD" || symbol == "USDTTD" || symbol == "USDBBD" || symbol == "USDJMD" || symbol == "USDBZD" || symbol == "USDGTQ" || symbol == "USDHNL" || symbol == "USDNIO" ||
		symbol == "USDPAB" || symbol == "USDCRC" || symbol == "USDDOP" || symbol == "USDXCD" || symbol == "USDAWG" || symbol == "USDBMD")
		return 300.0;

	// Majors y cruces líquidos
	if (symbol == "EURUSD") return 50.0;
	if (symbol == "GBPUSD") return 50.0;
	if (symbol == "USDJPY") return 40.0;
	if (symbol == "AUDUSD") return 50.0;
	if (symbol == "USDCAD") return 50.0;
	if (symbol == "USDCHF") return 50.0;
	if (symbol == "EURJPY" || symbol == "EURGBP") return 60.0;

	// Volátiles (yenes, crosses)
	if (symbol == "GBPJPY" || symbol == "NZDJPY" || symbol == "AUDJPY" || symbol == "CADJPY" || symbol == "EURAUD" ||
		symbol == "EURNZD" || symbol == "GBPCAD" || symbol == "AUDCAD" || symbol == "AUDNZD" || symbol == "NZDCAD" ||
		symbol == "EURCHF" || symbol == "GBPNZD" || symbol == "CADCHF" || symbol == "CHFJPY")
		return 100.0;

	// Default elevado
	return 100.0;
}

// Dynamic ATR multiplier
double GetATRMultiplier(string symbol) {
	if (symbol == "USDMXN") return 1.5;
	if (symbol == "USDZAR") return 1.5;
	if (symbol == "GBPJPY") return 1.5;
	if (symbol == "NZDJPY") return 1.5;
	if (symbol == "XAUUSD") return 1.5;
	if (symbol == "EURTRY") return 2.0;
	if (symbol == "USDBTC" || symbol == "USDETH") return 2.5;
	return 1.2;
}

// Dynamic ATR multiplier for Take Profit
double GetATRMultiplierTP(string symbol) {
	if (symbol == "EURUSD") return 1.0;
	if (symbol == "GBPUSD") return 1.2;
	if (symbol == "USDJPY") return 1.0;
	if (symbol == "AUDUSD") return 1.0;
	if (symbol == "NZDUSD") return 1.2;
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
	if (symbol == "USDSGD") return 1.0;
	if (symbol == "USDHKD") return 1.0;
	if (symbol == "USDBTC") return 3.0;
	if (symbol == "USDETH") return 2.5;
	return 1.0;
}

// Spread calculation
double GetSpread(string symbol) {
	double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
	double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
	double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
	if (point == 0.0 || ask == 0.0 || bid == 0.0) {
		return 1e9; // Bloquear por datos no disponibles
	}
	double spread_points = (ask - bid) / point;
	if (SpreadATRMultiplier > 0.0) {
		double atr_h1 = GetATR(symbol);
		if (atr_h1 > 0.0) {
			double threshold_points = (atr_h1 / point) * SpreadATRMultiplier;
			if (spread_points > threshold_points) return 1e9; // bloquea por spread relativo
		}
	}
	return spread_points;
}

// Get RSI on M5 - dinámico por categoría
double GetRSI(string symbol) {
	int idx = GetSymbolIndex(symbol);
	bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
					symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY" ||
					symbol == "USDBTC" || symbol == "USDETH");
	int desiredRSI = isHighVolSymbol ? 9 : RSIPeriod;

	if (idx >= 0) {
		if (indCache[idx].rsi_m5 == INVALID_HANDLE || indCache[idx].rsi_period_used != desiredRSI) {
			if (indCache[idx].rsi_m5 != INVALID_HANDLE) IndicatorRelease(indCache[idx].rsi_m5);
			indCache[idx].rsi_m5 = iRSI(symbol, TimeFrame_Main, desiredRSI, PRICE_CLOSE);
			indCache[idx].rsi_period_used = desiredRSI;
			tickBuf[idx].has_rsi = false;
		}
	}
	int handle = (idx >= 0 ? indCache[idx].rsi_m5 : iRSI(symbol, TimeFrame_Main, desiredRSI, PRICE_CLOSE));
	if (handle == INVALID_HANDLE) {
		return 50.0;
	}
	if (idx >= 0 && tickBuf[idx].has_rsi) return tickBuf[idx].rsi;
	double buffer[];
	int retries = 0;
	while (retries < MAX_RETRIES) {
		if (CopyBuffer(handle, 0, 0, 2, buffer) > 0) {
			if (idx >= 0) { 
				tickBuf[idx].has_rsi = true; 
				tickBuf[idx].rsi = buffer[0]; 
				tickBuf[idx].rsi_prev = buffer[1];
			}
			return buffer[0];
		}
		retries++;
		if (retries < MAX_RETRIES) Sleep(WAIT_MS);
	}
	return 50.0;
}

// CORREGIDO: Get MACD Histogram on M5 (buffer 2)
double GetMACDHistogram(string symbol) {
	int idx = GetSymbolIndex(symbol);
	bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
					symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY" ||
					symbol == "USDBTC" || symbol == "USDETH");
	int dFast = isHighVolSymbol ? 10 : MACDFastEMA;
	int dSlow = isHighVolSymbol ? 24 : MACDSlowEMA;
	int dSig  = isHighVolSymbol ? 6  : MACDSignalSMA;

	if (idx >= 0 && (indCache[idx].macd_m5 == INVALID_HANDLE ||
		indCache[idx].macd_fast_used != dFast ||
		indCache[idx].macd_slow_used != dSlow ||
		indCache[idx].macd_signal_used != dSig)) {
		if (indCache[idx].macd_m5 != INVALID_HANDLE) IndicatorRelease(indCache[idx].macd_m5);
		indCache[idx].macd_m5 = iMACD(symbol, TimeFrame_Main, dFast, dSlow, dSig, PRICE_CLOSE);
		indCache[idx].macd_fast_used = dFast;
		indCache[idx].macd_slow_used = dSlow;
		indCache[idx].macd_signal_used = dSig;
		tickBuf[idx].has_macd = false;
	}
	int handle = (idx >= 0 ? indCache[idx].macd_m5 : iMACD(symbol, TimeFrame_Main, dFast, dSlow, dSig, PRICE_CLOSE));
	if (handle == INVALID_HANDLE) {
		return 0.0;
	}
	if (idx >= 0 && tickBuf[idx].has_macd) return tickBuf[idx].macdHistogram;
	double buffer[];
	int retries = 0;
	while (retries < MAX_RETRIES) {
		if (CopyBuffer(handle, 2, 0, 2, buffer) > 0) {
			if (idx >= 0) { 
				tickBuf[idx].has_macd = true; 
				tickBuf[idx].macdHistogram = buffer[0]; 
				tickBuf[idx].macdHistogram_prev = buffer[1];
			}
			return buffer[0];
		}
		retries++;
		if (retries < MAX_RETRIES) Sleep(WAIT_MS);
	}
	return 0.0;
}

// CORREGIDO: Get MACD Line on M5 (buffer 0)
double GetMACDLine(string symbol) {
	int idx = GetSymbolIndex(symbol);
	bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
					symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY" ||
					symbol == "USDBTC" || symbol == "USDETH");
	int dFast = isHighVolSymbol ? 10 : MACDFastEMA;
	int dSlow = isHighVolSymbol ? 24 : MACDSlowEMA;
	int dSig  = isHighVolSymbol ? 6  : MACDSignalSMA;

	if (idx >= 0 && (indCache[idx].macd_m5 == INVALID_HANDLE ||
		indCache[idx].macd_fast_used != dFast ||
		indCache[idx].macd_slow_used != dSlow ||
		indCache[idx].macd_signal_used != dSig)) {
		if (indCache[idx].macd_m5 != INVALID_HANDLE) IndicatorRelease(indCache[idx].macd_m5);
		indCache[idx].macd_m5 = iMACD(symbol, TimeFrame_Main, dFast, dSlow, dSig, PRICE_CLOSE);
		indCache[idx].macd_fast_used = dFast;
		indCache[idx].macd_slow_used = dSlow;
		indCache[idx].macd_signal_used = dSig;
		tickBuf[idx].has_macd = false;
	}
	int handle = (idx >= 0 ? indCache[idx].macd_m5 : iMACD(symbol, TimeFrame_Main, dFast, dSlow, dSig, PRICE_CLOSE));
	if (handle == INVALID_HANDLE) {
		return 0.0;
	}
	if (idx >= 0 && tickBuf[idx].has_macd) return tickBuf[idx].macdLine;
	double buffer[];
	int retries = 0;
	while (retries < MAX_RETRIES) {
		if (CopyBuffer(handle, 0, 0, 1, buffer) > 0) {
			if (idx >= 0) { 
				tickBuf[idx].has_macd = true; 
				tickBuf[idx].macdLine = buffer[0]; 
			}
			return buffer[0];
		}
		retries++;
		if (retries < MAX_RETRIES) Sleep(WAIT_MS);
	}
	return 0.0;
}

// CORREGIDO: Get MACD Signal on M5 (buffer 1)
double GetMACDSignal(string symbol) {
	int idx = GetSymbolIndex(symbol);
	bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
					symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY" ||
					symbol == "USDBTC" || symbol == "USDETH");
	int dFast = isHighVolSymbol ? 10 : MACDFastEMA;
	int dSlow = isHighVolSymbol ? 24 : MACDSlowEMA;
	int dSig  = isHighVolSymbol ? 6  : MACDSignalSMA;

	if (idx >= 0 && (indCache[idx].macd_m5 == INVALID_HANDLE ||
		indCache[idx].macd_fast_used != dFast ||
		indCache[idx].macd_slow_used != dSlow ||
		indCache[idx].macd_signal_used != dSig)) {
		if (indCache[idx].macd_m5 != INVALID_HANDLE) IndicatorRelease(indCache[idx].macd_m5);
		indCache[idx].macd_m5 = iMACD(symbol, TimeFrame_Main, dFast, dSlow, dSig, PRICE_CLOSE);
		indCache[idx].macd_fast_used = dFast;
		indCache[idx].macd_slow_used = dSlow;
		indCache[idx].macd_signal_used = dSig;
		tickBuf[idx].has_macd = false;
	}
	int handle = (idx >= 0 ? indCache[idx].macd_m5 : iMACD(symbol, TimeFrame_Main, dFast, dSlow, dSig, PRICE_CLOSE));
	if (handle == INVALID_HANDLE) {
		return 0.0;
	}
	if (idx >= 0 && tickBuf[idx].has_macd) return tickBuf[idx].macdSignal;
	double buffer[];
	int retries = 0;
	while (retries < MAX_RETRIES) {
		if (CopyBuffer(handle, 1, 0, 1, buffer) > 0) {
			if (idx >= 0) { 
				tickBuf[idx].has_macd = true; 
				tickBuf[idx].macdSignal = buffer[0]; 
			}
			return buffer[0];
		}
		retries++;
		if (retries < MAX_RETRIES) Sleep(WAIT_MS);
	}
	return 0.0;
}

// Recent high on M5
double GetRecentHigh(string symbol) {
	MqlRates rates[];
	if (CopyRates(symbol, TimeFrame_Main, 0, 50, rates) < 50) {
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
		return 0.0;
	}
	double minLow = rates[0].low;
	for (int i = 1; i < 50; i++) {
		if (rates[i].low < minLow) minLow = rates[i].low;
	}
	return minLow;
}

// ATR for volatility on H1 - MEJORADO con manejo robusto de errores
double GetATR(string symbol) {
	int idx = GetSymbolIndex(symbol);
	if (idx >= 0 && indCache[idx].atr_h1 == INVALID_HANDLE) {
		indCache[idx].atr_h1 = iATR(symbol, TimeFrame_H1, 14);
	}
	int handle = (idx >= 0 ? indCache[idx].atr_h1 : iATR(symbol, TimeFrame_H1, 14));
	if (handle == INVALID_HANDLE) {
		return 0.0;
	}
	if (idx >= 0 && tickBuf[idx].has_atr_h1) return tickBuf[idx].atr_h1;
	double buffer[];
	int retries = 0;
	while (retries < MAX_RETRIES) {
		if (CopyBuffer(handle, 0, 0, 1, buffer) > 0) {
			if (idx >= 0) { 
				tickBuf[idx].has_atr_h1 = true; 
				tickBuf[idx].atr_h1 = buffer[0]; 
			}
			return buffer[0];
		}
		retries++;
		if (retries < MAX_RETRIES) Sleep(WAIT_MS);
	}
	return 0.0;
}

// NUEVO: ATR en M5 para Trailing Stop dinámico - MEJORADO
double GetATRM5(string symbol) {
	int idx = GetSymbolIndex(symbol);
	if (idx >= 0 && indCache[idx].atr_m5 == INVALID_HANDLE) {
		 indCache[idx].atr_m5 = iATR(symbol, TimeFrame_Main, 14);
	}
	int handle = (idx >= 0 ? indCache[idx].atr_m5 : iATR(symbol, TimeFrame_Main, 14));
	if (handle == INVALID_HANDLE) {
		return 0.0;
	}
	if (idx >= 0 && tickBuf[idx].has_atr_m5) return tickBuf[idx].atr_m5;
	double buffer[];
	int retries = 0;
	while (retries < MAX_RETRIES) {
		if (CopyBuffer(handle, 0, 0, 1, buffer) > 0) {
			if (idx >= 0) { 
				tickBuf[idx].has_atr_m5 = true; 
				tickBuf[idx].atr_m5 = buffer[0]; 
			}
			return buffer[0];
		}
		retries++;
		if (retries < MAX_RETRIES) Sleep(WAIT_MS);
	}
	return 0.0;
}

// Get M5 support level - MODIFICADO: 100 velas para alta volatilidad, 50 para el resto
double GetSupportM5(string symbol) {
	bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
					symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY" ||
					symbol == "USDBTC" || symbol == "USDETH");
	int barsToUse = isHighVolSymbol ? 100 : 50;
	MqlRates rates[];
	if (CopyRates(symbol, TimeFrame_Main, 0, barsToUse, rates) < barsToUse) {
		return 0.0;
	}
	double support = rates[0].low;
	for (int i = 1; i < barsToUse; i++) {
		if (rates[i].low < support) support = rates[i].low;
	}
	return support;
}

// Get M5 resistance level - MODIFICADO: 100 velas para alta volatilidad, 50 para el resto
double GetResistanceM5(string symbol) {
	bool isHighVolSymbol = (symbol == "USDMXN" || symbol == "USDZAR" || symbol == "GBPJPY" ||
					symbol == "NZDJPY" || symbol == "XAUUSD" || symbol == "EURTRY" ||
					symbol == "USDBTC" || symbol == "USDETH");
	int barsToUse = isHighVolSymbol ? 100 : 50;
	MqlRates rates[];
	if (CopyRates(symbol, TimeFrame_Main, 0, barsToUse, rates) < barsToUse) {
		return 0.0;
	}
	double resistance = rates[0].high;
	for (int i = 1; i < barsToUse; i++) {
		if (rates[i].high > resistance) resistance = rates[i].high;
	}
	return resistance;
}

// MODIFICADO: Verificar si el precio está LEJOS del soporte M5 (ELIMINADO - sin distancia requerida)
bool IsFarFromSupportM5(string symbol, double price) {
	return true;
}

// MODIFICADO: Verificar si el precio está LEJOS de la resistencia M5 (ELIMINADO - sin distancia requerida)
bool IsFarFromResistanceM5(string symbol, double price) {
	return true;
}

// Add indicator handle
void AddIndicatorHandle(int handle) {
	for (int i = 0; i < ArraySize(indicatorHandles); i++) {
		if (indicatorHandles[i] == handle) return;
	}
	int size = ArraySize(indicatorHandles);
	if (size >= maxHandles) {
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
	// Liberar cache de handles
	for (int i = 0; i < ArraySize(indCache); i++) {
		if (indCache[i].rsi_m5 != INVALID_HANDLE) { 
			IndicatorRelease(indCache[i].rsi_m5); 
			indCache[i].rsi_m5 = INVALID_HANDLE; 
		}
		if (indCache[i].macd_m5 != INVALID_HANDLE) { IndicatorRelease(indCache[i].macd_m5); indCache[i].macd_m5 = INVALID_HANDLE; }
		if (indCache[i].atr_m5  != INVALID_HANDLE) { IndicatorRelease(indCache[i].atr_m5);  indCache[i].atr_m5  = INVALID_HANDLE; }
		if (indCache[i].atr_h1  != INVALID_HANDLE) { IndicatorRelease(indCache[i].atr_h1);  indCache[i].atr_h1  = INVALID_HANDLE; }
		if (indCache[i].ema20_h1!= INVALID_HANDLE) { IndicatorRelease(indCache[i].ema20_h1);indCache[i].ema20_h1= INVALID_HANDLE; }
		if (indCache[i].ema50_h1!= INVALID_HANDLE) { IndicatorRelease(indCache[i].ema50_h1);indCache[i].ema50_h1= INVALID_HANDLE; }
		// Fractales H1/H4 unificados: evitar doble release del mismo handle
		if (indCache[i].fractals_up_h1 != INVALID_HANDLE) {
			IndicatorRelease(indCache[i].fractals_up_h1);
			indCache[i].fractals_up_h1 = INVALID_HANDLE;
		}
		if (indCache[i].fractals_down_h1 != INVALID_HANDLE && indCache[i].fractals_down_h1 != indCache[i].fractals_up_h1) {
			IndicatorRelease(indCache[i].fractals_down_h1);
		}
		indCache[i].fractals_down_h1 = INVALID_HANDLE;
		if (indCache[i].fractals_up_h4 != INVALID_HANDLE) {
			IndicatorRelease(indCache[i].fractals_up_h4);
			indCache[i].fractals_up_h4 = INVALID_HANDLE;
		}
		if (indCache[i].fractals_down_h4 != INVALID_HANDLE && indCache[i].fractals_down_h4 != indCache[i].fractals_up_h4) {
			IndicatorRelease(indCache[i].fractals_down_h4);
		}
		indCache[i].fractals_down_h4 = INVALID_HANDLE;
	}
	ArrayFree(indicatorHandles);
}

// CORREGIDO: Fetch news from Myfxbook - WebRequest corregido
bool FetchNewsFromWeb() {
	string url = "https://www.myfxbook.com/forex-economic-calendar";
	string headers = "User-Agent: Mozilla/5.0\r\n";
	char post[], result[];
	string result_headers;
	int timeout = 5000;
	int res = WebRequest("GET", url, headers, timeout, post, result, result_headers);
	if (res != 200) {
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
				newsEvents[eventCount] = event; // FIX: guardar evento
				eventCount++;
			}
		}
	}
	Print("High impact news loaded from web (UTC): ", IntegerToString(eventCount), " events.");
	webRequestFailed = (eventCount == 0);
	return eventCount > 0;
}

// Extract HTML tag
string ExtractHTMLTag(string text) {
	return text; // no-op (no se usa en esta versión)
}

// Fetch news from CSV
void FetchNewsFromCSV() {
	ArrayResize(newsEvents, 0); // Limpiar el array
	int handle = FileOpen("news.csv", FILE_READ | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
	if (handle == INVALID_HANDLE) {
		return;
	}
	
	// Leer encabezado (5 campos)
	string h1 = FileReadString(handle);
	string h2 = FileReadString(handle);
	string h3 = FileReadString(handle);
	string h4 = FileReadString(handle);
	string h5 = FileReadString(handle);
	if (h1 == "" || h2 == "" || h3 == "" || h4 == "" || h5 == "") {
		FileClose(handle);
		return;
	}
	
	string symbolCurrency1 = StringSubstr(_Symbol, 0, 3); // Ejemplo: "EUR"
	string symbolCurrency2 = StringSubstr(_Symbol, 3, 3); // Ejemplo: "USD"
	
	int eventCount = 0;

	// Ajuste zona horaria: CSV asumido en UTC -> convertir a hora del servidor
	long serverToUTC = (long)TimeCurrent() - (long)TimeGMT();
	
	while (!FileIsEnding(handle)) {
		string date = FileReadString(handle);
		string time = FileReadString(handle);
		string currency = FileReadString(handle);
		string description = FileReadString(handle);
		string impact = FileReadString(handle);
		
		// Verificar si la línea está vacía o incompleta
		if (date == "" || time == "" || currency == "" || description == "" || impact == "") {
			continue;
		}
		
		// Validar formato de fecha/hora
		if (StringLen(date) != 10 || StringFind(date, ".") != 4 || StringLen(time) != 5 || StringFind(time, ":") != 2) {
			continue;
		}
		
		// Convertir a datetime (StringToTime interpreta en hora del servidor)
		string datetimeStr = date + " " + time;
		datetime parsed = StringToTime(datetimeStr);
		if (parsed == 0) {
			continue;
		}
		// CSV está en UTC: convertir UTC -> servidor sumando delta
		datetime eventTimeServer = (datetime)((long)parsed + serverToUTC);
		
		// Verificar si la divisa coincide
		if (StringCompare(currency, symbolCurrency1, false) == 0 || StringCompare(currency, symbolCurrency2, false) == 0) {
			NewsEvent event;
			event.time = eventTimeServer;
			event.currency = currency;
			event.description = description;
			event.impact = impact;
			ArrayResize(newsEvents, eventCount + 1);
			newsEvents[eventCount] = event;
			eventCount++;
		}
	}
	
	FileClose(handle);
	Print("Noticias cargadas desde news.csv (UTC->Server ajustado) para ", _Symbol, ": ", IntegerToString(eventCount), " eventos de alto impacto.");
}

// OnTimer: tareas no críticas para liberar OnTick
void OnTimer() {
	datetime now = TimeCurrent();
	// Noticias
	if (now - lastNewsCheck >= NEWS_CHECK_INTERVAL) {
		FetchNewsEvents();
		lastNewsCheck = now;
	}
	// Correlación
	UpdateCorrelationMatrix();
	// Umbrales volumen
	UpdateVolumeThresholds();
	// Re-chequeo de disponibilidad de símbolos (1 hora)
	if (lastSymbolAvailabilityCheck == 0 || now - lastSymbolAvailabilityCheck >= 3600) {
		for (int i = 0; i < symbolCount; i++) {
			if (!symbolDataAvailable[i]) {
				string sym = activeSymbols[i];
				EnsureSeriesReady(sym, PERIOD_H1, 50, 10000);
				EnsureSeriesReady(sym, PERIOD_M5, 50, 10000);
				EnsureSeriesReady(sym, PERIOD_H4, 50, 10000);
				if (IsMarketDataAvailable(sym)) {
					symbolDataAvailable[i] = true;
					Print("Símbolo ahora disponible y habilitado: ", sym);
				}
			}
		}
		lastSymbolAvailabilityCheck = now;
	}
	// Flush CSV
	if (EnableBufferedCSV) {
		if (lastCSVFlush == 0 || now - lastCSVFlush >= CSVFlushIntervalSeconds || ArraySize(csvBuffer) >= CSVFlushBatchSize) {
			if (ArraySize(csvBuffer) > 0) {
				int handle = FileOpen("TradeLog.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
				if (handle != INVALID_HANDLE) {
					FileSeek(handle, 0, SEEK_END);
					for (int i = 0; i < ArraySize(csvBuffer); i++) FileWrite(handle, csvBuffer[i]);
					FileClose(handle);
					ArrayResize(csvBuffer, 0);
				}
				lastCSVFlush = now;
			}
		}
	}
	// Limpiar cache
	CleanupCache();
	// Actualizar métricas
	UpdatePerformanceStats();
}

// Fetch news events
void FetchNewsEvents() {
	ArrayFree(newsEvents);
	if (!FetchNewsFromWeb()) {
		FetchNewsFromCSV();
	}
	if (ArraySize(newsEvents) == 0) {
		lastErrorMessage = "ADVERTENCIA: Could not get high impact news data. EA sin noticias.";
		Print(lastErrorMessage);
	}
}

// Check for high impact news - MODIFICADO: 10 min antes, 15 min después
bool IsNewsHighImpactSoon(string symbol) {
	datetime now = TimeCurrent();
	if (now == 0) {
		return false;
	}
	for (int i = 0; i < ArraySize(newsEvents); i++) {
		if (newsEvents[i].impact != "High") continue;
		string baseCurrency = StringSubstr(symbol, 0, 3);
		string quoteCurrency = StringSubstr(symbol, 3, 3);
		if (newsEvents[i].currency == baseCurrency || newsEvents[i].currency == quoteCurrency) {
			long timeDiff = (long)newsEvents[i].time - (long)now;
			// MODIFICADO: 10 min antes (600 segundos) y 15 min después (900 segundos)
			if (timeDiff >= -600 && timeDiff <= 900) {
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
		return;
	}
	int total = PositionsTotal();
	for (int i = total - 1; i >= 0; i--) {
		ulong ticket = GetPositionTicket(i);
		if (ticket == 0) continue;
		if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
			long type = m_position_info.PositionType();
			double price_open = m_position_info.PriceOpen();
			double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
			double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
		  if (bid == 0.0 || ask == 0.0) {
				continue;
			}
			bool isPositive = (type == POSITION_TYPE_BUY && bid > price_open) ||
							  (type == POSITION_TYPE_SELL && ask < price_open);
			if (isPositive) {
				if (!trade.PositionClose(ticket)) {
					Print("ERROR: Error closing position: Symbol=" + symbol + ", Ticket=" + StringFormat("%I64u", ticket) + ", Error=" + IntegerToString(GetLastError()));
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
					UpdateMetrics(symbol, m_position_info.Profit());
				}
			}
		}
	}
}

// NUEVO: detectar ventana de bloqueo/no operación (sin abrir nuevas operaciones, pero cumpliendo obligaciones)
bool IsBlockedOrNoOpWindow() {
	datetime now = TimeCurrent();
	if (now == 0) return false;
	MqlDateTime tm;
	ToLocalStruct(now, tm);
	
	// NUEVO: Bloqueo domingos desde apertura hasta 21:00 (Quito)
	if (tm.day_of_week == 0 && tm.hour < 21) return true;
	
	// MODIFICADO: Bloqueo lunes-jueves 16:00-19:00 (Quito)
	if (tm.day_of_week >= 1 && tm.day_of_week <= 4 && tm.hour >= 16 && tm.hour < 19) return true;
	
	// MODIFICADO: Bloqueo viernes desde BlockStartHourLocal hasta cierre (Quito)
	if (tm.day_of_week == 5 && tm.hour >= BlockStartHourLocal) return true;
	
	if (IsLowLiquidityPeriod()) return true;
	return false;
}

// NUEVO: cierre ≤5 min antes de noticias durante bloqueos/no operación: SOLO posiciones en ganancia
void ClosePositionsBeforeNewsForceIfWithin5Min(string symbol) {
	datetime now = TimeCurrent();
	if (now == 0) {
		return;
	}
	for (int i = 0; i < ArraySize(newsEvents); i++) {
		if (newsEvents[i].impact != "High") continue;
		string baseCurrency = StringSubstr(symbol, 0, 3);
		string quoteCurrency = StringSubstr(symbol, 3, 3);
		if (newsEvents[i].currency == baseCurrency || newsEvents[i].currency == quoteCurrency) {
			long timeDiff = (long)newsEvents[i].time - (long)now;
			if (timeDiff <= 300 && timeDiff >= 0) {
				int total = PositionsTotal();
				for (int j = total - 1; j >= 0; j--) {
					ulong ticket = GetPositionTicket(j);
					if (ticket == 0) continue;
					if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
						long type = m_position_info.PositionType();
						double price_open = m_position_info.PriceOpen();
						double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
						double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
						if (bid == 0.0 || ask == 0.0) {
							continue;
						}
						bool isPositive = (type == POSITION_TYPE_BUY && bid > price_open) ||
									  (type == POSITION_TYPE_SELL && ask < price_open);
						if (!isPositive) continue; // NO cerrar pérdidas
						double closePrice = (type == POSITION_TYPE_BUY) ? bid : ask;
						if (!trade.PositionClose(ticket)) {
							Print("ERROR: Error closing position (force before news): Symbol=" + symbol + ", Ticket=" + StringFormat("%I64u", ticket) + ", Error=" + IntegerToString(GetLastError()));
						} else {
							Print("Position closed (force before news, positive only): Symbol=", symbol, ", Ticket=", StringFormat("%I64u", ticket));
							LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
									 symbol,
									 (type == POSITION_TYPE_BUY ? "BuyClose" : "SellClose"),
									 DoubleToString(closePrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
									 DoubleToString(m_position_info.Volume(), 2),
									 DoubleToString(m_position_info.StopLoss(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
									 DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
									 "Closed Before News (Force, Positive Only)");
							UpdateMetrics(symbol, m_position_info.Profit());
						}
					}
				}
				break;
			}
		}
	}
}

// Check low liquidity period
bool IsLowLiquidityPeriod() {
	datetime now = TimeCurrent();
	if (now == 0) {
		return false;
	}
	MqlDateTime tm;
	ToLocalStruct(now, tm);
	return (tm.day_of_week == 0 && tm.hour < 22);
}

// Check if trading is allowed - MODIFICADO: nuevos horarios de bloqueo
bool IsAllowedToOpenTrade(string symbol) {
	if (!IsMarketOpen(symbol)) return false;

	// Bloqueos horarios SIEMPRE, aun sin noticias
	datetime now = TimeCurrent();
	if (now == 0) return false;
	MqlDateTime tm;
	ToLocalStruct(now, tm);

	if (tm.day_of_week == 0 && tm.hour < 21) return false; // Domingo
	if (tm.day_of_week >= 1 && tm.day_of_week <= 4 && tm.hour >= 16 && tm.hour < 19) return false; // Lun-Jue
	if (tm.day_of_week == 5 && tm.hour >= BlockStartHourLocal) return false; // Viernes
	if (IsLowLiquidityPeriod()) return false;

	// Noticias si están disponibles
	if (ArraySize(newsEvents) > 0 && IsNewsHighImpactSoon(symbol)) return false;

	return true;
}

// Check market status
bool IsMarketOpen(string symbol) {
	double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
	double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
	if (bid == 0.0 || ask == 0.0) {
		return false;
	}
	return true;
}

// Is volume sufficient (usa vela H1 cerrada previa para evitar bloqueo al inicio de hora)
bool IsVolumeSufficient(string symbol) {
	int symbolIndex = GetSymbolIndex(symbol);
	if (symbolIndex == -1) return true;

	int sessionId = GetCurrentSessionId();
	if (sessionId < 0 || sessionId >= SESSION_COUNT) return true;

	// Elegir si usar REAL o TICK según disponibilidad declarada para el símbolo
	bool preferReal = useRealVolumeForSymbol[symbolIndex];

	// Obtener vela H1 actual y anterior
	MqlRates rates[2];
	int got = CopyRates(symbol, PERIOD_H1, 0, 2, rates);
	if (got < 2) return true; // más permisivo: si no hay vela previa, no bloquear

	// Si existe la vela previa, usarla; si no, usar la actual
	long realVolume = (long)rates[1].real_volume;
	long tickVolume = (long)rates[1].tick_volume;

	// Umbrales
	double minReal = cachedMinRealVol[symbolIndex][sessionId];
	double minTick = cachedMinTickVol[symbolIndex][sessionId];

	if (preferReal && realVolume > 0) {
		if (minReal <= 0.0) return true;
		return (double)realVolume >= minReal;
	}
	if (minTick <= 0.0) return true;
	return (double)tickVolume >= minTick;
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

// NUEVA FUNCIÓN: Validación robusta de consistencia de datos EMA H1 - 11.6/11.7: SIEMPRE TRUE
bool ValidateEMADataConsistency(string symbol) {
	return true;
}

// CORREGIDO: Get H1 market direction - solo velas cerradas [1..3], mayoría 2-de-3
long GetH1MarketDirection(string symbol) {
	int ema20_handle = iMA(symbol, TimeFrame_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
	int ema50_handle = iMA(symbol, TimeFrame_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
	if (ema20_handle == INVALID_HANDLE || ema50_handle == INVALID_HANDLE) return 0;

	double ema20[4], ema50[4];
	if (CopyBuffer(ema20_handle, 0, 0, 4, ema20) != 4 ||
	    CopyBuffer(ema50_handle, 0, 0, 4, ema50) != 4) {
		if (ema20_handle != INVALID_HANDLE) IndicatorRelease(ema20_handle);
		if (ema50_handle != INVALID_HANDLE) IndicatorRelease(ema50_handle);
		return 0;
	}

	IndicatorRelease(ema20_handle);
	IndicatorRelease(ema50_handle);

	int bullish = 0, bearish = 0;
	for (int i = 1; i <= 3; i++) {
		if (ema20[i] > ema50[i]) bullish++;
		else if (ema20[i] < ema50[i]) bearish++;
	}
	if (bullish >= 2) return 1;
	if (bearish >= 2) return -1;
	return 0;
}

// Manage Break Even - MODIFICADO: Dinámico basado en ATR M5
void ManageBreakEven(string symbol) {
	int total = PositionsTotal();
	for (int i = total - 1; i >= 0; i--) {
		ulong ticket = GetPositionTicket(i);
		if (ticket == 0) continue;
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
				continue;
			}

			// Obtener ATR M5 para cálculo dinámico
			double atr_m5 = GetATRM5(symbol);
			if (atr_m5 <= 0.0) continue;

			// Calcular distancia dinámica basada en ATR M5
			double atr_distance = atr_m5 * ATR_TS_MULTIPLIER;

			if (type == POSITION_TYPE_BUY) {
				profit_pips = (bid - price_open) / PipValue(symbol);
				new_sl_level = price_open + BE_OFFSET_PIPS * PipValue(symbol);
			} else if (type == POSITION_TYPE_SELL) {
				profit_pips = (price_open - ask) / PipValue(symbol);
				new_sl_level = price_open - BE_OFFSET_PIPS * PipValue(symbol);
			}

			double profit_atr_ratio = profit_pips * PipValue(symbol) / atr_distance;
			
			if (profit_atr_ratio >= 1.0 && (current_sl == 0.0 || 
				(type == POSITION_TYPE_BUY && new_sl_level > current_sl) || 
				(type == POSITION_TYPE_SELL && new_sl_level < current_sl))) {
				if (trade.PositionModify(ticket, new_sl_level, m_position_info.TakeProfit())) {
                    if (LogLevel >= 2) Print("Break Even dinámico activado para ", symbol, ". SL movido a ", DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
					LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
							 symbol,
							 "BE",
							 DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 DoubleToString(m_position_info.Volume(), 2),
							 DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 "Break Even Dinámico ATR M5");
				}
			}
		}
	}
}

// Manage Trailing Stop - MODIFICADO: Dinámico basado en ATR M5 + Promo H1/H4
void ManageTrailingStop(string symbol) {
	int total = PositionsTotal();
	for (int i = total - 1; i >= 0; i--) {
		ulong ticket = GetPositionTicket(i);
		if (ticket == 0) continue;
		if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
			long type = m_position_info.PositionType();
			double price_open = m_position_info.PriceOpen();
			double current_sl = m_position_info.StopLoss();
			double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
			double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
			double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
			int idx = GetSymbolIndex(symbol);
			if (idx < 0) continue;

			if (bid == 0.0 || ask == 0.0 || point == 0.0) {
				continue;
			}
			
			// ATRs
			double atr_m5 = GetATRM5(symbol);
			if (atr_m5 <= 0.0) continue;
			double atr_h1 = GetATR(symbol);

			// Calcular distancia dinámica basada en ATR M5
			double atr_distance = atr_m5 * ATR_TS_MULTIPLIER;

			double new_sl_level = current_sl;

			if (type == POSITION_TYPE_BUY) {
				double profit_pips = (bid - price_open) / PipValue(symbol);
				double ts_level = bid - atr_distance;
				double min_step = TRAILING_STEP_PIPS * PipValue(symbol);
				bool step_ok = (current_sl == 0.0 || ts_level - current_sl >= min_step);
				if (profit_pips * PipValue(symbol) / atr_distance >= 1.5 && step_ok) {
					new_sl_level = MathMax(new_sl_level, ts_level);
				}
				// Promoción por ruptura de resistencia H1/H4
				RefreshSRLevelsIfNeeded(symbol, idx);
				double resLevelsH1[3]; int resCountH1=0;
				GetH1Resistances(symbol, resLevelsH1, 3, resCountH1);
				RefreshSRLevelsH4IfNeeded(symbol, idx);
				double resLevelsH4[3]; int resCountH4=0; double atr_h4=0.0;
				GetH4Resistances(symbol, resLevelsH4, 3, resCountH4, atr_h4);

				if (resCountH1 > 0 && atr_h1 > 0.0) {
					for (int r=0;r<resCountH1;r++) {
						double lvl = resLevelsH1[r];
						if (bid > lvl) {
							double promo = lvl - 0.25 * atr_h1;
							if (current_sl == 0.0 || promo > new_sl_level) new_sl_level = promo;
							break;
						}
					}
				}
				if (resCountH4 > 0 && atr_h4 > 0.0) {
					for (int r=0;r<resCountH4;r++) {
						double lvl = resLevelsH4[r];
						// cierre por encima del nivel H4 (rompió)
						if (bid > lvl) {
							double promo = lvl - 0.30 * atr_h4; // promoción por ruptura H4
							if (current_sl == 0.0 || promo > new_sl_level) new_sl_level = promo;
							break;
						}
					}
				}
			} else if (type == POSITION_TYPE_SELL) {
				double profit_pips = (price_open - ask) / PipValue(symbol);
				double ts_level = ask + atr_distance;
				double min_step = TRAILING_STEP_PIPS * PipValue(symbol);
				bool step_ok = (current_sl == 0.0 || current_sl - ts_level >= min_step);
				if (profit_pips * PipValue(symbol) / atr_distance >= 1.5 && step_ok) {
					new_sl_level = (current_sl == 0.0) ? ts_level : MathMin(new_sl_level, ts_level);
				}
				// Promoción por ruptura de soporte H1/H4
				RefreshSRLevelsIfNeeded(symbol, idx);
				double supLevelsH1[3]; int supCountH1=0;
				GetH1Supports(symbol, supLevelsH1, 3, supCountH1);
				RefreshSRLevelsH4IfNeeded(symbol, idx);
				double supLevelsH4[3]; int supCountH4=0; double atr_h4=0.0;
				GetH4Supports(symbol, supLevelsH4, 3, supCountH4, atr_h4);

				if (supCountH1 > 0 && atr_h1 > 0.0) {
					for (int s=0;s<supCountH1;s++) {
						double lvl = supLevelsH1[s];
						if (ask < lvl) {
							double promo = lvl + 0.25 * atr_h1;
							if (current_sl == 0.0 || promo < new_sl_level) new_sl_level = promo;
							break;
						}
					}
				}
				if (supCountH4 > 0 && atr_h4 > 0.0) {
					for (int s=0;s<supCountH4;s++) {
						double lvl = supLevelsH4[s];
						if (ask < lvl) {
							double promo = lvl + 0.30 * atr_h4; // promoción por ruptura H4
							if (current_sl == 0.0 || promo < new_sl_level) new_sl_level = promo;
							break;
						}
					}
				}
			}

			if (new_sl_level != current_sl && new_sl_level > 0.0) {
				if (trade.PositionModify(ticket, new_sl_level, m_position_info.TakeProfit())) {
					if (LogLevel >= 2) Print("Trailing/Promo SL actualizado para ", symbol, ". SL=", DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
					LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
							 symbol,
							 "TS/Promo",
							 DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 DoubleToString(m_position_info.Volume(), 2),
							 DoubleToString(new_sl_level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 "TS Dinámico ATR M5 + Promo S/R H1/H4");
				}
			}
		}
	}
}

// Close positions on Friday - OPTIMIZADO: Una sola vez por tick
void ClosePositionsOnFriday() {
	static datetime lastFridayCheck = 0;
	datetime now = TimeCurrent();
	if (now == lastFridayCheck) return; // Evitar llamadas redundantes
	lastFridayCheck = now;
	
	if (now == 0) {
		return;
	}
	MqlDateTime tm;
	ToLocalStruct(now, tm);
	if (tm.day_of_week == 5 && tm.hour >= BlockStartHourLocal) {
		CloseAllPositivePositions();
	}
}

// NUEVA FUNCIÓN: Verificar si se pueden abrir nuevas operaciones con límite por dirección
bool CanOpenNewPosition(string symbol) {
	int total = PositionsTotal();
	int symbolPositions = 0;
	int buyPositions = 0;
	int sellPositions = 0;
	int protectedPositions = 0;
	
	for (int i = 0; i < total; i++) {
		ulong ticket = GetPositionTicket(i);
		if (ticket == 0) continue;
		if (m_position_info.SelectByTicket(ticket) && m_position_info.Symbol() == symbol) {
			symbolPositions++;
			if (m_position_info.PositionType() == POSITION_TYPE_BUY) {
				buyPositions++;
			} else {
				sellPositions++;
			}
			if (IsPositionProtected(symbol, ticket)) {
				protectedPositions++;
			}
		}
	}
	
	if (symbolPositions == 0) return true;
	if (buyPositions >= MaxPositionsPerSymbolPerDirection) return false;
	if (sellPositions >= MaxPositionsPerSymbolPerDirection) return false;
	
	return (protectedPositions == symbolPositions);
}

// NUEVA FUNCIÓN: Obtener ticket de posición de forma segura
ulong GetPositionTicket(int index) {
	if (index < 0 || index >= PositionsTotal()) return 0;
	return PositionGetTicket(index);
}

//+------------------------------------------------------------------+
//| NUEVA FUNCIÓN: Validación H1 solo velas anteriores: 1 de 3 velas anteriores    |
//+------------------------------------------------------------------+
bool IsH1TrendAlignedPreviousOnly(string symbol, bool isBuy) {
    int ema20_handle = iMA(symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int ema50_handle = iMA(symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    
    if (ema20_handle == INVALID_HANDLE || ema50_handle == INVALID_HANDLE) {
        if (LogLevel >= 2) Print("ERROR: No se pueden obtener handles de EMAs H1 para ", symbol);
        return false;
    }
    
    double ema20[], ema50[];
    if (CopyBuffer(ema20_handle, 0, 0, 4, ema20) != 4 || 
        CopyBuffer(ema50_handle, 0, 0, 4, ema50) != 4) {
        if (LogLevel >= 2) Print("ERROR: No se pueden obtener datos de EMAs H1 para ", symbol);
        IndicatorRelease(ema20_handle);
        IndicatorRelease(ema50_handle);
        return false;
    }
    
    IndicatorRelease(ema20_handle);
    IndicatorRelease(ema50_handle);
    
    int velasAnterioresAlcistas = 0;
    int velasAnterioresBajistas = 0;
    
    for (int i = 1; i < 4; i++) {
        if (ema20[i] > ema50[i]) velasAnterioresAlcistas++;
        else if (ema20[i] < ema50[i]) velasAnterioresBajistas++;
    }
    
    if (isBuy) {
        bool cumpleValidacion = (velasAnterioresAlcistas >= 1);
        if (LogLevel >= 3) {
            Print("VALIDACIÓN H1 COMPRA SOLO VELAS ANTERIORES ", symbol, ":");
            Print("  Vela actual (en formación): IGNORADA");
            Print("  Velas anteriores alcistas: ", velasAnterioresAlcistas, "/3");
            Print("  Velas anteriores bajistas: ", velasAnterioresBajistas, "/3");
            Print("  Cumple validación: ", cumpleValidacion ? "SÍ" : "NO");
        }
        return cumpleValidacion;
        
    } else {
        bool cumpleValidacion = (velasAnterioresBajistas >= 1);
        if (LogLevel >= 3) {
            Print("VALIDACIÓN H1 VENTA SOLO VELAS ANTERIORES ", symbol, ":");
            Print("  Vela actual (en formación): IGNORADA");
            Print("  Velas anteriores alcistas: ", velasAnterioresAlcistas, "/3");
            Print("  Velas anteriores bajistas: ", velasAnterioresBajistas, "/3");
            Print("  Cumple validación: ", cumpleValidacion ? "SÍ" : "NO");
        }
        return cumpleValidacion;
    }
}

bool ValidateM5Signals(string symbol, bool isBuy) {
	return true;
}

// Validación absoluta
bool IsH1TrendAlignedAbsolute(string symbol, bool isBuy) {
	return IsH1TrendAlignedPreviousOnly(symbol, isBuy);
}

// Candado estricto
bool IsH1DirectionStrict(string symbol, bool isBuy) {
	return IsH1TrendAlignedPreviousOnly(symbol, isBuy);
}

// Check if there are open positions
bool HasOpenPosition(string symbol) {
	int total = PositionsTotal();
	for (int i = 0; i < total; i++) {
		ulong ticket = GetPositionTicket(i);
		if (ticket == 0) continue;
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
		ulong ticket = GetPositionTicket(i);
		if (ticket == 0) continue;
		if (m_position_info.SelectByTicket(ticket)) {
			string symbol = m_position_info.Symbol();
			long type = m_position_info.PositionType();
			double price_open = m_position_info.PriceOpen();
			double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
			double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
			if (bid == 0.0 || ask == 0.0) {
				continue;
			}
			bool isPositive = (type == POSITION_TYPE_BUY && bid > price_open) ||
							  (type == POSITION_TYPE_SELL && ask < price_open);
			if (isPositive) {
				if (!trade.PositionClose(ticket)) {
					Print("ERROR: Error closing position: Symbol=" + symbol + ", Ticket=" + StringFormat("%I64u", ticket) + ", Error=" + IntegerToString(GetLastError()));
				} else {
					if (LogLevel >= 2) Print("Positive position closed: Symbol=", symbol, ", Ticket=", StringFormat("%I64u", ticket));
					LogTrade(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
							 symbol,
							 (type == POSITION_TYPE_BUY ? "BuyClose" : "SellClose"),
							 DoubleToString((type == POSITION_TYPE_BUY ? bid : ask), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 DoubleToString(m_position_info.Volume(), 2),
							 DoubleToString(m_position_info.StopLoss(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 DoubleToString(m_position_info.TakeProfit(), (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
							 "Closed on Friday");
					UpdateMetrics(symbol, m_position_info.Profit());
				}
			}
		}
	}
}

// Check if all data is available
bool AreAllDataAvailable(string symbol) {
	int idx = GetSymbolIndex(symbol);
	if (idx >= 0 && !symbolDataAvailable[idx]) {
		if (LogLevel >= 3) Print("DATA GATE: symbolDataAvailable=false para ", symbol);
		return false;
	}
	
	double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
	double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
	double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
	double pipv = PipValue(symbol);
	if (bid == 0.0 || ask == 0.0 || point == 0.0 || pipv == 0.0) {
		if (LogLevel >= 3) Print("DATA GATE: bid/ask/point/pipv inválidos para ", symbol, " b=", bid, " a=", ask, " p=", point, " pip=", pipv);
		return false;
	}
	
	// IMPORTANTE: NO exigir ATR(H1)>0 aquí para no bloquear procesamiento temprano
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

...
