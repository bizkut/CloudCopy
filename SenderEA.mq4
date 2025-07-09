//+------------------------------------------------------------------+
//|                                                     SenderEA.mq4 |
//|                        Copyright 2024, Your Name/Company         |
//|                                             https://example.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Your Name/Company"
#property link      "https://example.com"
#property version   "1.41" // Incremented version
#property strict

//--- Include necessary libraries
// #include <WinSock2.mqh> // Commented out as it might be causing "can't open include file" error
                       // Necessary constants are defined below.

//--- Defines for Winsock constants (if WinSock2.mqh is not used or missing them)
#ifndef AF_INET
#define AF_INET 2
#endif
#ifndef SOCK_STREAM
#define SOCK_STREAM 1
#endif
#ifndef IPPROTO_TCP
#define IPPROTO_TCP 6
#endif
#ifndef INVALID_SOCKET
#define INVALID_SOCKET -1
#endif
#ifndef SOCKET_ERROR
#define SOCKET_ERROR -1
#endif
#ifndef FIONBIO
#define FIONBIO 0x8004667E
#endif
#ifndef WSAEWOULDBLOCK // Common Winsock error codes
#define WSAEWOULDBLOCK 10035
#endif
#ifndef WSAEINPROGRESS
#define WSAEINPROGRESS 10036
#endif
#ifndef WSAENOTCONN
#define WSAENOTCONN    10057
#endif
#ifndef WSAECONNABORTED
#define WSAECONNABORTED 10053
#endif

// For WSAStartup
#ifndef WSADATA_SIZE_IN_INTS
#define WSADATA_SIZE_IN_INTS 100
#endif

//--- Import ws2_32.dll functions
#import "ws2_32.dll"
int WSAStartup(ushort wVersionRequired, int &WSAData[]);
int WSACleanup();
int socket(int af, int type, int protocol);
int closesocket(int s);
int connect(int s, int &sockAddr[], int nameLen);
int send(int s, uchar &buf[], int len, int flags);
int recv(int s, uchar &buf[], int len, int flags);
ushort htons(ushort hostshort);
uint inet_addr(string cp);
int WSAGetLastError();
int ioctlsocket(int s, long cmd, int &argp);
#import

//--- Import kernel32.dll for CopyMemory
#import "kernel32.dll"
void CopyMemory(int &destination[], int &source[], int length);
void CopyMemory(uchar &destination[], string source, int length);
void CopyMemory(uchar &dest[], const string src, int n); // For StringToCharArray alternative if needed
void ZeroMemory(int &block[], int size); // For sockaddr_in_DLL
void ZeroMemory(char &block[], int size); // For sockaddr_in_DLL.sin_zero
#import

// Define sockaddr_in structure (16 bytes)
struct sockaddr_in_DLL
{
  short  sin_family;
  ushort sin_port;
  uint   sin_addr;
  char   sin_zero[8];
};

//--- Input parameters
input string ServerAddress = "metaapi.gametrader.my";
input int ServerPort = 3000;
input string AccountIdentifier = "SenderAccount123";

//--- Global variables
int ExtSocketHandle = INVALID_SOCKET;
bool ExtIsConnected = false;
bool ExtIdentified = false;
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
KnownOrderState ExtKnownOpenOrders[200];
int ExtKnownOpenOrdersCount = 0;
int ExtLastHistoryTotal = 0;
datetime ExtLastOnTickProcessedTime = 0;

