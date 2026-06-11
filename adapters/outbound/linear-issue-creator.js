/**
 * linear-issue-creator.js — creates Linear issues via GraphQL.
 *
 * Distinct from linear-tracker.js (which polls for existing tickets).
 */

const ENDPOINT = 'https://api.linear.app/graphql';

async function gql(apiKey, query, variables = {}) {
  const res = await fetch(ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: apiKey },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors) throw new Error(`Linear GQL: ${json.errors[0].message}`);
  return json.data;
}

export class LinearIssueCreator {
  constructor(apiKey, teamKey) {
    this.apiKey = apiKey;
    this.teamKey = teamKey;
    this._teamId = null;
  }

  async getTeamId() {
    if (this._teamId) return this._teamId;
    const data = await gql(this.apiKey, `{ teams { nodes { id key } } }`);
    const team = (data.teams?.nodes ?? []).find((t) => t.key === this.teamKey);
    if (!team) throw new Error(`Linear team not found: ${this.teamKey}`);
    this._teamId = team.id;
    return this._teamId;
  }

  /**
   * @param {{ title: string, description?: string, priority?: number }} opts
   *   priority: 0=none 1=urgent 2=high 3=medium 4=low
   * @returns {{ id, identifier, url, title }}
   */
  async createIssue({ title, description, priority }) {
    const teamId = await this.getTeamId();
    const data = await gql(
      this.apiKey,
      `mutation CreateIssue($input: IssueCreateInput!) {
        issueCreate(input: $input) {
          success
          issue { id identifier url title }
        }
      }`,
      { input: { title, description: description ?? '', teamId, priority: priority ?? 3 } },
    );
    if (!data.issueCreate?.success) throw new Error('Linear issueCreate returned success=false');
    return data.issueCreate.issue;
  }
}
