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

// Structure to store order state for detecting modifications
struct KnownOrderState {
    int ticket;
    double sl;
    double tp;
    double lots; // To detect partial closes if they reflect on OrderLots()
};
KnownOrderState ExtKnownOpenOrders[100]; // Max 100 open orders tracked, adjust if needed
int ExtKnownOpenOrdersCount = 0;
int ExtLastOrdersTotal = 0;       // To detect new/closed orders by count
int ExtLastHistoryTotal = 0;      // To detect closed orders from history pool
datetime ExtLastOnTickProcessedTime = 0; // To prevent processing too frequently if OnTick is rapid

//+------------------------------------------------------------------+
//| Initialize order states                                          |
//+------------------------------------------------------------------+
void InitializeOrderStates() {
    ExtKnownOpenOrdersCount = 0;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            if (OrderMagicNumber() == 0 || AccountInfoInteger(ACCOUNT_LOGIN) == OrderMagicNumber()) { // Optional: Filter by current EA's magic or all manual trades
                if (ExtKnownOpenOrdersCount < ArraySize(ExtKnownOpenOrders)) {
                    ExtKnownOpenOrders[ExtKnownOpenOrdersCount].ticket = OrderTicket();
                    ExtKnownOpenOrders[ExtKnownOpenOrdersCount].sl = OrderStopLoss();
                    ExtKnownOpenOrders[ExtKnownOpenOrdersCount].tp = OrderTakeProfit();
                    ExtKnownOpenOrders[ExtKnownOpenOrdersCount].lots = OrderLots();
                    ExtKnownOpenOrdersCount++;
                }
            }
        }
    }
    ExtLastOrdersTotal = OrdersTotal();
    ExtLastHistoryTotal = HistoryTotal();
    Print("Initial order states captured. Open orders tracked: ", ExtKnownOpenOrdersCount);
}


