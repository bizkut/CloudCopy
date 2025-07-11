//+------------------------------------------------------------------+
//|                                                   ReceiverEA.mq4 |
//|                        Copyright 2023, Your Name/Company         |
//|                                             https://example.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Your Name/Company"
#property link      "https://example.com"
#property version   "1.12" // Version updated for millisecond timestamp (manual provision)
#property strict

//--- Include necessary libraries
#include <socket-library-mt4-mt5.mqh> // Use the new socket library
#include <stdlib.mqh>                 // For StringToDouble, StringToInteger, etc.

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my"; // Can be hostname or IP
input int ServerPort = 3000;
input string SenderAccountIdToFollow = "SenderAccount123";
input int MagicNumberReceiver = 12345;

//--- Global variables
ClientSocket *g_clientSocket = NULL; // Use the ClientSocket class from the library

bool ExtIsConnected = false; // EA's internal flag for connection status
datetime ExtLastHeartbeatSent = 0;
int ExtHeartbeatInterval = 30; // Seconds

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    if (!ConnectToServer()) {
        Print("ReceiverEA: Initial connection and identification failed during OnInit.");
        return(INIT_FAILED);
    }
    EventSetTimer(1);
    Print("ReceiverEA: Initialized, connected and identified.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
    Print("ReceiverEA: Deinitializing...");
    if (g_clientSocket != NULL) {
        Print("ReceiverEA: Closing socket connection.");
        delete g_clientSocket;
        g_clientSocket = NULL;
    }
    ExtIsConnected = false;
    Print("ReceiverEA: Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        ExtIsConnected = false;
        Print("ReceiverEA Timer: Not connected. Attempting to connect and identify...");
        if (ConnectToServer()) {
            Print("ReceiverEA Timer: Connection and identification attempt successful.");
        } else {
            Print("ReceiverEA Timer: Connection and identification attempt failed. Will retry on next timer tick.");
            return;
        }
    }

    if (ExtIsConnected && (TimeCurrent() - ExtLastHeartbeatSent >= ExtHeartbeatInterval)) {
        string currentReceiverMT4AccountId = IntegerToString(AccountNumber());
        string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + currentReceiverMT4AccountId + "\",\"timestamp\":" + DoubleToString(TimeCurrent() * 1000.0, 0) + "}"; // Milliseconds
        string msgWithNewline = heartbeatMsg + "\n";

        Print("ReceiverEA: Preparing Heartbeat JSON: ", heartbeatMsg);

        if (g_clientSocket.Send(msgWithNewline)) {
            if (g_clientSocket.IsSocketConnected()) {
                ExtLastHeartbeatSent = TimeCurrent();
            } else {
                Print("ReceiverEA Timer: Heartbeat send attempted, but socket disconnected. Error: ", g_clientSocket.GetLastSocketError());
                ExtIsConnected = false;
            }
        } else {
            Print("ReceiverEA Timer: Failed to send heartbeat. Error: ", g_clientSocket.GetLastSocketError());
            if (!g_clientSocket.IsSocketConnected()){
                 ExtIsConnected = false;
            }
        }
    }

    if (ExtIsConnected) {
        ReceiveMessages();
    }
}

