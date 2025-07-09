//+------------------------------------------------------------------+
//|                                                     SenderEA.mq4 |
//|                        Copyright 2023, Your Name/Company |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Your Name/Company"
#property link      "https://example.com"
#property version   "1.00"
#property strict

//--- Include necessary libraries
#include <WinSock2.mqh> // For socket functions (assuming standard MQL4 include)

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my";
input int ServerPort = 3000;
input string AccountIdentifier = "SenderAccount123"; // To identify this sender account on the server

//--- Global variables
int ExtSocketHandle = INVALID_SOCKET;
bool ExtIsConnected = false;
datetime ExtLastHeartbeatSent = 0;
int ExtHeartbeatInterval = 30; // Seconds

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
        // Optionally, you might want to allow the EA to keep trying in OnTick or a timer
        // For now, we'll fail initialization if the first attempt fails.
        WSACleanup();
        return(INIT_FAILED);
    }

    //--- Set a timer to send heartbeats
    EventSetTimer(ExtHeartbeatInterval);

    Print("Sender EA initialized and connected to ", ServerAddress, ":", ServerPort);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Kill the timer
    EventKillTimer();

    if (ExtSocketHandle != INVALID_SOCKET)
    {
        Print("Closing socket connection...");
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
    }
    ExtIsConnected = false;
    WSACleanup();
    Print("Sender EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function to send heartbeats                                |
//+------------------------------------------------------------------+
void OnTimer()
{
    if (!ExtIsConnected)
    {
        Print("Timer: Not connected. Attempting to reconnect...");
        if (!ConnectToServer())
        {
            Print("Timer: Reconnect attempt failed.");
            return;
        }
        Print("Timer: Reconnected successfully.");
    }

    // Send heartbeat
    string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + AccountIdentifier + "\",\"timestamp\":" + (string)TimeCurrent() + "}";
    if (SocketSend(ExtSocketHandle, heartbeatMsg + "\n", StringLen(heartbeatMsg + "\n")) <= 0) // Adding newline as a simple delimiter
    {
        Print("Failed to send heartbeat. Error: ", GetLastError());
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
    }
    else
    {
        //Print("Heartbeat sent to server.");
        ExtLastHeartbeatSent = TimeCurrent();
    }
}


//+------------------------------------------------------------------+
//| Connect to server function                                       |
//+------------------------------------------------------------------+
bool ConnectToServer()
{
    if (ExtIsConnected && ExtSocketHandle != INVALID_SOCKET)
    {
        Print("Already connected.");
        return true;
    }

    ExtSocketHandle = SocketCreate();
    if (ExtSocketHandle == INVALID_SOCKET)
    {
        Print("Failed to create socket. Error: ", GetLastError());
        return false;
    }

    if (!SocketConnect(ExtSocketHandle, ServerAddress, ServerPort, 10000)) // 10 seconds timeout
    {
        Print("Failed to connect to server ", ServerAddress, ":", ServerPort, ". Error: ", GetLastError());
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        return false;
    }

    ExtIsConnected = true;
    Print("Successfully connected to server: ", ServerAddress, ":", ServerPort);

    // Send an initial identification message
    string identMsg = "{\"type\":\"identification\",\"role\":\"sender\",\"accountId\":\"" + AccountIdentifier + "\"}";
    if (SocketSend(ExtSocketHandle, identMsg + "\n", StringLen(identMsg + "\n")) <= 0)
    {
        Print("Failed to send identification message. Error: ", GetLastError());
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
        return false;
    }
    Print("Identification message sent.");
    ExtLastHeartbeatSent = TimeCurrent(); // Initialize heartbeat timer
    return true;
}

//+------------------------------------------------------------------+
//| Trade event function                                             |
//+------------------------------------------------------------------+
//| IMPORTANT: OnTradeTransaction is an MQL5 feature. For MQL4,      |
//| trade detection logic needs to be implemented in OnTick() by     |
//| comparing current order states with previously stored states.    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    if (!ExtIsConnected)
    {
        Print("Not connected to server. Trade event ignored.");
        if (!ConnectToServer()) {
            Print("Failed to reconnect. Trade event lost.");
            return;
        }
        Print("Reconnected. Will process next trade event.");
        return;
    }

    string jsonPayload = "{";
    jsonPayload += "\"type\":\"tradeEvent\",";
    jsonPayload += "\"accountId\":\"" + AccountIdentifier + "\",";
    jsonPayload += "\"transactionType\":\"" + EnumToString(trans.type) + "\","; // MQL5 specific, needs MQL4 mapping
    jsonPayload += "\"timestamp\":" + (string)trans.time + ",";

    // Order details
    if (trans.order > 0) {
        if (OrderSelect(trans.order, SELECT_BY_TICKET)) {
            jsonPayload += "\"order\":{";
            jsonPayload += "\"ticket\":" + (string)OrderTicket() + ",";
            jsonPayload += "\"symbol\":\"" + OrderSymbol() + "\",";
            jsonPayload += "\"type\":" + (string)OrderType() + ",";
            jsonPayload += "\"lots\":" + DoubleToString(OrderLots(), OrderDigits()) + ",";
            jsonPayload += "\"openPrice\":" + DoubleToString(OrderOpenPrice(), OrderDigits()) + ",";
            jsonPayload += "\"openTime\":\"" + TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS) + "\",";
            jsonPayload += "\"stopLoss\":" + DoubleToString(OrderStopLoss(), OrderDigits()) + ",";
            jsonPayload += "\"takeProfit\":" + DoubleToString(OrderTakeProfit(), OrderDigits()) + ",";
            jsonPayload += "\"closePrice\":" + DoubleToString(OrderClosePrice(), OrderDigits()) + ",";
            jsonPayload += "\"closeTime\":\"" + TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS) + "\",";
            jsonPayload += "\"commission\":" + DoubleToString(OrderCommission(), 2) + ",";
            jsonPayload += "\"swap\":" + DoubleToString(OrderSwap(), 2) + ",";
            jsonPayload += "\"profit\":" + DoubleToString(OrderProfit(), 2) + ",";
            jsonPayload += "\"comment\":\"" + StringSubst(OrderComment(),"\"","\\\"") + "\","; // Escape quotes in comment
            jsonPayload += "\"magicNumber\":" + (string)OrderMagicNumber();
            jsonPayload += "}";
        } else {
            jsonPayload += "\"order\":{\"ticket\":" + (string)trans.order + ",\"error\":\"Failed to select order\"}";
        }
    } else {
         jsonPayload += "\"order\":null";
    }

    jsonPayload += ",";

    // Deal details
    if (trans.deal > 0) {
        if (HistoryDealSelect(trans.deal)) {
            jsonPayload += "\"deal\":{";
            jsonPayload += "\"ticket\":" + (string)HistoryDealGetInteger(trans.deal, DEAL_TICKET) + ",";
            jsonPayload += "\"order\":" + (string)HistoryDealGetInteger(trans.deal, DEAL_ORDER) + ",";
            jsonPayload += "\"symbol\":\"" + HistoryDealGetString(trans.deal, DEAL_SYMBOL) + "\",";
            jsonPayload += "\"type\":" + (string)HistoryDealGetInteger(trans.deal, DEAL_TYPE) + ",";
            jsonPayload += "\"entry\":" + (string)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) + ",";
            jsonPayload += "\"lots\":" + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetInteger(trans.deal, DEAL_DIGITS)) + ",";
            jsonPayload += "\"price\":" + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), HistoryDealGetInteger(trans.deal, DEAL_DIGITS)) + ",";
            jsonPayload += "\"time\":\"" + TimeToString(HistoryDealGetInteger(trans.deal, DEAL_TIME), TIME_DATE|TIME_SECONDS) + "\",";
            jsonPayload += "\"commission\":" + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_COMMISSION), 2) + ",";
            jsonPayload += "\"swap\":" + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_SWAP), 2) + ",";
            jsonPayload += "\"profit\":" + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PROFIT), 2) + ",";
            jsonPayload += "\"fee\":" + DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_FEE), 2);
            jsonPayload += "}";
        } else {
            jsonPayload += "\"deal\":{\"ticket\":" + (string)trans.deal + ",\"error\":\"Failed to select deal\"}";
        }
    } else {
        jsonPayload += "\"deal\":null";
    }

    jsonPayload += ",";

    // Request details
    jsonPayload += "\"request\":{";
    jsonPayload += "\"id\":" + (string)request.id + ",";
    jsonPayload += "\"action\":" + (string)request.action; // MQL5 specific, needs MQL4 mapping
    jsonPayload += "},";

    // Result details
    jsonPayload += "\"result\":{";
    jsonPayload += "\"retcode\":" + (string)result.retcode + ",";
    jsonPayload += "\"comment\":\"" + StringSubst(result.comment,"\"","\\\"") + "\""; // Escape quotes
    jsonPayload += "}";

    jsonPayload += "}";

    string messageToSend = jsonPayload + "\n";

    Print("Sending trade event: ", messageToSend);
    if (SocketSend(ExtSocketHandle, messageToSend, StringLen(messageToSend)) <= 0)
    {
        Print("Failed to send trade event. Error: ", GetLastError());
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
    }
    else
    {
        Print("Trade event sent successfully.");
    }
}

