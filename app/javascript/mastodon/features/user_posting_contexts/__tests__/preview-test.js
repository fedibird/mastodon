import {
  applyUserPostingContextPreview,
  bindUserPostingContextPreview,
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
      <input data-preserve-on-preview name="user_posting_context[visibility_value]" value="private" />
      <input data-preserve-on-preview name="user_posting_context[hashtags_text]" value="fedibird" />
      <div data-user-posting-context-constraints></div>
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
});