//+------------------------------------------------------------------+
//| Connect to server and send identification                        |
//+------------------------------------------------------------------+
bool ConnectToServer() {
    if (g_clientSocket != NULL && g_clientSocket.IsSocketConnected()) {
         Print("ReceiverEA: ConnectToServer called, but already connected. Assuming ID sent.");
         ExtIsConnected = true;
         return true;
    }

    if (g_clientSocket != NULL) {
        Print("ReceiverEA: Cleaning up previous socket instance.");
        delete g_clientSocket;
        g_clientSocket = NULL;
    }
    ExtIsConnected = false;

    Print("ReceiverEA: Attempting to connect to ", ServerAddress, ":", ServerPort, "...");
    g_clientSocket = new ClientSocket(ServerAddress, ServerPort);

    if (g_clientSocket == NULL) {
        Print("ReceiverEA: Failed to allocate ClientSocket object memory.");
        return false;
    }

    if (!g_clientSocket.IsSocketConnected()) {
        Print("ReceiverEA: Failed to connect to server. Error: ", g_clientSocket.GetLastSocketError());
        delete g_clientSocket;
        g_clientSocket = NULL;
        return false;
    }

    Print("ReceiverEA: Successfully connected to server. Sending identification...");
    ExtIsConnected = true;

    string currentReceiverMT4AccountId = IntegerToString(AccountNumber());
    string identMsg = "{\"type\":\"identification\",\"role\":\"receiver\"";
    identMsg += ",\"accountId\":\"" + currentReceiverMT4AccountId + "\"";
    identMsg += ",\"listenTo\":\"" + SenderAccountIdToFollow + "\"}";
    string identMsgWithNewline = identMsg + "\n";

    Print("ReceiverEA: Preparing Identification JSON: ", identMsg);

    if (g_clientSocket.Send(identMsgWithNewline)) {
        if (g_clientSocket.IsSocketConnected()) {
            Print("ReceiverEA: Identification message sent successfully.");
            ExtLastHeartbeatSent = TimeCurrent();
            return true;
        } else {
            Print("ReceiverEA: Identification send attempted, but socket disconnected. Error: ", g_clientSocket.GetLastSocketError());
            ExtIsConnected = false;
            return false;
        }
    } else {
        Print("ReceiverEA: Failed to send identification message. Error: ", g_clientSocket.GetLastSocketError());
        if (!g_clientSocket.IsSocketConnected()) {
            ExtIsConnected = false;
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| Receive messages from server                                     |
//+------------------------------------------------------------------+
void ReceiveMessages() {
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        if (ExtIsConnected) {
             Print("ReceiverEA: ReceiveMessages called but found disconnected state. Error: ", (g_clientSocket ? (string)g_clientSocket.GetLastSocketError() : "Socket is NULL"));
        }
        ExtIsConnected = false;
        return;
    }

    string message;
    int messagesProcessedThisCycle = 0;
    do {
        message = g_clientSocket.Receive("\n");
        if (message != "") {
            string trimmedMessage = StringTrim(message);
            if (trimmedMessage != "") {
                 Print("ReceiverEA: Processing message: ", trimmedMessage);
                 ProcessServerMessage(trimmedMessage);
                 messagesProcessedThisCycle++;
            }
        }
    } while (message != "" && messagesProcessedThisCycle < 100);

    if (messagesProcessedThisCycle >= 100) {
        Print("ReceiverEA: Processed 100 messages in one cycle. More might be pending.");
    }

    if (!g_clientSocket.IsSocketConnected()) {
        Print("ReceiverEA: Disconnected from server during/after receive operation. Error: ", g_clientSocket.GetLastSocketError());
        ExtIsConnected = false;
    }
}

//+------------------------------------------------------------------+
//| Process a single message from the server                         |
//+------------------------------------------------------------------+
void ProcessServerMessage(string message) {
    string msgType = ParseJsonValue(message, "type");

    if (msgType == "ack") {
        string ackStatus = ParseJsonValue(message, "status");
        if(ackStatus == "authenticated_primary") {
            Print("ReceiverEA: ACK - Authenticated as PRIMARY data connection.");
        } else if (ackStatus == "authenticated_duplicate") {
            Print("ReceiverEA: ACK - Authenticated as DUPLICATE stream. No trade data will be sent to this instance.");
        } else if (ackStatus == "unauthorized") {
            Print("ReceiverEA: ERROR - Server reported this account is UNAUTHORIZED.");
        }
        return;
    }
    if (msgType == "error") {
        Print("ReceiverEA: Received ERROR from server: ", message);
        string errorStatus = ParseJsonValue(message, "status");
         if (errorStatus == "unauthorized") {
            Print("ReceiverEA: CRITICAL - Server reported this account is UNAUTHORIZED during operation.");
        }
        return;
    }

    if (msgType == "tradeEvent") {
        string accountId = ParseJsonValue(message, "accountId");
        if (accountId != SenderAccountIdToFollow) {
            Print("ReceiverEA: Ignoring trade event from wrong sender: ", accountId, ". Expected: ", SenderAccountIdToFollow);
            return;
        }

        string orderJson = GetJsonObjectString(message, "order");
        string dealJson = GetJsonObjectString(message, "deal");
        string transactionType = ParseJsonValue(message, "transactionType");
        long senderOrderTicket = StringToInteger(ParseJsonValue(orderJson, "ticket"));

        if (transactionType == "TRADE_TRANSACTION_ORDER_ADD" || (transactionType == "TRADE_TRANSACTION_DEAL" && ParseJsonValue(dealJson,"entry") == "DEAL_ENTRY_IN")) {
            HandleOpenTrade(orderJson, senderOrderTicket);
        } else if (transactionType == "TRADE_TRANSACTION_ORDER_UPDATE") {
            HandleModifyTrade(orderJson, senderOrderTicket);
        } else if (transactionType == "TRADE_TRANSACTION_DEAL" && ParseJsonValue(dealJson,"entry") == "DEAL_ENTRY_OUT") {
            long dealOrderTicket = StringToInteger(ParseJsonValue(dealJson, "order"));
            if (dealOrderTicket == 0 && senderOrderTicket != 0) dealOrderTicket = senderOrderTicket;
            HandleCloseTrade(ParseJsonValue(orderJson, "symbol"), dealOrderTicket, StringToDouble(ParseJsonValue(dealJson, "lots")));
        } else {
            Print("ReceiverEA: Unhandled transactionType or combination: ", transactionType, " with order: ", orderJson, " and deal: ", dealJson);
        }
    } else {
        Print("ReceiverEA: Received unhandled message type '", msgType, "' or format: ", message);
    }
}

//+------------------------------------------------------------------+
//| Handle Open Trade Signal                                         |
//+------------------------------------------------------------------+
void HandleOpenTrade(string orderJson, long senderTicket) {
    string symbol = ParseJsonValue(orderJson, "symbol");
    int orderType = StringToInteger(ParseJsonValue(orderJson, "type"));
    double lots = StringToDouble(ParseJsonValue(orderJson, "lots"));
    double price = StringToDouble(ParseJsonValue(orderJson, "openPrice"));
    double sl = StringToDouble(ParseJsonValue(orderJson, "stopLoss"));
    double tp = StringToDouble(ParseJsonValue(orderJson, "takeProfit"));

    if (symbol == "" || lots <= 0 || (orderType != OP_BUY && orderType != OP_SELL)) {
        Print("ReceiverEA OpenTrade: Invalid parameters. Symbol:", symbol, " Lots:", lots, " Type:", orderType);
        return;
    }
    if (FindCopiedTrade(symbol, senderTicket, orderType) != -1) {
        Print("ReceiverEA OpenTrade: Trade for sender ticket ", senderTicket, " on ", symbol, " already exists. Ignoring.");
        return;
    }
    string comment = "CPY:" + SenderAccountIdToFollow + ":" + (string)senderTicket;
    if (orderType == OP_BUY) price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    if (orderType == OP_SELL) price = SymbolInfoDouble(symbol, SYMBOL_BID);

    int symDigits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    if (sl != 0) sl = NormalizeDouble(sl, symDigits); else sl = 0;
    if (tp != 0) tp = NormalizeDouble(tp, symDigits); else tp = 0;
    price = NormalizeDouble(price, symDigits);

    Print("ReceiverEA: Attempting to OPEN: ", EnumToString(orderType), " ", symbol, " ", DoubleToString(lots, MarketLotsDigits(symbol)), " lots @ ", DoubleToString(price,symDigits), " SL:", sl, " TP:", tp, " Comment:", comment);
    int ticket = OrderSend(symbol, orderType, lots, price, 3, sl, tp, comment, MagicNumberReceiver, 0, CLR_NONE);
    if (ticket > 0) {
        Print("ReceiverEA: Trade OPENED successfully. Receiver Ticket: ", ticket, " (Copied Sender Ticket: ", senderTicket, ")");
    } else {
        Print("ReceiverEA: Failed to OPEN trade. Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Handle Modify Trade Signal (SL/TP)                               |
//+------------------------------------------------------------------+
void HandleModifyTrade(string orderJson, long senderTicket) {
    string symbol = ParseJsonValue(orderJson, "symbol");
    double sl = StringToDouble(ParseJsonValue(orderJson, "stopLoss"));
    double tp = StringToDouble(ParseJsonValue(orderJson, "takeProfit"));
    int orderType = StringToInteger(ParseJsonValue(orderJson, "type"));

    if (symbol == "") { Print("ReceiverEA ModifyTrade: Symbol is empty."); return; }

    int receiverTicket = FindCopiedTrade(symbol, senderTicket, orderType);
    if (receiverTicket == -1) {
        Print("ReceiverEA ModifyTrade: Could not find copied trade for sender ticket ", senderTicket, " on ", symbol);
        return;
    }
    if (!OrderSelect(receiverTicket, SELECT_BY_TICKET)) {
        Print("ReceiverEA ModifyTrade: Failed to select order ticket ", receiverTicket, ". Error: ", GetLastError());
        return;
    }

    int symDigits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double currentOrderSL = OrderStopLoss();
    double currentOrderTP = OrderTakeProfit();
    double newSL = (sl != 0) ? NormalizeDouble(sl, symDigits) : currentOrderSL;
    double newTP = (tp != 0) ? NormalizeDouble(tp, symDigits) : currentOrderTP;

    if (MathAbs(currentOrderSL - newSL) < SymbolInfoDouble(symbol, SYMBOL_POINT) * 0.1 &&
        MathAbs(currentOrderTP - newTP) < SymbolInfoDouble(symbol, SYMBOL_POINT) * 0.1) {
        return;
    }

    Print("ReceiverEA: Attempting to MODIFY Ticket: ", receiverTicket, " Symbol: ", symbol, " New SL: ", newSL, " New TP: ", newTP);
    bool modified = OrderModify(receiverTicket, OrderOpenPrice(), newSL, newTP, 0, CLR_NONE);
    if (modified) {
        Print("ReceiverEA: Trade MODIFIED successfully. Ticket: ", receiverTicket);
    } else {
        Print("ReceiverEA: Failed to MODIFY trade. Ticket: ", receiverTicket, " Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Handle Close Trade Signal                                        |
//+------------------------------------------------------------------+
void HandleCloseTrade(string symbol, long senderTicket, double closedLotsFromSignal) {
    if (symbol == "") { Print("ReceiverEA CloseTrade: Symbol is empty."); return; }

    int receiverTicket = FindCopiedTrade(symbol, senderTicket, -1);
    if (receiverTicket == -1) {
        Print("ReceiverEA CloseTrade: Could not find copied trade for sender ticket ", senderTicket, " on ", symbol);
        return;
    }
    if (!OrderSelect(receiverTicket, SELECT_BY_TICKET)) {
        Print("ReceiverEA CloseTrade: Failed to select order ticket ", receiverTicket, ". Error: ", GetLastError());
        return;
    }

    double lotsToClose = OrderLots();
    if (closedLotsFromSignal > 0 && closedLotsFromSignal < OrderLots()) {
       Print("ReceiverEA CloseTrade: Signal indicates partial close of ", closedLotsFromSignal, " for ticket ", receiverTicket, ". Full close will be attempted for simplicity as per current EA logic.");
    } else if (closedLotsFromSignal == 0) {
        Print("ReceiverEA CloseTrade: Signal did not specify lots to close for ticket ", receiverTicket, " (or specified 0). Assuming full close.");
    }

    Print("ReceiverEA: Attempting to CLOSE Ticket: ", receiverTicket, " Symbol: ", symbol, " Lots: ", DoubleToString(lotsToClose, MarketLotsDigits(symbol)));
    bool closed = OrderClose(receiverTicket, lotsToClose, OrderClosePrice(), 3, CLR_NONE);
    if (closed) {
        Print("ReceiverEA: Trade CLOSED successfully. Ticket: ", receiverTicket);
    } else {
        Print("ReceiverEA: Failed to CLOSE trade. Ticket: ", receiverTicket, " Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Find a copied trade                                              |
//+------------------------------------------------------------------+
int FindCopiedTrade(string symbol, long senderTicket, int orderTypeToMatch) {
    string searchComment = "CPY:" + SenderAccountIdToFollow + ":" + (string)senderTicket;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            if (OrderSymbol() == symbol && OrderComment() == searchComment && OrderMagicNumber() == MagicNumberReceiver) {
                if (orderTypeToMatch == -1 || OrderType() == orderTypeToMatch) {
                    return OrderTicket();
                }
            }
        }
    }
    return -1;
}

//+------------------------------------------------------------------+
//| JSON Parsers                                                     |
//+------------------------------------------------------------------+
string ParseJsonValue(string json, string key) {
    string searchPattern = "\"" + key + "\":";
    int keyPos = StringFind(json, searchPattern);
    if (keyPos == -1) return "";
    int valueStartPos = keyPos + StringLen(searchPattern);
    char firstChar = StringGetCharacter(json, valueStartPos);
    while(firstChar == ' ' && valueStartPos < StringLen(json) -1) {
        valueStartPos++;
        firstChar = StringGetCharacter(json, valueStartPos);
    }
    if (firstChar == '"') {
        valueStartPos++;
        int valueEndPos = StringFind(json, "\"", valueStartPos);
        if (valueEndPos == -1) return "";
        return StringSubstr(json, valueStartPos, valueEndPos - valueStartPos);
    } else {
        int valueEndPos = StringLen(json);
        int commaPos = StringFind(json, ",", valueStartPos);
        int bracePos = StringFind(json, "}", valueStartPos);
        if (commaPos != -1) valueEndPos = commaPos;
        if (bracePos != -1 && bracePos < valueEndPos) valueEndPos = bracePos;
        string val = StringSubstr(json, valueStartPos, valueEndPos - valueStartPos);
        return StringTrim(val);
    }
}

string GetJsonObjectString(string json, string key) {
    string searchPattern = "\"" + key + "\":{";
    int keyPos = StringFind(json, searchPattern);
    if (keyPos == -1) return "";
    int objectStartPos = keyPos + StringLen(searchPattern) - 1;
    int braceCount = 0;
    for (int i = objectStartPos; i < StringLen(json); i++) {
        char currentChar = StringGetCharacter(json, i);
        if (currentChar == '{') braceCount++;
        else if (currentChar == '}') {
            braceCount--;
            if (braceCount == 0) return StringSubstr(json, objectStartPos, i - objectStartPos + 1);
        }
    }
    return "";
}

//+------------------------------------------------------------------+
//| OnTick function                                                  |
//+------------------------------------------------------------------+
void OnTick() {}

//+------------------------------------------------------------------+
//| Helper function to trim whitespace from both ends of a string    |
//+------------------------------------------------------------------+
string StringTrim(string text) {
    return StringTrimRight(StringTrimLeft(text));
}

//+------------------------------------------------------------------+
//| Helper for lot size string formatting                            |
//+------------------------------------------------------------------+
int MarketLotsDigits(string symbol) {
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    if (lotStep == 1.0) return 0;
    if (lotStep == 0.1) return 1;
    if (lotStep == 0.01) return 2;
    if (lotStep == 0.001) return 3;
    return 2;
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
