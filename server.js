const net = require('net');
const fs = require('fs');

const PORT = 3000;
const HOST = '0.0.0.0'; // Listen on all available network interfaces

// Load authorized receiver accounts from a JSON file
let AUTHORIZED_RECEIVER_ACCOUNTS = new Set();
try {
    const data = fs.readFileSync('./authorized_receiver_accounts.json', 'utf8');
    const accounts = JSON.parse(data);
    if (Array.isArray(accounts)) {
        AUTHORIZED_RECEIVER_ACCOUNTS = new Set(accounts);
        console.log('Authorized receiver accounts loaded:', Array.from(AUTHORIZED_RECEIVER_ACCOUNTS));
    } else {
        console.error('Error: authorized_receiver_accounts.json is not a valid JSON array. No accounts loaded.');
    }
} catch (err) {
    console.error('Error reading or parsing authorized_receiver_accounts.json:', err.message);
    console.log('No authorized receiver accounts loaded. All receiver connections will be treated as unauthorized unless the file is created/fixed and server restarted.');
}


// In-memory store for clients
// client = { id: string, socket: net.Socket, role: 'sender'|'receiver'|null, accountId: string|null, listenTo?: string, lastHeartbeat: number, isAuthenticatedReceiver: boolean, isPrimaryConnection: boolean }
const clients = new Map();

// Track active primary connections for receiver accounts
// Key: receiverAccountId (MT4 account number), Value: clientId (e.g., socket.remoteAddress + ':' + socket.remotePort)
const activePrimaryReceiverConnections = new Map();

function generateClientId(socket) {
    return `${socket.remoteAddress}:${socket.remotePort}`;
}

function broadcastToReceivers(senderAccountId, messageString) {
    let relayedCount = 0;
    clients.forEach(client => {
        if (client.role === 'receiver' &&
            client.listenTo === senderAccountId &&
            client.isAuthenticatedReceiver && // Must be an authorized account
            client.isPrimaryConnection) {    // Must be the primary connection for that account
            try {
                client.socket.write(messageString); // Forward the raw message string (it includes newline)
                relayedCount++;
            } catch (error) {
                console.error(`Error sending message to primary receiver ${client.accountId} (${client.id}): ${error.message}`);
                // Potentially handle socket write errors, e.g., by cleaning up this client
            }
        }
    });
    if (relayedCount > 0) {
        console.log(`Relayed message from ${senderAccountId} to ${relayedCount} primary receiver(s).`);
    }
}

