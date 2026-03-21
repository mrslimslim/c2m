/**
 * Transport interface — abstraction over WebSocket communication.
 */

import type { BridgeMessage, PhoneMessage } from "@codepilot/protocol";

export interface TransportClient {
  id: string;
  send(message: BridgeMessage): void;
}

export interface TransportServer {
  /**
   * Start the transport server and return the connection URL / pairing info.
   */
  start(): Promise<{
    url: string;
    httpUrl: string;
    pairingData: Record<string, unknown>;
    listenUrl?: string;
  }>;

  /**
   * Register a handler for incoming messages from any connected client.
   */
  onMessage(handler: (client: TransportClient, message: PhoneMessage) => void): void;

  /**
   * Register a handler for client connection events.
   */
  onConnect(handler: (client: TransportClient) => void): void;

  /**
   * Register a handler for client disconnection events.
   */
  onDisconnect(handler: (client: TransportClient) => void): void;

  /**
   * Broadcast a message to all connected clients.
   */
  broadcast(message: BridgeMessage): void;

  /**
   * Shut down the transport.
   */
  stop(): Promise<void>;
}
