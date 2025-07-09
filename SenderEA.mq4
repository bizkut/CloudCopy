//+------------------------------------------------------------------+
//|                                                     SenderEA.mq4 |
//|                        Copyright 2024, Your Name/Company         |
//|                                             https://example.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Your Name/Company"
#property link      "https://example.com"
#property version   "1.50" // Version updated for library integration
#property strict

//--- Include new socket library
#include <socket-library-mt4-mt5.mqh> // Assuming this is in the MQL4/Include directory or same dir as EA

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my"; // Can now be hostname or IP
input int ServerPort = 3000;
input string AccountIdentifier = "SenderAccount123";

//--- Global variables
ClientSocket *g_clientSocket = NULL; // Use the ClientSocket class from the library

bool ExtIsConnected = false; // EA's internal flag for connection status
bool ExtIdentified = false;  // EA's internal flag for identification status
datetime ExtLastHeartbeatSent = 0;
int ExtHeartbeatInterval = 30;       // Seconds

struct KnownOrderState {
    int    ticket;
    double sl;
    double tp;
    double lots;
    int    type;
    string symbol;
};
KnownOrderState ExtKnownOpenOrders[200]; // Consider dynamic array or list if >200 orders likely
int ExtKnownOpenOrdersCount = 0;
int ExtLastHistoryTotal = 0;
datetime ExtLastOnTickProcessedTime = 0;