const server = net.createServer(socket => {
    const clientId = generateClientId(socket);
    console.log(`Client connected: ${clientId}`);

    clients.set(clientId, {
        id: clientId,
        socket: socket,
        role: null,
        accountId: null,
        lastHeartbeat: Date.now(),
        isAuthenticatedReceiver: false, // Default for receivers
        isPrimaryConnection: false      // Default for receivers
    });

    let accumulatedData = '';

    socket.on('data', data => {
        const currentClient = clients.get(clientId);
        if (!currentClient) return; // Should not happen if client is still in map

        currentClient.lastHeartbeat = Date.now();
        accumulatedData += data.toString();

        let newlineIndex;
        while ((newlineIndex = accumulatedData.indexOf('\n')) !== -1) {
            const messageString = accumulatedData.substring(0, newlineIndex);
            accumulatedData = accumulatedData.substring(newlineIndex + 1);

            if (messageString.trim() === '') continue;

            console.log(`Received from ${clientId} (${currentClient.accountId || 'unidentified'}): ${messageString}`);

            try {
                const message = JSON.parse(messageString);

                if (message.type === 'identification') {
                    currentClient.accountId = message.accountId; // Store accountId regardless of role for logging
                    currentClient.role = message.role;

                    if (message.role === 'sender') {
                        if (message.accountId) {
                            console.log(`Client ${clientId} identified as SENDER: ${message.accountId}`);
                            socket.write(JSON.stringify({type: "ack", message: "Sender identification successful"}) + "\n");
                        } else {
                             console.warn(`Invalid sender identification from ${clientId}: missing accountId`, message);
                            socket.write(JSON.stringify({type: "error", message: "Invalid sender identification: missing accountId"}) + "\n");
                        }
                    } else if (message.role === 'receiver') {
                        if (message.accountId && message.listenTo) {
                            currentClient.listenTo = message.listenTo;
                            if (AUTHORIZED_RECEIVER_ACCOUNTS.has(message.accountId)) {
                                if (!activePrimaryReceiverConnections.has(message.accountId)) {
                                    activePrimaryReceiverConnections.set(message.accountId, clientId);
                                    currentClient.isAuthenticatedReceiver = true;
                                    currentClient.isPrimaryConnection = true;
                                    console.log(`Receiver ${message.accountId} (${clientId}) AUTHENTICATED as PRIMARY for sender ${message.listenTo}`);
                                    socket.write(JSON.stringify({type: "ack", status: "authenticated_primary", message: "Authenticated as primary data connection."}) + "\n");
                                } else {
                                    currentClient.isAuthenticatedReceiver = true; // Authenticated as known account
                                    currentClient.isPrimaryConnection = false;  // But not the primary data stream
                                    console.log(`Receiver ${message.accountId} (${clientId}) connected as DUPLICATE. Data will go to primary connection ${activePrimaryReceiverConnections.get(message.accountId)}.`);
                                    socket.write(JSON.stringify({type: "ack", status: "authenticated_duplicate", message: "Connection accepted. This is a duplicate stream; data will be sent to the primary connection only."}) + "\n");
                                }
                            } else {
                                currentClient.isAuthenticatedReceiver = false;
                                currentClient.isPrimaryConnection = false;
                                console.warn(`Receiver ${message.accountId} (${clientId}) identification FAILED: Account not authorized.`);
                                socket.write(JSON.stringify({type: "error", status: "unauthorized", message: "Identification failed: Account not authorized."}) + "\n");
                            }
                        } else {
                            console.warn(`Invalid receiver identification from ${clientId}: missing accountId or listenTo`, message);
                            socket.write(JSON.stringify({type: "error", message: "Invalid receiver identification: missing accountId or listenTo"}) + "\n");
                        }
                    } else {
                        console.warn(`Unknown role in identification from ${clientId}: ${message.role}`);
                        socket.write(JSON.stringify({type: "error", message: "Unknown role in identification message"}) + "\n");
                    }

                } else if (message.type === 'heartbeat') {
                    // console.log(`Heartbeat from ${currentClient.accountId || clientId}`); // Already commented, ensure any other verbose log is also commented
                    socket.write(JSON.stringify({type: "ack", message: "Heartbeat received"}) + "\n");
                } else if (message.type === 'tradeEvent') {
                    if (currentClient.role === 'sender' && currentClient.accountId) {
                        console.log(`Trade event from sender ${currentClient.accountId}:`, message.order ? `Order ${message.order.ticket}` : 'Details in log');
                        broadcastToReceivers(currentClient.accountId, messageString + '\n');
                    } else {
                        console.warn(`Trade event from non-sender or unidentified client ${clientId}. Role: ${currentClient.role}, AccountID: ${currentClient.accountId}`);
                        socket.write(JSON.stringify({type: "error", message: "Cannot process tradeEvent: identify as sender first or invalid role."}) + "\n");
                    }
                } else {
                    console.warn(`Unknown message type from ${currentClient.accountId || clientId}: ${message.type}`);
                    socket.write(JSON.stringify({type: "error", message: "Unknown message type"}) + "\n");
                }

            } catch (error) {
                console.error(`Failed to parse JSON from ${currentClient.accountId || clientId} (${clientId}): ${error.message}. Data: "${messageString}"`);
                socket.write(JSON.stringify({type: "error", message: "Invalid JSON format"}) + "\n");
            }
        }
    });

    socket.on('end', () => {
        const clientInfo = clients.get(clientId);
        if (clientInfo) {
            console.log(`Client disconnected: ${clientInfo.accountId || clientId} (${clientId})`);
            if (clientInfo.role === 'receiver' && clientInfo.isPrimaryConnection) {
                // Check if this exact clientId was the primary for this accountId
                if (activePrimaryReceiverConnections.get(clientInfo.accountId) === clientId) {
                    activePrimaryReceiverConnections.delete(clientInfo.accountId);
                    console.log(`Primary connection for receiver account ${clientInfo.accountId} removed. Another instance can now become primary.`);
                }
            }
            clients.delete(clientId);
        } else {
            console.log(`Client disconnected: ${clientId} (no info found in clients map)`);
        }
    });

    socket.on('error', err => {
        const clientInfo = clients.get(clientId);
        if (clientInfo) {
            console.error(`Socket error from ${clientInfo.accountId || clientId} (${clientId}): ${err.message}`);
            if (clientInfo.role === 'receiver' && clientInfo.isPrimaryConnection) {
                if (activePrimaryReceiverConnections.get(clientInfo.accountId) === clientId) {
                    activePrimaryReceiverConnections.delete(clientInfo.accountId);
                    console.log(`Primary connection for receiver account ${clientInfo.accountId} removed due to error. Another instance can now become primary.`);
                }
            }
            clients.delete(clientId);
        } else {
            console.error(`Socket error from ${clientId} (no info found in clients map): ${err.message}`);
        }
    });
});

server.on('error', err => {
    console.error(`Server error: ${err.message}`);
    if (err.code === 'EADDRINUSE') {
        console.error(`Port ${PORT} is already in use. Please choose a different port or stop the other process.`);
        process.exit(1);
    }
});

const HEARTBEAT_CHECK_INTERVAL = 30 * 1000;
const HEARTBEAT_TIMEOUT = 90 * 1000;

setInterval(() => {
    const now = Date.now();
    clients.forEach(client => {
        if (now - client.lastHeartbeat > HEARTBEAT_TIMEOUT) {
            console.log(`Client ${client.accountId || client.id} timed out. Last heartbeat: ${new Date(client.lastHeartbeat).toISOString()}. Ending connection.`);
            client.socket.end(); // This will trigger the 'end' event for cleanup
            // No need to delete from activePrimaryReceiverConnections here, 'end' handler will do it.
        }
    });
}, HEARTBEAT_CHECK_INTERVAL);


server.listen(PORT, HOST, () => {
    console.log(`NodeJS TCP server listening on ${HOST}:${PORT}`);
    console.log(`Domain for clients: metaapi.gametrader.my (ensure DNS points to this server's IP and port ${PORT} is open)`);
    console.log(`Ensure 'authorized_receiver_accounts.json' is present and correctly formatted in the same directory.`);
});

function shutdown() {
    console.log('Shutting down server...');
    server.close(() => {
        console.log('Server closed. Exiting.');
        process.exit(0);
    });

    clients.forEach(client => {
        client.socket.destroy();
    });

    setTimeout(() => {
        console.error('Could not close connections in time, forcefully shutting down');
        process.exit(1);
    }, 5000);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

console.log("Server script updated with receiver authentication and duplicate connection management.");
console.log("Remember to create/update 'authorized_receiver_accounts.json' with valid MT4 account numbers.");
console.log("Example 'authorized_receiver_accounts.json':");
console.log("[\n  \"12345\",\n  \"67890\"\n]");
