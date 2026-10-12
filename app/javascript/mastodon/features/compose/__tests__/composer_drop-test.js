import { composerIdFromEventTarget, dropAlreadyHandled, isExternalFileDrag, markComposerFileDrop, shouldAcceptGlobalFileDrop } from '../composer_drop';

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

  it('lets the composer own an internal drop no matter which handler runs first', () => {
    document.body.innerHTML = `
      <div data-composer-id="portable:list:1"><div id="inside"></div></div>
      <div id="outside"></div>
    `;

    const files = [{ name: 'a.png' }, { name: 'b.png' }, { name: 'c.png' }];
    const uploadsFor = (order) => {
      const event = {
        target: document.getElementById('inside'),
        dataTransfer: { types: ['Files'], files },
        nativeEvent: {},
      };
      const uploads = [];
      const composer = () => {
        if (!isExternalFileDrag(event.dataTransfer)) return;

        markComposerFileDrop(event);
        uploads.push(files);
      };
      const global = () => {
        if (shouldAcceptGlobalFileDrop(event)) uploads.push('global');
      };
      const steps = { composer, global };

      order.forEach(name => steps[name]());

      return uploads;
    };

    expect(uploadsFor(['global', 'composer'])).toEqual([files]);
    expect(uploadsFor(['composer', 'global'])).toEqual([files]);
    expect(shouldAcceptGlobalFileDrop({
      target: document.getElementById('outside'),
      dataTransfer: { types: ['Files'], files },
    })).toBe(true);
    expect(files).toHaveLength(3);
  });
});