//+------------------------------------------------------------------+
//| JSON String Escaping (remains the same)                          |
//+------------------------------------------------------------------+
string EscapeJsonString(string text) {
    string result = "";
    int len = StringLen(text);
    for (int i = 0; i < len; i++) {
        char ch = StringGetCharacter(text, i);
        switch (ch) {
            case '\\': result += "\\\\"; break; // Backslash
            case '"':  result += "\\\""; break; // Double quote
            case 8:    result += "\\b";  break; // Backspace
            case 12:   result += "\\f";  break; // Form feed
            case 10:   result += "\\n";  break; // Newline
            case 13:   result += "\\r";  break; // Carriage return
            case 9:    result += "\\t";  break; // Tab
            // Note: Forward slash '/' is a valid character in JSON strings and typically doesn't need escaping unless for HTML embedding.
            // case '/':  result += "\\/";  break;
            default:
                if (ch < 32 || ch == 127) { // Control characters (0-31) and DEL (127)
                    string temp;
                    // Format as \\uXXXX - standard JSON Unicode escape
                    temp = "\\u00"; // All these are in the 00xx range
                    int h1 = ch / 16;
                    int h2 = ch % 16;
                    StringAppend(temp, h1 < 10 ? (string)h1 : CharToStr((char)('A' + h1 - 10)));
                    StringAppend(temp, h2 < 10 ? (string)h2 : CharToStr((char)('A' + h2 - 10)));
                    result += temp;
                } else {
                    result += CharToStr(ch); // Regular character
                }
        }
    }
    return result;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    // WSAStartup is not called here; assuming library handles it or relies on system state.
    EventSetTimer(1); // Timer for connection management and heartbeats
    Print("SenderEA: Initialized. AccountIdentifier: ", AccountIdentifier);
    ExtLastOnTickProcessedTime = 0;
    ArrayResize(ExtKnownOpenOrders, 200); // Ensure array is sized
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
    // WSACleanup is not called here; assuming library handles it or relies on system state.
    Print("SenderEA: Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function (for heartbeats and connection management)        |
//+------------------------------------------------------------------+
void OnTimer() {
    //--- Connection Management ---
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        ExtIsConnected = false; // Ensure our flag reflects reality
        ExtIdentified = false;  // If not connected, not identified
        ExtLastOnTickProcessedTime = 0; // Reset to force re-init of orders on next valid tick

        Print("SenderEA Timer: Not connected. Attempting to connect...");
        if (ConnectToServer()) { // This function now also sets ExtIsConnected
            Print("SenderEA Timer: Connection attempt successful.");
        } else {
            Print("SenderEA Timer: Connection attempt failed. Will retry on next timer tick.");
            return; // Wait for next timer tick to retry
        }
    }

    // At this point, g_clientSocket should be non-NULL and connected.
    // ExtIsConnected should be true.

    //--- Identification ---
    if (ExtIsConnected && !ExtIdentified) {
        Print("SenderEA Timer: Connected, attempting identification...");
        if (SendIdentification()) {
            ExtIdentified = true; // Mark as identified
            Print("SenderEA Timer: Identification successful. Initializing order states.");
            InitializeOrderStates(); // Initialize order states after successful identification
        } else {
            Print("SenderEA Timer: Identification failed. Will retry on next timer tick if still connected.");
            // If SendIdentification failed due to socket error, connection state will be handled
            // at the start of the next OnTimer call.
            return;
        }
    }

    //--- Heartbeat ---
    // Ensure we are connected AND identified before sending heartbeats
    if (ExtIsConnected && ExtIdentified && (TimeCurrent() - ExtLastHeartbeatSent >= ExtHeartbeatInterval)) {
        string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + AccountIdentifier + "\",\"timestamp\":" + (string)TimeCurrent() + "}";
        string msgWithNewline = heartbeatMsg + "\n";

        Print("SenderEA Timer: Sending heartbeat...");
        if (g_clientSocket != NULL && g_clientSocket.Send(msgWithNewline)) {
            if (g_clientSocket.IsSocketConnected()) { // Double check connection after send
                ExtLastHeartbeatSent = TimeCurrent();
                // Print("SenderEA Timer: Heartbeat sent successfully."); // Optional: for verbose logging
            } else {
                Print("SenderEA Timer: Heartbeat send attempted, but socket disconnected during/after send. Error: ", g_clientSocket.GetLastSocketError());
                // Connection will be handled by the next OnTimer cycle's initial check
                ExtIsConnected = false;
                ExtIdentified = false;
            }
        } else {
            Print("SenderEA Timer: Failed to send heartbeat.");
            if (g_clientSocket != NULL) {
                 Print("SenderEA Timer: Heartbeat send error: ", g_clientSocket.GetLastSocketError());
                 if (!g_clientSocket.IsSocketConnected()){ // If send failed because socket is no longer connected
                    ExtIsConnected = false;
                    ExtIdentified = false;
                 }
            } else {
                Print("SenderEA Timer: Heartbeat send failed, socket object is NULL.");
                ExtIsConnected = false; // Socket is null, definitely not connected
                ExtIdentified = false;
            }
            // Reconnection will be attempted by the next OnTimer cycle.
        }
    }
}

//+------------------------------------------------------------------+
//| Connect to server function                                       |
//+------------------------------------------------------------------+
bool ConnectToServer() {
    // Clean up existing socket object if it exists
    if (g_clientSocket != NULL) {
        Print("SenderEA: Cleaning up previous socket instance before reconnecting.");
        delete g_clientSocket;
        g_clientSocket = NULL;
    }
    ExtIsConnected = false; // Reset connection flag
    ExtIdentified = false;  // Reset identification flag

    Print("SenderEA: Attempting to connect to ", ServerAddress, ":", ServerPort, "...");
    g_clientSocket = new ClientSocket(ServerAddress, ServerPort);

    if (g_clientSocket == NULL) {
        Print("SenderEA: Failed to allocate ClientSocket object memory.");
        // No ExtIsConnected = false needed as it's already false
        return false;
    }

    if (g_clientSocket.IsSocketConnected()) {
        Print("SenderEA: Successfully connected to server.");
        ExtIsConnected = true; // Set our internal flag
        return true;
    } else {
        Print("SenderEA: Failed to connect to server. Error: ", g_clientSocket.GetLastSocketError());
        delete g_clientSocket; // Clean up failed socket object
        g_clientSocket = NULL;
        // No ExtIsConnected = false needed as it's already false
        return false;
    }
}

//+------------------------------------------------------------------+
//| Send Identification Message                                      |
//+------------------------------------------------------------------+
bool SendIdentification() {
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
         Print("SenderEA: Cannot send identification, not connected.");
         ExtIsConnected = false; // Update our flag
         ExtIdentified = false;
         return false;
    }

    string identMsg = "{\"type\":\"identification\",\"role\":\"sender\",\"accountId\":\"" + AccountIdentifier + "\"}";
    string msgWithNewline = identMsg + "\n";

    Print("SenderEA: Sending identification message...");
    if (g_clientSocket.Send(msgWithNewline)) {
        if (g_clientSocket.IsSocketConnected()) { // Check connection status after send
            Print("SenderEA: Identification message sent successfully.");
            ExtLastHeartbeatSent = TimeCurrent(); // Reset heartbeat timer as we had successful comms
            return true;
        } else {
            Print("SenderEA: Identification send attempted, but socket disconnected. Error: ", g_clientSocket.GetLastSocketError());
            ExtIsConnected = false; // Update our flag
            ExtIdentified = false;
            // Socket cleanup might be handled by OnTimer or a dedicated disconnect function if needed
            return false;
        }
    } else {
        Print("SenderEA: Failed to send identification message. Error: ", g_clientSocket.GetLastSocketError());
        if (!g_clientSocket.IsSocketConnected()) { // If send failed due to disconnection
            ExtIsConnected = false;
            ExtIdentified = false;
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| Initialize order states (logic remains the same)                 |
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
    ExtLastOnTickProcessedTime = TimeCurrent(); // Mark that initialization has happened
}


//+------------------------------------------------------------------+
//| OnTick function                                                  |
//+------------------------------------------------------------------+
void OnTick() {
    // Ensure connection and identification before processing ticks
    if (!ExtIsConnected || !ExtIdentified || g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        // If any of these conditions are true, we are not in a state to process trades.
        // OnTimer will handle reconnection and re-identification.
        // We reset ExtLastOnTickProcessedTime to ensure InitializeOrderStates is called
        // once connection & identification are re-established.
        if(ExtIsConnected || ExtIdentified){ // If we thought we were connected/identified but socket says otherwise
            Print("SenderEA OnTick: Discrepancy in connection/identification state. Socket Connected: ", (g_clientSocket!=NULL && g_clientSocket.IsSocketConnected()), " ExtIsConnected: ", ExtIsConnected, " ExtIdentified: ", ExtIdentified);
            ExtIsConnected = false;
            ExtIdentified = false;
        }
        ExtLastOnTickProcessedTime = 0;
        return;
    }

    // If this is the first tick after connection/identification and order initialization
    if (ExtLastOnTickProcessedTime == 0) {
         InitializeOrderStates(); // This also sets ExtLastOnTickProcessedTime
         // If after InitializeOrderStates, ExtLastOnTickProcessedTime is still 0 (e.g. if it failed somehow),
         // or if it simply needs to run once after connection, this check ensures it.
         // The current InitializeOrderStates always sets it, so this specific check might be redundant
         // if InitializeOrderStates is guaranteed to be called from OnTimer after identification.
         // For safety, keeping a check here.
         if(ExtLastOnTickProcessedTime == 0) { // Should not happen if InitializeOrderStates in OnTimer worked
            Print("SenderEA OnTick: ExtLastOnTickProcessedTime is still 0 after expected init. Re-initializing.");
            InitializeOrderStates();
            if(ExtLastOnTickProcessedTime == 0) { // Still not initialized
                Print("SenderEA OnTick: Critical - could not initialize order states time. Aborting tick.");
                return;
            }
         }
    }

    // --- Detect Closed Orders by iterating history ---
    if (HistoryTotal() > ExtLastHistoryTotal) {
        for (int i = ExtLastHistoryTotal; i < HistoryTotal(); i++) {
            if (OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) {
                if (OrderType() == OP_BUY || OrderType() == OP_SELL) { // Only market orders
                    int knownIndex = FindKnownOrderIndex(OrderTicket());
                    if (knownIndex != -1) { // If it was an order we were tracking
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
                        orderJson += "\"magicNumber\":" + (string)OrderMagicNumber();
                        orderJson += "}";

                        string dealJson = "{"; // Simplified deal representation for MQL4
                        dealJson += "\"order\":" + (string)OrderTicket() + ",";
                        dealJson += "\"entry\":\"DEAL_ENTRY_OUT\","; // Mimicking MQL5 deal entry type
                        dealJson += "\"lots\":" + DoubleToString(OrderLots(), MarketLotsDigits(orderSymbol)) + "";
                        dealJson += "}";

                        SendTradeEvent("TRADE_TRANSACTION_DEAL", orderJson, dealJson);
                        RemoveKnownOrder(OrderTicket()); // Remove from our tracked list
                    }
                }
            }
        }
    }
    ExtLastHistoryTotal = HistoryTotal();

    // --- Detect New Orders & Modifications for currently open orders ---
    bool currentKnownOrderFound[200]; // Assuming max 200 orders
    if(ArraySize(ExtKnownOpenOrders) > 0) ArrayInitialize(currentKnownOrderFound, false);

    for (int i = 0; i < OrdersTotal(); i++) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            int orderTicket = OrderTicket();
            string orderSymbol = OrderSymbol();
            int symDigits = (int)SymbolInfoInteger(orderSymbol, SYMBOL_DIGITS);
            double symPoint = SymbolInfoDouble(orderSymbol, SYMBOL_POINT);

            double currentSL = OrderStopLoss();
            double currentTP = OrderTakeProfit();
            double currentLots = OrderLots();
            int orderType = OrderType();

            int knownIndex = FindKnownOrderIndex(orderTicket);

            // Construct JSON for current order state
            string orderJson = "{";
            orderJson += "\"ticket\":" + (string)orderTicket + ",";
            orderJson += "\"symbol\":\"" + EscapeJsonString(orderSymbol) + "\",";
            orderJson += "\"type\":" + (string)orderType + ",";
            orderJson += "\"lots\":" + DoubleToString(currentLots, MarketLotsDigits(orderSymbol)) + ",";
            orderJson += "\"openPrice\":" + DoubleToString(OrderOpenPrice(), symDigits) + ",";
            orderJson += "\"openTime\":\"" + TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS) + "\",";
            orderJson += "\"stopLoss\":" + DoubleToString(currentSL, symDigits) + ",";
            orderJson += "\"takeProfit\":" + DoubleToString(currentTP, symDigits) + ",";
            // For open orders, closePrice and closeTime are not relevant yet from sender's perspective
            orderJson += "\"closePrice\":0,";
            orderJson += "\"closeTime\":0,";
            orderJson += "\"commission\":" + DoubleToString(OrderCommission(), 2) + ",";
            orderJson += "\"swap\":" + DoubleToString(OrderSwap(), 2) + ",";
            orderJson += "\"profit\":" + DoubleToString(OrderProfit(), 2) + ","; // Current floating profit
            orderJson += "\"comment\":\"" + EscapeJsonString(OrderComment()) + "\",";
            orderJson += "\"magicNumber\":" + (string)OrderMagicNumber();
            orderJson += "}";

            if (knownIndex == -1) { // New order
                SendTradeEvent("TRADE_TRANSACTION_ORDER_ADD", orderJson, "null");
                AddKnownOrder(orderTicket, currentSL, currentTP, currentLots, orderType, orderSymbol);
                if(ExtKnownOpenOrdersCount > 0 && (ExtKnownOpenOrdersCount-1) < ArraySize(currentKnownOrderFound)) {
                    currentKnownOrderFound[ExtKnownOpenOrdersCount-1] = true; // Mark the newly added one as found
                }
            } else { // Existing order, check for modifications
                if(knownIndex < ArraySize(currentKnownOrderFound)) currentKnownOrderFound[knownIndex] = true;

                bool slTpModified = false;
                // Check if SL/TP really changed, avoiding float precision issues and zero vs non-zero changes
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
                    // Update known state
                    ExtKnownOpenOrders[knownIndex].sl = currentSL;
                    ExtKnownOpenOrders[knownIndex].tp = currentTP;
                    ExtKnownOpenOrders[knownIndex].lots = currentLots;
                }
            }
        }
    }

    // --- Fallback: Check for orders in known list that are no longer in open orders pool ---
    // This might happen if a close event was missed by history scan due to timing or EA restart.
    for (int k = ExtKnownOpenOrdersCount - 1; k >= 0; k--) {
        if (k < ArraySize(currentKnownOrderFound) && !currentKnownOrderFound[k]) {
            // This order was in ExtKnownOpenOrders but was not found in the current OrdersTotal() scan.
            // It implies the order was closed. The history check should ideally capture this.
            // To avoid sending duplicate close events, we rely on history check.
            // This loop is mainly to clean up the internal ExtKnownOpenOrders list.
            Print("SenderEA OnTick: Order #", ExtKnownOpenOrders[k].ticket, " (Symbol: ", ExtKnownOpenOrders[k].symbol,
                  ") from known list not found in current open orders. Removing from internal list (event should have been sent by history check).");
            RemoveKnownOrderFromArray(k); // Just remove from local tracking
        }
    }
}

