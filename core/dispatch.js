/**
 * dispatch.js — priority-ordered ticket dispatch.
 *
 * Produces the same ordering as the Phase 0 bash priority sort in agent-core.sh:
 *   def prio_rank(n):
 *     p = n.get('priority') or 0  # missing OR null → 0 (no priority)
 *     return (5 if p == 0 else p, n.get('createdAt') or '')
 *   nodes.sort(key=prio_rank)
 *
 * Priority mapping (bash oracle):
 *   Linear values: 1=urgent, 2=high, 3=medium, 4=low, 0=none
 *   Rank:          1=first,  2=2nd,  3=3rd,    4=4th, 5=last (none sinks to bottom)
 */

/**
 * Map a Linear priority value to a sort rank.
 * Linear's 0 means "no priority" — it sinks to the bottom (rank 5).
 * Values 1–4 sort by their natural value (1=urgent first, 4=low last).
 *
 * @param {number} priority
 * @returns {number}
 */
export function prioRank(priority) {
  return priority === 0 ? 5 : priority;
}

/**
 * Sort tickets by priority (urgent first) then by createdAt (oldest first).
 * Returns a new array; does not mutate the input.
 *
 * @param {import('./ports.js').Ticket[]} tickets
 * @returns {import('./ports.js').Ticket[]}
 */
export function sortTickets(tickets) {
  return [...tickets].sort((a, b) => {
    const rankDiff = prioRank(a.priority) - prioRank(b.priority);
    if (rankDiff !== 0) return rankDiff;
    return a.createdAt.localeCompare(b.createdAt);
  });
}
