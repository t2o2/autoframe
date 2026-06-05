import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { sortTickets, prioRank } from './dispatch.js';

describe('prioRank', () => {
  it('maps 0 (none) to rank 5 — sinks to bottom', () => {
    assert.equal(prioRank(0), 5);
  });

  it('maps 1 (urgent) to rank 1 — rises to top', () => {
    assert.equal(prioRank(1), 1);
  });

  it('maps 2 (high) to rank 2', () => {
    assert.equal(prioRank(2), 2);
  });

  it('maps 3 (medium) to rank 3', () => {
    assert.equal(prioRank(3), 3);
  });

  it('maps 4 (low) to rank 4', () => {
    assert.equal(prioRank(4), 4);
  });
});

describe('sortTickets', () => {
  it('returns a new array without mutating the input', () => {
    const tickets = [
      { id: 'ENG-1', priority: 2, createdAt: '2024-01-01T00:00:00.000Z', state: 'Plan Approved' },
      { id: 'ENG-2', priority: 1, createdAt: '2024-01-02T00:00:00.000Z', state: 'Plan Approved' },
    ];
    const sorted = sortTickets(tickets);
    assert.notEqual(sorted, tickets);
    assert.equal(tickets[0].id, 'ENG-1');
  });

  it('sorts by priority rank ascending (urgent=1 before low=4)', () => {
    const tickets = [
      { id: 'ENG-4', priority: 4, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-1', priority: 1, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-3', priority: 3, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-2', priority: 2, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
    ];
    const sorted = sortTickets(tickets);
    assert.deepEqual(
      sorted.map((t) => t.id),
      ['ENG-1', 'ENG-2', 'ENG-3', 'ENG-4'],
    );
  });

  it('places priority=0 (none) last — after priority=4 (low)', () => {
    const tickets = [
      { id: 'ENG-0', priority: 0, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-4', priority: 4, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-1', priority: 1, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
    ];
    const sorted = sortTickets(tickets);
    // Expected order: 1 (urgent), 4 (low), 0 (none=rank 5)
    assert.deepEqual(
      sorted.map((t) => t.id),
      ['ENG-1', 'ENG-4', 'ENG-0'],
    );
  });

  it('breaks ties within same priority by createdAt ascending (oldest first)', () => {
    const tickets = [
      { id: 'ENG-3', priority: 2, createdAt: '2024-03-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-1', priority: 2, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-2', priority: 2, createdAt: '2024-02-01T00:00:00.000Z', state: 'a' },
    ];
    const sorted = sortTickets(tickets);
    // Expected: oldest first → ENG-1, ENG-2, ENG-3
    assert.deepEqual(
      sorted.map((t) => t.id),
      ['ENG-1', 'ENG-2', 'ENG-3'],
    );
  });

  it('sorts a full mix of priorities (0,1,2,3,4) with varying createdAt', () => {
    /**
     * Input — deliberately disordered:
     *   ENG-A: priority=4 (low),    createdAt=2024-01-01  → rank 4, old
     *   ENG-B: priority=0 (none),   createdAt=2024-01-01  → rank 5, old
     *   ENG-C: priority=1 (urgent), createdAt=2024-03-01  → rank 1, new
     *   ENG-D: priority=1 (urgent), createdAt=2024-01-01  → rank 1, old
     *   ENG-E: priority=3 (medium), createdAt=2024-02-01  → rank 3
     *   ENG-F: priority=2 (high),   createdAt=2024-01-15  → rank 2
     *
     * Expected order (bash oracle logic):
     *   ENG-D (urgent/oldest), ENG-C (urgent/newer),
     *   ENG-F (high),
     *   ENG-E (medium),
     *   ENG-A (low),
     *   ENG-B (none=rank5)
     */
    const tickets = [
      { id: 'ENG-A', priority: 4, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-B', priority: 0, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-C', priority: 1, createdAt: '2024-03-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-D', priority: 1, createdAt: '2024-01-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-E', priority: 3, createdAt: '2024-02-01T00:00:00.000Z', state: 'a' },
      { id: 'ENG-F', priority: 2, createdAt: '2024-01-15T00:00:00.000Z', state: 'a' },
    ];
    const sorted = sortTickets(tickets);
    assert.deepEqual(
      sorted.map((t) => t.id),
      ['ENG-D', 'ENG-C', 'ENG-F', 'ENG-E', 'ENG-A', 'ENG-B'],
    );
  });

  it('handles empty array', () => {
    assert.deepEqual(sortTickets([]), []);
  });
});
