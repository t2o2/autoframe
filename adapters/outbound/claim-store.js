/**
 * claim-store.js — ClaimPort: in-memory claim store for single-process deployment.
 *
 * Re-exports createClaimStore from core/claim.js.
 * Safe under --stage all (single supervised process owns all dispatch).
 *
 * For multi-container deployments, replace with a Redis-backed implementation
 * that uses SET claim:<ticket> <owner> NX PX <ttl> for atomic claim acquisition.
 */

export { createClaimStore } from '../../core/claim.js';
