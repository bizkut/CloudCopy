//+------------------------------------------------------------------+
//|                                                   ReceiverEA.mq4 |
//|                        Copyright 2023, Your Name/Company |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Your Name/Company"
#property link      "https://example.com"
#property version   "1.00"
#property strict

//--- Include necessary libraries
#include <WinSock2.mqh> // For socket functions
#include <stdlib.mqh>   // For StringToDouble, StringToInteger, etc.
// #include <Trade\Trade.mqh> // Not used in this version as direct MQL4 functions are employed

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my";
input int ServerPort = 3000;
// input string ReceiverAccountId = "ReceiverAccount456"; // To identify this receiver account on the server - REMOVED, will use AccountNumber()
input string SenderAccountIdToFollow = "SenderAccount123"; // Which sender account to listen to
input int MagicNumberReceiver = 12345; // Magic number for trades opened by this EA

//--- Global variables
int ExtSocketHandle = INVALID_SOCKET;
bool ExtIsConnected = false;
datetime ExtLastHeartbeatSent = 0;
int ExtHeartbeatInterval = 30; // Seconds
string ExtSocketBuffer = ""; // Buffer for incoming socket data

// CTrade ExtTrade; // Using direct MQL4 order functions instead of CTrade for this version.

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Initialize WinSock
    int error;
    WORD wVersionRequested = MAKEWORD(2, 2);
    WSADATA wsaData;
    error = WSAStartup(wVersionRequested, wsaData);
    if (error != 0)
    {
        Print("WSAStartup failed with error: ", error);
        return(INIT_FAILED);
    }

    if (!ConnectToServer())
    {
        Print("Failed to connect to server during OnInit.");
        WSACleanup();
        return(INIT_FAILED);
    }

    //--- Set a timer for heartbeats and checking messages
    EventSetTimer(1); // Check every 1 second

    Print("Receiver EA initialized. Attempting to connect and identify...");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    if (ExtSocketHandle != INVALID_SOCKET)
    {
        Print("Closing socket connection...");
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
    }
    ExtIsConnected = false;
    WSACleanup();
    Print("Receiver EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
    //--- Check connection status
    if (!ExtIsConnected)
    {
        //Print("Timer: Not connected. Attempting to reconnect...");
        if (!ConnectToServer())
        {
            //Print("Timer: Reconnect attempt failed.");
            return;
        }
        Print("Timer: Reconnected successfully.");
    }

    //--- Send heartbeat if due
    if (TimeCurrent() - ExtLastHeartbeatSent >= ExtHeartbeatInterval)
    {
        string currentReceiverMT4AccountId = IntegerToString(AccountNumber());
        string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + currentReceiverMT4AccountId + "\",\"timestamp\":" + (string)TimeCurrent() + "}";
        if (SocketSend(ExtSocketHandle, heartbeatMsg + "\n", StringLen(heartbeatMsg + "\n")) <= 0)
        {
            Print("Failed to send heartbeat to account '",currentReceiverMT4AccountId,"'. Error: ", GetLastError());
            SocketClose(ExtSocketHandle); // Assume connection is broken
            ExtSocketHandle = INVALID_SOCKET;
            ExtIsConnected = false;
        }
        else
        {
            //Print("Heartbeat sent.");
            ExtLastHeartbeatSent = TimeCurrent();
        }
    }

    //--- Check for incoming messages
    ReceiveMessages();
}

