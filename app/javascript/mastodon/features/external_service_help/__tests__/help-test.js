import { initializeExternalServiceHelp } from '../help';

const markup = `
  <form id="rss-form">
    <button type="submit" id="rss-subscribe" aria-describedby="rss-feed-url-hint">Add feed</button>
    <details class="external-service-help" data-described-controls="rss-subscribe">
      <summary class="external-service-help__summary" aria-label="About who can see imported RSS posts" aria-controls="rss-privacy-note"><span aria-hidden="true">?</span></summary>
      <p class="external-service-help__body" id="rss-privacy-note">Private to you.</p>
    </details>
    <article>
      <div class="external-service-help-row">
        <label for="rss-language-7">Content language</label>
        <details class="external-service-help" data-described-controls="rss-language-7">
          <summary aria-label="About content language" aria-controls="rss-language-hint-7"><span aria-hidden="true">?</span></summary>
          <p class="external-service-help__body" id="rss-language-hint-7">Language help.</p>
        </details>
      </div>
      <select id="rss-language-7" name="language">
        <option value="unspecified">Unset</option>
        <option value="ja" selected>Japanese</option>
      </select>
      <div class="external-service-help-row">
        <label for="rss-media-sensitive-7">
          <input type="checkbox" id="rss-media-sensitive-7" name="media_sensitive" value="1">
          <span>Sensitive</span>
        </label>
        <details class="external-service-help" data-described-controls="rss-media-sensitive-7">
          <summary aria-label="About sensitive media"><span aria-hidden="true">?</span></summary>
          <p class="external-service-help__body" id="rss-media-sensitive-hint-7">Media help.</p>
        </details>
      </div>
    </article>
    <article>
      <label for="rss-language-8">Content language</label>
      <select id="rss-language-8" name="language">
        <option value="en" selected>English</option>
      </select>
      <details class="external-service-help" data-described-controls="rss-language-8">
        <summary aria-label="About content language"><span aria-hidden="true">?</span></summary>
        <p class="external-service-help__body" id="rss-language-hint-8">Other language help.</p>
      </details>
      <label for="rss-cw-8">
        <input type="checkbox" id="rss-cw-8" name="cw_enabled" value="1" checked>
        <span>CW</span>
      </label>
    </article>
  </form>
`;

function toggle(details, open) {
  details.open = open;
  details.dispatchEvent(new Event('toggle'));
}

describe('external service help', () => {
  beforeEach(() => {
    document.body.innerHTML = markup;
    initializeExternalServiceHelp(document);
  });

  it('describes a control only while its own note is open', () => {
    const subscribe = document.getElementById('rss-subscribe');
    const language = document.getElementById('rss-language-7');
    const other = document.getElementById('rss-language-8');
    const privacy = document.querySelector('[aria-controls="rss-privacy-note"]').parentElement;
    const languageHelp = document.querySelector('[aria-controls="rss-language-hint-7"]').parentElement;

    expect(subscribe.getAttribute('aria-describedby')).toBe('rss-feed-url-hint');
    expect(language.getAttribute('aria-describedby')).toBeNull();
    expect(privacy.querySelector('summary').getAttribute('aria-describedby')).toBeNull();
    expect(language.closest('label')).toBeNull();

    toggle(privacy, true);

    expect(subscribe.getAttribute('aria-describedby')).toBe('rss-feed-url-hint rss-privacy-note');
    expect(privacy.querySelector('summary').getAttribute('aria-describedby')).toBe('rss-privacy-note');
    expect(language.getAttribute('aria-describedby')).toBeNull();

    toggle(languageHelp, true);

    expect(language.getAttribute('aria-describedby')).toBe('rss-language-hint-7');
    expect(other.getAttribute('aria-describedby')).toBeNull();
    expect(other.value).toBe('en');
    expect(language.value).toBe('ja');

    toggle(languageHelp, false);
    toggle(privacy, false);

    expect(language.getAttribute('aria-describedby')).toBeNull();
    expect(subscribe.getAttribute('aria-describedby')).toBe('rss-feed-url-hint');
    expect(privacy.querySelector('summary').getAttribute('aria-describedby')).toBeNull();
  });

  it('does not change inputs or submit the form when a note is opened', () => {
    const form = document.getElementById('rss-form');
    const media = document.getElementById('rss-media-sensitive-7');
    const language = document.getElementById('rss-language-7');
    const cw = document.getElementById('rss-cw-8');
    const summary = document.querySelector('[aria-label="About sensitive media"]');
    let submitted = false;

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      submitted = true;
    });

    summary.click();
    toggle(summary.parentElement, true);

    expect(submitted).toBe(false);
    expect(media.checked).toBe(false);
    expect(cw.checked).toBe(true);
    expect(language.value).toBe('ja');
    expect(media.getAttribute('aria-describedby')).toBe('rss-media-sensitive-hint-7');
    expect(summary.closest('label')).toBeNull();
  });
});
