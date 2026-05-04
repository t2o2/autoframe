#!/usr/bin/env node
/**
 * Linear MCP server — authenticates via LINEAR_API_KEY, no OAuth required.
 *
 * Implements the six tools used by autoframe ticket commands:
 *   get_issue, list_issue_statuses, list_comments,
 *   save_issue, save_comment, create_attachment
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const API_KEY = process.env.LINEAR_API_KEY;
if (!API_KEY) {
  process.stderr.write('LINEAR_API_KEY environment variable is required\n');
  process.exit(1);
}

const GQL_URL = 'https://api.linear.app/graphql';

async function gql(query, variables = {}) {
  const res = await fetch(GQL_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: API_KEY,
    },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Linear API HTTP ${res.status}: ${await res.text()}`);
  const json = await res.json();
  if (json.errors?.length) throw new Error(json.errors.map(e => e.message).join('; '));
  return json.data;
}

// ── Tool implementations ──────────────────────────────────────────────────────

async function getIssue({ id }) {
  const data = await gql(`
    query GetIssue($id: String!) {
      issue(id: $id) {
        id identifier title description
        state   { id name type }
        assignee { id name email }
        team     { id key name }
        labels   { nodes { id name } }
        attachments { nodes { id title url } }
        comments(last: 5) { nodes { id body createdAt user { name } } }
      }
    }`, { id });
  return data.issue;
}

async function listIssueStatuses({ teamId, teamKey } = {}) {
  // Accept either a UUID or a team key (e.g. "GYL")
  let filter = {};
  if (teamId)  filter = { team: { id:  { eq: teamId  } } };
  if (teamKey) filter = { team: { key: { eq: teamKey } } };

  const data = await gql(`
    query WorkflowStates($filter: WorkflowStateFilter) {
      workflowStates(filter: $filter, first: 50) {
        nodes { id name type position }
      }
    }`, { filter: Object.keys(filter).length ? filter : undefined });
  return data.workflowStates.nodes;
}

async function listComments({ issueId }) {
  const data = await gql(`
    query ListComments($id: String!) {
      issue(id: $id) {
        comments(first: 50) {
          nodes { id body createdAt user { name email } }
        }
      }
    }`, { id: issueId });
  return data.issue.comments.nodes;
}

async function saveIssue({ id, statusId, stateId, assignee, assigneeId, title, description, priority }) {
  const input = {};
  if (statusId || stateId) input.stateId = statusId ?? stateId;
  if (title)               input.title = title;
  if (description)         input.description = description;
  if (priority != null)    input.priority = priority;

  // assignee accepts either a UUID or an email — resolve email to UUID if needed
  const resolvedAssigneeId = assigneeId ?? (assignee ? await resolveUserId(assignee) : undefined);
  if (resolvedAssigneeId !== undefined) input.assigneeId = resolvedAssigneeId;

  const data = await gql(`
    mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) {
        success
        issue { id identifier state { name } assignee { name email } }
      }
    }`, { id, input });
  return data.issueUpdate;
}

async function saveComment({ issueId, body }) {
  const data = await gql(`
    mutation CreateComment($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) {
        success
        comment { id body createdAt }
      }
    }`, { issueId, body });
  return data.commentCreate;
}

async function createAttachment({ issueId, title, url, base64Content, contentType, filename }) {
  let assetUrl = url;

  // If binary content is provided, upload it to Linear's file store first
  if (base64Content) {
    const buf = Buffer.from(base64Content, 'base64');
    const ct  = contentType ?? (filename?.endsWith('.json') ? 'application/json' : 'image/jpeg');
    const fn  = filename ?? (ct.startsWith('image/') ? 'screenshot.jpg' : 'attachment.json');

    // Step 1: request presigned upload URL
    const uploadData = await gql(`
      query FileUpload($contentType: String!, $size: Int!, $filename: String) {
        fileUpload(contentType: $contentType, size: $size, filename: $filename) {
          uploadUrl
          assetUrl
          headers { key value }
        }
      }`, { contentType: ct, size: buf.byteLength, filename: fn });

    const { uploadUrl, assetUrl: returnedAsset, headers } = uploadData.fileUpload;

    // Step 2: PUT the file
    const uploadHeaders = { 'Content-Type': ct, 'Content-Length': String(buf.byteLength) };
    for (const h of (headers ?? [])) uploadHeaders[h.key] = h.value;
    const putRes = await fetch(uploadUrl, { method: 'PUT', headers: uploadHeaders, body: buf });
    if (!putRes.ok) throw new Error(`File upload failed: HTTP ${putRes.status}`);

    assetUrl = returnedAsset;
  }

  if (!assetUrl) throw new Error('Either url or base64Content must be provided');

  const data = await gql(`
    mutation CreateAttachment($issueId: String!, $title: String!, $url: String!) {
      attachmentCreate(input: { issueId: $issueId, title: $title, url: $url }) {
        success
        attachment { id title url }
      }
    }`, { issueId, title, url: assetUrl });
  return data.attachmentCreate;
}

// Resolve user email → Linear user UUID (cached per process)
const userCache = new Map();
async function resolveUserId(emailOrId) {
  if (!emailOrId || emailOrId.length === 36) return emailOrId; // already a UUID
  if (userCache.has(emailOrId)) return userCache.get(emailOrId);
  const data = await gql(`
    query FindUser($email: String!) {
      users(filter: { email: { eq: $email } }) { nodes { id } }
    }`, { email: emailOrId });
  const id = data.users.nodes[0]?.id ?? null;
  userCache.set(emailOrId, id);
  return id;
}

// ── MCP server wiring ─────────────────────────────────────────────────────────

const server = new Server(
  { name: 'linear-server', version: '1.0.0' },
  { capabilities: { tools: {} } },
);

const TOOLS = [
  {
    name: 'get_issue',
    description: 'Fetch a Linear issue by identifier (e.g. GYL-123) or UUID.',
    inputSchema: {
      type: 'object',
      properties: { id: { type: 'string', description: 'Issue identifier or UUID' } },
      required: ['id'],
    },
    handler: getIssue,
  },
  {
    name: 'list_issue_statuses',
    description: 'List workflow states (statuses) for a team.',
    inputSchema: {
      type: 'object',
      properties: {
        teamId:  { type: 'string', description: 'Team UUID' },
        teamKey: { type: 'string', description: 'Team key, e.g. "GYL"' },
      },
    },
    handler: listIssueStatuses,
  },
  {
    name: 'list_comments',
    description: 'List comments on a Linear issue.',
    inputSchema: {
      type: 'object',
      properties: { issueId: { type: 'string', description: 'Issue identifier or UUID' } },
      required: ['issueId'],
    },
    handler: listComments,
  },
  {
    name: 'save_issue',
    description: 'Update a Linear issue (status, assignee, title, description, priority).',
    inputSchema: {
      type: 'object',
      properties: {
        id:          { type: 'string', description: 'Issue UUID or identifier' },
        statusId:    { type: 'string', description: 'Workflow state UUID' },
        assignee:    { type: 'string', description: 'Assignee email or user UUID. Pass null to unassign.' },
        title:       { type: 'string' },
        description: { type: 'string' },
        priority:    { type: 'number', description: '0=no priority, 1=urgent, 2=high, 3=medium, 4=low' },
      },
      required: ['id'],
    },
    handler: saveIssue,
  },
  {
    name: 'save_comment',
    description: 'Post a comment on a Linear issue (Markdown supported).',
    inputSchema: {
      type: 'object',
      properties: {
        issueId: { type: 'string', description: 'Issue identifier or UUID' },
        body:    { type: 'string', description: 'Comment body in Markdown' },
      },
      required: ['issueId', 'body'],
    },
    handler: saveComment,
  },
  {
    name: 'create_attachment',
    description: 'Attach a URL or upload a file (base64) to a Linear issue.',
    inputSchema: {
      type: 'object',
      properties: {
        issueId:      { type: 'string', description: 'Issue identifier or UUID' },
        title:        { type: 'string', description: 'Attachment display name' },
        url:          { type: 'string', description: 'External URL to link' },
        base64Content: { type: 'string', description: 'Base64-encoded file to upload' },
        contentType:  { type: 'string', description: 'MIME type, e.g. image/jpeg (default: image/jpeg)' },
        filename:     { type: 'string', description: 'Filename hint, e.g. screenshot.jpg' },
      },
      required: ['issueId', 'title'],
    },
    handler: createAttachment,
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const tool = TOOLS.find(t => t.name === request.params.name);
  if (!tool) throw new Error(`Unknown tool: ${request.params.name}`);

  try {
    const result = await tool.handler(request.params.arguments ?? {});
    return {
      content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    };
  } catch (err) {
    return {
      content: [{ type: 'text', text: `Error: ${err.message}` }],
      isError: true,
    };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