//+------------------------------------------------------------------+
//| Connect to server function                                       |
//+------------------------------------------------------------------+
bool ConnectToServer()
{
    if (ExtIsConnected && ExtSocketHandle != INVALID_SOCKET) return true;

    ExtSocketHandle = SocketCreate();
    if (ExtSocketHandle == INVALID_SOCKET)
    {
        Print("Failed to create socket. Error: ", GetLastError());
        return false;
    }

    // Set to non-blocking is crucial for EAs to not freeze MT4 terminal
    int flags = 1; // Non-blocking
    if (SocketSetOption(ExtSocketHandle, SO_NONBLOCK, flags) != 0) {
       Print("Failed to set non-blocking mode. Error: ", GetLastError());
       // Continue anyway, but it might be less responsive or hang
    }


    if (!SocketConnect(ExtSocketHandle, ServerAddress, ServerPort, 5000)) // 5 seconds timeout
    {
        int err = GetLastError();
        // For non-blocking sockets, WSAEWOULDBLOCK (10035) is expected during connection attempt.
        // We need a loop or a different way to check when connection is established.
        // For simplicity here, we'll treat immediate failure or timeout as failure.
        // A more robust non-blocking connect needs to check socket state later.
        // Given the SocketConnect timeout parameter, it might handle this internally for MQL4.
        // If it returns false and error is not WSAEWOULDBLOCK, it's a real error.

        Print("Failed to connect to server ", ServerAddress, ":", ServerPort, ". Error: ", err);
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        return false;
    }

    ExtIsConnected = true; // Assume connected if SocketConnect returns true
    Print("Successfully connected to server: ", ServerAddress, ":", ServerPort);
    ExtLastHeartbeatSent = TimeCurrent(); // Initialize heartbeat timer

    // Get the account number for ReceiverAccountId
    string currentReceiverMT4AccountId = IntegerToString(AccountNumber());

    // Send identification message
    string identMsg = "{\"type\":\"identification\",\"role\":\"receiver\"";
    identMsg += ",\"accountId\":\"" + currentReceiverMT4AccountId + "\"";
    identMsg += ",\"listenTo\":\"" + SenderAccountIdToFollow + "\"}";

    if (SocketSend(ExtSocketHandle, identMsg + "\n", StringLen(identMsg + "\n")) <= 0)
    {
        Print("Failed to send identification message for account '", currentReceiverMT4AccountId, "'. Error: ", GetLastError());
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
        return false;
    }
    Print("Identification message sent: Receiver Account '", currentReceiverMT4AccountId, "' listening to '", SenderAccountIdToFollow, "'");
    return true;
}

//+------------------------------------------------------------------+
//| Receive messages from server                                     |
//+------------------------------------------------------------------+
void ReceiveMessages()
{
    if (!ExtIsConnected || ExtSocketHandle == INVALID_SOCKET) return;

    char buffer[4096]; // Read buffer
    int bytesRead = 0;

    // Non-blocking read
    // SocketIsReadable is one way, or just try to receive.
    // If socket is non-blocking, SocketRecv should return -1 and GetLastError() == WSAEWOULDBLOCK if no data.

    ZeroMemory(buffer);
    // For non-blocking sockets, we expect this to return immediately.
    // MSG_PEEK could be used to check for data without removing it, but not standard in WinSock2.mqh's SocketRecv typically.
    // The standard approach is to call recv and check for WSAEWOULDBLOCK.
    bytesRead = SocketRecv(ExtSocketHandle, buffer, sizeof(buffer) - 1, 0);

    if (bytesRead > 0) {
        buffer[bytesRead] = 0; // Null-terminate
        ExtSocketBuffer += CharArrayToString(buffer, 0, bytesRead);
        //Print("DEBUG: Received ", bytesRead, " bytes. Buffer now: '", ExtSocketBuffer, "'");

        int newlinePos;
        while ((newlinePos = StringFind(ExtSocketBuffer, "\n")) != -1) {
            string message = StringSubstr(ExtSocketBuffer, 0, newlinePos);
            ExtSocketBuffer = StringSubstr(ExtSocketBuffer, newlinePos + 1);

            if (StringTrim(message) != "") {
                Print("Processing message: ", message);
                ProcessServerMessage(message);
            }
        }
    }
    else if (bytesRead < 0)
    {
        int error = GetLastError();
        if (error != WSAEWOULDBLOCK && error != 0) // WSAEWOULDBLOCK is expected for non-blocking if no data
        {
            Print("SocketRecv failed. Error: ", error);
            SocketClose(ExtSocketHandle);
            ExtSocketHandle = INVALID_SOCKET;
            ExtIsConnected = false;
        }
        // else, no data available, which is fine for non-blocking
    }
    // if bytesRead == 0, connection gracefully closed by server
    else if (bytesRead == 0 && ExtIsConnected)
    {
        Print("Server closed connection.");
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
    }
}

