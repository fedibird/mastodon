import {
  applyUserPostingContextPreview,
  bindUserPostingContextPreview,
  syncUserPostingContextChoicePanels,
  syncUserPostingContextTargetPanels,
} from '../preview';

const markup = () => {
  document.body.innerHTML = `
    <form data-user-posting-context-form data-preview-url="/settings/user_posting_contexts/preview" data-record-id="4">
      <select data-target-kind data-preserve-on-preview name="user_posting_context[target_kind]">
        <option value="none">None</option>
        <option value="hashtag">Hashtag</option>
        <option value="group">Group</option>
      </select>
      <div data-target-panel="hashtag">
        <input data-preserve-on-preview name="user_posting_context[target_hashtag]" value="ruby" />
      </div>
      <div data-target-panel="group">
        <input data-preserve-on-preview name="user_posting_context[target_account_id]" value="9" />
      </div>
      <select data-choice-control="visibility" data-preserve-on-preview name="user_posting_context[visibility_choice]">
        <option value="inherit">Inherit</option>
        <option value="explicit" selected>Explicit</option>
      </select>
      <p data-choice-note="visibility" data-choice-note-for="inherit">usual private</p>
      <div data-choice-panel="visibility" data-choice-when="explicit">
        <input data-preserve-on-preview name="user_posting_context[visibility_value]" value="private" />
      </div>
      <input data-preserve-on-preview name="user_posting_context[name]" value="Field notes" />
      <input data-preserve-on-preview name="user_posting_context[purpose]" value="A note" />
      <input data-preserve-on-preview name="user_posting_context[hashtags_text]" value="fedibird" />
      <div data-user-posting-context-constraints><p>old constraint</p></div>
      <p data-user-posting-context-preview-status data-pending-message="updating" data-failed-message="failed"></p>
      <div data-user-posting-context-destination><p>old destination</p></div>
    </form>
    <div data-user-posting-context-preview><p>original</p></div>
  `;
};