//+------------------------------------------------------------------+
//| Send Trade Event to Server                                       |
//+------------------------------------------------------------------+
void SendTradeEvent(string transactionType, string orderJson, string dealJson) {
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected() || !ExtIdentified) {
        Print("SenderEA: Cannot send trade event '", transactionType, "', not connected or not identified.");
        if (g_clientSocket != NULL && !g_clientSocket.IsSocketConnected()) ExtIsConnected = false; // Correct our flag
        return;
    }

    string jsonPayload = "{";
    jsonPayload += "\"type\":\"tradeEvent\",";
    jsonPayload += "\"accountId\":\"" + AccountIdentifier + "\",";
    jsonPayload += "\"transactionType\":\"" + transactionType + "\",";
    jsonPayload += "\"timestamp\":" + (string)TimeCurrent() + ",";
    jsonPayload += "\"order\":" + orderJson + ",";
    jsonPayload += "\"deal\":" + dealJson; // dealJson can be "null" for non-deal events
    jsonPayload += "}";

    string messageToSend = jsonPayload + "\n";
    Print("SenderEA: Sending event: ", transactionType); // Shorter log for less clutter
    // Print("SenderEA: Sending event full: ", messageToSend); // For debugging full payload

    if (!g_clientSocket.Send(messageToSend)) {
        Print("SenderEA: Failed to send trade event '", transactionType, "'. Error: ", g_clientSocket.GetLastSocketError());
        // If send failed, connection might be broken. Mark for reconnection.
        if (!g_clientSocket.IsSocketConnected()) {
            ExtIsConnected = false;
            ExtIdentified = false; // If connection lost, we need to re-identify
            ExtLastOnTickProcessedTime = 0; // Force re-init of orders after reconnection
            // No need to delete g_clientSocket here, OnTimer will handle it
        }
    } else {
        // Optionally confirm send if needed, but library handles internal retries if any
        // Print("SenderEA: Trade event '", transactionType, "' sent to buffer.");
    }
}

