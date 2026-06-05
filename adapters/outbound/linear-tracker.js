/**
 * linear-tracker.js — GraphQL TrackerPort implementation.
 *
 * Split into:
 *   mapLinearResponse(json) — pure mapper, fully tested
 *   createLinearTracker({ apiKey, teamKey }) — I/O shell, UNVERIFIED: needs live run
 */

/**
 * Map a raw Linear GraphQL response to Ticket[].
 *
 * Handles null/missing priority (coerced to 0 = "no priority") and
 * missing createdAt (coerced to '' so sortTickets is safe).
 *
 * Expected response shape:
 *   { data: { issues: { nodes: [{ identifier, priority, createdAt }] } } }
 *
 * @param {object} json
 * @returns {import('../../core/ports.js').Ticket[]}
 */
export function mapLinearResponse(json) {
  const nodes = json?.data?.issues?.nodes;
  if (!Array.isArray(nodes)) return [];

  return nodes.map((node) => ({
    id: node.identifier ?? '',
    priority: typeof node.priority === 'number' ? node.priority : 0,
    createdAt: typeof node.createdAt === 'string' ? node.createdAt : '',
    state: typeof node.state?.name === 'string' ? node.state.name : '',
  }));
}

/**
 * Build a GraphQL query body for fetching candidates in a given state list.
 * Uses JSON.stringify to avoid the escaping pitfalls of string interpolation.
 *
 * @param {string} teamKey
 * @param {string[]} states
 * @returns {string}  JSON-encoded request body
 */
function buildFetchQuery(teamKey, states) {
  const query = `{
    issues(filter:{
      team:{key:{eq:"${teamKey}"}},
      state:{name:{in:${JSON.stringify(states)}}}
    }) {
      nodes { identifier priority createdAt state { name } }
    }
  }`;
  return JSON.stringify({ query });
}

/**
 * Build a mutation body to look up a ticket's issue ID by team+number.
 * @param {string} teamKey
 * @param {number} issueNum
 * @returns {string}
 */
function buildGetIssueIdQuery(teamKey, issueNum) {
  const query = `{
    issues(filter:{team:{key:{eq:${JSON.stringify(teamKey)}}},number:{eq:${issueNum}}}) {
      nodes { id state { name } }
    }
  }`;
  return JSON.stringify({ query });
}

/**
 * Build a mutation body to look up state IDs for a team.
 * @param {string} teamKey
 * @returns {string}
 */
function buildGetStatesQuery(teamKey) {
  const query = `{
    teams(filter:{key:{eq:${JSON.stringify(teamKey)}}}) {
      nodes { states { nodes { id name } } }
    }
  }`;
  return JSON.stringify({ query });
}

/**
 * Build an issueUpdate mutation body.
 * @param {string} issueId   UUID
 * @param {string} stateId   UUID
 * @returns {string}
 */
function buildUpdateMutation(issueId, stateId) {
  const query = `mutation {
    issueUpdate(id: ${JSON.stringify(issueId)}, input: { stateId: ${JSON.stringify(stateId)} }) {
      success
    }
  }`;
  return JSON.stringify({ query });
}

const LINEAR_API = 'https://api.linear.app/graphql';

/**
 * Create a Linear GraphQL TrackerPort.
 *
 * UNVERIFIED: needs live run with LINEAR_API_KEY
 *
 * @param {{ apiKey: string, teamKey: string }} opts
 * @returns {import('../../core/ports.js').TrackerPort}
 */
export function createLinearTracker({ apiKey, teamKey }) {
  async function gql(body) {
    const resp = await fetch(LINEAR_API, {
      method: 'POST',
      headers: {
        Authorization: apiKey,
        'Content-Type': 'application/json',
      },
      body,
    });
    if (!resp.ok) {
      throw new Error(`Linear API HTTP ${resp.status}`);
    }
    return resp.json();
  }

  async function resolveIssueUuid(ticketId) {
    const issueNum = parseInt(ticketId.split('-')[1], 10);
    const data = await gql(buildGetIssueIdQuery(teamKey, issueNum));
    const nodes = data?.data?.issues?.nodes ?? [];
    if (!nodes.length) throw new Error(`Issue not found: ${ticketId}`);
    return nodes[0].id;
  }

  /** @type {Map<string,string>|null} */
  let _stateCache = null;

  async function getStateMap() {
    if (_stateCache) return _stateCache;
    const data = await gql(buildGetStatesQuery(teamKey));
    const teams = data?.data?.teams?.nodes ?? [];
    _stateCache = new Map();
    for (const team of teams) {
      for (const state of team.states?.nodes ?? []) {
        _stateCache.set(state.name, state.id);
      }
    }
    return _stateCache;
  }

  async function resolveStateId(targetState) {
    const map = await getStateMap();
    const id = map.get(targetState);
    if (!id) throw new Error(`State not found: ${targetState}`);
    return id;
  }

  return {
    // UNVERIFIED: needs live run with LINEAR_API_KEY
    async fetchCandidates(stage) {
      const data = await gql(buildFetchQuery(teamKey, stage.poll));
      return mapLinearResponse(data);
    },

    // UNVERIFIED: needs live run with LINEAR_API_KEY
    async claimTicket(ticketId, toState) {
      const [issueId, stateId] = await Promise.all([
        resolveIssueUuid(ticketId),
        resolveStateId(toState),
      ]);
      await gql(buildUpdateMutation(issueId, stateId));
    },

    // UNVERIFIED: needs live run with LINEAR_API_KEY
    async revertTicket(ticketId, toState) {
      const [issueId, stateId] = await Promise.all([
        resolveIssueUuid(ticketId),
        resolveStateId(toState),
      ]);
      await gql(buildUpdateMutation(issueId, stateId));
    },

    // UNVERIFIED: needs live run with LINEAR_API_KEY
    async getState(ticketId) {
      const issueNum = parseInt(ticketId.split('-')[1], 10);
      const data = await gql(buildGetIssueIdQuery(teamKey, issueNum));
      const nodes = data?.data?.issues?.nodes ?? [];
      return nodes[0]?.state?.name ?? '';
    },
  };
}