//+------------------------------------------------------------------+
//| OnTick function (for MQL4, primary place for trade detection)    |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check connection status and try to reconnect if necessary
    if (!ExtIsConnected)
    {
        if (ConnectToServer())
        {
            Print("OnTick: Reconnected successfully.");
        }
    }

    // For MQL4, trade detection logic would go here.
    // This involves:
    // 1. Storing the state of orders (number, tickets, SL, TP, etc.) from the previous tick.
    // 2. Comparing with the current state in this tick.
    // 3. Identifying new orders, closed orders, modified orders.
    // 4. Formatting and sending the appropriate JSON message.
    // This is a complex task and `OnTradeTransaction` is used above as a placeholder
    // for what data needs to be sent once an event IS detected.
    // If you are using a pure MQL4 environment, you MUST implement this logic here.
}

// Helper for MQL4 as EnumToString is MQL5.
// This is a simplified version. A full version would cover all relevant enums.
string EnumToString(int enum_value) {
    // This function would need to be expanded to cover all relevant MQL4/MQL5 enums
    // For example, for transaction types (MqlTradeTransactionType for MQL5)
    // For MQL4, you'd be detecting event types yourself and creating your own string representation.
    return IntegerToString(enum_value);
}

// Helper to escape quotes in strings for JSON
string StringSubst(string text, string find, string replace) {
    string result = text;
    int findLen = StringLen(find);
    int replaceLen = StringLen(replace);
    int pos = StringFind(result, find, 0);
    while (pos != -1) {
        result = StringSubstr(result, 0, pos) + replace + StringSubstr(result, pos + findLen);
        pos = StringFind(result, find, pos + replaceLen);
    }
    return result;
}
