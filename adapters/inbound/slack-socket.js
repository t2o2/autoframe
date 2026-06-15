/**
 * slack-socket.js — minimal Slack Socket Mode client (no SDK, uses the Node
 * global WebSocket). Socket Mode is the transport that delivers button clicks
 * (block_actions interactivity) without a public HTTP Request URL.
 *
 * Requires a Slack APP-LEVEL token (xapp-…) with the connections:write scope,
 * and Socket Mode + Interactivity enabled in the app config.
 *
 * Usage:
 *   const sock = new SlackSocket(appToken);
 *   sock.onBlockAction = async (payload) => { ... };
 *   await sock.start();
 */

/**
 * Process one decoded Socket Mode frame. Pure routing logic, separated from the
 * WebSocket so it can be unit tested. `ack(envelopeId)` sends the required ack;
 * `onBlockAction(payload)` is invoked for block_actions interactivity payloads.
 *
 * @returns {'hello'|'disconnect'|'block_actions'|'ack-only'|'ignored'}
 */
export async function handleFrame(frame, { ack, onBlockAction }) {
  if (!frame || typeof frame !== 'object') return 'ignored';

  if (frame.type === 'hello') return 'hello';
  if (frame.type === 'disconnect') return 'disconnect';

  // Every envelope must be acked, even if we don't act on it.
  if (frame.envelope_id) await ack(frame.envelope_id);

  if (frame.type === 'interactive' && frame.payload?.type === 'block_actions') {
    await onBlockAction(frame.payload);
    return 'block_actions';
  }
  return frame.envelope_id ? 'ack-only' : 'ignored';
}

/**
 * Exponential backoff with a hard cap. Pure (no clock/timer) so it can be unit
 * tested. `attempt` is 1-based: attempt 1 → baseMs, 2 → 2×, 3 → 4×, … capped at
 * maxMs.
 */
export function backoffDelay(attempt, { baseMs = 1_000, maxMs = 30_000 } = {}) {
  const n = Math.max(1, Math.floor(attempt));
  const exp = baseMs * 2 ** (n - 1);
  return Math.min(exp, maxMs);
}

export class SlackSocket {
  /**
   * @param {string} appToken xapp-… app-level token
   * @param {{
   *   WebSocketImpl?: typeof globalThis.WebSocket,
   *   fetchImpl?: typeof globalThis.fetch,
   *   setTimeoutImpl?: typeof globalThis.setTimeout,
   *   clearTimeoutImpl?: typeof globalThis.clearTimeout,
   *   reconnect?: { baseMs?: number, maxMs?: number },
   * }} [opts]
   */
  constructor(appToken, {
    WebSocketImpl = globalThis.WebSocket,
    fetchImpl = globalThis.fetch,
    setTimeoutImpl = globalThis.setTimeout,
    clearTimeoutImpl = globalThis.clearTimeout,
    reconnect = {},
  } = {}) {
    if (!appToken) throw new Error('SlackSocket requires an app-level token (xapp-…)');
    this.appToken = appToken;
    this.WebSocketImpl = WebSocketImpl;
    this.fetchImpl = fetchImpl;
    this.setTimeoutImpl = setTimeoutImpl;
    this.clearTimeoutImpl = clearTimeoutImpl;
    /** @type {(payload: object) => Promise<void> | void} */
    this.onBlockAction = async () => {};
    this.ws = null;
    this.stopped = false;
    // Resilient-reconnect state. A failed reconnect MUST schedule another attempt
    // (the old one-shot setTimeout gave up on the first failure, permanently
    // killing Socket Mode after a transient network blip).
    this.reconnectBaseMs = reconnect.baseMs ?? 1_000;
    this.reconnectMaxMs = reconnect.maxMs ?? 30_000;
    this._reconnectAttempts = 0;
    this._reconnectTimer = null;
  }

  async _openConnectionUrl() {
    const res = await this.fetchImpl('https://slack.com/api/apps.connections.open', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.appToken}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    });
    const data = await res.json();
    if (!data.ok) throw new Error(`Slack apps.connections.open: ${data.error}`);
    return data.url;
  }

  /** Connect and keep the socket alive, reconnecting on close until stop(). */
  async start() {
    this.stopped = false;
    await this._connect();
  }

  async _connect() {
    const url = await this._openConnectionUrl();
    const ws = new this.WebSocketImpl(url);
    this.ws = ws;

    ws.addEventListener('message', (event) => {
      let frame;
      try {
        frame = JSON.parse(typeof event.data === 'string' ? event.data : event.data.toString());
      } catch (err) {
        console.error('[slack-socket] bad frame:', err.message);
        return;
      }
      handleFrame(frame, {
        ack: (envelopeId) => this._send({ envelope_id: envelopeId }),
        onBlockAction: this.onBlockAction,
      }).catch((err) => console.error('[slack-socket] handler error:', err.message));
    });

    ws.addEventListener('close', () => {
      if (this.stopped) return;
      console.error('[slack-socket] disconnected — scheduling reconnect');
      this._scheduleReconnect();
    });

    ws.addEventListener('error', (event) => {
      console.error('[slack-socket] ws error:', event?.message ?? 'unknown');
    });

    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, { once: true });
      ws.addEventListener('error', reject, { once: true });
    });
    // Connected cleanly — reset backoff so the next blip starts from baseMs.
    this._reconnectAttempts = 0;
    console.log('[slack-socket] connected (Socket Mode)');
  }

  /**
   * Schedule a reconnect attempt with exponential backoff, and — crucially —
   * keep rescheduling if the attempt itself fails. Idempotent: a single timer
   * is in flight at a time, so overlapping `close`/`error`/rejection signals
   * don't stack up duplicate loops.
   */
  _scheduleReconnect() {
    if (this.stopped) return;
    if (this._reconnectTimer) return; // an attempt is already pending
    this._reconnectAttempts += 1;
    const delay = backoffDelay(this._reconnectAttempts, {
      baseMs: this.reconnectBaseMs,
      maxMs: this.reconnectMaxMs,
    });
    this._reconnectTimer = this.setTimeoutImpl(() => {
      this._reconnectTimer = null;
      this._connect().catch((err) => {
        const cause = err?.cause?.code ?? err?.cause?.message;
        console.error(
          `[slack-socket] reconnect failed: ${err.message}${cause ? ` (${cause})` : ''}`,
        );
        this._scheduleReconnect(); // keep trying until stop()
      });
    }, delay);
  }

  _send(obj) {
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  stop() {
    this.stopped = true;
    if (this._reconnectTimer) {
      this.clearTimeoutImpl(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    try { this.ws?.close(); } catch { /* ignore */ }
  }
}
