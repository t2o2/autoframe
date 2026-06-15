import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mapLinearResponse, buildCommentMutation } from './linear-tracker.js';

describe('mapLinearResponse', () => {
  it('maps a well-formed response with multiple tickets', () => {
    const response = {
      data: {
        issues: {
          nodes: [
            { identifier: 'ENG-1', priority: 1, createdAt: '2024-01-15T10:30:00.000Z', state: { name: 'Plan Approved' } },
            { identifier: 'ENG-2', priority: 2, createdAt: '2024-02-20T08:00:00.000Z', state: { name: 'Changes Required' } },
          ],
        },
      },
    };

    const tickets = mapLinearResponse(response);

    assert.equal(tickets.length, 2);
    assert.deepEqual(tickets[0], {
      id: 'ENG-1',
      priority: 1,
      createdAt: '2024-01-15T10:30:00.000Z',
      state: 'Plan Approved',
    });
    assert.deepEqual(tickets[1], {
      id: 'ENG-2',
      priority: 2,
      createdAt: '2024-02-20T08:00:00.000Z',
      state: 'Changes Required',
    });
  });

  it('coerces null priority to 0 (no priority)', () => {
    const response = {
      data: {
        issues: {
          nodes: [{ identifier: 'ENG-5', priority: null, createdAt: '2024-01-01T00:00:00.000Z', state: { name: 'Todo' } }],
        },
      },
    };
    const [ticket] = mapLinearResponse(response);
    assert.equal(ticket.priority, 0);
  });

  it('coerces missing priority to 0', () => {
    const response = {
      data: {
        issues: {
          nodes: [{ identifier: 'ENG-6', createdAt: '2024-01-01T00:00:00.000Z' }],
        },
      },
    };
    const [ticket] = mapLinearResponse(response);
    assert.equal(ticket.priority, 0);
  });

  it('coerces missing createdAt to empty string', () => {
    const response = {
      data: {
        issues: {
          nodes: [{ identifier: 'ENG-7', priority: 3 }],
        },
      },
    };
    const [ticket] = mapLinearResponse(response);
    assert.equal(ticket.createdAt, '');
  });

  it('coerces null createdAt to empty string', () => {
    const response = {
      data: {
        issues: {
          nodes: [{ identifier: 'ENG-8', priority: 2, createdAt: null }],
        },
      },
    };
    const [ticket] = mapLinearResponse(response);
    assert.equal(ticket.createdAt, '');
  });

  it('coerces missing state to empty string', () => {
    const response = {
      data: {
        issues: {
          nodes: [{ identifier: 'ENG-9', priority: 1, createdAt: '2024-01-01T00:00:00.000Z' }],
        },
      },
    };
    const [ticket] = mapLinearResponse(response);
    assert.equal(ticket.state, '');
  });

  it('returns empty array for empty nodes', () => {
    const response = { data: { issues: { nodes: [] } } };
    assert.deepEqual(mapLinearResponse(response), []);
  });

  it('returns empty array for malformed response (no data)', () => {
    assert.deepEqual(mapLinearResponse({}), []);
  });

  it('returns empty array for null input', () => {
    assert.deepEqual(mapLinearResponse(null), []);
  });

  it('returns empty array when nodes is not an array', () => {
    const response = { data: { issues: { nodes: null } } };
    assert.deepEqual(mapLinearResponse(response), []);
  });

  it('maps a fixture with mixed null priority and missing createdAt', () => {
    const response = {
      data: {
        issues: {
          nodes: [
            { identifier: 'ENG-10', priority: 0, createdAt: '2024-03-01T12:00:00.000Z', state: { name: 'Plan Approved' } },
            { identifier: 'ENG-11', priority: null, createdAt: null, state: null },
            { identifier: 'ENG-12', priority: 4, state: { name: 'Changes Required' } },
          ],
        },
      },
    };

    const tickets = mapLinearResponse(response);
    assert.equal(tickets.length, 3);

    assert.equal(tickets[0].id, 'ENG-10');
    assert.equal(tickets[0].priority, 0);
    assert.equal(tickets[0].createdAt, '2024-03-01T12:00:00.000Z');
    assert.equal(tickets[0].state, 'Plan Approved');

    assert.equal(tickets[1].id, 'ENG-11');
    assert.equal(tickets[1].priority, 0);
    assert.equal(tickets[1].createdAt, '');
    assert.equal(tickets[1].state, '');

    assert.equal(tickets[2].id, 'ENG-12');
    assert.equal(tickets[2].priority, 4);
    assert.equal(tickets[2].createdAt, '');
    assert.equal(tickets[2].state, 'Changes Required');
  });
});


describe('buildCommentMutation', () => {
  it('embeds issueId and body and is valid JSON with a commentCreate mutation', () => {
    const body = buildCommentMutation('uuid-123', 'Merge failed: conflict in src/a.rs');
    const parsed = JSON.parse(body);
    assert.match(parsed.query, /commentCreate/);
    assert.match(parsed.query, /uuid-123/);
    assert.match(parsed.query, /Merge failed: conflict in src\/a\.rs/);
  });

  it('escapes quotes, newlines and backticks in the body (JSON.stringify)', () => {
    const tricky = 'line1\n"quoted" and `code` and \\backslash';
    const body = buildCommentMutation('uuid-9', tricky);
    // Must parse as JSON without throwing despite the special characters.
    const parsed = JSON.parse(body);
    // The body is re-encoded inside the GraphQL string literal; round-tripping
    // the embedded JSON-string back out must recover the original text.
    const embedded = JSON.parse(parsed.query.match(/body: (".*?")\s*\}\s*\)/s)[1]);
    assert.equal(embedded, tricky);
  });
});
