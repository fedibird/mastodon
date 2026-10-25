import { initializeFeedRoutePickers } from '../picker';

const pickerMarkup = (id, { create = true } = {}) => `
  <div class="feed-route-picker" data-feed-route-picker>
    <p class="feed-route-picker__summary" id="feed-route-${id}-summary">Receives in: Home</p>
    <details class="feed-route-picker__fallback">
      <summary class="button feed-route-picker__open" aria-label="Change destinations for Feed ${id}">Change destinations</summary>
      <form class="feed-route-picker__form" data-feed-route-form aria-labelledby="feed-route-${id}-heading" aria-describedby="feed-route-${id}-description">
        <button type="button" hidden data-feed-route-close>x</button>
        <h2 id="feed-route-${id}-heading">Destinations</h2>
        <p id="feed-route-${id}-description">Receive new posts in the timelines you choose.</p>
        <input type="hidden" name="feed_route[home]" value="0">
        <input type="checkbox" name="feed_route[home]" value="1" id="feed-route-${id}-home" checked>
        <input type="hidden" name="feed_route[list_ids][]" value="">
        <ul data-feed-route-lists data-id-prefix="feed-route-${id}">
          <li><label><input type="checkbox" name="feed_route[list_ids][]" value="7" id="feed-route-${id}-list-7"><span>Existing</span></label></li>
        </ul>
        ${create ? `
        <div hidden data-feed-route-create data-url="/settings/external_services/feed_route_lists" data-failure="Could not create">
          <button type="button" data-feed-route-create-toggle aria-expanded="false">+ New list</button>
          <div class="feed-route-picker__create-fields" hidden>
            <input type="text" data-feed-route-create-input>
            <button type="button" data-feed-route-create-submit>Create</button>
            <button type="button" data-feed-route-create-cancel>Cancel</button>
          </div>
          <p role="status" data-feed-route-status></p>
        </div>` : ''}
        <input type="hidden" name="feed_route[expected_revision]" value="3">
        <button type="button" hidden data-feed-route-close>Cancel</button>
        <button type="submit">Save</button>
      </form>
    </details>
  </div>
`;

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

const respond = (status, body) => Promise.resolve({
  ok: status >= 200 && status < 300,
  status,
  json: () => Promise.resolve(body),
});

