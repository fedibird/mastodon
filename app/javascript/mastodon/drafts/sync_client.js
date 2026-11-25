import api from '../api';

export const POST_DRAFT_TIMEOUT_MS = 15000;
export const POST_DRAFTS_PATH = '/api/v1/fedibird/post_drafts';

// The bearer token is read when the request starts, not when it returns.
// A later account change cannot reuse this call's headers.
export async function browserPostDraftRequest (getState, spec) {
  const state = typeof getState === 'function' ? getState() : null;
  const token = state && typeof state.getIn === 'function' ? state.getIn(['meta', 'access_token'], '') : '';
  const meId = state && typeof state.getIn === 'function' ? state.getIn(['meta', 'me'], '') : '';

  if (!token) {
    return { status: 401, body: null };
  }

  if (spec.accountId && meId && String(spec.accountId) !== String(meId)) {
    return { status: 0, ignored: true, body: null };
  }

  const client = api(() => state);

  try {
    const response = await client.request({
      method: spec.method,
      url: spec.path,
      data: spec.body,
      timeout: POST_DRAFT_TIMEOUT_MS,
    });

    return {
      status: response.status,
      body: response.data,
    };
  } catch (error) {
    const response = error && error.response;

    if (response) {
      return {
        status: response.status,
        body: response.data || null,
      };
    }

    return {
      status: 0,
      timedOut: Boolean(error && (error.code === 'ECONNABORTED' || error.code === 'ETIMEDOUT')),
      body: null,
    };
  }
}
