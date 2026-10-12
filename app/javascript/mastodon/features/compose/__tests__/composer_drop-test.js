import {
  clearColumnDropHighlight,
  composerIdFromEventTarget,
  dropAlreadyHandled,
  dragFeedback,
  isExternalFileDrag,
  markComposerFileDrop,
  planDocumentFileDrop,
  shouldAcceptGlobalFileDrop,
  syncColumnDropHighlight,
} from '../composer_drop';

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

  it('routes timeline drops to the visible portable composer and clears the global overlay', () => {
    document.body.innerHTML = `
      <div class="column" data-drop-composer-id="portable:list-column:a" id="list-column">
        <div class="column-header" id="list-title"></div>
        <div data-composer-id="portable:list-column:a"><div id="list-composer"></div></div>
        <article id="list-status"></article>
        <div class="timeline-split">
          <div class="timeline-split__pane--live"><article id="list-live"></article></div>
          <div class="timeline-split__pane--history"><article id="list-history"></article></div>
        </div>
      </div>
      <div class="column" data-drop-composer-id="portable:hashtag-column:b" id="tag-column">
        <article id="tag-status"></article>
      </div>
      <div class="column" data-drop-composer-id="portable:group-column:c" id="group-column">
        <div id="group-detail"></div>
        <article id="group-status"></article>
      </div>
      <div class="column" id="closed-column"><article id="closed-status"></article></div>
      <div id="outside"></div>
      <div class="upload-area" id="upload-overlay"></div>
    `;

    const files = [{ name: 'a.png' }, { name: 'b.png' }, { name: 'c.png' }];
    const drop = (id, { order = ['global'], primaryCanAccept = true, composerCanAccept } = {}) => {
      const event = {
        target: document.getElementById(id),
        dataTransfer: { types: ['Files'], files },
        nativeEvent: {},
      };
      let overlay = true;
      const uploads = [];
      const composer = () => {
        markComposerFileDrop(event);
        uploads.push({ action: 'composer-owned', files });
      };
      const global = () => {
        const plan = planDocumentFileDrop(event, { primaryCanAccept, composerCanAccept });

        if (plan.clearDragUi) overlay = false;
        if (plan.action === 'upload-composer' || plan.action === 'upload-primary') {
          uploads.push({ action: plan.action, composerId: plan.composerId, files });
        }
        if (plan.action === 'reject') uploads.push({ action: 'reject', composerId: plan.composerId });
      };

      order.forEach(step => (step === 'composer' ? composer() : global()));

      return { overlay, uploads };
    };

    expect(drop('list-status').uploads).toEqual([{
      action: 'upload-composer',
      composerId: 'portable:list-column:a',
      files,
    }]);
    expect(drop('list-status').overlay).toBe(false);
    expect(drop('tag-status').uploads[0].composerId).toBe('portable:hashtag-column:b');
    expect(drop('group-detail').uploads[0].composerId).toBe('portable:group-column:c');
    expect(drop('list-live').uploads[0].composerId).toBe('portable:list-column:a');
    expect(drop('list-history').uploads[0].composerId).toBe('portable:list-column:a');
    expect(drop('list-title').uploads[0].composerId).toBe('portable:list-column:a');
    expect(drop('list-composer', { order: ['global', 'composer'] }).uploads).toEqual([{ action: 'composer-owned', files }]);
    expect(drop('list-composer', { order: ['composer', 'global'] }).uploads).toEqual([{ action: 'composer-owned', files }]);
    expect(drop('list-composer', { order: ['global', 'composer'] }).overlay).toBe(false);
    expect(drop('closed-status').uploads[0].action).toBe('upload-primary');
    expect(drop('outside').uploads[0].action).toBe('upload-primary');
    expect(drop('list-status', { primaryCanAccept: false }).uploads[0].action).toBe('upload-composer');
    expect(drop('list-status', {
      composerCanAccept: () => false,
    }).uploads).toEqual([{ action: 'reject', composerId: 'portable:list-column:a' }]);
    expect(drop('tag-status').uploads).toHaveLength(1);
    expect(drop('tag-status').uploads[0].composerId).not.toBe('portable:list-column:a');

    const reorder = planDocumentFileDrop({
      target: document.getElementById('list-status'),
      dataTransfer: { types: ['Files', 'application/x-fedibird-media-reorder'], files },
    });

    expect(reorder.action).toBe('ignore');
    expect(files).toHaveLength(3);

    syncColumnDropHighlight(document.getElementById('list-status'));
    expect(document.getElementById('list-column').classList.contains('is-file-drop-target')).toBe(true);
    clearColumnDropHighlight();
    expect(document.querySelector('.column.is-file-drop-target')).toBeNull();
    expect(dragFeedback(document.getElementById('list-status'), { types: ['Files'] }, { canUploadPrimary: true }).overlay).toBe(false);
    expect(dragFeedback(document.getElementById('outside'), { types: ['Files'] }, { canUploadPrimary: true }).overlay).toBe(true);
  });
});