//+------------------------------------------------------------------+
//| Process a single message from the server                         |
//+------------------------------------------------------------------+
void ProcessServerMessage(string message)
{
    Print("Server message: ", message);
    // Basic JSON parsing (MQL4 doesn't have a built-in JSON parser)
    // This is a very simplified parser. A robust one is complex.
    string msgType = ParseJsonValue(message, "type");

    if (msgType == "ack") {
        // Print("Received ACK from server: ", message);
        return;
    }
    if (msgType == "error") {
        Print("Received ERROR from server: ", message);
        return;
    }

    if (msgType == "tradeEvent") {
        string accountId = ParseJsonValue(message, "accountId");
        if (accountId != SenderAccountIdToFollow) {
            Print("Ignoring trade event from wrong sender: ", accountId);
            return;
        }

        string orderJson = GetJsonObjectString(message, "order");
        string dealJson = GetJsonObjectString(message, "deal");
        // MQL5's OnTradeTransaction sends transactionType, which indicates the action.
        // e.g. TRADE_TRANSACTION_ORDER_ADD, TRADE_TRANSACTION_ORDER_UPDATE, TRADE_TRANSACTION_DEAL
        // For MQL4, the sender would need to determine this and send a clear "action" field.
        // Assuming sender adds an "action" field: "NEW", "MODIFY", "CLOSE"
        // Or we infer from transactionType (MQL5 style) or deal details.

        // Let's try to infer based on typical MQL5 transaction types the sender might forward
        string transactionType = ParseJsonValue(message, "transactionType"); // e.g. "TRADE_TRANSACTION_ORDER_ADD"
        long senderOrderTicket = StringToInteger(ParseJsonValue(orderJson, "ticket"));

        if (transactionType == "TRADE_TRANSACTION_ORDER_ADD" || (transactionType == "TRADE_TRANSACTION_DEAL" && ParseJsonValue(dealJson,"entry") == "DEAL_ENTRY_IN")) {
            HandleOpenTrade(orderJson, senderOrderTicket);
        } else if (transactionType == "TRADE_TRANSACTION_ORDER_UPDATE") {
            HandleModifyTrade(orderJson, senderOrderTicket);
        } else if (transactionType == "TRADE_TRANSACTION_DEAL" && ParseJsonValue(dealJson,"entry") == "DEAL_ENTRY_OUT") {
            // A DEAL_ENTRY_OUT means a position was closed or partially closed.
            // We need the order ticket associated with this deal to find our copied trade.
            long dealOrderTicket = StringToInteger(ParseJsonValue(dealJson, "order"));
            if (dealOrderTicket == 0 && senderOrderTicket != 0) dealOrderTicket = senderOrderTicket; // Fallback if deal.order is not the one we track

            HandleCloseTrade(ParseJsonValue(orderJson, "symbol"), dealOrderTicket, StringToDouble(ParseJsonValue(dealJson, "lots")));
        } else {
            Print("Unhandled transactionType or combination: ", transactionType, " with order: ", orderJson, " and deal: ", dealJson);
        }
    } else {
        Print("Received unhandled message type '", msgType, "' or format: ", message);
    }
}

