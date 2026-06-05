import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { AttemptState, createAttempt } from './attempt.js';

describe('AttemptState', () => {
  it('is a frozen object with all expected state constants', () => {
    assert.equal(AttemptState.PREPARING, 'PREPARING');
    assert.equal(AttemptState.LAUNCHING, 'LAUNCHING');
    assert.equal(AttemptState.STREAMING, 'STREAMING');
    assert.equal(AttemptState.SUCCEEDED, 'SUCCEEDED');
    assert.equal(AttemptState.FAILED, 'FAILED');
    assert.equal(AttemptState.TIMED_OUT, 'TIMED_OUT');
    assert.equal(AttemptState.STALLED, 'STALLED');
    assert.equal(AttemptState.CANCELED, 'CANCELED');
    assert.equal(Object.isFrozen(AttemptState), true);
  });
});

describe('createAttempt', () => {
  describe('initial state', () => {
    it('starts in PREPARING state', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      const json = attempt.toJSON();
      assert.equal(json.state, AttemptState.PREPARING);
    });

    it('toJSON includes all fields', () => {
      const attempt = createAttempt('ENG-42', 'review', 3);
      const json = attempt.toJSON();
      assert.equal(json.ticketId, 'ENG-42');
      assert.equal(json.stage, 'review');
      assert.equal(json.attempt, 3);
      assert.equal(json.state, AttemptState.PREPARING);
      assert.equal(typeof json.startedAt, 'number');
    });
  });

  describe('happy path — full run to SUCCEEDED', () => {
    it('transitions PREPARING → LAUNCHING → STREAMING → SUCCEEDED without error', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      assert.doesNotThrow(() => attempt.transition(AttemptState.LAUNCHING));
      assert.doesNotThrow(() => attempt.transition(AttemptState.STREAMING));
      assert.doesNotThrow(() => attempt.transition(AttemptState.SUCCEEDED));
      assert.equal(attempt.toJSON().state, AttemptState.SUCCEEDED);
    });
  });

  describe('other terminal paths from STREAMING', () => {
    it('STREAMING → FAILED is valid', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      attempt.transition(AttemptState.LAUNCHING);
      attempt.transition(AttemptState.STREAMING);
      assert.doesNotThrow(() => attempt.transition(AttemptState.FAILED));
    });

    it('STREAMING → TIMED_OUT is valid', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      attempt.transition(AttemptState.LAUNCHING);
      attempt.transition(AttemptState.STREAMING);
      assert.doesNotThrow(() => attempt.transition(AttemptState.TIMED_OUT));
    });

    it('STREAMING → STALLED is valid', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      attempt.transition(AttemptState.LAUNCHING);
      attempt.transition(AttemptState.STREAMING);
      assert.doesNotThrow(() => attempt.transition(AttemptState.STALLED));
    });

    it('STREAMING → CANCELED is valid', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      attempt.transition(AttemptState.LAUNCHING);
      attempt.transition(AttemptState.STREAMING);
      assert.doesNotThrow(() => attempt.transition(AttemptState.CANCELED));
    });
  });

  describe('early cancellation', () => {
    it('PREPARING → CANCELED is valid (aborted before launch)', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      assert.doesNotThrow(() => attempt.transition(AttemptState.CANCELED));
      assert.equal(attempt.toJSON().state, AttemptState.CANCELED);
    });
  });

  describe('invalid transitions throw', () => {
    it('PREPARING → SUCCEEDED throws', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      assert.throws(
        () => attempt.transition(AttemptState.SUCCEEDED),
        /invalid transition PREPARING → SUCCEEDED/,
      );
    });

    it('PREPARING → STREAMING throws (must go through LAUNCHING)', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      assert.throws(
        () => attempt.transition(AttemptState.STREAMING),
        /invalid transition PREPARING → STREAMING/,
      );
    });

    it('SUCCEEDED → FAILED throws (terminal states have no outgoing transitions)', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      attempt.transition(AttemptState.LAUNCHING);
      attempt.transition(AttemptState.STREAMING);
      attempt.transition(AttemptState.SUCCEEDED);
      assert.throws(
        () => attempt.transition(AttemptState.FAILED),
        /invalid transition SUCCEEDED → FAILED/,
      );
    });

    it('LAUNCHING → SUCCEEDED throws (must stream first)', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      attempt.transition(AttemptState.LAUNCHING);
      assert.throws(
        () => attempt.transition(AttemptState.SUCCEEDED),
        /invalid transition LAUNCHING → SUCCEEDED/,
      );
    });
  });

  describe('elapsed', () => {
    it('returns clock.now() minus startedAt', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      const { startedAt } = attempt.toJSON();
      const delta = 5000;
      const clock = { now: () => startedAt + delta };
      assert.equal(attempt.elapsed(clock), delta);
    });

    it('returns 0 when clock.now() equals startedAt', () => {
      const attempt = createAttempt('ENG-1', 'process', 1);
      const { startedAt } = attempt.toJSON();
      const clock = { now: () => startedAt };
      assert.equal(attempt.elapsed(clock), 0);
    });
  });
});
