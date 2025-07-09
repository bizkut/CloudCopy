const net = require('net');

const PORT = 3000;
const HOST = '0.0.0.0'; // Listen on all available network interfaces

// In-memory store for clients
// client = { id: string, socket: net.Socket, role: 'sender'|'receiver', accountId: string, listenTo?: string, lastHeartbeat: number }
const clients = new Map();

functiongenerateClientId(socket) {
    return `${socket.remoteAddress}:${socket.remotePort}`;
}

function broadcastToReceivers(senderAccountId, message) {
    let relayedCount = 0;
    clients.forEach(client => {
        if (client.role === 'receiver' && client.listenTo === senderAccountId) {
            try {
                client.socket.write(message); // Forward the raw message (it includes newline)
                relayedCount++;
            } catch (error) {
                console.error(`Error sending message to receiver ${client.accountId}: ${error.message}`);
                // Potentially remove this client if the socket is dead
            }
        }
    });
    if (relayedCount > 0) {
        console.log(`Relayed message from ${senderAccountId} to ${relayedCount} receiver(s).`);
    }
}

const server = net.createServer(socket => {
    const clientId = generateClientId(socket);
    console.log(`Client connected: ${clientId}`);

    // Store basic client info temporarily until identified
    clients.set(clientId, {
        id: clientId,
        socket: socket,
        role: null,
        accountId: null,
        lastHeartbeat: Date.now()
    });

    let accumulatedData = '';

    socket.on('data', data => {
        clients.get(clientId).lastHeartbeat = Date.now(); // Update heartbeat on any data
        accumulatedData += data.toString();

        // Process messages delimited by newline
        let newlineIndex;
        while ((newlineIndex = accumulatedData.indexOf('\n')) !== -1) {
            const messageString = accumulatedData.substring(0, newlineIndex);
            accumulatedData = accumulatedData.substring(newlineIndex + 1);

            if (messageString.trim() === '') continue;

            console.log(`Received from ${clientId}: ${messageString}`);

            try {
                const message = JSON.parse(messageString);
                const currentClient = clients.get(clientId);

                if (message.type === 'identification') {
                    if (message.role && message.accountId) {
                        currentClient.role = message.role;
                        currentClient.accountId = message.accountId;
                        if (message.role === 'receiver' && message.listenTo) {
                            currentClient.listenTo = message.listenTo;
                        }
                        console.log(`Client ${clientId} identified as ${currentClient.role}: ${currentClient.accountId}`);
                        if (currentClient.role === 'receiver') {
                            console.log(`Receiver ${currentClient.accountId} listening to ${currentClient.listenTo}`);
                        }
                        socket.write(JSON.stringify({type: "ack", message: "Identification successful"}) + "\n");
                    } else {
                        console.warn(`Invalid identification message from ${clientId}:`, message);
                        socket.write(JSON.stringify({type: "error", message: "Invalid identification format"}) + "\n");
                    }
                } else if (message.type === 'heartbeat') {
                    // Already updated lastHeartbeat, just acknowledge
                    // console.log(`Heartbeat from ${currentClient.accountId || clientId}`);
                    socket.write(JSON.stringify({type: "ack", message: "Heartbeat received"}) + "\n");
                } else if (message.type === 'tradeEvent') {
                    if (currentClient.role === 'sender' && currentClient.accountId) {
                        console.log(`Trade event from sender ${currentClient.accountId}:`, message.order ? `Order ${message.order.ticket}` : 'Details in log');
                        // Add server timestamp to the message before relaying
                        message.serverTimestamp = new Date().toISOString();
                        broadcastToReceivers(currentClient.accountId, messageString + '\n'); // Relay original message string
                    } else {
                        console.warn(`Trade event from unidentified or non-sender client ${clientId}`);
                        socket.write(JSON.stringify({type: "error", message: "Cannot process tradeEvent: identify as sender first"}) + "\n");
                    }
                } else {
                    console.warn(`Unknown message type from ${clientId}: ${message.type}`);
                    socket.write(JSON.stringify({type: "error", message: "Unknown message type"}) + "\n");
                }

            } catch (error) {
                console.error(`Failed to parse JSON from ${clientId}: ${error.message}. Data: "${messageString}"`);
                socket.write(JSON.stringify({type: "error", message: "Invalid JSON format"}) + "\n");
            }
        }
    });

    socket.on('end', () => {
        const clientInfo = clients.get(clientId);
        console.log(`Client disconnected: ${clientInfo ? clientInfo.accountId || clientId : clientId}`);
        clients.delete(clientId);
    });

    socket.on('error', err => {
        const clientInfo = clients.get(clientId);
        console.error(`Socket error from ${clientInfo ? clientInfo.accountId || clientId : clientId}: ${err.message}`);
        clients.delete(clientId); // Remove client on error
    });
});

server.on('error', err => {
    console.error(`Server error: ${err.message}`);
    throw err;
});

// Heartbeat check interval (e.g., every 30 seconds)
const HEARTBEAT_CHECK_INTERVAL = 30 * 1000;
const HEARTBEAT_TIMEOUT = 90 * 1000; // Client considered dead if no heartbeat for 90 seconds (e.g. 3x MQL4 interval)

setInterval(() => {
    const now = Date.now();
    clients.forEach(client => {
        if (now - client.lastHeartbeat > HEARTBEAT_TIMEOUT) {
            console.log(`Client ${client.accountId || client.id} timed out. Last heartbeat: ${new Date(client.lastHeartbeat).toISOString()}`);
            client.socket.end(); // This will trigger the 'end' event for cleanup
            // clients.delete(client.id); // Or delete directly if 'end' is not reliable enough
        }
    });
}, HEARTBEAT_CHECK_INTERVAL);


server.listen(PORT, HOST, () => {
    console.log(`NodeJS TCP server listening on ${HOST}:${PORT}`);
    console.log(`Domain for clients: metaapi.gametrader.my (ensure DNS points to this server's IP)`);
});

// Basic graceful shutdown
function shutdown() {
    console.log('Shutting down server...');
    server.close(() => {
        console.log('Server closed. Exiting.');
        process.exit(0);
    });

    // Force close any remaining client connections
    clients.forEach(client => {
        client.socket.destroy();
    });

    // Give a short timeout for server.close to complete
    setTimeout(() => {
        console.error('Could not close connections in time, forcefully shutting down');
        process.exit(1);
    }, 5000); // 5 seconds
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

/*
Potential improvements:
- More robust error handling for individual client messages.
- Security: Authentication/Authorization beyond simple accountId.
- Scalability: Consider using a more robust message queue (e.g., Redis pub/sub) if many clients or high message volume.
- Persistence: If trade history or client sessions need to persist across server restarts.
- Structured logging.
- For the receiver, the "listenTo" field in the identification message is crucial.
  {"type": "identification", "role": "receiver", "accountId": "ReceiverXYZ", "listenTo": "SenderABC"}
- The server needs to send acknowledgements back to the MQL clients for identification and possibly heartbeats.
- Buffer splitting for TCP: The current `accumulatedData` logic handles messages split across TCP packets or multiple messages in one packet, as long as they are newline-delimited.
*/
console.log("Server script created. To run: node server.js");
