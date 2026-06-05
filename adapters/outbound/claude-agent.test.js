import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mapStreamLine } from './claude-agent.js';

/**
 * Collect all events from an array of raw JSON lines.
 * Each line may produce 0+ events.
 *
 * @param {string[]} lines
 * @returns {import('../../core/ports.js').AgentEvent[]}
 */
function collectEvents(lines) {
  const ctx = { lastText: '' };
  return lines.flatMap((line) => mapStreamLine(line, ctx));
}

describe('mapStreamLine', () => {
  describe('text blocks', () => {
    it('emits a text event for a plain text line', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: { content: [{ type: 'text', text: 'Hello world' }] },
      });
      const events = collectEvents([line]);
      assert.deepEqual(events, [{ kind: 'text', text: 'Hello world' }]);
    });

    it('splits multi-line text into individual text events', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: { content: [{ type: 'text', text: 'Line 1\nLine 2\nLine 3' }] },
      });
      const events = collectEvents([line]);
      assert.equal(events.length, 3);
      assert.equal(events[0].text, 'Line 1');
      assert.equal(events[1].text, 'Line 2');
      assert.equal(events[2].text, 'Line 3');
    });

    it('skips empty lines within text content', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: { content: [{ type: 'text', text: 'Line 1\n\nLine 3' }] },
      });
      const events = collectEvents([line]);
      assert.equal(events.filter((e) => e.kind === 'text').length, 2);
    });
  });

  describe('phase banners', () => {
    it('emits a phase event for === banners', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: { content: [{ type: 'text', text: '=== Phase 1 — Setup ===' }] },
      });
      const events = collectEvents([line]);
      assert.equal(events.length, 1);
      assert.equal(events[0].kind, 'phase');
      assert.equal(events[0].title, '=== Phase 1 — Setup ===');
    });

    it('emits a phase event for **Phase banners', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: { content: [{ type: 'text', text: '**Phase 2 — Implementation**' }] },
      });
      const events = collectEvents([line]);
      assert.equal(events.length, 1);
      assert.equal(events[0].kind, 'phase');
    });

    it('emits a phase event for ## Phase banners', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: { content: [{ type: 'text', text: '## Phase 3 — Review' }] },
      });
      const events = collectEvents([line]);
      assert.equal(events.length, 1);
      assert.equal(events[0].kind, 'phase');
    });
  });

  describe('tool_use blocks', () => {
    it('emits a tool event with name from content block', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: {
          content: [
            { type: 'tool_use', name: 'Bash', input: { command: 'ls -la /workspace' } },
          ],
        },
      });
      const events = collectEvents([line]);
      assert.equal(events.length, 1);
      assert.equal(events[0].kind, 'tool');
      assert.equal(events[0].name, 'Bash');
      assert.equal(events[0].hint, 'ls -la /workspace');
    });

    it('emits tool event with Read hint showing file_path', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: {
          content: [
            { type: 'tool_use', name: 'Read', input: { file_path: '/workspace/src/main.rs' } },
          ],
        },
      });
      const events = collectEvents([line]);
      assert.equal(events[0].hint, '/workspace/src/main.rs');
    });

    it('emits tool event without hint for unknown tool names', () => {
      const line = JSON.stringify({
        type: 'assistant',
        message: {
          content: [{ type: 'tool_use', name: 'MyCustomTool', input: { foo: 'bar' } }],
        },
      });
      const events = collectEvents([line]);
      assert.equal(events[0].kind, 'tool');
      assert.equal(events[0].hint, undefined);
    });

    it('emits tool event from top-level tool_use type', () => {
      const line = JSON.stringify({ type: 'tool_use', name: 'SearchFiles' });
      const events = collectEvents([line]);
      assert.equal(events.length, 1);
      assert.equal(events[0].kind, 'tool');
      assert.equal(events[0].name, 'SearchFiles');
    });
  });

  describe('result events', () => {
    it('emits tokens event from result.usage', () => {
      const line = JSON.stringify({
        type: 'result',
        result: 'success',
        usage: { input_tokens: 1000, output_tokens: 500, total_tokens: 1500 },
      });
      const events = collectEvents([line]);
      assert.equal(events.length, 1);
      assert.equal(events[0].kind, 'tokens');
      assert.equal(events[0].input, 1000);
      assert.equal(events[0].output, 500);
      assert.equal(events[0].total, 1500);
    });

    it('emits tokens without verdict when no DONE/PASS/FAIL in last text', () => {
      const lines = [
        JSON.stringify({
          type: 'assistant',
          message: { content: [{ type: 'text', text: 'Processing the ticket normally.' }] },
        }),
        JSON.stringify({
          type: 'result',
          result: 'success',
          usage: { input_tokens: 100, output_tokens: 50, total_tokens: 150 },
        }),
      ];
      const events = collectEvents(lines);
      const tokensEvent = events.find((e) => e.kind === 'tokens');
      assert.equal(tokensEvent.verdict, undefined);
    });

    it('emits tokens with verdict=DONE when last text contains DONE', () => {
      const lines = [
        JSON.stringify({
          type: 'assistant',
          message: { content: [{ type: 'text', text: 'Ticket marked as DONE.' }] },
        }),
        JSON.stringify({
          type: 'result',
          result: 'success',
          usage: { input_tokens: 100, output_tokens: 50, total_tokens: 150 },
        }),
      ];
      const events = collectEvents(lines);
      const tokensEvent = events.find((e) => e.kind === 'tokens');
      assert.equal(tokensEvent.verdict, 'DONE');
    });

    it('emits tokens with verdict=PASS', () => {
      const lines = [
        JSON.stringify({
          type: 'assistant',
          message: { content: [{ type: 'text', text: 'Review PASS — all checks green.' }] },
        }),
        JSON.stringify({
          type: 'result',
          result: 'success',
          usage: { input_tokens: 200, output_tokens: 100, total_tokens: 300 },
        }),
      ];
      const events = collectEvents(lines);
      const tokensEvent = events.find((e) => e.kind === 'tokens');
      assert.equal(tokensEvent.verdict, 'PASS');
    });

    it('emits tokens with verdict=FAIL', () => {
      const lines = [
        JSON.stringify({
          type: 'assistant',
          message: { content: [{ type: 'text', text: 'Tests FAIL — reverting.' }] },
        }),
        JSON.stringify({
          type: 'result',
          result: 'success',
          usage: { input_tokens: 50, output_tokens: 25, total_tokens: 75 },
        }),
      ];
      const events = collectEvents(lines);
      const tokensEvent = events.find((e) => e.kind === 'tokens');
      assert.equal(tokensEvent.verdict, 'FAIL');
    });

    it('emits an error event when result has is_error:true', () => {
      const line = JSON.stringify({
        type: 'result',
        result: 'Something went wrong',
        is_error: true,
      });
      const events = collectEvents([line]);
      assert.equal(events.length, 1);
      assert.equal(events[0].kind, 'error');
      assert.equal(events[0].message, 'Something went wrong');
    });

    it('computes total_tokens as input+output when total is absent', () => {
      const line = JSON.stringify({
        type: 'result',
        result: 'success',
        usage: { input_tokens: 300, output_tokens: 200 },
      });
      const events = collectEvents([line]);
      assert.equal(events[0].total, 500);
    });
  });

  describe('edge cases', () => {
    it('ignores empty lines', () => {
      assert.deepEqual(mapStreamLine(''), []);
      assert.deepEqual(mapStreamLine('   '), []);
    });

    it('ignores non-JSON lines', () => {
      assert.deepEqual(mapStreamLine('not json'), []);
    });

    it('ignores system init events', () => {
      const line = JSON.stringify({ type: 'system', subtype: 'init' });
      assert.deepEqual(collectEvents([line]), []);
    });

    it('processes a minimal valid stream from start to finish', () => {
      const stream = [
        JSON.stringify({ type: 'system', subtype: 'init' }),
        JSON.stringify({
          type: 'assistant',
          message: { content: [{ type: 'text', text: '=== Phase 1 — Research ===' }] },
        }),
        JSON.stringify({
          type: 'assistant',
          message: {
            content: [
              { type: 'tool_use', name: 'Bash', input: { command: 'git status' } },
            ],
          },
        }),
        JSON.stringify({
          type: 'assistant',
          message: { content: [{ type: 'text', text: 'All checks DONE.' }] },
        }),
        JSON.stringify({
          type: 'result',
          result: 'success',
          usage: { input_tokens: 1000, output_tokens: 500, total_tokens: 1500 },
        }),
      ];

      const events = collectEvents(stream);
      const kinds = events.map((e) => e.kind);

      assert.ok(kinds.includes('phase'), 'should have phase event');
      assert.ok(kinds.includes('tool'), 'should have tool event');
      assert.ok(kinds.includes('text'), 'should have text event');
      assert.ok(kinds.includes('tokens'), 'should have tokens event');

      const tokensEvent = events.find((e) => e.kind === 'tokens');
      assert.equal(tokensEvent.verdict, 'DONE');
    });
  });
});
