//+------------------------------------------------------------------+
//|                                                     SenderEA.mq4 |
//|                        Copyright 2024, Your Name/Company         |
//|                                             https://example.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Your Name/Company"
#property link      "https://example.com"
#property version   "1.53" // Final version with all fixes
#property strict

//--- Include new socket library
#include <socket-library-mt4-mt5.mqh>

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my";
input int ServerPort = 3000;
input string AccountIdentifier = "SenderAccount123";

//--- Global variables
ClientSocket *g_clientSocket = NULL;

bool ExtIsConnected = false;
bool ExtIdentified = false;
datetime ExtLastHeartbeatSent = 0;
int ExtHeartbeatInterval = 30;

struct KnownOrderState {
    int    ticket;
    double sl;
    double tp;
    double lots;
    int    type;
    string symbol;
};
KnownOrderState ExtKnownOpenOrders[200];
int ExtKnownOpenOrdersCount = 0;
int ExtLastHistoryTotal = 0;
datetime ExtLastOnTickProcessedTime = 0;

//+------------------------------------------------------------------+
//| JSON String Escaping                                             |
//+------------------------------------------------------------------+
string EscapeJsonString(string text) {
    string result = "";
    int len = StringLen(text);
    for (int i = 0; i < len; i++) {
        char ch = StringGetCharacter(text, i);
        switch (ch) {
            case '\\': result += "\\\\"; break;
            case '"':  result += "\\\""; break;
            case 8:    result += "\\b";  break;
            case 12:   result += "\\f";  break;
            case 10:   result += "\\n";  break;
            case 13:   result += "\\r";  break;
            case 9:    result += "\\t";  break;
            default:
                if (ch < 32 || ch == 127) {
                    string temp;
                    temp = "\\u00";
                    int h1 = ch / 16;
                    int h2 = ch % 16;
                    temp += (h1 < 10 ? (string)h1 : CharToStr((char)('A' + h1 - 10)));
                    temp += (h2 < 10 ? (string)h2 : CharToStr((char)('A' + h2 - 10)));
                    result += temp;
                } else {
                    result += CharToStr(ch);
                }
        }
    }
    return result;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    EventSetTimer(1);
    Print("SenderEA: Initialized. AccountIdentifier: ", AccountIdentifier);
    ExtLastOnTickProcessedTime = 0;
    ArrayResize(ExtKnownOpenOrders, 200);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
    Print("SenderEA: Deinitializing...");
    if (g_clientSocket != NULL) {
        Print("SenderEA: Closing socket connection.");
        delete g_clientSocket;
        g_clientSocket = NULL;
    }
    ExtIsConnected = false;
    ExtIdentified = false;
    Print("SenderEA: Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function (for heartbeats and connection management)        |
//+------------------------------------------------------------------+
void OnTimer() {
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        ExtIsConnected = false;
        ExtIdentified = false;
        ExtLastOnTickProcessedTime = 0;

        Print("SenderEA Timer: Not connected. Attempting to connect...");
        if (ConnectToServer()) {
            Print("SenderEA Timer: Connection attempt successful.");
        } else {
            Print("SenderEA Timer: Connection attempt failed. Will retry on next timer tick.");
            return;
        }
    }

    if (ExtIsConnected && !ExtIdentified) {
        Print("SenderEA Timer: Connected, attempting identification...");
        if (SendIdentification()) {
            ExtIdentified = true;
            Print("SenderEA Timer: Identification successful. Initializing order states.");
            InitializeOrderStates();
        } else {
            Print("SenderEA Timer: Identification failed. Will retry on next timer tick if still connected.");
            return;
        }
    }

    if (ExtIsConnected && ExtIdentified && (TimeCurrent() - ExtLastHeartbeatSent >= ExtHeartbeatInterval)) {
        string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + AccountIdentifier + "\",\"timestamp\":" + DoubleToString(TimeCurrent() * 1000.0, 0) + "}";
        string msgWithNewline = heartbeatMsg + "\n";

        Print("SenderEA: Preparing Heartbeat JSON: ", heartbeatMsg);

        Print("SenderEA Timer: Sending heartbeat...");
        if (g_clientSocket != NULL && g_clientSocket.Send(msgWithNewline)) {
            if (g_clientSocket.IsSocketConnected()) {
                ExtLastHeartbeatSent = TimeCurrent();
            } else {
                Print("SenderEA Timer: Heartbeat send attempted, but socket disconnected during/after send. Error: ", g_clientSocket.GetLastSocketError());
                ExtIsConnected = false;
                ExtIdentified = false;
            }
        } else {
            Print("SenderEA Timer: Failed to send heartbeat.");
            if (g_clientSocket != NULL) {
                 Print("SenderEA Timer: Heartbeat send error: ", g_clientSocket.GetLastSocketError());
                 if (!g_clientSocket.IsSocketConnected()){
                    ExtIsConnected = false;
                    ExtIdentified = false;
                 }
            } else {
                Print("SenderEA Timer: Heartbeat send failed, socket object is NULL.");
                ExtIsConnected = false;
                ExtIdentified = false;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Connect to server function                                       |
//+------------------------------------------------------------------+
bool ConnectToServer() {
    if (g_clientSocket != NULL) {
        Print("SenderEA: Cleaning up previous socket instance before reconnecting.");
        delete g_clientSocket;
        g_clientSocket = NULL;
    }
    ExtIsConnected = false;
    ExtIdentified = false;

    Print("SenderEA: Attempting to connect to ", ServerAddress, ":", ServerPort, "...");
    g_clientSocket = new ClientSocket(ServerAddress, ServerPort);

    if (g_clientSocket == NULL) {
        Print("SenderEA: Failed to allocate ClientSocket object memory.");
        return false;
    }

    if (g_clientSocket.IsSocketConnected()) {
        Print("SenderEA: Successfully connected to server.");
        ExtIsConnected = true;
        return true;
    } else {
        Print("SenderEA: Failed to connect to server. Error: ", g_clientSocket.GetLastSocketError());
        delete g_clientSocket;
        g_clientSocket = NULL;
        return false;
    }
}

//+------------------------------------------------------------------+
//| Send Identification Message                                      |
//+------------------------------------------------------------------+
bool SendIdentification() {
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
         Print("SenderEA: Cannot send identification, not connected.");
         ExtIsConnected = false;
         ExtIdentified = false;
         return false;
    }

    string identMsg = "{\"type\":\"identification\",\"role\":\"sender\",\"accountId\":\"" + AccountIdentifier + "\"}";
    string msgWithNewline = identMsg + "\n";

    Print("SenderEA: Preparing Identification JSON: ", identMsg);

    Print("SenderEA: Sending identification message...");
    if (g_clientSocket.Send(msgWithNewline)) {
        if (g_clientSocket.IsSocketConnected()) {
            Print("SenderEA: Identification message sent successfully.");
            ExtLastHeartbeatSent = TimeCurrent();
            return true;
        } else {
            Print("SenderEA: Identification send attempted, but socket disconnected. Error: ", g_clientSocket.GetLastSocketError());
            ExtIsConnected = false;
            ExtIdentified = false;
            return false;
        }
    } else {
        Print("SenderEA: Failed to send identification message. Error: ", g_clientSocket.GetLastSocketError());
        if (!g_clientSocket.IsSocketConnected()) {
            ExtIsConnected = false;
            ExtIdentified = false;
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| Initialize order states                                          |
//+------------------------------------------------------------------+
void InitializeOrderStates() {
    ExtKnownOpenOrdersCount = 0;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            if (ExtKnownOpenOrdersCount < ArraySize(ExtKnownOpenOrders)) {
                ExtKnownOpenOrders[ExtKnownOpenOrdersCount].ticket = OrderTicket();
                ExtKnownOpenOrders[ExtKnownOpenOrdersCount].sl = OrderStopLoss();
                ExtKnownOpenOrders[ExtKnownOpenOrdersCount].tp = OrderTakeProfit();
                ExtKnownOpenOrders[ExtKnownOpenOrdersCount].lots = OrderLots();
                ExtKnownOpenOrders[ExtKnownOpenOrdersCount].type = OrderType();
                ExtKnownOpenOrders[ExtKnownOpenOrdersCount].symbol = OrderSymbol();
                ExtKnownOpenOrdersCount++;
            } else {
                Print("SenderEA: InitializeOrderStates: Known open orders array is full. Max: ", ArraySize(ExtKnownOpenOrders));
                break;
            }
        }
    }
    ExtLastHistoryTotal = HistoryTotal();
    Print("SenderEA: Initial order states captured. Open orders tracked: ", ExtKnownOpenOrdersCount, ". HistoryTotal: ", ExtLastHistoryTotal);
    ExtLastOnTickProcessedTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| OnTick function                                                  |
//+------------------------------------------------------------------+
void OnTick() {
    if (!ExtIsConnected || !ExtIdentified || g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        if(ExtIsConnected || ExtIdentified){
            Print("SenderEA OnTick: Discrepancy in connection/identification state. Socket Connected: ", (g_clientSocket!=NULL && g_clientSocket.IsSocketConnected()), " ExtIsConnected: ", ExtIsConnected, " ExtIdentified: ", ExtIdentified);
            ExtIsConnected = false;
            ExtIdentified = false;
        }
        ExtLastOnTickProcessedTime = 0;
        return;
    }

    if (ExtLastOnTickProcessedTime == 0) {
         InitializeOrderStates();
         if(ExtLastOnTickProcessedTime == 0) {
            Print("SenderEA OnTick: ExtLastOnTickProcessedTime is still 0 after expected init. Re-initializing.");
            InitializeOrderStates();
            if(ExtLastOnTickProcessedTime == 0) {
                Print("SenderEA OnTick: Critical - could not initialize order states time. Aborting tick.");
                return;
            }
         }
    }

    // --- Detect Closed Orders by iterating history ---
    if (HistoryTotal() > ExtLastHistoryTotal) {
        for (int i = ExtLastHistoryTotal; i < HistoryTotal(); i++) {
            if (OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) {
                if (OrderType() == OP_BUY || OrderType() == OP_SELL) {
                    int knownIndex = FindKnownOrderIndex(OrderTicket());
                    if (knownIndex != -1) {
                        string orderSymbol = OrderSymbol();
                        int symDigits = (int)SymbolInfoInteger(orderSymbol, SYMBOL_DIGITS);

                        string orderJson = "{";
                        orderJson += "\"ticket\":" + (string)OrderTicket() + ",";
                        orderJson += "\"symbol\":\"" + EscapeJsonString(orderSymbol) + "\",";
                        orderJson += "\"type\":" + (string)OrderType() + ",";
                        orderJson += "\"lots\":" + DoubleToString(OrderLots(), MarketLotsDigits(orderSymbol)) + ",";
                        orderJson += "\"openPrice\":" + DoubleToString(OrderOpenPrice(), symDigits) + ",";
                        orderJson += "\"openTime\":\"" + TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS) + "\",";
                        orderJson += "\"stopLoss\":" + DoubleToString(OrderStopLoss(), symDigits) + ",";
                        orderJson += "\"takeProfit\":" + DoubleToString(OrderTakeProfit(), symDigits) + ",";
                        orderJson += "\"closePrice\":" + DoubleToString(OrderClosePrice(), symDigits) + ",";
                        orderJson += "\"closeTime\":\"" + TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS) + "\",";
                        orderJson += "\"commission\":" + DoubleToString(OrderCommission(), 2) + ",";
                        orderJson += "\"swap\":" + DoubleToString(OrderSwap(), 2) + ",";
                        orderJson += "\"profit\":" + DoubleToString(OrderProfit(), 2) + ",";
                        orderJson += "\"comment\":\"" + EscapeJsonString(OrderComment()) + "\",";
                        orderJson += "\"magicNumber\":" + (string)OrderMagicNumber(); // Last item
                        orderJson += "}";

                        string dealJson = "{";
                        dealJson += "\"order\":" + (string)OrderTicket() + ",";
                        dealJson += "\"entry\":\"DEAL_ENTRY_OUT\",";
                        dealJson += "\"lots\":" + DoubleToString(OrderLots(), MarketLotsDigits(orderSymbol)); // Last item
                        dealJson += "}";

                        SendTradeEvent("TRADE_TRANSACTION_DEAL", orderJson, dealJson);
                        RemoveKnownOrder(OrderTicket());
                    }
                }
            }
        }
    }
    ExtLastHistoryTotal = HistoryTotal();

    bool currentKnownOrderFound[200];
    if(ArraySize(ExtKnownOpenOrders) > 0) ArrayInitialize(currentKnownOrderFound, false);

    for (int i = 0; i < OrdersTotal(); i++) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            int orderTicket = OrderTicket();
            string orderSymbol = OrderSymbol();
            int symDigits = (int)SymbolInfoInteger(orderSymbol, SYMBOL_DIGITS);
            // double symPoint = SymbolInfoDouble(orderSymbol, SYMBOL_POINT); // Not used here

            double currentSL = OrderStopLoss();
            double currentTP = OrderTakeProfit();
            double currentLots = OrderLots();
            int orderType = OrderType();

            int knownIndex = FindKnownOrderIndex(orderTicket);

            string orderJson = "{";
            orderJson += "\"ticket\":" + (string)orderTicket + ",";
            orderJson += "\"symbol\":\"" + EscapeJsonString(orderSymbol) + "\",";
            orderJson += "\"type\":" + (string)orderType + ",";
            orderJson += "\"lots\":" + DoubleToString(currentLots, MarketLotsDigits(orderSymbol)) + ",";
            orderJson += "\"openPrice\":" + DoubleToString(OrderOpenPrice(), symDigits) + ",";
            orderJson += "\"openTime\":\"" + TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS) + "\",";
            orderJson += "\"stopLoss\":" + DoubleToString(currentSL, symDigits) + ",";
            orderJson += "\"takeProfit\":" + DoubleToString(currentTP, symDigits) + ",";
            orderJson += "\"closePrice\":0,";
            orderJson += "\"closeTime\":0,";
            orderJson += "\"commission\":" + DoubleToString(OrderCommission(), 2) + ",";
            orderJson += "\"swap\":" + DoubleToString(OrderSwap(), 2) + ",";
            orderJson += "\"profit\":" + DoubleToString(OrderProfit(), 2) + ",";
            orderJson += "\"comment\":\"" + EscapeJsonString(OrderComment()) + "\",";
            orderJson += "\"magicNumber\":" + (string)OrderMagicNumber(); // Last item
            orderJson += "}";

            if (knownIndex == -1) {
                SendTradeEvent("TRADE_TRANSACTION_ORDER_ADD", orderJson, "null");
                AddKnownOrder(orderTicket, currentSL, currentTP, currentLots, orderType, orderSymbol);
                if(ExtKnownOpenOrdersCount > 0 && (ExtKnownOpenOrdersCount-1) < ArraySize(currentKnownOrderFound)) {
                    currentKnownOrderFound[ExtKnownOpenOrdersCount-1] = true;
                }
            } else {
                if(knownIndex < ArraySize(currentKnownOrderFound)) currentKnownOrderFound[knownIndex] = true;

                bool slTpModified = false;
                if (NormalizeDouble(ExtKnownOpenOrders[knownIndex].sl, symDigits) != NormalizeDouble(currentSL, symDigits) ||
                    NormalizeDouble(ExtKnownOpenOrders[knownIndex].tp, symDigits) != NormalizeDouble(currentTP, symDigits)) {
                     slTpModified = true;
                }

                bool lotsModified = (MathAbs(ExtKnownOpenOrders[knownIndex].lots - currentLots) > MarketLotsStep(orderSymbol) * 0.1 );

                if (slTpModified || lotsModified) {
                    Print("SenderEA: Modification detected for ticket ", orderTicket,
                          ": Old SL=", ExtKnownOpenOrders[knownIndex].sl, ", New SL=", currentSL,
                          ", Old TP=", ExtKnownOpenOrders[knownIndex].tp, ", New TP=", currentTP,
                          ", Old Lots=", ExtKnownOpenOrders[knownIndex].lots, ", New Lots=", currentLots);
                    SendTradeEvent("TRADE_TRANSACTION_ORDER_UPDATE", orderJson, "null");
                    ExtKnownOpenOrders[knownIndex].sl = currentSL;
                    ExtKnownOpenOrders[knownIndex].tp = currentTP;
                    ExtKnownOpenOrders[knownIndex].lots = currentLots;
                }
            }
        }
    }

    for (int k = ExtKnownOpenOrdersCount - 1; k >= 0; k--) {
        if (k < ArraySize(currentKnownOrderFound) && !currentKnownOrderFound[k]) {
            Print("SenderEA OnTick: Order #", ExtKnownOpenOrders[k].ticket, " (Symbol: ", ExtKnownOpenOrders[k].symbol,
                  ") from known list not found in current open orders. Removing from internal list (event should have been sent by history check).");
            RemoveKnownOrderFromArray(k);
        }
    }
}

//+------------------------------------------------------------------+
//| Send Trade Event to Server                                       |
//+------------------------------------------------------------------+
void SendTradeEvent(string transactionType, string orderJson, string dealJson) {
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected() || !ExtIdentified) {
        Print("SenderEA: Cannot send trade event '", transactionType, "', not connected or not identified.");
        if (g_clientSocket != NULL && !g_clientSocket.IsSocketConnected()) ExtIsConnected = false;
        return;
    }

    string jsonPayload = "{";
    jsonPayload += "\"type\":\"tradeEvent\",";
    jsonPayload += "\"accountId\":\"" + AccountIdentifier + "\",";
    jsonPayload += "\"transactionType\":\"" + transactionType + "\",";
    jsonPayload += "\"timestamp\":" + DoubleToString(TimeCurrent() * 1000.0, 0) + ","; // Milliseconds
    jsonPayload += "\"order\":" + orderJson + ",";
    jsonPayload += "\"deal\":" + dealJson;
    jsonPayload += "}";

    string messageToSend = jsonPayload + "\n";
    Print("SenderEA: Preparing Trade Event JSON: ", jsonPayload);
    Print("SenderEA: Sending event: ", transactionType);

    if (!g_clientSocket.Send(messageToSend)) {
        Print("SenderEA: Failed to send trade event '", transactionType, "'. Error: ", g_clientSocket.GetLastSocketError());
        if (!g_clientSocket.IsSocketConnected()) {
            ExtIsConnected = false;
            ExtIdentified = false;
            ExtLastOnTickProcessedTime = 0;
        }
    } else {
        // Print("SenderEA: Trade event '", transactionType, "' sent to buffer.");
    }
}