//+------------------------------------------------------------------+
//| Handle Open Trade Signal                                         |
//+------------------------------------------------------------------+
void HandleOpenTrade(string orderJson, long senderTicket) {
    string symbol = ParseJsonValue(orderJson, "symbol");
    int orderType = StringToInteger(ParseJsonValue(orderJson, "type")); // OP_BUY, OP_SELL etc.
    double lots = StringToDouble(ParseJsonValue(orderJson, "lots"));
    double price = StringToDouble(ParseJsonValue(orderJson, "openPrice")); // For market orders, this is indicative.
    double sl = StringToDouble(ParseJsonValue(orderJson, "stopLoss"));
    double tp = StringToDouble(ParseJsonValue(orderJson, "takeProfit"));
    // string senderComment = ParseJsonValue(orderJson, "comment"); // We'll create our own

    if (symbol == "" || lots <= 0 || (orderType != OP_BUY && orderType != OP_SELL)) { // Simplified: only market orders
        Print("OpenTrade: Invalid parameters. Symbol:", symbol, " Lots:", lots, " Type:", orderType);
        return;
    }

    // Check if this trade (by sender's ticket) was already copied to prevent duplicates from re-processed messages
    if (FindCopiedTrade(symbol, senderTicket, orderType) != -1) {
        Print("OpenTrade: Trade for sender ticket ", senderTicket, " on ", symbol, " already exists. Ignoring duplicate open signal.");
        return;
    }

    string comment = "CPY:" + SenderAccountIdToFollow + ":" + (string)senderTicket;

    // For market orders, get current prices
    if (orderType == OP_BUY) price = MarketInfo(symbol, MODE_ASK);
    if (orderType == OP_SELL) price = MarketInfo(symbol, MODE_BID);

    // Normalize SL/TP (ensure they are valid distances if relative, or absolute values)
    if (sl != 0) sl = NormalizeDouble(sl, MarketInfo(symbol, MODE_DIGITS)); else sl = 0;
    if (tp != 0) tp = NormalizeDouble(tp, MarketInfo(symbol, MODE_DIGITS)); else tp = 0;
    price = NormalizeDouble(price, MarketInfo(symbol, MODE_DIGITS));

    Print("Attempting to OPEN: ", EnumToString(orderType), " ", symbol, " ", lots, " lots @ ", DoubleToString(price,Digits), " SL:", sl, " TP:", tp, " Comment:", comment);
    int ticket = OrderSend(symbol, orderType, lots, price, 3, sl, tp, comment, MagicNumberReceiver, 0, CLR_NONE);

    if (ticket > 0) {
        Print("Trade OPENED successfully. Receiver Ticket: ", ticket, " (Copied from Sender Ticket: ", senderTicket, ")");
    } else {
        Print("Failed to OPEN trade. Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Handle Modify Trade Signal (SL/TP)                               |
//+------------------------------------------------------------------+
void HandleModifyTrade(string orderJson, long senderTicket) {
    string symbol = ParseJsonValue(orderJson, "symbol");
    double sl = StringToDouble(ParseJsonValue(orderJson, "stopLoss"));
    double tp = StringToDouble(ParseJsonValue(orderJson, "takeProfit"));
    int orderType = StringToInteger(ParseJsonValue(orderJson, "type")); // To help identify if it's BUY or SELL for SL/TP validation

    if (symbol == "") {
        Print("ModifyTrade: Symbol is empty.");
        return;
    }

    int receiverTicket = FindCopiedTrade(symbol, senderTicket, orderType);
    if (receiverTicket == -1) {
        Print("ModifyTrade: Could not find copied trade for sender ticket ", senderTicket, " on ", symbol);
        return;
    }

    if (!OrderSelect(receiverTicket, SELECT_BY_TICKET)) {
        Print("ModifyTrade: Failed to select order ticket ", receiverTicket, ". Error: ", GetLastError());
        return;
    }

    // Normalize SL/TP
    if (sl != 0) sl = NormalizeDouble(sl, MarketInfo(symbol, MODE_DIGITS)); else sl = OrderStopLoss(); // Keep existing if 0
    if (tp != 0) tp = NormalizeDouble(tp, MarketInfo(symbol, MODE_DIGITS)); else tp = OrderTakeProfit(); // Keep existing if 0

    // Check if modification is necessary
    if (MathAbs(OrderStopLoss() - sl) < Point*0.1 && MathAbs(OrderTakeProfit() - tp) < Point*0.1) {
        Print("ModifyTrade: No change in SL/TP for ticket ", receiverTicket, ". SL: ", sl, ", TP: ", tp);
        return;
    }

    Print("Attempting to MODIFY Ticket: ", receiverTicket, " Symbol: ", symbol, " New SL: ", sl, " New TP: ", tp);
    bool modified = OrderModify(receiverTicket, OrderOpenPrice(), sl, tp, 0, CLR_NONE);

    if (modified) {
        Print("Trade MODIFIED successfully. Ticket: ", receiverTicket);
    } else {
        Print("Failed to MODIFY trade. Ticket: ", receiverTicket, " Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Handle Close Trade Signal                                        |
//+------------------------------------------------------------------+
void HandleCloseTrade(string symbol, long senderTicket, double closedLots) {
    if (symbol == "") {
        Print("CloseTrade: Symbol is empty.");
        return;
    }

    // We need to find the trade based on symbol and sender's ticket in comment.
    // The order type (BUY/SELL) might be needed if multiple positions for same symbol & sender ticket (unlikely with good comment).
    // For now, assume comment is unique enough with symbol.
    int receiverTicket = FindCopiedTrade(symbol, senderTicket, -1); // -1 for orderType means don't check it strictly

    if (receiverTicket == -1) {
        Print("CloseTrade: Could not find copied trade for sender ticket ", senderTicket, " on ", symbol);
        return;
    }

    if (!OrderSelect(receiverTicket, SELECT_BY_TICKET)) {
        Print("CloseTrade: Failed to select order ticket ", receiverTicket, ". Error: ", GetLastError());
        return;
    }

    // Determine lots to close. If sender's `closedLots` is available and less than OrderLots(), it's a partial close.
    // For simplicity, we'll assume full close if closedLots from signal matches OrderLots or is not reliably provided.
    // The `dealJson` from sender should have the actual lots closed for that deal.
    double lotsToClose = OrderLots();
    if (closedLots > 0 && closedLots < OrderLots()) {
       // Implement partial close if needed. For now, full close.
       Print("CloseTrade: Signal indicates partial close of ", closedLots, " for ticket ", receiverTicket, ". Full close will be attempted for simplicity.");
       // For true partial close: lotsToClose = closedLots;
    } else if (closedLots == 0) { // If signal doesn't specify lots, assume full close
        Print("CloseTrade: Signal did not specify lots to close for ticket ", receiverTicket, ". Assuming full close.");
    }


    Print("Attempting to CLOSE Ticket: ", receiverTicket, " Symbol: ", symbol, " Lots: ", lotsToClose);
    bool closed = OrderClose(receiverTicket, lotsToClose, OrderClosePrice(), 3, CLR_NONE);

    if (closed) {
        Print("Trade CLOSED successfully. Ticket: ", receiverTicket);
    } else {
        Print("Failed to CLOSE trade. Ticket: ", receiverTicket, " Error: ", GetLastError());
    }
}


//+------------------------------------------------------------------+
//| Find a copied trade by its comment linking to sender's ticket    |
//+------------------------------------------------------------------+
int FindCopiedTrade(string symbol, long senderTicket, int orderTypeToMatch) {
    string searchComment = "CPY:" + SenderAccountIdToFollow + ":" + (string)senderTicket;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            if (OrderSymbol() == symbol && OrderComment() == searchComment && OrderMagicNumber() == MagicNumberReceiver) {
                if (orderTypeToMatch == -1 || OrderType() == orderTypeToMatch) { // -1 means any order type
                    return OrderTicket();
                }
            }
        }
    }
    return -1;
}


//+------------------------------------------------------------------+
//| Improved JSON Value Extractor                                    |
//| Extracts value for a key. Handles strings, numbers, booleans.    |
//| NOTE: This is still a basic parser, not for complex/nested JSON. |
//+------------------------------------------------------------------+
string ParseJsonValue(string json, string key) {
    string searchPattern = "\"" + key + "\":";
    int keyPos = StringFind(json, searchPattern);

    if (keyPos == -1) return ""; // Key not found

    int valueStartPos = keyPos + StringLen(searchPattern);
    char firstChar = StringGetCharacter(json, valueStartPos);

    // Skip leading spaces if any after colon
    while(firstChar == ' ' && valueStartPos < StringLen(json) -1) {
        valueStartPos++;
        firstChar = StringGetCharacter(json, valueStartPos);
    }

    if (firstChar == '"') { // String value
        valueStartPos++; // Skip the opening quote
        int valueEndPos = StringFind(json, "\"", valueStartPos);
        if (valueEndPos == -1) return ""; // Malformed: no closing quote
        return StringSubstr(json, valueStartPos, valueEndPos - valueStartPos);
    } else { // Numeric or boolean or null value
        int valueEndPos = StringLen(json);
        int commaPos = StringFind(json, ",", valueStartPos);
        int bracePos = StringFind(json, "}", valueStartPos);

        if (commaPos != -1) valueEndPos = commaPos;
        if (bracePos != -1 && bracePos < valueEndPos) valueEndPos = bracePos;

        string val = StringSubstr(json, valueStartPos, valueEndPos - valueStartPos);
        return StringTrim(val); // Trim spaces for values like 'true '
    }
}

//+------------------------------------------------------------------+
//| Get a nested JSON object as a string                             |
//+------------------------------------------------------------------+
string GetJsonObjectString(string json, string key) {
    string searchPattern = "\"" + key + "\":{";
    int keyPos = StringFind(json, searchPattern);

    if (keyPos == -1) return ""; // Key not found or not an object

    int objectStartPos = keyPos + StringLen(searchPattern) - 1; // Include the starting '{'
    int braceCount = 0;
    for (int i = objectStartPos; i < StringLen(json); i++) {
        char currentChar = StringGetCharacter(json, i);
        if (currentChar == '{') {
            braceCount++;
        } else if (currentChar == '}') {
            braceCount--;
            if (braceCount == 0) {
                return StringSubstr(json, objectStartPos, i - objectStartPos + 1);
            }
        }
    }
    return ""; // Malformed: object doesn't close properly
}

//+------------------------------------------------------------------+
//| OnTick function                                                  |
//+------------------------------------------------------------------+
void OnTick() {
    // Main logic is in OnTimer for periodic checks & message processing.
    // OnTick can be used for more frequent updates if needed, but not primary for this EA's comms.
}

/*
Trade Execution Notes:
- JSON Parsing: `ParseJsonValue` and `GetJsonObjectString` are improvements but still basic.
  A robust MQL4 JSON library is HIGHLY recommended for production.
- Trade Identification: Uses a comment "CPY:<SenderAccountID>:<SenderTicketID>" and magic number.
  This is crucial for `HandleModifyTrade` and `HandleCloseTrade`.
- Error Handling: Basic `GetLastError()` checks are present. Production systems need more.
- Partial Closes: `HandleCloseTrade` currently attempts full close. True partial close logic
  would use the `closedLots` from the sender's deal information.
- Idempotency: Added a check in `HandleOpenTrade` to prevent re-opening an already copied trade
  based on sender's ticket and symbol. Similar checks might be needed for modify/close if signals
  could be re-processed without unique event IDs from sender.
- Transaction Types: The logic assumes sender provides `transactionType` (like MQL5) or can infer
  from `deal.entry` for closes. If sender provides a simpler custom "action" field (e.g. "NEW", "MODIFY", "CLOSE"),
  the conditions in `ProcessServerMessage` would need adjustment.
*/
// Print("ReceiverEA.mq4 script updated with more functional trade handling."); // Commented out for tool use
