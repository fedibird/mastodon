import { initializeFilterForms } from '../filter_form';

const markup = `
  <form class="simple_form">
    <fieldset class="filter-contexts">
      <div class="filter-contexts__toolbar">
        <button type="button" class="filter-contexts__bulk" data-filter-contexts-action="select-all">Select all</button>
        <button type="button" class="filter-contexts__bulk" data-filter-contexts-action="select-none">Deselect all</button>
      </div>
      <details class="filter-contexts__disclosure">
        <summary class="filter-contexts__summary" aria-controls="custom_filter_context_home_description custom_filter_context_public_description" data-show-label="Show descriptions" data-hide-label="Hide descriptions">Show descriptions</summary>
        <p class="filter-contexts__disclosure-note">Descriptions are shown under each name.</p>
      </details>
      <div id="filter-context-choices" class="filter-contexts__list">
        <div class="filter-contexts__item">
          <label class="filter-contexts__choice">
            <input type="checkbox" name="custom_filter[context][]" value="home" id="custom_filter_context_home">
            <span class="filter-contexts__name">Home</span>
          </label>
          <p class="filter-contexts__description" id="custom_filter_context_home_description">Home details</p>
        </div>
        <div class="filter-contexts__item">
          <label class="filter-contexts__choice">
            <input type="checkbox" name="custom_filter[context][]" value="public" id="custom_filter_context_public" checked>
            <span class="filter-contexts__name">Public</span>
          </label>
          <p class="filter-contexts__description" id="custom_filter_context_public_description">Public details</p>
        </div>
      </div>
    </fieldset>
    <div class="filter-keywords">
      <details class="filter-keywords__help">
        <summary aria-controls="filter-whole-word-help-body">What does whole word mean?</summary>
        <div id="filter-whole-word-help-body" class="filter-keywords__help-body"><p>Boundary help</p></div>
      </details>
      <div class="filter-keywords__list">
        <div class="filter-keyword nested-fields">
          <input type="text" name="custom_filter[keywords_attributes][0][keyword]" value="cat">
          <input type="checkbox" name="custom_filter[keywords_attributes][0][whole_word]" id="whole_word_0" checked>
        </div>
      </div>
    </div>
  </form>
`;

function boxes() {
  return Array.from(document.querySelectorAll('input[name="custom_filter[context][]"]'));
}

function toggle(details, open) {
  details.open = open;
  details.dispatchEvent(new Event('toggle'));
}

describe('filter form', () => {
  beforeEach(() => {
    document.body.innerHTML = markup;
    initializeFilterForms(document);
  });

  it('selects and clears every context without touching keyword fields', () => {
    const keyword = document.querySelector('input[name$="[keyword]"]');
    const wholeWord = document.querySelector('input[name$="[whole_word]"]');

    document.querySelector('[data-filter-contexts-action="select-all"]').click();
    expect(boxes().every((box) => box.checked)).toBe(true);
    expect(keyword.value).toBe('cat');
    expect(wholeWord.checked).toBe(true);

    document.querySelector('[data-filter-contexts-action="select-none"]').click();
    expect(boxes().every((box) => box.checked)).toBe(false);
    expect(wholeWord.checked).toBe(true);
  });

  it('associates descriptions only while the context disclosure is open', () => {
    const home = document.getElementById('custom_filter_context_home');
    const details = document.querySelector('.filter-contexts__disclosure');
    const summary = details.querySelector('summary');

    expect(home.getAttribute('aria-describedby')).toBeNull();
    expect(summary.textContent).toBe('Show descriptions');
    expect(summary.getAttribute('aria-controls')).toBe('custom_filter_context_home_description custom_filter_context_public_description');
    expect(home.checked).toBe(false);

    toggle(details, true);

    expect(home.getAttribute('aria-describedby')).toBe('custom_filter_context_home_description');
    expect(document.getElementById('custom_filter_context_public').getAttribute('aria-describedby')).toBe('custom_filter_context_public_description');
    expect(summary.textContent).toBe('Hide descriptions');
    expect(home.checked).toBe(false);
    expect(document.getElementById('custom_filter_context_public').checked).toBe(true);

    toggle(details, false);

    expect(home.getAttribute('aria-describedby')).toBeNull();
    expect(summary.textContent).toBe('Show descriptions');
    expect(summary.getAttribute('aria-controls')).toBe('custom_filter_context_home_description custom_filter_context_public_description');
    expect(document.getElementById('custom_filter_context_public').checked).toBe(true);
  });

  it('associates the shared whole-word help only while that disclosure is open', () => {
    const wholeWord = document.querySelector('input[name$="[whole_word]"]');
    const details = document.querySelector('.filter-keywords__help');

    expect(wholeWord.getAttribute('aria-describedby')).toBeNull();

    toggle(details, true);
    expect(wholeWord.getAttribute('aria-describedby')).toBe('filter-whole-word-help-body');

    const added = document.createElement('input');
    added.type = 'checkbox';
    added.name = 'custom_filter[keywords_attributes][1][whole_word]';
    document.querySelector('.filter-keywords__list').appendChild(added);
    document.querySelector('.filter-keywords').dispatchEvent(new Event('cocoon:after-insert'));

    expect(added.getAttribute('aria-describedby')).toBe('filter-whole-word-help-body');

    toggle(details, false);
    expect(wholeWord.getAttribute('aria-describedby')).toBeNull();
    expect(added.getAttribute('aria-describedby')).toBeNull();
  });
});
