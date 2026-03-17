export function normalizeRelayUrl(relayUrl) {
  return String(relayUrl || "").trim().replace(/\/$/, "");
}

export function buildSocketUrl(config) {
  if (config.mode === "relay") {
    const relayBase = normalizeRelayUrl(config.relay);
    return `${relayBase}/ws?device=phone&channel=${encodeURIComponent(config.channel)}`;
  }

  return `ws://${config.host}:${config.port}`;
}

export function canInitiateConnection(socket) {
  if (!socket) {
    return true;
  }

  return socket.readyState !== 0 && socket.readyState !== 1;
}

export function validateConnectionInput(config) {
  const hasPairing = Boolean(config.bridgePubkey && config.pairingOtp);

  if (config.mode === "relay") {
    if (!config.relay || !config.channel) {
      return "Please fill in relay URL and channel";
    }
    if (!hasPairing) {
      return "Relay mode requires pairing data (bridge pubkey and OTP)";
    }
    return null;
  }

  if (!config.host || !config.port) {
    return "Please fill in host and port";
  }
  if (!config.token && !hasPairing) {
    return "LAN mode requires a token or E2E pairing data";
  }

  return null;
}

export function resolveInitialConfig(params, locationLike) {
  const relay = normalizeRelayUrl(params.get("relay") || "");
  const channel = params.get("channel") || "";
  const host = params.get("host") || locationLike.hostname || "127.0.0.1";
  const port = params.get("port") || locationLike.port || "19260";
  const token = params.get("token") || "";
  const bridgePubkey = params.get("bridge_pubkey") || "";
  const pairingOtp = params.get("otp") || "";
  const mode = relay || channel ? "relay" : "lan";
  const hasPairing = Boolean(bridgePubkey && pairingOtp);
  const shouldAutoConnect = mode === "relay"
    ? Boolean(relay && channel && hasPairing)
    : Boolean(host && port && (token || hasPairing));

  return {
    mode,
    host,
    port,
    token,
    relay,
    channel,
    bridgePubkey,
    pairingOtp,
    shouldAutoConnect,
  };
}

class E2ECrypto {
  constructor() {
    this.keyPair = null;
    this.sessionKey = null;
    this.publicKeyBase64 = null;
    this.encrypted = false;
  }

  async generateKeyPair() {
    this.keyPair = await crypto.subtle.generateKey("X25519", true, ["deriveBits"]);
    const pubRaw = await crypto.subtle.exportKey("raw", this.keyPair.publicKey);
    this.publicKeyBase64 = btoa(String.fromCharCode(...new Uint8Array(pubRaw)));
    return this.publicKeyBase64;
  }

  async deriveSessionKey(bridgePubkeyBase64, otp) {
    const bridgePubBytes = Uint8Array.from(atob(bridgePubkeyBase64), (c) => c.charCodeAt(0));
    const bridgePubKey = await crypto.subtle.importKey(
      "raw",
      bridgePubBytes,
      "X25519",
      false,
      [],
    );

    const sharedBits = await crypto.subtle.deriveBits(
      { name: "X25519", public: bridgePubKey },
      this.keyPair.privateKey,
      256,
    );

    const hkdfKey = await crypto.subtle.importKey(
      "raw",
      sharedBits,
      "HKDF",
      false,
      ["deriveKey"],
    );

    const encoder = new TextEncoder();
    this.sessionKey = await crypto.subtle.deriveKey(
      {
        name: "HKDF",
        hash: "SHA-256",
        salt: encoder.encode(otp),
        info: encoder.encode("codepilot-e2e-v1"),
      },
      hkdfKey,
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );

    this.encrypted = true;
    return this.sessionKey;
  }

  async encrypt(plaintext) {
    if (!this.sessionKey) {
      throw new Error("No session key");
    }

    const encoder = new TextEncoder();
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const encoded = encoder.encode(plaintext);

    const cipherBuf = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce, tagLength: 128 },
      this.sessionKey,
      encoded,
    );

    const combined = new Uint8Array(cipherBuf);
    const ciphertext = combined.slice(0, combined.length - 16);
    const tag = combined.slice(combined.length - 16);

    return {
      v: 1,
      nonce: btoa(String.fromCharCode(...nonce)),
      ciphertext: btoa(String.fromCharCode(...ciphertext)),
      tag: btoa(String.fromCharCode(...tag)),
    };
  }

  async decrypt(message) {
    if (!this.sessionKey) {
      throw new Error("No session key");
    }

    const nonce = Uint8Array.from(atob(message.nonce), (c) => c.charCodeAt(0));
    const ciphertext = Uint8Array.from(atob(message.ciphertext), (c) => c.charCodeAt(0));
    const tag = Uint8Array.from(atob(message.tag), (c) => c.charCodeAt(0));

    const combined = new Uint8Array(ciphertext.length + tag.length);
    combined.set(ciphertext);
    combined.set(tag, ciphertext.length);

    const plainBuf = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce, tagLength: 128 },
      this.sessionKey,
      combined,
    );

    return new TextDecoder().decode(plainBuf);
  }
}