describe('initializeFeedRoutePickers', () => {
  let originalShowModal;
  let originalClose;

  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="token-123">';
    originalShowModal = window.HTMLDialogElement.prototype.showModal;
    originalClose = window.HTMLDialogElement.prototype.close;
    window.HTMLDialogElement.prototype.showModal = function showModal() {
      this.setAttribute('open', '');
    };
    window.HTMLDialogElement.prototype.close = function close() {
      this.removeAttribute('open');
      this.dispatchEvent(new Event('close'));
    };
    global.fetch = jest.fn();
  });

  afterEach(() => {
    window.HTMLDialogElement.prototype.showModal = originalShowModal;
    window.HTMLDialogElement.prototype.close = originalClose;
    delete global.fetch;
    document.body.innerHTML = '';
  });

  it('moves the form into a dialog and opens it from a button', () => {
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);

    expect(document.querySelector('details')).toBeNull();
    const dialog = document.querySelector('dialog');
    const opener = document.querySelector('button.feed-route-picker__open');
    expect(dialog.querySelector('form')).not.toBeNull();
    expect(dialog.getAttribute('aria-labelledby')).toBe('feed-route-1-heading');
    expect(opener.getAttribute('aria-label')).toBe('Change destinations for Feed 1');
    expect(dialog.querySelectorAll('[data-feed-route-close]')).toHaveLength(2);
    dialog.querySelectorAll('[data-feed-route-close]').forEach((button) => expect(button.hidden).toBe(false));

    opener.click();
    expect(dialog.hasAttribute('open')).toBe(true);
    expect(document.activeElement).toBe(document.getElementById('feed-route-1-home'));
  });

  it('keeps the inline form when dialogs are not supported', () => {
    window.HTMLDialogElement.prototype.showModal = undefined;
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);

    expect(document.querySelector('dialog')).toBeNull();
    expect(document.querySelector('details form')).not.toBeNull();
    expect(document.querySelector('[data-feed-route-create]').hidden).toBe(false);
    expect(document.querySelector('details [data-feed-route-close]').hidden).toBe(true);
  });

  it('discards unsaved choices on cancel and returns focus to the opener', () => {
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);
    const opener = document.querySelector('button.feed-route-picker__open');
    const dialog = document.querySelector('dialog');

    opener.click();
    document.getElementById('feed-route-1-home').checked = false;
    document.getElementById('feed-route-1-list-7').checked = true;
    dialog.querySelectorAll('[data-feed-route-close]')[1].click();

    expect(dialog.hasAttribute('open')).toBe(false);
    expect(document.getElementById('feed-route-1-home').checked).toBe(true);
    expect(document.getElementById('feed-route-1-list-7').checked).toBe(false);
    expect(document.activeElement).toBe(opener);
  });

  it('closes on a backdrop click but not on a click inside the form', () => {
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);
    const dialog = document.querySelector('dialog');

    document.querySelector('button.feed-route-picker__open').click();
    dialog.querySelector('form').click();
    expect(dialog.hasAttribute('open')).toBe(true);

    dialog.click();
    expect(dialog.hasAttribute('open')).toBe(false);
  });

  it('wraps Tab and Shift+Tab focus inside the open dialog', () => {
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);
    const dialog = document.querySelector('dialog');
    document.querySelector('button.feed-route-picker__open').click();

    const buttons = Array.from(dialog.querySelectorAll('button')).filter((button) => !button.closest('[hidden]') && !button.hidden);
    const first = buttons[0];
    const last = dialog.querySelector('button[type="submit"]');
    const press = (shiftKey) => {
      const event = new KeyboardEvent('keydown', { key: 'Tab', shiftKey, bubbles: true, cancelable: true });
      dialog.dispatchEvent(event);
      return event.defaultPrevented;
    };

    last.focus();
    expect(press(false)).toBe(true);
    expect(document.activeElement).toBe(first);

    expect(press(true)).toBe(true);
    expect(document.activeElement).toBe(last);

    document.getElementById('feed-route-1-home').focus();
    expect(press(false)).toBe(false);
  });

  it('creates a list, selects it, and keeps the other unsaved choices', async () => {
    document.body.innerHTML = pickerMarkup(1) + pickerMarkup(2);
    initializeFeedRoutePickers(document);
    global.fetch.mockReturnValue(respond(201, { id: '42', title: 'New <b>list</b>', message: 'Created' }));

    const dialog = document.querySelectorAll('dialog')[0];
    document.querySelectorAll('button.feed-route-picker__open')[0].click();
    document.getElementById('feed-route-1-home').checked = false;
    document.getElementById('feed-route-1-list-7').checked = true;

    dialog.querySelector('[data-feed-route-create-toggle]').click();
    const input = dialog.querySelector('[data-feed-route-create-input]');
    expect(document.activeElement).toBe(input);
    input.value = 'New <b>list</b>';
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
    await flush();

    expect(global.fetch).toHaveBeenCalledTimes(1);
    const [url, options] = global.fetch.mock.calls[0];
    expect(url).toBe('/settings/external_services/feed_route_lists');
    expect(options.method).toBe('POST');
    expect(options.headers['X-CSRF-Token']).toBe('token-123');
    expect(JSON.parse(options.body)).toEqual({ list: { title: 'New <b>list</b>' } });

    const created = document.getElementById('feed-route-1-list-42');
    expect(created.checked).toBe(true);
    expect(created.name).toBe('feed_route[list_ids][]');
    expect(created.parentElement.textContent).toBe('New <b>list</b>');
    expect(created.parentElement.querySelector('b')).toBeNull();
    expect(document.getElementById('feed-route-1-home').checked).toBe(false);
    expect(document.getElementById('feed-route-1-list-7').checked).toBe(true);
    expect(dialog.querySelector('[data-feed-route-status]').textContent).toBe('Created');
    expect(dialog.querySelector('.feed-route-picker__create-fields').hidden).toBe(true);

    const other = document.getElementById('feed-route-2-list-42');
    expect(other).not.toBeNull();
    expect(other.checked).toBe(false);
  });

  it('shows the server error and keeps the typed name when creation fails', async () => {
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);
    global.fetch.mockReturnValue(respond(422, { error: 'A list with that name already exists.' }));

    const dialog = document.querySelector('dialog');
    document.querySelector('button.feed-route-picker__open').click();
    dialog.querySelector('[data-feed-route-create-toggle]').click();
    const input = dialog.querySelector('[data-feed-route-create-input]');
    input.value = 'Existing';
    dialog.querySelector('[data-feed-route-create-submit]').click();
    await flush();

    const status = dialog.querySelector('[data-feed-route-status]');
    expect(status.textContent).toBe('A list with that name already exists.');
    expect(status.getAttribute('data-state')).toBe('error');
    expect(input.value).toBe('Existing');
    expect(dialog.querySelectorAll('input[name="feed_route[list_ids][]"][type=checkbox]')).toHaveLength(1);
    expect(dialog.querySelector('[data-feed-route-create-submit]').disabled).toBe(false);
  });

  it('shows a generic failure when the request throws and ignores a second click while busy', async () => {
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);
    let reject;
    global.fetch.mockReturnValue(new Promise((_, fail) => {
      reject = fail;
    }));

    const dialog = document.querySelector('dialog');
    document.querySelector('button.feed-route-picker__open').click();
    dialog.querySelector('[data-feed-route-create-toggle]').click();
    dialog.querySelector('[data-feed-route-create-input]').value = 'Slow';
    const submit = dialog.querySelector('[data-feed-route-create-submit]');
    submit.click();
    submit.click();

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(submit.disabled).toBe(true);

    reject(new Error('offline'));
    await flush();

    expect(dialog.querySelector('[data-feed-route-status]').textContent).toBe('Could not create');
    expect(submit.disabled).toBe(false);
  });

  describe('while a list is being created', () => {
    const deferred = () => {
      const result = {};
      result.promise = new Promise((resolve) => {
        result.resolve = resolve;
      });
      return result;
    };

    const startCreate = (title) => {
      const dialog = document.querySelector('dialog');
      const opener = document.querySelector('button.feed-route-picker__open');
      opener.click();
      dialog.querySelector('[data-feed-route-create-toggle]').click();
      dialog.querySelector('[data-feed-route-create-input]').value = title;
      dialog.querySelector('[data-feed-route-create-submit]').click();
      return { dialog, opener };
    };

    const created = (id) => respond(201, { id, title: `List ${id}`, message: `Created ${id}` });

    it('blocks saving the destinations until the list exists', async () => {
      document.body.innerHTML = pickerMarkup(1);
      initializeFeedRoutePickers(document);
      const pending = deferred();
      global.fetch.mockReturnValue(pending.promise);

      const { dialog } = startCreate('Slow');
      const form = dialog.querySelector('form');
      const save = form.querySelector('button[type="submit"]');
      const submitted = new Event('submit', { bubbles: true, cancelable: true });

      expect(save.disabled).toBe(true);
      expect(form.dispatchEvent(submitted)).toBe(false);

      pending.resolve(created('42'));
      await flush();

      expect(save.disabled).toBe(false);
      expect(form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))).toBe(true);
      expect(document.getElementById('feed-route-1-list-42').checked).toBe(true);
    });

    it('does not select the list in a dialog closed before the response arrives', async () => {
      document.body.innerHTML = pickerMarkup(1);
      initializeFeedRoutePickers(document);
      const pending = deferred();
      global.fetch.mockReturnValue(pending.promise);

      const { dialog, opener } = startCreate('Late');
      dialog.close();
      pending.resolve(created('42'));
      await flush();

      const late = document.getElementById('feed-route-1-list-42');
      expect(late.checked).toBe(false);
      expect(dialog.querySelector('[data-feed-route-status]').textContent).toBe('');
      expect(dialog.querySelector('button[type="submit"]').disabled).toBe(false);

      opener.click();
      expect(late.checked).toBe(false);
      expect(dialog.querySelector('.feed-route-picker__create-fields').hidden).toBe(true);
    });

    it('ignores an old response after the dialog is closed and reopened', async () => {
      document.body.innerHTML = pickerMarkup(1);
      initializeFeedRoutePickers(document);
      const first = deferred();
      const second = deferred();
      global.fetch.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);

      const { dialog, opener } = startCreate('First');
      dialog.close();
      opener.click();
      dialog.querySelector('[data-feed-route-create-toggle]').click();
      dialog.querySelector('[data-feed-route-create-input]').value = 'Second';
      dialog.querySelector('[data-feed-route-create-submit]').click();

      first.resolve(created('1'));
      await flush();

      expect(document.getElementById('feed-route-1-list-1').checked).toBe(false);
      expect(dialog.querySelector('[data-feed-route-create-submit]').disabled).toBe(true);
      expect(dialog.querySelector('[data-feed-route-status]').textContent).toBe('');

      second.resolve(created('2'));
      await flush();

      expect(document.getElementById('feed-route-1-list-2').checked).toBe(true);
      expect(dialog.querySelector('[data-feed-route-status]').textContent).toBe('Created 2');
    });

    it('does not select the list after the creation itself was cancelled', async () => {
      document.body.innerHTML = pickerMarkup(1);
      initializeFeedRoutePickers(document);
      const pending = deferred();
      global.fetch.mockReturnValue(pending.promise);

      const { dialog } = startCreate('Cancelled');
      dialog.querySelector('button[data-feed-route-create-cancel]').click();
      expect(dialog.querySelector('button[type="submit"]').disabled).toBe(false);

      pending.resolve(created('9'));
      await flush();

      expect(document.getElementById('feed-route-1-list-9').checked).toBe(false);
      expect(dialog.hasAttribute('open')).toBe(true);
    });
  });

  it('leaves pickers without a create section working', () => {
    document.body.innerHTML = pickerMarkup(1, { create: false });
    expect(() => initializeFeedRoutePickers(document)).not.toThrow();
    expect(document.querySelector('dialog')).not.toBeNull();
  });

  it('does not enhance a picker twice', () => {
    document.body.innerHTML = pickerMarkup(1);
    initializeFeedRoutePickers(document);
    initializeFeedRoutePickers(document);

    expect(document.querySelectorAll('dialog')).toHaveLength(1);
  });
});
