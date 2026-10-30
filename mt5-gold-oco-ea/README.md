# Gold OCO Breakout EA (MetaTrader 5, HFM)

An Expert Advisor for **XAUUSD** that runs this cycle:

1. Places a **Buy Stop** above and a **Sell Stop** below the reference price (the last closing price, or the current price if the last close is old or too far away).
2. When one order fills, it **deletes the other** (OCO). If both fill in a spike, it closes the newer one.
3. Manages the trade:
   - initial stop loss (default 4 pips = $4.00 gold move)
   - **break-even lock**: at +0.6 pips, the SL moves to +0.2 pips
   - **trailing stop**: 0.4 pips behind price
   - optional profit ladder and partial close
   - **time stop**: closes the trade if it hasn't reached the lock within 10 minutes
4. When the trade closes, it places a new pair.

It starts as soon as it is attached (an optional session filter is available), pauses around **high-impact USD news**, skips orders when the **spread is wide**, and stops for the day after the **daily loss limits** are hit.

## Pip convention

`InpPipSize = 1.0` means **1 pip = $1.00 gold price move**:

| Lot | Money per pip | 4-pip SL | 0.2-pip lock |
|---|---|---|---|
| 0.01 | $1 | $4 | $0.20 |
| 0.15 | $15 | $60 | $3 |
| 1.00 | $100 | $400 | $20 |

When the EA starts, the Experts tab prints the symbol's digits, stop level, lot size, money per pip and SL money. Check that they match what you expect.

## Install

1. In MT5: **File → Open Data Folder → MQL5 → Experts**. Copy `GoldOCOBreakout.mq5` there.
2. Open it in **MetaEditor** (F4) and press **Compile** (F7). It should show 0 errors.
3. In MT5, enable **Algo Trading**. Drag the EA onto an **XAUUSD** chart (any timeframe).
4. For the news filter to work live, allow the economic calendar (enabled by default in MT5).

## Session time (important)

Session inputs use **broker server time** (the time shown in Market Watch), not your local time.
HFM server time is usually GMT+2 in winter and GMT+3 in summer, so New York 8:30–12:00 ≈ **15:30–19:00 server time**.
Compare Market Watch time with New York time and adjust `InpSessionStart` / `InpSessionEnd` if they differ.

## Main settings

| Setting | Default | Meaning |
|---|---|---|
| `InpLotMode` / `InpFixedLot` / `InpRiskMoney` | Fixed, 0.15, 60 | Fixed lot, or a lot calculated so the SL costs `InpRiskMoney` |
| `InpEntryOffsetPips` | 0.735 | Pending order distance from the reference |
| `InpPendingExpiryMin` | 30 | Re-center untriggered orders around current price |
| `InpStopLossPips` / `InpTakeProfitPips` | 4.0 / 0 | Initial SL; no TP by default, profit is secured by the trailing stop |
| `InpBETriggerPips` / `InpBELockPips` | 0.6 / 0.2 | Break-even lock |
| `InpTrailStartPips` / `InpTrailGapPips` / `InpTrailStepPips` | 0.6 / 0.4 / 0.05 | Trailing stop |
| `InpUseLadder` | off | Extra locks: +1.5 → +0.8, +3.0 → +2.0 |
| `InpUsePartialClose` | off | Close 50% at +1.0 pips |
| `InpUseTimeStop` / `InpTimeStopMin` | on / 10 | Close if not locked in time |
| `InpUseSession` | off | Off = starts trading as soon as the EA is on; on = only between `InpSessionStart` and `InpSessionEnd` (server time) |
| `InpMaxSpreadPips` | 0.60 | No new orders above this spread |
| `InpMaxLossesPerDay` / `InpMaxDailyLoss` | 3 / 150 | Stop for the day |
| `InpCooldownSecAfterLoss` | 90 | Pause after a losing trade |
| `InpUseNewsFilter` | on | No trading 15 min before / after high-impact USD news |

## Testing

1. **Strategy Tester** (Ctrl+R): choose the EA and XAUUSD, and set Modelling to **"Every tick based on real ticks"**. Other modes give unrealistic results with distances this small.
2. The economic calendar doesn't work in the tester. To skip news days in a backtest, list the times in `InpManualNews`, for example `2026.11.06 15:30;2026.11.12 15:30`.
3. Run on a **demo account for 2–4 weeks** before going live. The chart panel shows trades, win rate, average win, average loss and net for today and in total.

The break-even math: with a $60 loss and a 90% win rate, the **average win must be above about $6.67** to make money.

> Trading involves risk of loss. Test thoroughly on demo before using real money.
