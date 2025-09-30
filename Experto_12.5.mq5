//+------------------------------------------------------------------+
//|                                     Experto_12.5.mq5             |
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
//| NUEVO: RSI M5 con umbrales 32/68 (estándar) |
//| NUEVO: Bloqueos horarios específicos para Quito, Ecuador |
//| MODIFICADO: RSI M5 período 10, umbrales 32/68 (estándar) |
//| MODIFICADO: MACD M5 Fast EMA 8, Slow EMA 21, Signal 5 |
//| VERSIÓN 11.2: Break Even y Trailing Stop dinámicos basados en ATR M5 |
//| VERSIÓN 11.2: Validación de tendencia H1 con 4 velas consecutivas (sin pendientes) |
//| VERSIÓN 11.4: DEBUG COMPLETO ACTIVADO - LogLevel = 3 |
//| VERSIÓN 11.5: OPTIMIZADO - Validación H1 solo velas anteriores (1 de 3) |
//| VERSIÓN 11.6: Corrección MACD buffers, H1 2 de 3 velas cerradas, fractales unificados, CSV append real, correlación optimizada |
//| VERSIÓN 11.7: Desbloqueo de procesamiento por tick, volumen más permisivo, reintentos H1 y candado H1 estricto |
//| VERSIÓN 12.1: Fix soportes H4, reintentos M5/H1, fallback ATR(H1) en apertura |
//| VERSIÓN 12.5: Endurecimiento cero contra-tendencia, revalidaciones H1 sin caché, epsilon cruces EMA |
//| VERSIÓN 12.5: Ventana de noticias 15 min antes / 30 min después, encabezado extendido |
//+------------------------------------------------------------------+

// DESCRIPCIÓN EXTENDIDA (Experto 12.5)
// - Marco multi-símbolo (hasta 100 símbolos) con caché unificada por símbolo, caches H1 y S/R, y procesamiento por lotes para
//   optimizar la carga por tick. Mantiene la arquitectura robusta del 12.4.
// - Filtros H1:
//   * Tendencia por EMA(20/50) con validación en velas cerradas. Candado estricto para impedir cualquier operación contra la tendencia.
//   * Cierre inmediato por descruce EMA(20/50) en velas cerradas con tolerancia (epsilon) para no perder cruces marginales.
//   * Cierre anticipado por PRE-DESCRUCE (vela 0) amortiguado por ATR(H1), solo para posiciones no protegidas.
//   * ATR(H1) dinámico como filtro superior de volatilidad (umbral flexible por sesión y categoría de par).
// - Filtros M5:
//   * Señal compuesta de RSI y MACD, con StrictMACD para confirmar histograma y candado estricto H1 (dirección 1/-1 requerida).
//   * RSI estándar (periodo 10) con umbrales 32/68; en pares de alta volatilidad se aplican overrides suaves.
//   * MACD estándar 8/21/5 (Fast/Slow/Signal), alineado con la descripción.
// - Gestión y riesgo:
//   * Aperturas sin SL inicial. Break Even dinámico y Trailing Stop dinámico basados en ATR(M5) con paso mínimo de 2 pips.
//   * Reapertura de nuevas posiciones solo si todas las existentes en el símbolo están protegidas (BE/TS).
// - Bloqueos y ventanas operativas:
//   * Bloqueos por horario local de Quito (UTC-5) y cierre de posiciones positivas los viernes desde las 14:00.
//   * Noticias de alto impacto: bloqueo 15 minutos antes y 30 minutos después; cierre en positivo 5 minutos antes del evento.
// - Correlación dinámica:
//   * Previene nuevas operaciones si existe correlación absoluta por encima del umbral y posiciones relacionadas sin protección.
// - Spreads y volumen:
//   * Filtro de spread por categoría de símbolo y opción de filtro relativo al ATR.
//   * Umbrales dinámicos de volumen (tick/real) por sesión y categoría de par, con autodetección de disponibilidad de volumen real.
// - S/R multi-timeframe:
//   * S/R H1 y H4 con fractales, clustering, scoring y caché por barra. Posibilidad de cap de TP por H4 (opcional y desactivado por defecto).
// - Métricas en tiempo real:
//   * Estadísticas de performance: win rate, total trades, cache hits, símbolos procesados por tick y latencias medias.
// - Robustez y auto-recuperación:
//   * Reintentos de lectura de indicadores con timeouts, tolerancias y fallback de ATR(H1) histórico.
//   * Reintentos en cierres si el servidor rechaza la operación de forma transitoria.
// - GARANTÍA ABSOLUTA 12.5 (cero contra-tendencia):
//   * CheckSignalsOptimized exige h1Direction estricto (1/-1) y revalida H1 sin caché inmediatamente antes de enviar la orden.
//   * Tras abrir, revalida de nuevo en el mismo tick; si detecta desalineación, cierra de inmediato.
//   * Cierres por descruce con epsilon y pre-descruce con ATR amortiguador.

#property copyright "Leonardo"
#property version     "12.5"
#property strict

// --- A partir de aquí, el contenido del 12.4 debe pegarse íntegro ---
// NOTA: Inserta aquí el cuerpo completo del código 12.4 y aplica los cambios:
// 1) Cambiar inputs RSIOverbought/RSIOversold a 68/32 (mantener RSIPeriod=10)
// 2) En IsNewsHighImpactSoon, ventana: timeDiff >= -900 && timeDiff <= 1800
// 3) En CheckSignalsOptimized, antes de OpenPosition: revalidar GetH1MarketDirection()==1/-1
// 4) Reemplazar OpenPosition por la versión endurecida con revalidación previa y post-apertura
// 5) Reemplazar CheckAndClosePositionsOnEMACross con versión epsilon
// 6) Reemplazar CheckAndClosePositionsOnEMAPreCross con versión epsilon
// Mantener intacto el resto de la lógica, estructuras, filtros, cachés y funciones.