function initTestClient() {
  const e2e = new E2ECrypto();
  let ws = null;
  let currentSessionId = null;
  let bridgePubkey = "";
  let pairingOtp = "";

  function element(id) {
    return document.getElementById(id);
  }

  function readConfigFromForm() {
    return {
      mode: element("modeSelect").value,
      host: element("hostInput").value.trim(),
      port: element("portInput").value.trim(),
      token: element("tokenInput").value.trim(),
      relay: normalizeRelayUrl(element("relayInput").value),
      channel: element("channelInput").value.trim(),
      bridgePubkey: element("bridgePubkeyInput").value.trim(),
      pairingOtp: element("otpInput").value.trim(),
    };
  }

  function applyConfigToForm(config) {
    element("modeSelect").value = config.mode;
    element("hostInput").value = config.host;
    element("portInput").value = config.port;
    element("tokenInput").value = config.token;
    element("relayInput").value = config.relay;
    element("channelInput").value = config.channel;
    element("bridgePubkeyInput").value = config.bridgePubkey;
    element("otpInput").value = config.pairingOtp;

    bridgePubkey = config.bridgePubkey;
    pairingOtp = config.pairingOtp;
    updateConnectionMode();
  }

  function addEvent(type, title, detail) {
    const container = element("events");
    const eventEl = document.createElement("div");
    eventEl.className = `event-item ${type}`;
    eventEl.innerHTML = `
      <div class="event-type">${escapeHtml(title)}</div>
      ${detail ? `<div class="event-detail">${escapeHtml(detail)}</div>` : ""}
    `;
    container.appendChild(eventEl);
    container.scrollTop = container.scrollHeight;
  }

  function setConnected(connected) {
    element("statusDot").classList.toggle("connected", connected);
    element("statusText").textContent = connected ? "Connected" : "Disconnected";
    element("sendBtn").disabled = !connected;
    if (!connected) {
      element("e2eBadge").classList.remove("active");
      e2e.encrypted = false;
      e2e.sessionKey = null;
    }
  }

  function autoResize(textarea) {
    textarea.style.height = "auto";
    textarea.style.height = `${Math.min(textarea.scrollHeight, 120)}px`;
  }

  function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }

  function formatEventTitle(event) {
    switch (event.type) {
      case "status":
        return `Status: ${event.state}`;
      case "thinking":
        return "Thinking";
      case "agent_message":
        return "Agent";
      case "code_change":
        return `Code Change (${event.changes.length} files)`;
      case "command_exec":
        return `Command: ${event.status}`;
      case "error":
        return "Error";
      case "turn_completed":
        return "Turn Completed";
      default:
        return event.type;
    }
  }

  function formatEventDetail(event) {
    switch (event.type) {
      case "status":
        return event.message;
      case "thinking":
        return event.text;
      case "agent_message":
        return event.text;
      case "code_change":
        return event.changes.map((change) => `${change.kind}: ${change.path}`).join("\n");
      case "command_exec": {
        let summary = `$ ${event.command}`;
        if (event.output) {
          summary += `\n${event.output}`;
        }
        if (event.exitCode !== undefined) {
          summary += `\n(exit: ${event.exitCode})`;
        }
        return summary;
      }
      case "error":
        return event.message;
      case "turn_completed": {
        let detail = event.summary;
        if (event.filesChanged?.length) {
          detail += `\nFiles: ${event.filesChanged.join(", ")}`;
        }
        if (event.usage) {
          detail += `\nTokens: ${event.usage.inputTokens} in / ${event.usage.outputTokens} out`;
        }
        return detail;
      }
      default:
        return JSON.stringify(event, null, 2);
    }
  }

  function updateConnectionMode() {
    const mode = element("modeSelect").value;
    document.querySelectorAll("[data-mode-group]").forEach((node) => {
      node.classList.toggle("hidden", node.dataset.modeGroup !== mode);
    });
  }

  async function handleMessage(message) {
    switch (message.type) {
      case "auth_ok":
        setConnected(true);
        addEvent("system", "Authenticated", `Client: ${message.clientId}`);
        element("connectPanel").classList.add("hidden");
        break;

      case "handshake_ok":
        try {
          await e2e.deriveSessionKey(bridgePubkey, pairingOtp);
          setConnected(true);
          element("e2eBadge").classList.add("active");
          addEvent("system", "E2E Encrypted", `Handshake complete. Client: ${message.clientId || ""}`);
          element("connectPanel").classList.add("hidden");
        } catch (error) {
          addEvent("error", "E2E Failed", `Key derivation failed: ${error.message}`);
        }
        break;

      case "auth_failed":
        addEvent("error", "Auth Failed", message.reason || "Invalid token or OTP");
        break;

      case "event":
        currentSessionId = message.sessionId;
        addEvent(message.event.type, formatEventTitle(message.event), formatEventDetail(message.event));
        break;

      case "session_list":
        if (message.sessions.length > 0) {
          currentSessionId = message.sessions[0].id;
          addEvent(
            "system",
            "Sessions",
            message.sessions.map((session) => (
              `${session.id.slice(0, 12)} [${session.agentType}] ${session.state}`
            )).join("\n"),
          );
        }
        break;

      case "pong":
        addEvent("system", "Pong", `Latency: ${message.latencyMs}ms`);
        break;

      case "file_content":
        addEvent("system", `File: ${message.path}`, message.content.slice(0, 1000));
        break;

      case "error":
        addEvent("error", "Error", message.message);
        break;

      default:
        addEvent("system", "Message", JSON.stringify(message, null, 2));
        break;
    }
  }

  async function connect() {
    if (!canInitiateConnection(ws)) {
      addEvent("system", "Connection", "Already connected or connecting");
      return;
    }

    const config = readConfigFromForm();
    bridgePubkey = config.bridgePubkey;
    pairingOtp = config.pairingOtp;

    const validationError = validateConnectionInput(config);
    if (validationError) {
      addEvent("system", "Error", validationError);
      return;
    }

    const useE2E = Boolean(bridgePubkey && pairingOtp);
    const url = buildSocketUrl(config);
    addEvent("system", "Connecting", `${config.mode.toUpperCase()}: ${url}`);

    if (useE2E) {
      try {
        await e2e.generateKeyPair();
        addEvent("system", "E2E", "Generated X25519 keypair");
      } catch (error) {
        addEvent("system", "E2E Warning", `Keypair generation failed: ${error.message}`);
        return;
      }
    }

    try {
      ws = new WebSocket(url);
    } catch (error) {
      addEvent("system", "Error", `Failed to create WebSocket: ${error.message}`);
      return;
    }

    ws.onopen = () => {
      addEvent("system", "Connected", "Authenticating...");

      if (useE2E && e2e.publicKeyBase64) {
        ws.send(JSON.stringify({
          type: "handshake",
          phone_pubkey: e2e.publicKeyBase64,
          otp: pairingOtp,
        }));
      } else {
        ws.send(JSON.stringify({
          type: "auth",
          token: config.token,
        }));
      }
    };

    ws.onmessage = async (event) => {
      try {
        const raw = JSON.parse(event.data);

        if (raw.v === 1 && raw.nonce && raw.ciphertext && raw.tag && e2e.encrypted) {
          const decrypted = await e2e.decrypt(raw);
          await handleMessage(JSON.parse(decrypted));
          return;
        }

        await handleMessage(raw);
      } catch (_error) {
        addEvent("system", "Raw", event.data);
      }
    };

    ws.onclose = (event) => {
      setConnected(false);
      addEvent("system", "Disconnected", `Code: ${event.code} ${event.reason || ""}`);
      ws = null;
    };

    ws.onerror = () => {
      addEvent("system", "Error", "WebSocket connection failed");
    };
  }

  async function sendCommand() {
    const input = element("cmdInput");
    const text = input.value.trim();
    if (!text || !ws || ws.readyState !== WebSocket.OPEN) {
      return;
    }

    const payload = {
      type: "command",
      text,
      sessionId: currentSessionId || undefined,
    };

    if (e2e.encrypted) {
      const encrypted = await e2e.encrypt(JSON.stringify(payload));
      ws.send(JSON.stringify(encrypted));
    } else {
      ws.send(JSON.stringify(payload));
    }

    addEvent("system", "You", text);
    input.value = "";
    autoResize(input);
  }

  function quickCmd(text) {
    element("cmdInput").value = text;
    sendCommand();
  }

  const initialConfig = resolveInitialConfig(new URLSearchParams(location.search), {
    hostname: location.hostname,
    port: location.port,
  });
  applyConfigToForm(initialConfig);

  if (initialConfig.shouldAutoConnect) {
    setTimeout(connect, 500);
  }

  window.connect = connect;
  window.sendCommand = sendCommand;
  window.quickCmd = quickCmd;
  window.autoResize = autoResize;
  window.updateConnectionMode = updateConnectionMode;
}

if (typeof window !== "undefined" && typeof document !== "undefined") {
  initTestClient();
}
