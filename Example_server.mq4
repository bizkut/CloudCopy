// ###################################################################
// Compatible with both MT4 and MT5.
// Implements a simple server socket which you can telnet into,
// and which responds with a price quote if you type in "quote"
// (terminated by a CRLF)
// ###################################################################
#property strict

#include <socket-library-mt4-mt5.mqh>

// Server socket
ServerSocket * glbServerSocket;

// Array of current clients
ClientSocket * glbClients[];

// Watch for need to create timer;
bool glbCreatedTimer = false;

// --------------------------------------------------------------------
// Initialisation - set up server socket
// --------------------------------------------------------------------

void OnInit()
{
   // Create the server socket
   glbServerSocket = new ServerSocket(23456, false);
   if (glbServerSocket.Created()) {
      Print("Server socket created");

      // Note: this can fail if MT4/5 starts up
      // with the EA already attached to a chart. Therefore,
      // we repeat in OnTick()
      glbCreatedTimer = EventSetMillisecondTimer(100);
   } else {
      Print("Server socket FAILED - is the port already in use?");
   }
}


// --------------------------------------------------------------------
// Termination - free server socket and any clients
// --------------------------------------------------------------------

void OnDeinit(const int reason)
{
   glbCreatedTimer = false;
   
   // Delete all clients currently connected
   for (int i = 0; i < ArraySize(glbClients); i++) {
      delete glbClients[i];
   }

   // Free the server socket
   delete glbServerSocket;
   Print("Server socket terminated");
}

// --------------------------------------------------------------------
// Timer - accept new connections, and handle incoming data from clients
// --------------------------------------------------------------------
void OnTimer()
{
   // Keep accepting any pending connections until Accept() returns NULL
   ClientSocket * pNewClient = NULL;
   do {
      pNewClient = glbServerSocket.Accept();
      if (pNewClient != NULL) {
         int sz = ArraySize(glbClients);
         ArrayResize(glbClients, sz + 1);
         glbClients[sz] = pNewClient;
         
         pNewClient.Send("Hello\r\n");
      }
      
   } while (pNewClient != NULL);
   
   // Read incoming data from all current clients, watching for
   // any which now appear to be dead
   int ctClients = ArraySize(glbClients);
   for (int i = ctClients - 1; i >= 0; i--) {
      ClientSocket * pClient = glbClients[i];

      // Keep reading CRLF-terminated lines of input from the client
      // until we run out of data
      string strCommand;
      do {
         strCommand = pClient.Receive("\r\n");
         if (strCommand == "quote") {
            pClient.Send(Symbol() + "," + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_BID), 6) + "," + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_ASK), 6) + "\r\n");
         } else {
            // Potentially handle other commands etc here...
         }
      
      } while (strCommand != "");

      if (!pClient.IsSocketConnected()) {
         // Client is dead. Remove from array
         delete pClient;
         for (int j = i + 1; j < ctClients; j++) {
            glbClients[j - 1] = glbClients[j];
         }
         ctClients--;
         ArrayResize(glbClients, ctClients);
      }
   }
}

// Use OnTick() to watch for failure to create the timer in OnInit()
void OnTick()
{
   if (!glbCreatedTimer) glbCreatedTimer = EventSetMillisecondTimer(100);
}