#!/usr/bin/env node
// Ephemeral Aedes MQTT 3.1.1 broker for HonkMQTT M3 interop (loopback only).
"use strict";

const net = require("net");
const aedes = require("aedes");

const port = Number(process.argv[2] || "0");
if (!Number.isFinite(port) || port < 0 || port > 65535) {
  console.error("usage: aedes_server.js <port>");
  process.exit(2);
}

const broker = aedes({
  concurrency: 10,
  heartbeatInterval: 60000,
  connectTimeout: 5000,
});

const server = net.createServer(broker.handle);
server.listen(port, "127.0.0.1", () => {
  const addr = server.address();
  process.stdout.write(`AEDES_READY ${addr.port}\n`);
});

function shutdown(code) {
  server.close(() => {
    broker.close(() => process.exit(code));
  });
  setTimeout(() => process.exit(code || 1), 2000).unref();
}

process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));
broker.on("clientError", (client, err) => {
  process.stderr.write(`aedes clientError ${client && client.id}: ${err.message}\n`);
});