//+------------------------------------------------------------------+
//| Helper functions for managing known orders (logic remains same)  |
//+------------------------------------------------------------------+
int FindKnownOrderIndex(int ticket) {
    for (int i = 0; i < ExtKnownOpenOrdersCount; i++) {
        if (ExtKnownOpenOrders[i].ticket == ticket) return i;
    }
    return -1;
}

void AddKnownOrder(int ticket, double sl, double tp, double lots, int orderTypeVal, string symbolStr) {
    if (FindKnownOrderIndex(ticket) != -1) return; // Already known

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
        // Consider resizing ExtKnownOpenOrders if this happens often
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
      // Optional: Clear the last element if sensitive data or for neatness
      // ExtKnownOpenOrders[ExtKnownOpenOrdersCount].ticket = 0;
    }
}

void RemoveKnownOrder(int ticket) {
    int index = FindKnownOrderIndex(ticket);
    if (index != -1) {
        RemoveKnownOrderFromArray(index);
    }
}

// Helper for lot size string formatting
int MarketLotsDigits(string symbol) {
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    if (lotStep == 1.0) return 0;
    if (lotStep == 0.1) return 1;
    if (lotStep == 0.01) return 2;
    if (lotStep == 0.001) return 3;
    // Add more cases or a more generic way if needed
    return 2; // Default
}

// Helper for lot step
double MarketLotsStep(string symbol) {
    return SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
}


// EnumToString can be useful for logging (remains same)
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

//Dummy line to ensure replace block works if the file is identical.
