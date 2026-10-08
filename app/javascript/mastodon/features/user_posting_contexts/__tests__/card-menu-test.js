import { bindUserPostingContextCardMenus } from '../preview';

const markup = () => {
  document.body.innerHTML = `
    <details data-user-posting-context-menu>
      <summary>First</summary>
      <button type="button">Delete</button>
    </details>
    <details data-user-posting-context-menu>
      <summary>Second</summary>
      <button type="button">Delete</button>
    </details>
    <button type="button" id="outside">Outside</button>
  `;
};

describe('user posting context card menus', () => {
  beforeEach(() => {
    markup();
    bindUserPostingContextCardMenus(document);
  });

  it('closes an open menu when the click is outside it', () => {
    const [first] = document.querySelectorAll('[data-user-posting-context-menu]');

    first.open = true;
    document.querySelector('#outside').click();

    expect(first.open).toBe(false);
  });

  it('closes the previously open menu when another menu is clicked', () => {
    const [first, second] = document.querySelectorAll('[data-user-posting-context-menu]');

    first.open = true;
    second.querySelector('summary').click();

    expect(first.open).toBe(false);
  });

  it('leaves the menu open when the click stays inside it', () => {
    const [first] = document.querySelectorAll('[data-user-posting-context-menu]');

    first.open = true;
    first.querySelector('button').click();

    expect(first.open).toBe(true);
  });

  it('closes on Escape and returns focus to the summary', () => {
    const [first] = document.querySelectorAll('[data-user-posting-context-menu]');
    const summary = first.querySelector('summary');

    first.open = true;
    summary.focus();
    first.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));

    expect(first.open).toBe(false);
    expect(document.activeElement).toBe(summary);
  });
});
