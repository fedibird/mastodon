import { composerIdFromEventTarget, dropAlreadyHandled, isExternalFileDrag, markComposerFileDrop } from '../composer_drop';

describe('composer file drop routing', () => {
  it('reads the composer under the pointer and ignores internal media drags', () => {
    document.body.innerHTML = `
      <div data-composer-id="primary"><div id="primary-target"></div></div>
      <div data-composer-id="portable:tag:1"><div id="tag-target"></div></div>
    `;

    expect(composerIdFromEventTarget(document.getElementById('tag-target'))).toBe('portable:tag:1');
    expect(composerIdFromEventTarget(document.body)).toBeNull();
    expect(isExternalFileDrag({ types: ['Files'] })).toBe(true);
    expect(isExternalFileDrag({ types: ['Files', 'application/x-fedibird-media-reorder'] })).toBe(false);
    expect(isExternalFileDrag({ types: ['text/plain'] })).toBe(false);

    const event = { nativeEvent: {} };
    markComposerFileDrop(event);

    expect(dropAlreadyHandled(event)).toBe(true);
    expect(dropAlreadyHandled(event.nativeEvent)).toBe(true);
  });
});