//+------------------------------------------------------------------+
//| OnTick function (primary place for MQL4 trade detection)         |
//+------------------------------------------------------------------+
void OnTick() {
    //--- Ensure connected
    if (!ExtIsConnected) {
        if (ConnectToServer()) {
            Print("OnTick: Reconnected successfully. Initializing order states.");
            InitializeOrderStates(); // Re-initialize states after reconnect
        } else {
            return; // Not connected, nothing to do
        }
    }

    // Initialize states on first successful tick if not already done (e.g. after EA start/reconnect)
    if (ExtLastOnTickProcessedTime == 0 && ExtIsConnected) {
         InitializeOrderStates();
    }
    ExtLastOnTickProcessedTime = TimeCurrent();


    // --- Detect Closed Orders by iterating history ---
    // This is more reliable for detecting any type of close (manual, SL, TP)
    if (HistoryTotal() > ExtLastHistoryTotal) {
        for (int i = ExtLastHistoryTotal; i < HistoryTotal(); i++) {
            if (OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) {
                // Check if it's a closed trade relevant to us (e.g. by magic number or if we track all)
                // And ensure it's actually a position closure (not balance operation etc.)
                if (OrderType() == OP_BUY || OrderType() == OP_SELL) { // Only actual buy/sell orders
                    // We need to confirm this order was previously open and known to us,
                    // or assume any new history item is a close to be reported.
                    // A simple way: if an order appears in history, it was closed or partially closed.
                    // The ReceiverEA expects "DEAL_ENTRY_OUT" for closes.
                    // We also need to provide the original order details as best as possible.
                    // The "order" object in the JSON should reflect the state *before* closing if possible,
                    // or at least its identifying characteristics.

                    // Construct JSON for a closed order
                    string orderJson = "{";
                    orderJson += "\"ticket\":" + (string)OrderTicket() + ",";
                    orderJson += "\"symbol\":\"" + OrderSymbol() + "\",";
                    orderJson += "\"type\":" + (string)OrderType() + ",";
                    orderJson += "\"lots\":" + DoubleToString(OrderLots(), OrderDigits()) + ","; // Original lots
                    orderJson += "\"openPrice\":" + DoubleToString(OrderOpenPrice(), OrderDigits()) + ",";
                    orderJson += "\"openTime\":\"" + TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS) + "\",";
                    orderJson += "\"stopLoss\":" + DoubleToString(OrderStopLoss(), OrderDigits()) + ","; // SL at time of close
                    orderJson += "\"takeProfit\":" + DoubleToString(OrderTakeProfit(), OrderDigits()) + ","; // TP at time of close
                    orderJson += "\"closePrice\":" + DoubleToString(OrderClosePrice(), OrderDigits()) + ",";
                    orderJson += "\"closeTime\":\"" + TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS) + "\",";
                    orderJson += "\"commission\":" + DoubleToString(OrderCommission(), 2) + ",";
                    orderJson += "\"swap\":" + DoubleToString(OrderSwap(), 2) + ",";
                    orderJson += "\"profit\":" + DoubleToString(OrderProfit(), 2) + ",";
                    orderJson += "\"comment\":\"" + StringSubst(OrderComment(),"\"","\\\"") + "\",";
                    orderJson += "\"magicNumber\":" + (string)OrderMagicNumber();
                    orderJson += "}";

                    string dealJson = "{";
                    dealJson += "\"order\":" + (string)OrderTicket() + ","; // Link to the order ticket that was closed
                    dealJson += "\"entry\":\"DEAL_ENTRY_OUT\","; // Simulate MQL5 deal entry type for close
                    dealJson += "\"lots\":" + DoubleToString(OrderLots(), OrderDigits()) + ""; // Lots closed (assuming full close here)
                    // Add more deal fields if receiver needs them, like deal ticket (can be same as order ticket for MQL4 context)
                    // dealJson += ", \"price\":" + DoubleToString(OrderClosePrice(), OrderDigits());
                    // dealJson += ", \"time\":\"" + TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS) + "\"";
                    dealJson += "}";

                    SendTradeEvent("TRADE_TRANSACTION_DEAL", orderJson, dealJson);

                    // Remove from known open orders if it was there
                    RemoveKnownOrder(OrderTicket());
                }
            }
        }
    }
    ExtLastHistoryTotal = HistoryTotal();


    // --- Detect New Orders & Modifications for currently open orders ---
    bool knownOrdersUpdated[100]; // Max 100
    for(int k=0; k < ExtKnownOpenOrdersCount; k++) knownOrdersUpdated[k] = false;

    int currentOpenOrderCount = 0;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            currentOpenOrderCount++;
            // Optional: Filter by magic number if you only want to send trades from this EA or manual trades
            // if (OrderMagicNumber() != 0 && OrderMagicNumber() != SomeSpecificMagicNumber) continue;

            int knownIndex = FindKnownOrderIndex(OrderTicket());
            string orderJson = "{";
            orderJson += "\"ticket\":" + (string)OrderTicket() + ",";
            orderJson += "\"symbol\":\"" + OrderSymbol() + "\",";
            orderJson += "\"type\":" + (string)OrderType() + ",";
            orderJson += "\"lots\":" + DoubleToString(OrderLots(), OrderDigits()) + ",";
            orderJson += "\"openPrice\":" + DoubleToString(OrderOpenPrice(), OrderDigits()) + ",";
            orderJson += "\"openTime\":\"" + TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS) + "\",";
            orderJson += "\"stopLoss\":" + DoubleToString(OrderStopLoss(), OrderDigits()) + ",";
            orderJson += "\"takeProfit\":" + DoubleToString(OrderTakeProfit(), OrderDigits()) + ",";
            orderJson += "\"closePrice\":0,"; // Not closed
            orderJson += "\"closeTime\":0,";  // Not closed
            orderJson += "\"commission\":" + DoubleToString(OrderCommission(), 2) + ",";
            orderJson += "\"swap\":" + DoubleToString(OrderSwap(), 2) + ",";
            orderJson += "\"profit\":" + DoubleToString(OrderProfit(), 2) + ","; // Current floating profit
            orderJson += "\"comment\":\"" + StringSubst(OrderComment(),"\"","\\\"") + "\",";
            orderJson += "\"magicNumber\":" + (string)OrderMagicNumber();
            orderJson += "}";

            if (knownIndex == -1) { // New order
                SendTradeEvent("TRADE_TRANSACTION_ORDER_ADD", orderJson, "null");
                AddKnownOrder(OrderTicket(), OrderStopLoss(), OrderTakeProfit(), OrderLots());
            } else { // Existing order, check for modification (SL/TP)
                knownOrdersUpdated[knownIndex] = true;
                bool modified = false;
                if (ExtKnownOpenOrders[knownIndex].sl != OrderStopLoss() ||
                    ExtKnownOpenOrders[knownIndex].tp != OrderTakeProfit()) {
                    modified = true;
                }
                // Could also check for OrderLots() change for partial close detection if not handled by history
                // For now, focusing on SL/TP modification for "ORDER_UPDATE"

                if (modified) {
                    SendTradeEvent("TRADE_TRANSACTION_ORDER_UPDATE", orderJson, "null");
                    ExtKnownOpenOrders[knownIndex].sl = OrderStopLoss();
                    ExtKnownOpenOrders[knownIndex].tp = OrderTakeProfit();
                    ExtKnownOpenOrders[knownIndex].lots = OrderLots(); // Update lots too
                }
            }
        }
    }

    // If OrdersTotal decreased, or if some known orders were not found in current open pool, they were closed
    // This is a secondary check for closes, primary is history check.
    // Clean up ExtKnownOpenOrders for any trades that are no longer open but weren't caught by history scan (e.g. if history scan is offset)
    for (int k = ExtKnownOpenOrdersCount - 1; k >= 0; k--) {
        if (!knownOrdersUpdated[k]) { // If it wasn't updated, it might be closed
            if (OrderSelect(ExtKnownOpenOrders[k].ticket, SELECT_BY_TICKET, MODE_TRADES)) {
                // Still open, something is wrong with knownOrdersUpdated logic or it's a new order not yet in list
            } else {
                // No longer in MODE_TRADES, so it's closed. History check should have caught it.
                // This is a fallback cleanup.
                Print("Order ", ExtKnownOpenOrders[k].ticket, " no longer open (fallback detection). Removing from known list.");
                RemoveKnownOrderFromArray(k);
            }
        }
    }

    ExtLastOrdersTotal = currentOpenOrderCount; // Update to current actual open orders
}


