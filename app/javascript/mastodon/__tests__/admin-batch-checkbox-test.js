jest.mock('../../packs/public-path', () => {});

describe('admin batch checkbox', () => {
  const install = () => {
    document.body.innerHTML = `
      <form>
        <input type="checkbox" id="batch_checkbox_all" />
        <label class="batch-checkbox"><input type="checkbox" class="row" value="1" /></label>
        <label class="batch-checkbox"><input type="checkbox" class="row" value="2" /></label>
        <label class="batch-checkbox"><input type="checkbox" class="row" value="3" /></label>
      </form>
    `;
    jest.isolateModules(() => {
      require('../../packs/admin');
    });
  };

  const rows = () => Array.from(document.querySelectorAll('.batch-checkbox input[type="checkbox"]'));
  const master = () => document.querySelector('#batch_checkbox_all');

  const change = (element) => {
    element.dispatchEvent(new Event('change', { bubbles: true }));
  };

  beforeEach(() => {
    jest.resetModules();
    install();
  });

  it('checks and clears every row on the current page without a select-all-matching control', () => {
    master().checked = true;
    change(master());
    expect(rows().every((row) => row.checked)).toBe(true);

    master().checked = false;
    change(master());
    expect(rows().every((row) => row.checked)).toBe(false);
    expect(master().indeterminate).toBe(false);
  });

  it('marks the page checkbox indeterminate when one row is cleared', () => {
    master().checked = true;
    change(master());

    rows()[1].checked = false;
    change(rows()[1]);

    expect(master().checked).toBe(false);
    expect(master().indeterminate).toBe(true);
  });

  it('checks the page checkbox when every row is checked individually', () => {
    rows().forEach((row) => {
      row.checked = true;
      change(row);
    });

    expect(master().checked).toBe(true);
    expect(master().indeterminate).toBe(false);
  });
});