//+------------------------------------------------------------------+
//| Helper functions for managing known orders                       |
//+------------------------------------------------------------------+
int FindKnownOrderIndex(int ticket) {
    for (int i = 0; i < ExtKnownOpenOrdersCount; i++) {
        if (ExtKnownOpenOrders[i].ticket == ticket) return i;
    }
    return -1;
}

void AddKnownOrder(int ticket, double sl, double tp, double lots, int orderTypeVal, string symbolStr) {
    if (FindKnownOrderIndex(ticket) != -1) return;

    if (ExtKnownOpenOrdersCount < ArraySize(ExtKnownOpenOrders)) {
        ExtKnownOpenOrders[ExtKnownOpenOrdersCount].ticket = ticket;
        ExtKnownOpenOrders[ExtKnownOpenOrdersCount].sl = sl;
        ExtKnownOpenOrders[ExtKnownOpenOrdersCount].tp = tp;
        ExtKnownOpenOrders[ExtKnownOpenOrdersCount].lots = lots;
        ExtKnownOpenOrders[ExtKnownOpenOrdersCount].type = orderTypeVal;
        ExtKnownOpenOrders[ExtKnownOpenOrdersCount].symbol = symbolStr;
        ExtKnownOpenOrdersCount++;
        Print("SenderEA: Added to known orders: #", ticket, " ", symbolStr);
    } else {
        Print("SenderEA: Known open orders array is full. Cannot add ticket: ", ticket);
    }
}