describe('user posting context preview', () => {
  beforeEach(() => {
    markup();
  });

  it('keeps entered values when the destination panel changes', () => {
    const form = document.querySelector('form');
    const kind = form.querySelector('[data-target-kind]');

    kind.value = 'group';
    syncUserPostingContextTargetPanels(form);

    expect(form.querySelector('[name="user_posting_context[visibility_value]"]').value).toBe('private');
    expect(form.querySelector('[name="user_posting_context[target_hashtag]"]').value).toBe('ruby');
    expect(form.querySelector('[name="user_posting_context[hashtags_text]"]').value).toBe('fedibird');
    expect(form.querySelector('[data-target-panel="hashtag"]').hidden).toBe(true);
    expect(form.querySelector('[data-target-panel="group"]').hidden).toBe(false);
  });

  it('updates the preview without copying preview fields back into the form', () => {
    applyUserPostingContextPreview(document, {
      preview_html: '<p>conflict</p><input name="user_posting_context[visibility_value]" value="public" />',
      constraint_html: '<p>unverified</p>',
    });

    expect(document.querySelector('[name="user_posting_context[visibility_value]"]').value).toBe('private');
    expect(document.querySelector('[name="user_posting_context[hashtags_text]"]').value).toBe('fedibird');
    expect(document.querySelector('[data-user-posting-context-preview]').textContent).toContain('conflict');
    expect(document.querySelector('[data-user-posting-context-constraints]').textContent).toContain('unverified');
    expect(document.querySelector('form [name="user_posting_context[visibility_value]"]').value).not.toBe('public');
  });

  it('refreshes from the same origin without rewriting preserved fields', async () => {
    const fetchImpl = jest.fn(() => Promise.resolve({
      ok: true,
      json: () => Promise.resolve({
        preview_html: '<p>kept</p><input name="user_posting_context[visibility_value]" value="public" />',
        constraint_html: '<p>note</p>',
      }),
    }));

    bindUserPostingContextPreview(document, { fetchImpl, delay: 0 });
    document.querySelector('[data-target-kind]').value = 'hashtag';
    document.querySelector('[data-target-kind]').dispatchEvent(new Event('change', { bubbles: true }));

    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
    await Promise.resolve();
    await Promise.resolve();

    expect(fetchImpl).toHaveBeenCalledWith('/settings/user_posting_contexts/preview', expect.objectContaining({
      method: 'POST',
      credentials: 'same-origin',
    }));
    expect(document.querySelector('[name="user_posting_context[visibility_value]"]').value).toBe('private');
    expect(document.querySelector('[name="user_posting_context[target_hashtag]"]').value).toBe('ruby');
    expect(document.querySelector('[data-user-posting-context-preview]').textContent).toContain('kept');
  });

  it('hides the explicit control while inheriting and keeps the entered value', () => {
    const form = document.querySelector('form');
    const choice = form.querySelector('[data-choice-control="visibility"]');
    const panel = form.querySelector('[data-choice-panel="visibility"]');
    const value = form.querySelector('[name="user_posting_context[visibility_value]"]');

    choice.value = 'inherit';
    syncUserPostingContextChoicePanels(form);

    expect(panel.hidden).toBe(true);
    expect(form.querySelector('[data-choice-note="visibility"]').hidden).toBe(false);
    expect(value.value).toBe('private');

    choice.value = 'explicit';
    syncUserPostingContextChoicePanels(form);

    expect(panel.hidden).toBe(false);
    expect(value.value).toBe('private');
  });

  it('keeps the newest preview when an older response arrives later', async () => {
    let resolveFirst;
    let resolveSecond;
    const fetchImpl = jest.fn()
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveFirst = resolve;
      }))
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveSecond = resolve;
      }));

    bindUserPostingContextPreview(document, { fetchImpl, delay: 0 });
    const kind = document.querySelector('[data-target-kind]');
    const flush = () => new Promise((resolve) => {
      setTimeout(resolve, 0);
    });

    kind.value = 'hashtag';
    kind.dispatchEvent(new Event('change', { bubbles: true }));
    await flush();
    kind.value = 'group';
    kind.dispatchEvent(new Event('change', { bubbles: true }));
    await flush();

    resolveSecond({
      ok: true,
      json: () => Promise.resolve({
        preview_html: '<p>second</p>',
        constraint_html: '<p>second-constraint</p>',
        destination_html: '<p>second-destination</p>',
      }),
    });
    await flush();
    await flush();

    expect(document.querySelector('[data-user-posting-context-preview]').textContent).toContain('second');

    resolveFirst({
      ok: true,
      json: () => Promise.resolve({
        preview_html: '<p>first</p>',
        constraint_html: '<p>first-constraint</p>',
        destination_html: '<p>first-destination</p>',
      }),
    });
    await flush();
    await flush();

    expect(document.querySelector('[data-user-posting-context-preview]').textContent).toContain('second');
    expect(document.querySelector('[data-user-posting-context-preview]').textContent).not.toContain('first');
    expect(document.querySelector('[data-user-posting-context-destination]').textContent).toContain('second-destination');
    expect(document.querySelector('[data-user-posting-context-destination]').textContent).not.toContain('first-destination');
    expect(document.querySelector('[name="user_posting_context[visibility_value]"]').value).toBe('private');
    expect(fetchImpl.mock.calls[0][1].signal.aborted).toBe(true);
    expect(fetchImpl.mock.calls[1][1].signal.aborted).toBe(false);
  });

  it('clears stale conditions when loading fails and leaves the form values', async () => {
    const fetchImpl = jest.fn(() => Promise.resolve({ ok: false }));

    bindUserPostingContextPreview(document, { fetchImpl, delay: 0 });
    document.querySelector('[data-target-kind]').dispatchEvent(new Event('change', { bubbles: true }));

    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
    await Promise.resolve();
    await Promise.resolve();

    const status = document.querySelector('[data-user-posting-context-preview-status]');
    expect(status.dataset.state).toBe('failed');
    expect(status.textContent).toBe('failed');
    expect(document.querySelector('[data-user-posting-context-preview]').textContent).not.toContain('original');
    expect(document.querySelector('[data-user-posting-context-destination]').textContent).not.toContain('old destination');
    expect(document.querySelector('[data-user-posting-context-constraints]').textContent).not.toContain('old constraint');
    expect(document.querySelector('[name="user_posting_context[visibility_value]"]').value).toBe('private');
    expect(document.querySelector('[name="user_posting_context[hashtags_text]"]').value).toBe('fedibird');
  });

  it('does not refresh the preview when only the name or purpose changes', async () => {
    const fetchImpl = jest.fn();

    bindUserPostingContextPreview(document, { fetchImpl, delay: 0 });
    document.querySelector('[name="user_posting_context[name]"]').dispatchEvent(new Event('input', { bubbles: true }));
    document.querySelector('[name="user_posting_context[purpose]"]').dispatchEvent(new Event('input', { bubbles: true }));

    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });

    expect(fetchImpl).not.toHaveBeenCalled();
    expect(document.querySelector('[data-user-posting-context-preview]').classList.contains('user-posting-context-conditions--stale')).toBe(false);
  });

  it('ignores an older response that arrives before the next request starts', async () => {
    let resolveFirst;
    const fetchImpl = jest.fn()
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveFirst = resolve;
      }))
      .mockImplementationOnce(() => Promise.resolve({
        ok: true,
        json: () => Promise.resolve({
          preview_html: '<p>second</p>',
          constraint_html: '<p>second-constraint</p>',
          destination_html: '<p>second-destination</p>',
        }),
      }));

    bindUserPostingContextPreview(document, { fetchImpl, delay: 30 });
    const kind = document.querySelector('[data-target-kind]');
    const preview = () => document.querySelector('[data-user-posting-context-preview]');

    kind.value = 'hashtag';
    kind.dispatchEvent(new Event('change', { bubbles: true }));
    await new Promise((resolve) => {
      setTimeout(resolve, 40);
    });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(preview().getAttribute('aria-busy')).toBe('true');

    kind.value = 'group';
    kind.dispatchEvent(new Event('change', { bubbles: true }));
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(preview().classList.contains('user-posting-context-conditions--stale')).toBe(true);
    expect(fetchImpl.mock.calls[0][1].signal.aborted).toBe(true);

    resolveFirst({
      ok: true,
      json: () => Promise.resolve({
        preview_html: '<p>first</p>',
        constraint_html: '<p>first-constraint</p>',
        destination_html: '<p>first-destination</p>',
      }),
    });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(preview().textContent).toContain('original');
    expect(preview().textContent).not.toContain('first');
    expect(preview().classList.contains('user-posting-context-conditions--stale')).toBe(true);

    await new Promise((resolve) => {
      setTimeout(resolve, 40);
    });
    await Promise.resolve();
    await Promise.resolve();

    expect(preview().textContent).toContain('second');
    expect(preview().textContent).not.toContain('first');
    expect(preview().classList.contains('user-posting-context-conditions--stale')).toBe(false);
    expect(document.querySelector('[data-user-posting-context-destination]').textContent).toContain('second-destination');
  });
});
