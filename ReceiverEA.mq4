//+------------------------------------------------------------------+
//|                                                   ReceiverEA.mq4 |
//|                        Copyright 2023, Your Name/Company         |
//|                                             https://example.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Your Name/Company"
#property link      "https://example.com"
#property version   "1.10" // Version updated for new socket library
#property strict

//--- Include necessary libraries
#include "socket-library-mt4-mt5.mqh" // Use the new socket library
#include <stdlib.mqh>                 // For StringToDouble, StringToInteger, etc.

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my"; // Can be hostname or IP
input int ServerPort = 3000;
input string SenderAccountIdToFollow = "SenderAccount123";
input int MagicNumberReceiver = 12345;

//--- Global variables
ClientSocket *g_clientSocket = NULL; // Use the ClientSocket class from the library

bool ExtIsConnected = false; // EA's internal flag for connection status
// ExtIdentified is implicitly true if connected for receiver, as ID is sent on connect
datetime ExtLastHeartbeatSent = 0;
int ExtHeartbeatInterval = 30; // Seconds
// string ExtSocketBuffer = ""; // No longer needed, library handles internal buffering for Receive

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    // WSAStartup is not called here; assuming library handles it or relies on system state.
    if (!ConnectToServer()) { // ConnectToServer now also sends identification
        Print("ReceiverEA: Initial connection and identification failed during OnInit.");
        // No WSACleanup here
        return(INIT_FAILED);
    }

    EventSetTimer(1); // Timer for heartbeats and checking messages
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
    // WSACleanup is not called here.
    Print("ReceiverEA: Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    //--- Check connection status & attempt reconnect/re-identify if needed ---
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        ExtIsConnected = false; // Ensure our flag reflects reality
        Print("ReceiverEA Timer: Not connected. Attempting to connect and identify...");
        if (ConnectToServer()) { // This function now also sets ExtIsConnected and sends ID
            Print("ReceiverEA Timer: Connection and identification attempt successful.");
        } else {
            Print("ReceiverEA Timer: Connection and identification attempt failed. Will retry on next timer tick.");
            return; // Wait for next timer tick
        }
    }
    // At this point, g_clientSocket should be non-NULL and connected, and identification sent.
    // ExtIsConnected should be true.

    //--- Send heartbeat if due ---
    if (ExtIsConnected && (TimeCurrent() - ExtLastHeartbeatSent >= ExtHeartbeatInterval)) {
        string currentReceiverMT4AccountId = IntegerToString(AccountNumber());
        string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + currentReceiverMT4AccountId + "\",\"timestamp\":" + (string)TimeCurrent() + "}";
        string msgWithNewline = heartbeatMsg + "\n";

        // Print("ReceiverEA Timer: Sending heartbeat..."); // Optional verbose log
        if (g_clientSocket.Send(msgWithNewline)) {
            if (g_clientSocket.IsSocketConnected()) {
                ExtLastHeartbeatSent = TimeCurrent();
            } else {
                Print("ReceiverEA Timer: Heartbeat send attempted, but socket disconnected. Error: ", g_clientSocket.GetLastSocketError());
                ExtIsConnected = false; // Will trigger reconnect in next OnTimer
            }
        } else {
            Print("ReceiverEA Timer: Failed to send heartbeat. Error: ", g_clientSocket.GetLastSocketError());
            if (!g_clientSocket.IsSocketConnected()){
                 ExtIsConnected = false; // Will trigger reconnect in next OnTimer
            }
        }
    }

    //--- Check for incoming messages ---
    if (ExtIsConnected) { // Only try to receive if we believe we are connected
        ReceiveMessages();
    }
}

//+------------------------------------------------------------------+
//| Connect to server and send identification                        |
//+------------------------------------------------------------------+
bool ConnectToServer() {
    if (g_clientSocket != NULL && g_clientSocket.IsSocketConnected()) {
        // If called when already connected, maybe just ensure ID was sent or resend?
        // For now, assume if socket object exists and is connected, initial ID was sent.
        // Or, the caller (OnInit/OnTimer) handles the logic of when to call this.
        // Let's stick to: if this function is called, it tries to establish a fresh connection & ID.
         Print("ReceiverEA: ConnectToServer called, but already connected. Assuming ID sent. To force reconnect, disconnect first.");
         ExtIsConnected = true; // Ensure flag is set
         return true;
    }

    // Clean up existing socket object if it exists
    if (g_clientSocket != NULL) {
        Print("ReceiverEA: Cleaning up previous socket instance.");
        delete g_clientSocket;
        g_clientSocket = NULL;
    }
    ExtIsConnected = false; // Reset connection flag

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
    ExtIsConnected = true; // Mark as connected

    // Send identification message
    string currentReceiverMT4AccountId = IntegerToString(AccountNumber());
    string identMsg = "{\"type\":\"identification\",\"role\":\"receiver\"";
    identMsg += ",\"accountId\":\"" + currentReceiverMT4AccountId + "\"";
    identMsg += ",\"listenTo\":\"" + SenderAccountIdToFollow + "\"}";
    string identMsgWithNewline = identMsg + "\n";

    if (g_clientSocket.Send(identMsgWithNewline)) {
        if (g_clientSocket.IsSocketConnected()) {
            Print("ReceiverEA: Identification message sent successfully.");
            ExtLastHeartbeatSent = TimeCurrent(); // Reset heartbeat as we had successful comms
            return true;
        } else {
            Print("ReceiverEA: Identification send attempted, but socket disconnected. Error: ", g_clientSocket.GetLastSocketError());
            ExtIsConnected = false; // Mark as disconnected
            // g_clientSocket will be cleaned up/recreated by OnTimer's logic
            return false;
        }
    } else {
        Print("ReceiverEA: Failed to send identification message. Error: ", g_clientSocket.GetLastSocketError());
        if (!g_clientSocket.IsSocketConnected()) {
            ExtIsConnected = false; // Mark as disconnected
        }
        // g_clientSocket might still exist but failed to send; OnTimer will handle.
        return false;
    }
}