void RemoveKnownOrderFromArray(int index) {
    if (index < 0 || index >= ExtKnownOpenOrdersCount) return;
    Print("SenderEA: Removing from known orders by index ", index, ", ticket ", ExtKnownOpenOrders[index].ticket);
    for (int i = index; i < ExtKnownOpenOrdersCount - 1; i++) {
        ExtKnownOpenOrders[i] = ExtKnownOpenOrders[i+1];
    }
    if (ExtKnownOpenOrdersCount > 0) {
      ExtKnownOpenOrdersCount--;
    }
}

void RemoveKnownOrder(int ticket) {
    int index = FindKnownOrderIndex(ticket);
    if (index != -1) {
        RemoveKnownOrderFromArray(index);
    }
}

int MarketLotsDigits(string symbol) {
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    if (lotStep == 1.0) return 0;
    if (lotStep == 0.1) return 1;
    if (lotStep == 0.01) return 2;
    if (lotStep == 0.001) return 3;
    return 2;
}

double MarketLotsStep(string symbol) {
    return SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
}

string EnumToString(int enum_value) {
    switch(enum_value) {
        case OP_BUY: return "OP_BUY";
        case OP_SELL: return "OP_SELL";
        case OP_BUYLIMIT: return "OP_BUYLIMIT";
        case OP_SELLLIMIT: return "OP_SELLLIMIT";
        case OP_BUYSTOP: return "OP_BUYSTOP";
        case OP_SELLSTOP: return "OP_SELLSTOP";
        default: return "UNKNOWN_ORDER_TYPE_" + IntegerToString(enum_value);
    }
}
//+------------------------------------------------------------------+