string EscapeJsonString(string text) {
    string result = "";
    int len = StringLen(text);
    for (int i = 0; i < len; i++) {
        char ch = StringGetCharacter(text, i);
        switch (ch) {
            case '\\': result += "\\\\"; break;
            case '"':  result += "\\\""; break;
            case '\b': result += "\\b"; break;
            case '\f': result += "\\f"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:
                if (ch < 32) {
                    string temp;
                    StringAppend(temp, "\\u"); // MQL4 doesn't have direct uXXXX, this is illustrative
                                             // For actual control chars, might need specific handling or ignore
                    int h1 = ch / 16;
                    int h2 = ch % 16;
                    StringAppend(temp, h1<10? (string)h1 : CharToStr((char)('A'+h1-10)) );
                    StringAppend(temp, h2<10? (string)h2 : CharToStr((char)('A'+h2-10)) );
                    // This is a simplified hex, proper \\uXXXX needs 4 hex digits.
                    // For MQL4 JSON, often best to avoid complex control chars or filter them.
                    // For now, just pass through if not one of the common escapes.
                    result += CharToStr(ch);

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
    int wsaData[WSADATA_SIZE_IN_INTS];
    ushort wVersionRequired = 0x0202;
    int error = WSAStartup(wVersionRequested, wsaData);
    if (error != 0) {
        Print("SenderEA: WSAStartup failed with error: ", error, " (WSAGetLastError: ", WSAGetLastError(), ")");
        return(INIT_FAILED);
    }

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
    if (ExtSocketHandle != INVALID_SOCKET) {
        Print("SenderEA: Closing socket connection (", ExtSocketHandle, ")");
        closesocket(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
    }
    ExtIsConnected = false;
    ExtIdentified = false;
    WSACleanup();
    Print("SenderEA: Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function (for heartbeats and connection management)        |
//+------------------------------------------------------------------+
void OnTimer() {
    if (!ExtIsConnected || ExtSocketHandle == INVALID_SOCKET) {
        if (ConnectToServer()) {
            Print("SenderEA Timer: Connection attempt successful/in progress.");
        } else {
            return;
        }
    }

    if (ExtIsConnected && ExtSocketHandle != INVALID_SOCKET && !ExtIdentified) {
        if (SendIdentification()) {
            ExtIdentified = true;
            Print("SenderEA Timer: Identification successful. Initializing order states.");
            InitializeOrderStates();
        } else {
            return;
        }
    }

    if (ExtIsConnected && ExtSocketHandle != INVALID_SOCKET && ExtIdentified && (TimeCurrent() - ExtLastHeartbeatSent >= ExtHeartbeatInterval)) {
        string currentSenderAccountId = AccountIdentifier;
        string heartbeatMsg = "{\"type\":\"heartbeat\",\"accountId\":\"" + currentSenderAccountId + "\",\"timestamp\":" + (string)TimeCurrent() + "}";
        uchar sendBuffer[];
        StringToCharArray(heartbeatMsg + "\n", sendBuffer, 0, -1, CP_UTF8);
        int len = ArraySize(sendBuffer) -1;

        if (len > 0 && send(ExtSocketHandle, sendBuffer, len, 0) <= 0) {
            Print("SenderEA: Failed to send heartbeat to account '",currentSenderAccountId,"'. Error: ", WSAGetLastError());
            closesocket(ExtSocketHandle);
            ExtSocketHandle = INVALID_SOCKET;
            ExtIsConnected = false;
            ExtIdentified = false;
            ExtLastOnTickProcessedTime = 0;
        } else if (len > 0) {
            ExtLastHeartbeatSent = TimeCurrent();
        }
    }
}

//+------------------------------------------------------------------+
//| Connect to server function                                       |
//+------------------------------------------------------------------+
bool ConnectToServer() {
    if (ExtIsConnected && ExtSocketHandle != INVALID_SOCKET && ExtIdentified) {
        return true;
    }
    if(ExtSocketHandle != INVALID_SOCKET) {
        closesocket(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
    }
    ExtIsConnected = false;
    ExtIdentified = false;

    ExtSocketHandle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ExtSocketHandle == INVALID_SOCKET) {
        Print("SenderEA: Failed to create socket. Error: ", WSAGetLastError());
        return false;
    }

    int nonBlocking = 1;
    int argp = nonBlocking;
    if (ioctlsocket(ExtSocketHandle, FIONBIO, argp) != 0) {
       Print("SenderEA: ioctlsocket failed to set non-blocking. Error: ", WSAGetLastError());
       closesocket(ExtSocketHandle);
       ExtSocketHandle = INVALID_SOCKET;
       return false;
    }

    sockaddr_in_DLL serverAddrStructLocal; // Use a local variable
    // ZeroMemory for struct needs to be careful with MQL4 types
    // For a struct, it's safer to initialize members directly or use a helper
    int serverAddr_int[sizeof(sockaddr_in_DLL)/sizeof(int)];
    ZeroMemory(serverAddr_int, sizeof(sockaddr_in_DLL)); // Zero out the int array

    serverAddrStructLocal.sin_family = AF_INET;
    serverAddrStructLocal.sin_port = htons(ServerPort);
    serverAddrStructLocal.sin_addr = inet_addr(ServerAddress);

    if (serverAddrStructLocal.sin_addr == 0xFFFFFFFF || serverAddrStructLocal.sin_addr == 0) {
        Print("SenderEA: inet_addr failed for ServerAddress: ", ServerAddress,". Please use a valid IPv4 address.");
        closesocket(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        return false;
    }

    CopyMemory(serverAddr_int, serverAddrStructLocal, sizeof(sockaddr_in_DLL));

    int connectResult = connect(ExtSocketHandle, serverAddr_int, sizeof(sockaddr_in_DLL));

    if (connectResult == SOCKET_ERROR) {
        int err = WSAGetLastError();
        if (err != WSAEWOULDBLOCK && err != WSAEINPROGRESS) {
             Print("SenderEA: Failed to connect to server ", ServerAddress, ":", ServerPort, ". Error: ", err);
             closesocket(ExtSocketHandle);
             ExtSocketHandle = INVALID_SOCKET;
             return false;
        }
        Print("SenderEA: Connection attempt in progress (non-blocking) to ", ServerAddress, ":", ServerPort, ". Error code (if any): ", err);
    } else {
         Print("SenderEA: Connect call returned success immediately.");
    }

    ExtIsConnected = true;
    return true;
}

//+------------------------------------------------------------------+
//| Send Identification Message                                      |
//+------------------------------------------------------------------+
bool SendIdentification() {
    if (ExtSocketHandle == INVALID_SOCKET || !ExtIsConnected) {
         Print("SenderEA: Cannot send identification, socket not valid or connection not initiated.");
         return false;
    }

    string identMsg = "{\"type\":\"identification\",\"role\":\"sender\",\"accountId\":\"" + AccountIdentifier + "\"}";
    uchar sendBufferIdent[];
    StringToCharArray(identMsg + "\n", sendBufferIdent, 0, -1, CP_UTF8);
    int identLen = ArraySize(sendBufferIdent) -1;

    if (identLen <=0) {
        Print("SenderEA: Identification message is empty.");
        return false;
    }

    int sentBytes = send(ExtSocketHandle, sendBufferIdent, identLen, 0);
    if (sentBytes <= 0) {
        int sendError = WSAGetLastError();
        Print("SenderEA: Failed to send identification message. Error: ", sendError);
        if (sendError != WSAEWOULDBLOCK && sendError != WSAENOTCONN && sendError != WSAECONNABORTED) {
            closesocket(ExtSocketHandle);
            ExtSocketHandle = INVALID_SOCKET;
            ExtIsConnected = false;
            ExtIdentified = false;
            return false;
        }
        Print("SenderEA: Identification send pending (Error: ",sendError,"), connection likely not fully established yet.");
        return false;
    }
    Print("SenderEA: Identification message appears sent (or queued by OS).");
    ExtLastHeartbeatSent = TimeCurrent();
    return true;
}

//+------------------------------------------------------------------+
//| Initialize order states                                          |
//+------------------------------------------------------------------+
void InitializeOrderStates() {
    ExtKnownOpenOrdersCount = 0;
    // ArrayResize(ExtKnownOpenOrders, 200); // Already sized

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
//| OnTick function (primary place for MQL4 trade detection)         |
//+------------------------------------------------------------------+
void OnTick() {
    if (!ExtIsConnected || ExtSocketHandle == INVALID_SOCKET || !ExtIdentified) {
        ExtLastOnTickProcessedTime = 0;
        return;
    }

    if (ExtLastOnTickProcessedTime == 0) {
         InitializeOrderStates();
         if(ExtKnownOpenOrdersCount == 0 && OrdersTotal() == 0 && HistoryTotal() == ExtLastHistoryTotal) {
             ExtLastOnTickProcessedTime = TimeCurrent();
         }
         // If still 0 after init, means init didn't complete or no orders
         if(ExtLastOnTickProcessedTime == 0) return;
    }

    // --- Detect Closed Orders by iterating history ---
    if (HistoryTotal() > ExtLastHistoryTotal) {
        for (int i = ExtLastHistoryTotal; i < HistoryTotal(); i++) {
            if (OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) {
                if (OrderType() == OP_BUY || OrderType() == OP_SELL) {
                    int knownIndex = FindKnownOrderIndex(OrderTicket());
                    if (knownIndex != -1) {
                        string orderSymbol = OrderSymbol();
                        int symDigits = MarketInfo(orderSymbol, MODE_DIGITS);

                        string orderJson = "{";
                        orderJson += "\"ticket\":" + (string)OrderTicket() + ",";
                        orderJson += "\"symbol\":\"" + EscapeJsonString(orderSymbol) + "\",";
                        orderJson += "\"type\":" + (string)OrderType() + ",";
                        orderJson += "\"lots\":" + DoubleToString(OrderLots(), symDigits) + ",";
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

                        string dealJson = "{";
                        dealJson += "\"order\":" + (string)OrderTicket() + ",";
                        dealJson += "\"entry\":\"DEAL_ENTRY_OUT\",";
                        dealJson += "\"lots\":" + DoubleToString(OrderLots(), symDigits) + "";
                        dealJson += "}";

                        SendTradeEvent("TRADE_TRANSACTION_DEAL", orderJson, dealJson);
                        RemoveKnownOrder(OrderTicket());
                    }
                }
            }
        }
    }
    ExtLastHistoryTotal = HistoryTotal();

    // --- Detect New Orders & Modifications for currently open orders ---
    bool currentKnownOrderFound[200];
    if(ArraySize(ExtKnownOpenOrders) > 0) ArrayInitialize(currentKnownOrderFound, false);

    for (int i = 0; i < OrdersTotal(); i++) {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            int orderTicket = OrderTicket();
            string orderSymbol = OrderSymbol();
            int symDigits = MarketInfo(orderSymbol, MODE_DIGITS);
            double symPoint = MarketInfo(orderSymbol, MODE_POINT);

            double currentSL = OrderStopLoss();
            double currentTP = OrderTakeProfit();
            double currentLots = OrderLots();
            int orderType = OrderType();

            int knownIndex = FindKnownOrderIndex(orderTicket);

            string orderJson = "{";
            orderJson += "\"ticket\":" + (string)orderTicket + ",";
            orderJson += "\"symbol\":\"" + EscapeJsonString(orderSymbol) + "\",";
            orderJson += "\"type\":" + (string)orderType + ",";
            orderJson += "\"lots\":" + DoubleToString(currentLots, symDigits) + ",";
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
            orderJson += "\"magicNumber\":" + (string)OrderMagicNumber();
            orderJson += "}";

            if (knownIndex == -1) {
                SendTradeEvent("TRADE_TRANSACTION_ORDER_ADD", orderJson, "null");
                AddKnownOrder(orderTicket, currentSL, currentTP, currentLots, orderType, orderSymbol);
                 if(ExtKnownOpenOrdersCount > 0 && (ExtKnownOpenOrdersCount-1) < ArraySize(currentKnownOrderFound))
                    currentKnownOrderFound[ExtKnownOpenOrdersCount-1] = true;
            } else {
                if(knownIndex < ArraySize(currentKnownOrderFound)) currentKnownOrderFound[knownIndex] = true;

                bool slTpModified = false;
                if (MathAbs(ExtKnownOpenOrders[knownIndex].sl - currentSL) > symPoint * 0.1 ||
                    MathAbs(ExtKnownOpenOrders[knownIndex].tp - currentTP) > symPoint * 0.1 ) {
                    if (! (ExtKnownOpenOrders[knownIndex].sl == 0 && currentSL == 0 && ExtKnownOpenOrders[knownIndex].tp == 0 && currentTP == 0) ) {
                         slTpModified = true;
                    }
                }

                bool lotsModified = (MathAbs(ExtKnownOpenOrders[knownIndex].lots - currentLots) > 0.0000001);

                if (slTpModified || lotsModified) {
                    Print("SenderEA: Modification detected for ticket ", orderTicket, ": Old SL=", ExtKnownOpenOrders[knownIndex].sl, ", New SL=", currentSL,
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
            // This order was in ExtKnownOpenOrders but was not found in the current OrdersTotal() scan.
            // It implies the order was closed. The history check should ideally capture this.
            // This is a fallback to remove it from the known list.
            // To avoid sending duplicate close events, we rely on history check to send the actual event.
            Print("SenderEA: Order ", ExtKnownOpenOrders[k].ticket, " (Symbol: ", ExtKnownOpenOrders[k].symbol,
                  ") from known list not found in current open orders scan. Removing from known list.");
            RemoveKnownOrderFromArray(k);
        }
    }
}

//+------------------------------------------------------------------+
//| Send Trade Event to Server                                       |
//+------------------------------------------------------------------+
void SendTradeEvent(string transactionType, string orderJson, string dealJson) {
    if (!ExtIsConnected || ExtSocketHandle == INVALID_SOCKET || !ExtIdentified) {
        Print("SenderEA: Not connected or not identified, cannot send trade event '", transactionType, "'");
        return;
    }

    string jsonPayload = "{";
    jsonPayload += "\"type\":\"tradeEvent\",";
    jsonPayload += "\"accountId\":\"" + AccountIdentifier + "\",";
    jsonPayload += "\"transactionType\":\"" + transactionType + "\",";
    jsonPayload += "\"timestamp\":" + (string)TimeCurrent() + ",";
    jsonPayload += "\"order\":" + orderJson + ",";
    jsonPayload += "\"deal\":" + dealJson;
    jsonPayload += "}";

    string messageToSend = jsonPayload + "\n";
    Print("SenderEA: Sending event: ", messageToSend);

    uchar sendBuffer[];
    StringToCharArray(messageToSend, sendBuffer, 0, -1, CP_UTF8);
    int len = ArraySize(sendBuffer) -1;

    if (len <= 0) {
        Print("SenderEA: Cannot send empty message for event ", transactionType);
        return;
    }

    if (send(ExtSocketHandle, sendBuffer, len, 0) <= 0) {
        Print("SenderEA: Failed to send trade event '", transactionType, "'. Error: ", WSAGetLastError());
        closesocket(ExtSocketHandle);
        ExtSocketHandle = INVALID_SOCKET;
        ExtIsConnected = false;
        ExtIdentified = false;
        ExtLastOnTickProcessedTime = 0;
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
    if (ExtKnownOpenOrdersCount < ArraySize(ExtKnownOpenOrders)) {
        if (FindKnownOrderIndex(ticket) == -1) {
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].ticket = ticket;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].sl = sl;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].tp = tp;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].lots = lots;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].type = orderTypeVal;
            ExtKnownOpenOrders[ExtKnownOpenOrdersCount].symbol = symbolStr;
            ExtKnownOpenOrdersCount++;
            Print("SenderEA: Added to known orders: #", ticket, " ", symbolStr, " Type:", EnumToString(orderTypeVal), " Lots:", lots, " SL:", sl, " TP:",tp);
        }
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
    if (ExtKnownOpenOrdersCount > 0) ExtKnownOpenOrdersCount--;
}

void RemoveKnownOrder(int ticket) {
    int index = FindKnownOrderIndex(ticket);
    if (index != -1) {
        RemoveKnownOrderFromArray(index);
    }
}

string StringSubst(string text, string findStr, string replaceStr) {
    string result = text;
    if (StringLen(findStr) == 0) return text;

    int findLen = StringLen(findStr);
    int replaceLen = StringLen(replaceStr);
    int pos = StringFind(result, findStr, 0);

    while (pos != -1) {
        string part1 = StringSubstr(result, 0, pos);
        string part2 = StringSubstr(result, pos + findLen);
        result = part1 + replaceStr + part2;
        pos = StringFind(result, findStr, pos + replaceLen);
    }
    return result;
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
```

I have made the following changes in this full version:
-   **Commented out `#include <WinSock2.mqh>`:** And defined necessary constants (`AF_INET`, `SOCK_STREAM`, `IPPROTO_TCP`, `INVALID_SOCKET`, `SOCKET_ERROR`, `FIONBIO`, `WSAEWOULDBLOCK`, etc.) directly in the file. This should resolve the "can't open include file" error if `WinSock2.mqh` is missing or problematic in your environment.
-   **Corrected DLL Import Signatures:**
    *   `send` and `recv`: Changed buffer parameter to `uchar &buf[]` to correctly pass by reference for modification.
    *   `connect`: Changed `sockaddr` parameter to `int &sockAddr[]` to reflect passing the structure as an integer array by reference.
    *   `WSAStartup`: `WSAData` parameter is `int &WSAData[]`.
    *   `ioctlsocket`: `argp` is `int &argp`.
-   **`CopyMemory` Imports:** Added necessary imports for `CopyMemory` from `kernel32.dll` for different use cases (int array to int array, string to uchar array). Added `ZeroMemory` for initializing `sockaddr_in_DLL` via an int array.
-   **`OrderDigits()` Replacement:** Replaced all instances of `OrderDigits()` with `MarketInfo(OrderSymbol(), MODE_DIGITS)` or simply `Digits` (if `OrderSymbol()` is already available in context).
-   **Array Initialization:** Ensured `currentKnownOrderFound` array is initialized using `ArrayInitialize(currentKnownOrderFound, false);` before its use in loops.
-   **`send()` parameters:** Ensured `StringToCharArray` is used to populate the `uchar` buffer and `ArraySize(buffer) - 1` is used for the length to exclude the null terminator. Added `CP_UTF8` for encoding.
-   **`inet_addr` return type:** Confirmed `uint` for `inet_addr`.
-   **`sockaddr_in_DLL` Zeroing:** Used `ZeroMemory` on the `int` array version of `sockaddr_in_DLL` before populating it.
-   **JSON Escaping:** Included the `EscapeJsonString` function and used it for `OrderSymbol()` and `OrderComment()` when building JSON strings to prevent issues with special characters.
-   **Refined Connection/Identification Logic:** Made the connection and identification attempts primarily driven by `OnTimer` to prevent `OnTick` from being blocked or spamming. `OnTick` now checks if connected and identified before proceeding with trade detection. `InitializeOrderStates` is called after successful identification.

Please replace the entire content of your `SenderEA.mq4` with this code. I am hopeful this will compile successfully and address the previous issues.
I sincerely apologize for the multiple attempts and the errors. This has highlighted areas I need to improve in handling complex code generation and state.
