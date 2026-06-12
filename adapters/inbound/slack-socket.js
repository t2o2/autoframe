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

export class SlackSocket {
  /** @param {string} appToken xapp-… app-level token */
  constructor(appToken, { WebSocketImpl = globalThis.WebSocket } = {}) {
    if (!appToken) throw new Error('SlackSocket requires an app-level token (xapp-…)');
    this.appToken = appToken;
    this.WebSocketImpl = WebSocketImpl;
    /** @type {(payload: object) => Promise<void> | void} */
    this.onBlockAction = async () => {};
    this.ws = null;
    this.stopped = false;
  }

  async _openConnectionUrl() {
    const res = await fetch('https://slack.com/api/apps.connections.open', {
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
      console.error('[slack-socket] disconnected — reconnecting in 1s');
      setTimeout(() => this._connect().catch((err) =>
        console.error('[slack-socket] reconnect failed:', err.message)), 1_000);
    });

    ws.addEventListener('error', (event) => {
      console.error('[slack-socket] ws error:', event?.message ?? 'unknown');
    });

    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, { once: true });
      ws.addEventListener('error', reject, { once: true });
    });
    console.log('[slack-socket] connected (Socket Mode)');
  }

  _send(obj) {
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  stop() {
    this.stopped = true;
    try { this.ws?.close(); } catch { /* ignore */ }
  }
}