//+------------------------------------------------------------------+
//| Receive messages from server                                     |
//+------------------------------------------------------------------+
void ReceiveMessages() {
    // Ensure we have a valid, connected socket
    if (g_clientSocket == NULL || !g_clientSocket.IsSocketConnected()) {
        if (ExtIsConnected) { // If our flag was true but socket says no
             Print("ReceiverEA: ReceiveMessages called but found disconnected state. Error: ", (g_clientSocket ? (string)g_clientSocket.GetLastSocketError() : "Socket is NULL"));
        }
        ExtIsConnected = false; // Correct our state
        return;
    }

    string message;
    int messagesProcessedThisCycle = 0;
    do {
        message = g_clientSocket.Receive("\n"); // Using newline as the message separator
        if (message != "") {
            // Print("ReceiverEA: Raw message received: '", message, "'"); // Debugging
            string trimmedMessage = StringTrim(message); // Use the new helper function
            if (trimmedMessage != "") { // Check the trimmed message
                 Print("ReceiverEA: Processing message: ", trimmedMessage); // Log the trimmed message
                 ProcessServerMessage(trimmedMessage); // Process the trimmed message
                 messagesProcessedThisCycle++;
            }
        }
    } while (message != "" && messagesProcessedThisCycle < 100); // Loop to process all buffered messages, with a safety break

    if (messagesProcessedThisCycle >= 100) {
        Print("ReceiverEA: Processed 100 messages in one cycle. More might be pending.");
    }

    // After attempting to receive, check connection status again, as Receive can detect a disconnect
    if (!g_clientSocket.IsSocketConnected()) {
        Print("ReceiverEA: Disconnected from server during/after receive operation. Error: ", g_clientSocket.GetLastSocketError());
        ExtIsConnected = false; // This will trigger reconnection attempt in OnTimer
        // No need to delete g_clientSocket here, OnTimer will handle it
    }
}


//+------------------------------------------------------------------+
//| Process a single message from the server (logic remains same)    |
//+------------------------------------------------------------------+
void ProcessServerMessage(string message) {
    // Print("Server message: ", message); // Already printed by ReceiveMessages
    string msgType = ParseJsonValue(message, "type");

    if (msgType == "ack") {
        string ackStatus = ParseJsonValue(message, "status");
        if(ackStatus == "authenticated_primary") {
            Print("ReceiverEA: ACK - Authenticated as PRIMARY data connection.");
        } else if (ackStatus == "authenticated_duplicate") {
            Print("ReceiverEA: ACK - Authenticated as DUPLICATE stream. No trade data will be sent to this instance.");
            // Consider if EA should stop or notify user prominently
        } else if (ackStatus == "unauthorized") {
            Print("ReceiverEA: ERROR - Server reported this account is UNAUTHORIZED.");
            // Consider if EA should stop or notify user prominently
        } else {
            // Generic ACK, e.g. for heartbeat
            // Print("ReceiverEA: Received ACK from server: ", message);
        }
        return;
    }
    if (msgType == "error") {
        Print("ReceiverEA: Received ERROR from server: ", message);
        string errorStatus = ParseJsonValue(message, "status");
         if (errorStatus == "unauthorized") {
            Print("ReceiverEA: CRITICAL - Server reported this account is UNAUTHORIZED during operation.");
            // This is more severe than an unauthorized ACK on identification
            // Consider stopping the EA or specific actions
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
//| Handle Open Trade Signal (logic remains same)                    |
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
//| Handle Modify Trade Signal (SL/TP) (logic remains same)          |
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
        // Print("ReceiverEA ModifyTrade: No significant change in SL/TP for ticket ", receiverTicket); // Optional log
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
//| Handle Close Trade Signal (logic remains same, but check lots)   |
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

    double lotsToClose = OrderLots(); // Default to full close
    if (closedLotsFromSignal > 0 && closedLotsFromSignal < OrderLots()) {
       // For now, still full close as per original logic.
       // To implement partial close: lotsToClose = closedLotsFromSignal;
       Print("ReceiverEA CloseTrade: Signal indicates partial close of ", closedLotsFromSignal, " for ticket ", receiverTicket, ". Full close will be attempted for simplicity as per current EA logic.");
    } else if (closedLotsFromSignal == 0) {
        Print("ReceiverEA CloseTrade: Signal did not specify lots to close for ticket ", receiverTicket, " (or specified 0). Assuming full close.");
    } else if (closedLotsFromSignal >= OrderLots()) {
        // Signal lots match or exceed order lots, so full close.
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
//| Find a copied trade (logic remains same)                         |
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
//| JSON Parsers (logic remains same)                                |
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
//| OnTick function (remains empty)                                  |
//+------------------------------------------------------------------+
void OnTick() {}

//+------------------------------------------------------------------+
//| Helper function to trim whitespace from both ends of a string    |
//+------------------------------------------------------------------+
string StringTrim(string text) {
    return StringTrimRight(StringTrimLeft(text));
}

//+------------------------------------------------------------------+
//| Helper for lot size string formatting (consistent with SenderEA) |
//+------------------------------------------------------------------+
int MarketLotsDigits(string symbol) {
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    if (lotStep == 1.0) return 0;
    if (lotStep == 0.1) return 1;
    if (lotStep == 0.01) return 2;
    if (lotStep == 0.001) return 3;
    return 2; // Default
}

// EnumToString can be useful for logging (consistent with SenderEA)
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
