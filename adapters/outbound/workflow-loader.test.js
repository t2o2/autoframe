import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { loadWorkflow } from './workflow-loader.js';

const REAL_TOML = '/Users/chuanbai/code/autoframe/workflow.toml';

describe('loadWorkflow', () => {
  describe('with the real workflow.toml', () => {
    it('returns a non-null config object', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null, 'Expected config to be non-null for valid workflow.toml');
    });

    it('has all 6 stages present', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      const stageNames = config.stages.map((s) => s.name);
      assert.deepEqual(stageNames.sort(), ['approve', 'plan', 'process', 'research', 'retro', 'review']);
    });

    it('process stage poll states match the bash loader output', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      const process = config.stages.find((s) => s.name === 'process');
      assert.notEqual(process, undefined);
      assert.deepEqual(process.poll, ['Plan Approved', 'Changes Required']);
    });

    it('process stage claim is "In Progress"', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      const process = config.stages.find((s) => s.name === 'process');
      assert.equal(process.claim, 'In Progress');
    });

    it('process stage done is "Review Pending"', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      const process = config.stages.find((s) => s.name === 'process');
      assert.equal(process.done, 'Review Pending');
    });

    it('process stage revert is "Plan Approved"', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      const process = config.stages.find((s) => s.name === 'process');
      assert.equal(process.revert, 'Plan Approved');
    });

    it('stale thresholds are numbers', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      for (const stage of config.stages) {
        assert.equal(typeof stage.stale_threshold_s, 'number', `${stage.name}.stale_threshold_s should be number`);
      }
    });

    it('process stale_threshold_s is 1800', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      const process = config.stages.find((s) => s.name === 'process');
      assert.equal(process.stale_threshold_s, 1800);
    });

    it('review stage done can be empty string', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      const review = config.stages.find((s) => s.name === 'review');
      assert.equal(review.done, '');
    });

    it('dispatch.concurrency is a positive integer', () => {
      const config = loadWorkflow(REAL_TOML);
      assert.notEqual(config, null);
      assert.equal(typeof config.dispatch.concurrency, 'number');
      assert.equal(config.dispatch.concurrency > 0, true);
    });
  });

  describe('error handling — returns null', () => {
    it('returns null for a missing file', () => {
      const result = loadWorkflow('/does/not/exist/workflow.toml');
      assert.equal(result, null);
    });

    it('returns null for invalid TOML', async () => {
      const { writeFileSync, unlinkSync } = await import('node:fs');
      const { join } = await import('node:path');
      const { tmpdir } = await import('node:os');
      const tmpPath = join(tmpdir(), `test-invalid-${Date.now()}.toml`);
      writeFileSync(tmpPath, 'this is not valid [toml syntax {{{', 'utf8');
      try {
        const result = loadWorkflow(tmpPath);
        assert.equal(result, null);
      } finally {
        unlinkSync(tmpPath);
      }
    });

    it('returns null for TOML that fails schema validation', async () => {
      const { writeFileSync, unlinkSync } = await import('node:fs');
      const { join } = await import('node:path');
      const { tmpdir } = await import('node:os');
      const tmpPath = join(tmpdir(), `test-schema-${Date.now()}.toml`);
      writeFileSync(tmpPath, '[missing_required_fields]\nfoo = "bar"\n', 'utf8');
      try {
        const result = loadWorkflow(tmpPath);
        assert.equal(result, null);
      } finally {
        unlinkSync(tmpPath);
      }
    });
  });
});
