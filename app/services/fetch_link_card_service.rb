# frozen_string_literal: true

class FetchLinkCardService < BaseService
  include Redisable
  include Lockable

  URL_PATTERN = %r{
    (#{Twitter::TwitterText::Regex[:valid_url_preceding_chars]})                                                                #   $1 preceeding chars
    (                                                                                                                           #   $2 URL
      (https?:\/\/)                                                                                                             #   $3 Protocol (required)
      (#{Twitter::TwitterText::Regex[:valid_domain]})                                                                           #   $4 Domain(s)
      (?::(#{Twitter::TwitterText::Regex[:valid_port_number]}))?                                                                #   $5 Port number (optional)
      (/#{Twitter::TwitterText::Regex[:valid_url_path]}*)?                                                                      #   $6 URL Path and anchor
      (\?#{Twitter::TwitterText::Regex[:valid_url_query_chars]}*#{Twitter::TwitterText::Regex[:valid_url_query_ending_chars]})? #   $7 Query String
    )
  }iox

  # URL size limit to safely store in PosgreSQL's unique indexes
  BYTESIZE_LIMIT = 2692

  REDIRECT_TARGET_HOST = %w(0.gp 000.fo 00m.in 069.biz 0e0.pw 0rz.tw 0x.co 1-0x.com 110.vg 125.back.jp 128.pl 1lil.li 1ly.red 1s.pt 2.gp 2.ly 2cm.es 2d.al 2h.ae 2m.is 2no.co 2rs.me 2s.gg 3.ly 3.sv 301.link 302.jp 302.to 33-4.me 34vv.net 3n.si 3u.gs 4.gp 4.ly 443.cyou 4e.fi 4z.no 5.gp 52.nu 5ne.co 6.gp 6.ly 7.ly 73.nu 7c.tel 7i.se 7x.qa 7z.si 8.ly 985.so 9lick.me 9m.no a.info a38.fr aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.com aic.la alturl.com amz.run amzn.asia amzn.com amzn.to app.udcxx.me archive.today beautylinks.net bit.do bit.ly bitly.com bitly.cx bitly.lc bitly.pk biy.us bly.to bom.so c.je c.shogo82148.com cfg.me cia.sh cl.gy clickmoe.link clickurl.link cut.onl cut.tw cutt.ly cxy.jp d99.biz da.gd directmeto.site dlj.li doturl.link dub.sh dym.icu e.vg ee.sb etinyurl.com f.ht flu.yt ft.ax g.asia g.vu g5.vc g60.jp gg.gg ggle.in goo.cm goo.gl goo.su goo.vc grabify.link grabify.org gyo.tc h-ref.com hakanaurl.link heh.st hq.ax htn.to http://su.ima24.net/ i.gg i8.ae if.fm iii.im iil.la in.mt inx.lv iplog.co is.am is.gd iwe.re j.mp j2l.de jii.li jli.cl jumper.jp kawaii.st kik.to ko.fm koaku.ma kuku.lu kutt.uk lc.cx lel.st lhs.cx linkify.me links.tube llili.li ln.run lnk.farm ly.my mcaf.ee md.ly microurl.org mini-url.net miniurl.be miniurl.cl miniurl.com miniurl.pro miniurl.top minurls.com mixi.bz mq.gy myu.pw n9.cl nolog.link nullrefer.me num.to o0o.jp onl.bz onl.sc onlineminitools.com ooooooooooooooooooooooo.ooo ov.cm oyn.at p.asia p.tl plu.sh pnt.to pro-url.com prt.nu prt.red qqq.yt qr1.jp quick2.link r.sv r5f.jp rb.gy reallylong.link rebrand.ly rebrand.ly redir.lat redirect-project.glitch.me redirect.bio rid.ee rssfeed.news ryaku.jp s.id sdigo.app short-link.me short.af short.bg short.cm short.io short.pw shorten.ws shortenerlink.xyz shorter.me shortifyme.co shortpals.online shorturl.asia shorturl.at shorturl.click shorturl.gg shorturl.is shorturl.ma shorturl.me shorturl.re shorturl.sbs shorturl.tokyo sht.ac sht.moe smallurl.co sor.bz srt.rw ss.ly ssurl.at su2.me suo.yt surl.li surlz.com swit.as syu.to t-p.bz t.co t.ly tg.pe tgr.jp tin.al tinu.be tiny.cc tiny.cc tiny.cc tiny.ee tiny.pl tiny.re tinylink.at tinylink.cz tinylink.in tinylink.net tinylink.onl tinylinks.cc tinyurl.com tinyurl.mobi tinyurl.one tinyurl.ph tinyurl.se tinyurl.top tinyurl.ws tinyurls.tech to.lk to2.pw tobeto.be tools.emboma.jp tr.ee tri.im tt.vg ttlk.xyz tto.jp u.egg-p.net u.kawaii.su u.to u301.co u5a.cn u6e.cn upto.site ur0.cc ur0.jp ur3.us ur7.cc ure.my url-s.xyz url.ba url.beauty url.rw url.rw url.sa url.sa url2.fun urlc.net urls.cat urls.fr urls.my.id urls.wtf urlshortener.biz urlsmall.com urlsrt.io urlto.me urlty.co urly.it urlz.fr urx.nu urx2.nu use.my ux.nu v.af v.gd v.vin v0.nu vvd.bz w.wiki wal.ee we.pe webinfo.link ws.tc ww9.jp wz.my x-short.plus x.gd xn--s7y.xn--tckwe xx.nz xy2.eu ye.pe yoro.cc your.ls your.ls youtu.be ytub.ee z2.ink zhp.jp zip.lu zizi.ly zo.cm zws.im zz.sd zzb.bz 短.コム 跳.jp)
  REDIRECT_TARGET_HOST_PATTERN = /(\.1sl\.pw|\.i188\.eu\.org|\.ip1\.cc|\.zhp\.jp)$/

  def self.redirect_target_host?(host)
    !REDIRECT_TARGET_HOST.bsearch_index { |v| host <=> v }.nil? || REDIRECT_TARGET_HOST_PATTERN.match?(host)
  end

  PRESET_ENDPOINTS = {
    'www.youtube.com' => {:endpoint=>"https://www.youtube.com/oembed?format=json&url={url}", :format=>:json},
    'youtu.be'        => {:endpoint=>"https://www.youtube.com/oembed?format=json&url={url}", :format=>:json},
  }

  def link_type(status)
    @status = status
    urls = parse_urls

    if urls.any? {|url| FetchLinkCardService.redirect_target_host?(Addressable::URI.parse(url).host)}
      :include_redirect
    elsif urls.present?
      :include
    else
      :none
    end
  end

  def call(status, **options)
    @status      = status
    @parse_urls  = parse_urls
    @url         = @parse_urls.shift
    @parse_urls -= RedirectLink.where(url: @parse_urls).pluck(:url)

    RedirectLinkResolveWorker.push_bulk(@parse_urls) do |url|
      redis.sadd("statuses/#{@status.id}/processing", "RedirectLinkResolveWorker:#{url}")
      redis.expire("statuses/#{@status.id}/processing", 60.seconds)
      [url.to_s, @status.id]
    end

    return if @url.nil? || @status.preview_cards.any?

    with_redis_lock("fetch:#{@url}") do
      @card = PreviewCard.find_by(url: @url)
      process_url if @card.nil? || @card.updated_at <= 2.weeks.ago || @card.missing_image?
    end

    attach_card if @card&.persisted?
  rescue HTTP::Error, OpenSSL::SSL::SSLError, Addressable::URI::InvalidURIError, Mastodon::HostValidationError, Mastodon::LengthValidationError => e
    Rails.logger.debug "Error fetching link #{@url}: #{e}"
    nil
  end

  private

  def process_url
    html
    @card ||= PreviewCard.new(url: @url, redirected_url: @redirected_url)

    attempt_oembed || attempt_opengraph
  end

  def html
    return @html if defined?(@html)

    Request.new(:get, @url).add_headers('Accept' => 'text/html', 'User-Agent' => Mastodon::Version.user_agent + ' Bot').perform do |res|
      if res.code == 200 && res.mime_type == 'text/html'
        @html_charset = res.charset
        @html = res.body_with_limit(4.megabyte)

        parsed_url = Addressable::URI.parse(@url)
        res_uri = Addressable::URI.parse(res.uri.to_s)
        if FetchLinkCardService.redirect_target_host?(parsed_url.host) && @url != res_uri.to_s && !(parsed_url.normalized_host.casecmp(res_uri.normalized_host)&.zero? && res_uri.path.match?(/^$|^\/[A-Za-z]{2,}([_\-][A-Za-z]{2,})?$/))
          @redirected_url = res_uri.to_s
          RedirectLink.create(url: @url, redirected_url: res_uri.to_s)
        end
      else
        @html_charset = nil
        @html = nil
      end
    end
  end

  def attach_card
    @status.preview_cards << @card
    StatusStat.find_by(status_id: @status.id)&.touch || StatusStat.create!(status_id: @status.id)
  end

  def parse_urls
    if @status.local?
      urls = @status.text.scan(URL_PATTERN).map { |array| Addressable::URI.parse(array[1]).normalize }
      urls.push(Addressable::URI.parse(references_short_account_status_url(@status.account, @status))) if @status.references.exists?
    else
      html  = Nokogiri::HTML(@status.text)
      links = html.css(':not(.quote-inline) > a')
      urls  = links.filter_map { |a| Addressable::URI.parse(a['href']) unless skip_link?(a) }.filter_map(&:normalize)
    end

    urls.uniq.reject { |uri| bad_url?(uri) }.map(&:to_s)
  end

  def bad_url?(uri)
    # Avoid local instance URLs and invalid URLs
    uri.host.blank? || (TagManager.instance.local_url?(uri.to_s) && !status_reference_url?(uri.to_s)) || !%w(http https).include?(uri.scheme) || uri.to_s.bytesize > BYTESIZE_LIMIT
  end

  def status_reference_url?(uri)
    recognized_params = Rails.application.routes.recognize_path(uri) rescue {}
    recognized_params && %w(statuses activitypub/statuses).include?(recognized_params[:controller]) && recognized_params[:action] == 'references'
  end

  # rubocop:disable Naming/MethodParameterName
  def mention_link?(a)
    @status.mentions.any? do |mention|
      a['href'] == ActivityPub::TagManager.instance.url_for(mention.account)
    end
  end

  def skip_link?(a)
    # Avoid links for hashtags and mentions (microformats)
    a['rel']&.include?('tag') || a['class']&.match?(/u-url|h-card/) || mention_link?(a)
  end
  # rubocop:enable Naming/MethodParameterName

  def attempt_oembed
    service         = FetchOEmbedService.new
    url_domain      = Addressable::URI.parse(@url).normalized_host
    cached_endpoint = Rails.cache.read("oembed_endpoint:#{url_domain}") || PRESET_ENDPOINTS[url_domain]

    embed   = service.call(@url, cached_endpoint: cached_endpoint) unless cached_endpoint.nil?
    embed ||= service.call(@url, html: html) unless html.nil?

    return false if embed.nil?

    url = Addressable::URI.parse(service.endpoint_url)

    @card.type          = embed[:type]
    @card.title         = embed[:title]         || ''
    @card.author_name   = embed[:author_name]   || ''
    @card.author_url    = embed[:author_url].present? ? (url + embed[:author_url]).to_s : ''
    @card.provider_name = embed[:provider_name] || ''
    @card.provider_url  = embed[:provider_url].present? ? (url + embed[:provider_url]).to_s : ''
    @card.width         = 0
    @card.height        = 0

    case @card.type
    when 'link'
      @card.image_remote_url = (url + embed[:thumbnail_url]).to_s if embed[:thumbnail_url].present?
    when 'photo'
      return false if embed[:url].blank?

      @card.embed_url        = (url + embed[:url]).to_s
      @card.image_remote_url = (url + embed[:url]).to_s
      @card.width            = embed[:width].presence  || 0
      @card.height           = embed[:height].presence || 0
    when 'video'
      @card.width            = embed[:width].presence  || 0
      @card.height           = embed[:height].presence || 0
      @card.html             = Formatter.instance.sanitize(embed[:html], Sanitize::Config::MASTODON_OEMBED)
      @card.image_remote_url = (url + embed[:thumbnail_url]).to_s if embed[:thumbnail_url].present?
    when 'rich'
      # Most providers rely on <script> tags, which is a no-no
      return false
    end

    @card.save_with_optional_image!
  end

  def attempt_opengraph
    return if html.nil?

    detector = CharlockHolmes::EncodingDetector.new
    detector.strip_tags = true

    guess      = detector.detect(@html, @html_charset)
    encoding   = guess&.fetch(:confidence, 0).to_i > 60 ? guess&.fetch(:encoding, nil) : nil
    page       = Nokogiri::HTML(@html, nil, encoding)
    player_url = meta_property(page, 'twitter:player')

    if player_url && !bad_url?(Addressable::URI.parse(player_url))
      @card.type   = :video
      @card.width  = meta_property(page, 'twitter:player:width') || 0
      @card.height = meta_property(page, 'twitter:player:height') || 0
      @card.html   = content_tag(:iframe, nil, src: player_url,
                                               width: @card.width,
                                               height: @card.height,
                                               allowtransparency: 'true',
                                               scrolling: 'no',
                                               frameborder: '0')
    else
      @card.type = :link
    end

    @card.title            = meta_property(page, 'og:title').presence || page.at_xpath('//title')&.content || ''
    @card.description      = meta_property(page, 'og:description').presence || meta_property(page, 'description') || ''
    @card.image_remote_url = (Addressable::URI.parse(@url) + meta_property(page, 'og:image')).to_s if meta_property(page, 'og:image')

    return if @card.title.blank? && @card.html.blank?

    @card.save_with_optional_image!
  end

  def meta_property(page, property)
    page.at_xpath("//meta[contains(concat(' ', normalize-space(@property), ' '), ' #{property} ')]")&.attribute('content')&.value || page.at_xpath("//meta[@name=\"#{property}\"]")&.attribute('content')&.value
  end
end