//+------------------------------------------------------------------+
//| Send Trade Event to Server                                       |
//+------------------------------------------------------------------+
void SendTradeEvent(string transactionType, string orderJson, string dealJson) {
    if (!ExtIsConnected) {
        Print("Not connected, cannot send trade event.");
        return;
    }

    string jsonPayload = "{";
    jsonPayload += "\"type\":\"tradeEvent\",";
    jsonPayload += "\"accountId\":\"" + AccountIdentifier + "\",";
    jsonPayload += "\"transactionType\":\"" + transactionType + "\",";
    jsonPayload += "\"timestamp\":" + (string)TimeCurrent() + ","; // Current server time on MT4
    jsonPayload += "\"order\":" + orderJson + ",";
    jsonPayload += "\"deal\":" + dealJson;  // dealJson can be "null" if not applicable
    // Request and Result objects are omitted for MQL4 OnTick implementation simplicity
    // jsonPayload += ",\"request\":null,";
    // jsonPayload += "\"result\":null";
    jsonPayload += "}";

    string messageToSend = jsonPayload + "\n";
    Print("Sending event: ", transactionType, " for order details: ", orderJson, " deal details: ", dealJson);

    if (SocketSend(ExtSocketHandle, messageToSend, StringLen(messageToSend)) <= 0) {
        Print("Failed to send trade event. Error: ", GetLastError());
        SocketClose(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
        ExtLastOnTickProcessedTime = 0; // Reset to re-init states on next connect
    } else {
        // Print("Trade event sent successfully.");
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

void AddKnownOrder(int ticket, double sl, double tp, double lots) {
    if (ExtKnownOpenOrdersCount < ArraySize(ExtKnownOpenOrders)) {
        if (FindKnownOrderIndex(ticket) == -1) { // Ensure not already added
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].ticket = ticket;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].sl = sl;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].tp = tp;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].lots = lots;
            ExtKnownOpenOrdersCount++;
            Print("Added to known orders: ", ticket);
        }
    } else {
        Print("Known open orders array is full. Cannot add ticket: ", ticket);
    }
}

void RemoveKnownOrderFromArray(int index) { // Removes by array index
    if (index < 0 || index >= ExtKnownOpenOrdersCount) return;
    Print("Removing from known orders by index ", index, ", ticket ", ExtKnownOpenOrders[index].ticket);
    for (int i = index; i < ExtKnownOpenOrdersCount - 1; i++) {
        ExtKnownOpenOrders[i] = ExtKnownOpenOrders[i+1];
    }
    ExtKnownOpenOrdersCount--;
}

void RemoveKnownOrder(int ticket) { // Removes by ticket number
    int index = FindKnownOrderIndex(ticket);
    if (index != -1) {
        RemoveKnownOrderFromArray(index);
    }
}

// Helper to escape quotes in strings for JSON (simplified)
string StringSubst(string text, string find, string replace) {
    string result = text;
    int findLen = StringLen(find);
    if (findLen == 0) return text; // Avoid infinite loop if find is empty
    int replaceLen = StringLen(replace);
    int pos = StringFind(result, find, 0);
    while (pos != -1) {
        result = StringSubstr(result, 0, pos) + replace + StringSubstr(result, pos + findLen);
        pos = StringFind(result, find, pos + replaceLen);
    }
    return result;
}

// EnumToString is not needed if we manually set transactionType strings.
/*
string EnumToString(int enum_value) {
    return IntegerToString(enum_value);
}
*/
}
