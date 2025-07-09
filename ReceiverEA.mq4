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
#include <Trade\Trade.mqh> // For CTrade class (MQL5 style, might need MQL4 equivalent or direct order functions)

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my";
input int ServerPort = 3000;
input string ReceiverAccountId = "ReceiverAccount456"; // To identify this receiver account on the server
input string SenderAccountIdToFollow = "SenderAccount123"; // Which sender account to listen to

//--- Global variables
int ExtSocketHandle = INVALID_SOCKET;
bool ExtIsConnected = false;
datetime ExtLastHeartbeatSent = 0;
int ExtHeartbeatInterval = 30; // Seconds (should match sender's logic for server expectations)
string ExtSocketBuffer = ""; // Buffer for incoming socket data

CTrade ExtTrade; // For trade operations (MQL5 style, adjust for MQL4 if needed)

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
        string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + ReceiverAccountId + "\",\"timestamp\":" + (string)TimeCurrent() + "}";
        if (SocketSend(ExtSocketHandle, heartbeatMsg + "\n", StringLen(heartbeatMsg + "\n")) <= 0)
        {
            Print("Failed to send heartbeat. Error: ", GetLastError());
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

    // Send identification message
    string identMsg = "{\"type\":\"identification\",\"role\":\"receiver\"";
    identMsg += ",\"accountId\":\"" + ReceiverAccountId + "\"";
    identMsg += ",\"listenTo\":\"" + SenderAccountIdToFollow + "\"}";

    if (SocketSend(ExtSocketHandle, identMsg + "\n", StringLen(identMsg + "\n")) <= 0)
    {
        Print("Failed to send identification message. Error: ", GetLastError());
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
        return false;
    }
    Print("Identification message sent: listening to ", SenderAccountIdToFollow);
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
    // SocketIsReadable is one way, or just try to receive with MSG_DONTWAIT if available
    // For MQL4, SocketRecv might block if not set to non-blocking, or return 0/-1 if no data.
    // If socket is non-blocking, SocketRecv should return -1 and GetLastError() == WSAEWOULDBLOCK if no data.

    ZeroMemory(buffer);
    bytesRead = SocketRecv(ExtSocketHandle, buffer, sizeof(buffer) - 1, 0); // Last param flags, 0 for none

    if (bytesRead > 0)
    {
        buffer[bytesRead] = 0; // Null-terminate the string
        ExtSocketBuffer += CharArrayToString(buffer, 0, bytesRead);
        //Print("Received ", bytesRead, " bytes. Buffer: '", ExtSocketBuffer, "'");

        // Process complete messages (newline delimited)
        int newlinePos;
        while ((newlinePos = StringFind(ExtSocketBuffer, "\n")) != -1)
        {
            string message = StringSubstr(ExtSocketBuffer, 0, newlinePos);
            ExtSocketBuffer = StringSubstr(ExtSocketBuffer, newlinePos + 1);

            if (StringTrim(message) != "")
            {
                //Print("Processing message: ", message);
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
    // Example: {"type":"tradeEvent", "accountId":"SenderAccount123", "order":{...}}

    // For now, let's assume the message is a trade event if not an ack
    // A real implementation needs a JSON parser.
    // We'll crudely check for "tradeEvent" and "order" keys.

    if (StringFind(message, "\"type\":\"ack\"") != -1) {
        //Print("Received ACK from server: ", message);
        return;
    }
    if (StringFind(message, "\"type\":\"error\"") != -1) {
        Print("Received ERROR from server: ", message);
        return;
    }


    if (StringFind(message, "\"type\":\"tradeEvent\"") != -1)
    {
        // This is where the complex part of parsing the JSON and acting on it goes.
        // For MQL4, you'd need a custom JSON parsing routine or a library.
        // Let's extract some common fields using string manipulation for demonstration.
        // THIS IS NOT A ROBUST JSON PARSER.

        string symbol = GetJsonStringValue(message, "symbol");
        string orderTypeStr = GetJsonStringValue(message, "\"type\"", StringFind(message, "\"order\":")); // type within order object
        double lots = StringToDouble(GetJsonStringValue(message, "lots"));
        double price = StringToDouble(GetJsonStringValue(message, "openPrice")); // Assuming new order for now
        double sl = StringToDouble(GetJsonStringValue(message, "stopLoss"));
        double tp = StringToDouble(GetJsonStringValue(message, "takeProfit"));
        long orderTicket = (long)StringToInteger(GetJsonStringValue(message, "ticket")); // Original sender's ticket
        string comment = "Copied from " + SenderAccountIdToFollow + " (Ticket: " + (string)orderTicket + ")";

        // Transaction type can be used to determine if it's a new order, modify, or close
        // string transactionType = GetJsonStringValue(message, "transactionType"); // e.g., "TRADE_TRANSACTION_ORDER_ADD"

        // For simplicity, we'll only handle new market orders (BUY/SELL)
        // And we'll assume the "order" object contains the primary details.
        // We also need to parse the "type" from within the "order" object.
        // The sender sends MqlTradeTransaction, so we need to look at "order.type" for OP_BUY etc.
        // and "transactionType" at the root to see if it's an add/update/remove.

        string orderObjStr = GetJsonObject(message, "order");
        if (orderObjStr == "") {
            Print("No 'order' object in tradeEvent: ", message);
            return;
        }

        int tradeAction = -1; // 0 for BUY, 1 for SELL
        int orderTypeValue = StringToInteger(GetJsonStringValue(orderObjStr, "type"));

        switch(orderTypeValue) {
            case 0: // OP_BUY
                tradeAction = OP_BUY;
                break;
            case 1: // OP_SELL
                tradeAction = OP_SELL;
                break;
            // Extend for OP_BUYLIMIT, OP_SELLLIMIT etc. if needed
            default:
                Print("Unsupported order type in message: ", orderTypeValue);
                return;
        }

        if (symbol != "" && lots > 0 && tradeAction != -1)
        {
            // Normalize SL/TP (ensure they are valid distances if relative, or absolute values)
            // For simplicity, assume they are absolute values or 0.
            if (sl != 0) sl = NormalizeDouble(sl, MarketInfo(symbol, MODE_DIGITS));
            if (tp != 0) tp = NormalizeDouble(tp, MarketInfo(symbol, MODE_DIGITS));
            if (price == 0 && (tradeAction == OP_BUY || tradeAction == OP_SELL)) { // Market order
                price = (tradeAction == OP_BUY) ? MarketInfo(symbol, MODE_ASK) : MarketInfo(symbol, MODE_BID);
            } else {
                price = NormalizeDouble(price, MarketInfo(symbol, MODE_DIGITS));
            }


            Print("Attempting to execute trade: ", EnumToString(tradeAction), " ", symbol, " ", lots, " lots, P: ", price, " SL: ", sl, " TP: ", tp);

            // Using MQL4 direct OrderSend
            int ticket = OrderSend(symbol, tradeAction, lots, price, 3, sl, tp, comment, 0, 0, CLR_NONE);

            if (ticket > 0)
            {
                Print("Trade opened successfully. Ticket: ", ticket);
            }
            else
            {
                Print("Failed to open trade. Error: ", GetLastError());
            }
        }
        else
        {
            Print("Could not parse necessary trade details from message or invalid trade params.");
            Print("Symbol: '", symbol, "', Lots: ", lots, ", Action: ", tradeAction, " (OrderTypeVal:", orderTypeValue, ")");
            Print("Order Object String: ", orderObjStr);
        }
    }
    else
    {
        Print("Received unhandled message type or format: ", message);
    }
}


//+------------------------------------------------------------------+
//| Helper to extract string value from simple JSON-like string      |
//| THIS IS NOT A ROBUST JSON PARSER. It's very basic.               |
//+------------------------------------------------------------------+
string GetJsonStringValue(string jsonString, string key, int searchStartPos=0)
{
    string searchKey = "\"" + key + "\":";
    int keyPos = StringFind(jsonString, searchKey, searchStartPos);
    if (keyPos == -1) return "";

    int valueStartPos = keyPos + StringLen(searchKey);

    // Check if value is a string (starts with quote)
    if (StringGetCharacter(jsonString, valueStartPos) == '"')
    {
        valueStartPos++; // Skip the opening quote
        int valueEndPos = StringFind(jsonString, "\"", valueStartPos);
        if (valueEndPos == -1) return ""; // Malformed
        return StringSubstr(jsonString, valueStartPos, valueEndPos - valueStartPos);
    }
    else // Assume it's a number or boolean (not enclosed in quotes in JSON)
    {
        int valueEndPos = StringFind(jsonString, ",", valueStartPos);
        if (valueEndPos == -1) // Maybe it's the last element
        {
            valueEndPos = StringFind(jsonString, "}", valueStartPos);
            if (valueEndPos == -1) return ""; // Malformed
        }
        return StringSubstr(jsonString, valueStartPos, valueEndPos - valueStartPos);
    }
}

//+------------------------------------------------------------------+
//| Helper to extract a JSON object as a string                      |
//+------------------------------------------------------------------+
string GetJsonObject(string jsonString, string key, int searchStartPos=0) {
    string searchKey = "\"" + key + "\":{";
    int keyPos = StringFind(jsonString, searchKey, searchStartPos);
    if (keyPos == -1) return "";

    int objectStartPos = keyPos + StringLen(searchKey) -1; // Include the opening brace
    int braceCount = 0;
    for (int i = objectStartPos; i < StringLen(jsonString); i++) {
        if (StringGetCharacter(jsonString, i) == '{') {
            braceCount++;
        } else if (StringGetCharacter(jsonString, i) == '}') {
            braceCount--;
            if (braceCount == 0) {
                return StringSubstr(jsonString, objectStartPos, i - objectStartPos + 1);
            }
        }
    }
    return ""; // Malformed or object not found
}


//+------------------------------------------------------------------+
//| OnTick function (not strictly needed if OnTimer handles all)     |
//+------------------------------------------------------------------+
void OnTick()
{
    // Can be left empty if OnTimer is frequent enough (e.g. 1 sec)
    // Or can be used for additional checks if necessary
}

/*
Trade Execution Notes:
- The current trade execution logic is VERY basic. It only handles new market orders.
- It does not handle modifications (SL/TP changes on existing orders).
- It does not handle closing orders.
- It does not manage magic numbers to distinguish its own trades vs manual trades (though the comment helps).
- A robust implementation would need to:
    1. Parse `transactionType` from the sender's message (e.g., "TRADE_TRANSACTION_ORDER_ADD", "TRADE_TRANSACTION_ORDER_UPDATE", "TRADE_TRANSACTION_ORDER_DELETE" or "DEAL_ENTRY_OUT" for closes).
    2. For modifications/closes, identify the corresponding local order. This is tricky. The sender's ticket is not the receiver's ticket.
       One way is to store a mapping: sender_ticket -> receiver_ticket when an order is first copied.
       Or, use a unique ID generated by the sender for each trade lifecycle, sent with each event.
    3. Implement `OrderModify()` and `OrderClose()` logic.
    4. Handle partial fills, requotes, and other trading errors.
    5. Consider lot size adjustments (e.g., risk management based on receiver's account balance).
    6. The `CTrade` class (MQL5 style) is included but not fully used; direct `OrderSend` is used for MQL4 compatibility.
       If `CTrade` or a similar MQL4 library for trading is available, it can simplify operations.
- JSON Parsing: MQL4 lacks a native JSON parser. The `GetJsonStringValue` and `GetJsonObject` are extremely basic and error-prone.
  A proper JSON parsing library for MQL4 is highly recommended for production.
- SocketSetOption SO_NONBLOCK: This is important for EAs. The `SocketRecv` behavior with non-blocking sockets needs careful handling (checking for WSAEWOULDBLOCK).
*/
Print("ReceiverEA.mq4 script created.");
