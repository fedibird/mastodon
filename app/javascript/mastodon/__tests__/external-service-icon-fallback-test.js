import { initExternalServiceIconFallback } from '../external_service_icon_fallback';

describe('external service icon fallback', () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <span class="external-service-feed__icon">
        <img class="external-service-feed__icon-default" alt="" />
        <img class="external-service-feed__icon-image" alt="" src="/external_source_icons/1/x" />
      </span>
      <img class="other" alt="" />
    `;
  });

  it('removes a stored icon that fails to load and keeps the default glyph', () => {
    initExternalServiceIconFallback(document);
    document.querySelector('.external-service-feed__icon-image').dispatchEvent(new Event('error'));

    expect(document.querySelector('.external-service-feed__icon-image')).toBeNull();
    expect(document.querySelector('.external-service-feed__icon-default')).not.toBeNull();
  });

  it('ignores errors from unrelated images', () => {
    initExternalServiceIconFallback(document);
    document.querySelector('.other').dispatchEvent(new Event('error'));

    expect(document.querySelector('.other')).not.toBeNull();
    expect(document.querySelector('.external-service-feed__icon-image')).not.toBeNull();
  });
});
