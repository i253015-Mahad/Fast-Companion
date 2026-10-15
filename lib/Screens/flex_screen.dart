// lib/Screens/flex_screen.dart

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/flex_session_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// The Flex tab: the university's own student portal, embedded.
///
/// This is stage 1 of the Flex integration — the live site wrapped in
/// native chrome. Sign-in happens on the portal itself: it sits behind
/// Cloudflare Turnstile, which only a real browser engine can run, so
/// this screen never handles credentials. It adopts whatever session the
/// portal issues into [FlexSessionService] after every load, and leaves
/// parsing the portal's HTML into native UI to a later stage — until
/// then the site is rendered by the site, darkened to match the app.
class FlexScreen extends StatefulWidget {
  const FlexScreen({super.key});

  @override
  State<FlexScreen> createState() => _FlexScreenState();
}

class _FlexScreenState extends State<FlexScreen> {
  /// Darkens the portal by inverting the content half of it and
  /// recolouring the chrome half.
  ///
  /// Flex is a hybrid theme, which is what made this awkward. Read from
  /// the portal's own stylesheets rather than guessed at:
  ///
  ///   * `.m-body`       `#f2f3f8`   the light lavender page background
  ///   * `.m-header`     `#fff`      (via `.m-page--fluid`)
  ///   * `.m-topbar`     `#fff`      the row holding the profile photo
  ///   * `.m-header-head`, `.m-brand` `#355C7D`  the real header slate
  ///   * `.m-footer`     `#F0F0F0`
  ///
  /// So the header is *meant* to be dark and only half of it is, while
  /// the content is entirely light. Inverting `<html>` — the obvious
  /// move — flips both halves at once: the cards go black, which is the
  /// point, but the header comes out light periwinkle. Inverting a
  /// hybrid theme does not darken it, it swaps which half is bright.
  ///
  /// The inversion is therefore scoped to `.m-wrapper`, which is an
  /// ancestor of the content and a *sibling* of the offcanvas drawer.
  /// An earlier build filtered `.m-body` instead, which caught the page
  /// background as well and so needed no recolouring — but a filter
  /// creates a stacking context, and `.m-body` wraps both the drawer and
  /// the content. The drawer's `z-index: 1001` was trapped inside
  /// `.m-body`'s `z-index: auto`, so it lost to the fixed header's
  /// `z-index: 101` and the topbar painted over the menu. Scoping to
  /// `.m-wrapper` leaves the drawer competing in the root context, which
  /// is what the portal itself relies on.
  ///
  /// `.m-wrapper` has no background of its own — the only rule for it in
  /// `CustomCss.css` is `.m-grid__item m-grid__item--fluid m-wrapper`,
  /// missing its dots, so it never matches — so the lavender comes from
  /// `.m-body` above it, and is now recoloured directly. That needs no
  /// filter and so creates no stacking context. Media inside the
  /// filtered subtree still needs cancelling, or photos render as
  /// negatives.
  ///
  /// The header and footer sit outside it and are handled directly:
  /// the footer keeps its own filter, and the two white header surfaces
  /// are recoloured to `#355C7D` — the portal's own header slate, not a
  /// colour invented here — so the whole header reads as one dark bar.
  /// `.m-topbar` is left transparent rather than recoloured, because the
  /// portal pulls it up over the page-title row with `margin-top: -50px`:
  /// an opaque topbar is exactly what was hiding "Home". Transparent
  /// shows the slate behind it, which is the same colour it was being
  /// given anyway.
  ///
  /// The header box is `height: 60px !important`, but its rows stack to
  /// 110px and overflow it while the content is offset by only 60px — so
  /// the header also sat over the first 50px of the page.
  /// `syncHeaderOffset` measures those rows and moves the content down
  /// to where the header really ends.
  ///
  /// Anything attached to `<body>` outside `.m-page` escapes the filter
  /// the same way, so the navigation mask and the scroll-to-top pill are
  /// both recoloured directly rather than left glaring white.
  ///
  /// Scoping also fixes a problem the whole-page version had: because a
  /// filter makes *its own* element the containing block, filtering
  /// `<html>` unpinned the header, which is `position: fixed`. Leaving
  /// the root unfiltered means it pins normally.
  ///
  /// Injected at document start, which can fire before the root element
  /// exists. Appending a `<style>` to a null root throws and would kill
  /// the script silently, so boot waits for the root.
  static const String _darkModeScript = '''
(function () {
  if (window.__fcDarkApplied) return;
  window.__fcDarkApplied = true;

  function boot() {
    var root = document.head || document.documentElement;
    if (!root) { setTimeout(boot, 10); return; }

    var css = [
      // Dark base behind everything, so nothing flashes white while the
      // document is still parsing and nothing shows through on
      // overscroll.
      'html, body { background-color: #111111 !important; }',

      // The lavender page background. Recoloured directly rather than
      // filtered: a filter here would create a stacking context, and
      // .m-body wraps both the drawer and the content, which is what
      // trapped the drawer's z-index:1001 below the fixed header's 101.
      '.m-body { background-color: #111111 !important; }',

      // The light half of the theme — an ancestor of the content and a
      // sibling of the drawer, so everything the portal paints here
      // gets inverted once while the drawer stays outside it.
      '.m-wrapper { filter: invert(1) hue-rotate(180deg) !important; }',

      // Media inside the filtered subtree would render as a negative;
      // this cancels the parent's filter for photos and charts.
      '.m-wrapper img, .m-wrapper picture, .m-wrapper video,',
      '.m-wrapper canvas,',
      '.m-wrapper svg { filter: invert(1) hue-rotate(180deg) !important; }',

      // The footer is a sibling of .m-body, so it needs its own
      // filter rather than inheriting this one.
      '.m-footer { filter: invert(1) hue-rotate(180deg) !important; }',
      '.m-footer img, .m-footer picture, .m-footer video,',
      '.m-footer canvas, .m-footer svg {',
      '  filter: invert(1) hue-rotate(180deg) !important; }',

      // The header sits outside every filter above but is painted
      // white by .m-page--fluid .m-header and by .m-topbar, which is
      // why a white band sat under the title bar. Both are recoloured
      // to the portal's own #355C7D — the value CustomCss.css already
      // gives .m-header-head and .m-brand — so the header reads as one
      // dark bar instead of slate over white.
      '.m-page--fluid .m-header, .m-page--wide .m-header {',
      '  background-color: #355C7D !important; }',
      // The title row, which now has to be opaque: it covers the
      // content's first 50px and backs the transparent topbar below.
      '.m-header-head { background-color: #355C7D !important; }',

      // The portal pulls the topbar up over the page-title row with
      // `top: -71px` (.m-header--fixed-mobile), and an opaque
      // background here is what was hiding "Home". Transparent lets the
      // slate of .m-header-head show through unchanged — the same
      // colour it was being given.
      '.m-topbar { background-color: transparent !important;',
      '  box-shadow: none !important; }',

      // …and that same -71px dragged the avatar up under the brand row,
      // whose box is the header's own 0..60px, so the brand painted over
      // the top of it. Measured on device: the avatar is 40px and sits
      // 9px inside the topbar, so it landed at 48..88 on the profile
      // page and 42..82 on Attendance — the brand cut 12px and 18px off
      // the top respectively (the photo's blue starts at device y=532,
      // i.e. exactly CSS 60, on both). Because the topbar is positioned
      // off the title row, which is 110 tall on one page and 104 on the
      // other, a single shift has to work for both: -51px puts the
      // avatar at 68..108 and 62..102 — clear of the brand either way,
      // and landing 2px short of that page's own title-row bottom, which
      // falls out of the arithmetic rather than being fitted per page.
      // Scoped through body so it outranks the portal's own
      // `.m-header--fixed-mobile .m-topbar` by specificity rather than
      // depending on injection order.
      'body.m-header--fixed-mobile .m-topbar { top: -51px !important; }',

      // The portal's navigation mask: rgba(255,255,255,0.6) holding a
      // white .loader-box, outside .m_body — without this every page
      // change would flash white.
      '[id^="overlay"] { background-color: rgba(8, 17, 23, 0.82) !important; }',
      '.loader-box {',
      '  background: #16232b !important;',
      '  box-shadow: 0 0 10px rgba(0, 0, 0, 0.6) !important; }',

      // The scroll-to-top pill is appended straight to <body> after
      // .m-page closes, so it sits outside every filter and was the
      // last white thing left on screen. Recoloured to the header's
      // slate; the portal ships a --skin-dark variant of its own,
      // which is confirmation that this button is meant to adapt.
      '.m-scroll-top { background: #355C7D !important;',
      '  box-shadow: 0 0 15px 1px rgba(0, 0, 0, 0.5) !important; }',
      '.m-scroll-top > i { color: #ffffff !important; }',

      // Not theming — a deliberate UI change. This is the portal's own
      // offcanvas close button, #m_aside_left_close_btn, which floats
      // at the top-right of the drawer. The hamburger already toggles
      // the drawer and the overlay closes it, so it is redundant here;
      // removed on request.
      '.m-aside-left-close { display: none !important; }',

      // =================================================================
      // Login page.
      //
      // /Login shares none of the selectors above: it has no .m-body and
      // no .m-wrapper (fetched and checked — the page is .m-page >
      // #m_login.m-login.m-login--1, split into .m-login__aside for the
      // form and .m-login__content for the photo). So the invert never
      // reached it and the only rule that landed was the dark html/body
      // base sitting behind an opaque white panel: .m-login.m-login--1
      // { background:#fff }.
      //
      // Every rule below is scoped to .m-login.m-login--1, which exists
      // on no other page. That matters: the real pages put their fields
      // inside the inverted .m-wrapper, so an unscoped dark fill there
      // would invert straight back to white.
      // =================================================================
      '.m-login.m-login--1 { background-color: #111111 !important;',
      '  color: #dcdcdc !important; }',

      // The headings, field captions and checkbox carry no colour of
      // their own and were inheriting Bootstrap's near-black #212529.
      // The photo side's welcome text is already #fff, and the sign-in
      // button .btn-primary is indigo #5867dd, so neither needs help.
      '.m-login.m-login--1 h5,',
      '.m-login.m-login--1 .m-login__title,',
      '.m-login.m-login--1 .m-login__desc,',
      '.m-login.m-login--1 .m-form__help,',
      '.m-login.m-login--1 .m-checkbox { color: #dcdcdc !important; }',

      // Bootstrap's #fff fields. :focus repaints them white again and
      // adds a blue glow, and Chrome's autofill paints an opaque white
      // block over a remembered username — all three are covered here.
      '.m-login.m-login--1 .form-control {',
      '  background-color: #1a1a1a !important;',
      '  border-color: #3a3a3a !important;',
      '  color: #ffffff !important; }',
      '.m-login.m-login--1 .form-control:focus {',
      '  background-color: #1a1a1a !important;',
      '  border-color: #5867dd !important;',
      '  box-shadow: none !important; }',
      '.m-login.m-login--1 .form-control::placeholder {',
      '  color: #8a8a8a !important; }',
      '.m-login.m-login--1 .form-control:-webkit-autofill {',
      '  -webkit-box-shadow: 0 0 0 1000px #1a1a1a inset !important;',
      '  -webkit-text-fill-color: #ffffff !important; }',

      // The user/lock boxes bolted onto the ends of those fields:
      // #e9ecef by default.
      '.m-login.m-login--1 .input-group-addon {',
      '  background-color: #1a1a1a !important;',
      '  border-color: #3a3a3a !important;',
      '  color: #b9c2c9 !important; }',

      // "Forgot password?" — the portal's #3f51b5 is all but invisible
      // against #111, so it keeps the hue but takes the value up.
      '.m-login.m-login--1 .m-link { color: #8c9eff !important; }',

      // The photo panel (bg-5.jpg) is kept rather than replaced, but
      // pushed back so the page reads as dark. An inset shadow is
      // painted over the background yet under the content, so the white
      // welcome text sitting on the photo is untouched — and the
      // background-image URL never has to be rewritten.
      '.m-login.m-login--1 .m-login__content {',
      '  box-shadow: inset 0 0 0 2000px rgba(0, 0, 0, 0.55) !important; }',

      // The CAPTCHA is a cross-origin iframe, so it can't be restyled
      // from here — inverted like every other piece of media instead.
      // The portal serves reCAPTCHA or Turnstile depending on the day,
      // so both are covered.
      '.m-login.m-login--1 .cf-turnstile,',
      '.m-login.m-login--1 .g-recaptcha {',
      '  filter: invert(1) hue-rotate(180deg) !important; }'
    ].join('\\n');

    var style = document.createElement('style');
    style.textContent = css;
    root.appendChild(style);
  }

  // The header box is `height: 60px !important`, but its three rows
  // stack to ~110px and overflow it, while .m-body offsets the content
  // by only 60px. Measured on device: header 0->60, title row 60->110,
  // topbar 39->97, content from 60. The header was therefore sitting
  // over the page title *and* over the first 50px of the page. This
  // moves the content down to where the header really ends.
  //
  // Only the rows that actually paint are measured, never every
  // descendant: the topbar's dropdown menu is a descendant and would
  // report a much larger bottom while open, but a row's own border box
  // never includes what overflows it. The topbar itself is excluded —
  // it is transparent, so its box adds nothing visible, and counting it
  // would push the content 7px past the slate for no reason; the avatar
  // inside it ends 2px short of the title row's bottom regardless. The
  // value is absolute rather than incremental, so re-running on load or
  // resize is safe.
  function syncHeaderOffset(tries) {
    try {
      var header = document.querySelector('header.m-header');
      var body = document.querySelector('.m-body');
      if (!header || !body) {
        // Injected at document start, often before the header exists.
        if ((tries || 0) < 300) {
          setTimeout(function () { syncHeaderOffset((tries || 0) + 1); }, 50);
        }
        return;
      }
      var rows = header.querySelectorAll('.m-brand, .m-header-head');
      var bottom = 0;
      for (var i = 0; i < rows.length; i++) {
        var edge = rows[i].getBoundingClientRect().bottom;
        if (edge > bottom) bottom = edge;
      }
      if (bottom > 0) body.style.paddingTop = Math.ceil(bottom) + 'px';
    } catch (e) {
      // A portal change must never take the page down over this.
    }
  }

  boot();
  syncHeaderOffset();
  window.addEventListener('load', function () { syncHeaderOffset(); });
  window.addEventListener('resize', function () { syncHeaderOffset(); });
  setTimeout(syncHeaderOffset, 2500);
})();
''';

  /// Tells the system which field is the username, so it offers the
  /// saved roll number as well as the password.
  ///
  /// Chrome recognises a login form by looking at what surrounds a
  /// password box, so in a browser tapping the roll number already
  /// offers both halves of the credential. A WebView gets no such
  /// guessing: the Android autofill framework only pairs a credential
  /// with a field that has said it *is* the username, and a plain text
  /// input has said nothing — which is why only tapping the password box
  /// ever offered anything.
  ///
  /// So the form is described in the terms the framework wants. The
  /// roll number box is found the way Chrome would find it — the text
  /// field sitting in the same form as the password box — rather than by
  /// a name or id, which the portal is free to rename. Nothing is typed,
  /// stored or sent anywhere: this only adds an attribute.
  ///
  /// The form does not exist when this script first runs, so the work is
  /// done by an observer rather than once at start-up: every element the
  /// portal adds is checked, and the tags are set as soon as the fields
  /// appear.
  static const String _autofillScript = '''
(function () {
  if (window.__fcAutofillApplied) return;
  window.__fcAutofillApplied = true;

  function label(form) {
    try {
      var passwords = form.querySelectorAll('input[type="password"]');
      for (var i = 0; i < passwords.length; i++) {
        passwords[i].setAttribute('autocomplete', 'current-password');
      }
      if (!passwords.length) return;

      var fields = form.querySelectorAll(
        'input[type="text"], input[type="tel"], input[type="number"], input:not([type])'
      );
      for (var j = 0; j < fields.length; j++) {
        var field = fields[j];
        // A token the portal chose ("email", "one-time-code") is kept: it
        // describes the field better than this guess does. "off" is not —
        // it is the portal declining autofill, and it is exactly the
        // reason the roll number never got offered.
        var existing = (field.getAttribute('autocomplete') || '').toLowerCase();
        if (existing && existing !== 'off' && existing !== 'on') continue;
        field.setAttribute('autocomplete', 'username');
      }
    } catch (e) {
      // A portal change must never take the page down over this.
    }
  }

  function scan(node) {
    if (!node || node.nodeType !== 1) return;
    if (node.tagName === 'FORM') label(node);
    // The password box is often added to a form built earlier, so the
    // form is looked for from the field too, not only from its parent.
    var passwords = node.querySelectorAll
      ? node.querySelectorAll('input[type="password"]')
      : [];
    for (var i = 0; i < passwords.length; i++) {
      label(passwords[i].form || passwords[i].parentNode);
    }
    if (node.tagName === 'INPUT' && node.type === 'password') {
      label(node.form || node.parentNode);
    }
  }

  function boot() {
    var root = document.body || document.documentElement;
    if (!root) { setTimeout(boot, 10); return; }

    scan(root);
    try {
      new MutationObserver(function (changes) {
        for (var i = 0; i < changes.length; i++) {
          var added = changes[i].addedNodes;
          for (var j = 0; j < added.length; j++) scan(added[j]);
        }
      }).observe(root, { childList: true, subtree: true });
    } catch (e) {
      // A portal change must never take the page down over this.
    }
  }

  boot();
})();
''';

  /// Links the WebView can't usefully display — fee vouchers and other
  /// downloads — are handed to the system instead.
  static final RegExp _downloadRe = RegExp(
    r'\.(pdf|xlsx?|docx?|csv|zip)$',
    caseSensitive: false,
  );

  InAppWebViewController? _controller;
  late final PullToRefreshController _pullToRefresh;

  /// Address of the page currently on screen, kept so "open in browser"
  /// targets the visible page rather than wherever the tab started.
  String _url = FlexSessionService.baseUrl;

  bool _loading = true;
  bool _canGoBack = false;

  /// Set once a page has loaded successfully. Failures are only reported
  /// before that happens, so a broken subresource can never blank out a
  /// page that is working — and once we're in, the portal's own page
  /// handles whatever goes wrong next.
  bool _loaded = false;

  /// True while the first load has failed and nothing has loaded since.
  /// Cleared by [onLoadStop], which makes a brief false alarm self-heal
  /// instead of leaving a stale error panel over a working page.
  bool _failed = false;

  /// True when the portal is showing its sign-in page. A sign-out button
  /// there would be signing out of nothing, so it hides.
  bool get _onLoginPage {
    final path = Uri.tryParse(_url)?.path.toLowerCase() ?? '';
    return path == '/login' || path.startsWith('/login/');
  }

  @override
  void initState() {
    super.initState();
    // Seeds the Dart-side copy of the session cookie that later stages
    // replay; the WebView's own store is what keeps the student signed
    // in across launches.
    FlexSessionService.instance.restore();
    _pullToRefresh = PullToRefreshController(
      onRefresh: () => _controller?.reload(),
    );
  }

  // ================= BUILD =================

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Only the header is inset. The portal below it is full-bleed so
        // the site reaches both screen edges the way a browser would.
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 6, 0),
          child: Row(
            children: [
              const Expanded(child: Text('Flex', style: AppTextStyles.title)),
              if (_canGoBack)
                _action(
                  tooltip: 'Back',
                  icon: Icons.arrow_back_rounded,
                  onTap: () => _controller?.goBack(),
                ),
              _action(
                tooltip: 'Open in browser',
                icon: Icons.open_in_new_rounded,
                onTap: _openInBrowser,
              ),
              _action(
                tooltip: 'Refresh',
                icon: Icons.refresh_rounded,
                onTap: () => _controller?.reload(),
              ),
              if (!_onLoginPage)
                _action(
                  tooltip: 'Sign out',
                  icon: Icons.logout_rounded,
                  // The one destructive action in the header — tinted with
                  // the app's action colour so it doesn't read as another
                  // harmless utility button.
                  color: AppColors.cardOrange,
                  onTap: _confirmSignOut,
                ),
            ],
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(
              color: AppColors.cardOrange,
              backgroundColor: AppColors.navBar,
              minHeight: 3,
            ),
          )
        else
          const SizedBox(height: 11),
        const SizedBox(height: 4),
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// One header icon. Sized like an [IconButton] so the touch targets
  /// line up, but without the default Material ripple spreading over the
  /// app bar.
  Widget _action({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, color: color),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildBody() {
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri(FlexSessionService.baseUrl),
          ),
          initialSettings: InAppWebViewSettings(
            // Needed so the system, not the WebView, decides what happens
            // with mail links and downloads.
            useShouldOverrideUrlLoading: true,
          ),
          // Injected at document start so the page is already dark by the
          // time it paints — doing it after load would flash white first.
          initialUserScripts: UnmodifiableListView<UserScript>([
            UserScript(
              source: _darkModeScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: true,
            ),
            // Every frame rather than just the top one: the portal hosts
            // its login behind a redirect that can land in a nested
            // document, and a password box the script never sees is a
            // password box that still won't offer the roll number.
            UserScript(
              source: _autofillScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false,
            ),
          ]),
          pullToRefreshController: _pullToRefresh,
          onWebViewCreated: (controller) => _controller = controller,
          onLoadStart: (controller, url) {
            if (mounted) {
              setState(() {
                _loading = true;
                if (url != null) _url = url.toString();
              });
            }
          },
          onLoadStop: (controller, url) async {
            if (mounted) {
              setState(() {
                _loading = false;
                _loaded = true;
                _failed = false;
                if (url != null) _url = url.toString();
              });
            }
            await _updateBackAvailability(controller);
            await FlexSessionService.instance.adoptFromWebView(controller);
          },
          onReceivedError: (controller, url, error) {
            // Only the first load reports failures — see [_loaded].
            if (_loaded || _failed) return;
            if (mounted) {
              setState(() {
                _failed = true;
                _loading = false;
              });
            }
          },
          onUpdateVisitedHistory: (controller, url, isReload) async {
            await _updateBackAvailability(controller);
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final url = navigationAction.request.url;
            if (url == null) return NavigationActionPolicy.ALLOW;

            final scheme = url.scheme.toLowerCase();
            if (scheme == 'http' || scheme == 'https') {
              if (_downloadRe.hasMatch(url.path)) {
                await _launchExternally(url);
                return NavigationActionPolicy.CANCEL;
              }
              // A normal page: keep it in the tab.
              return NavigationActionPolicy.ALLOW;
            }

            // mailto:, tel:, intent:… anything that isn't a web page.
            await _launchExternally(url);
            return NavigationActionPolicy.CANCEL;
          },
        ),
        if (_failed)
          Positioned.fill(
            child: Container(
              color: AppColors.background,
              child: _buildMessage(
                icon: Icons.cloud_off_rounded,
                message: 'Could not reach Flex.\nCheck your connection.',
                actionLabel: 'Retry',
                onAction: () {
                  setState(() {
                    _failed = false;
                    _loading = true;
                  });
                  _controller?.reload();
                },
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _updateBackAvailability(
    InAppWebViewController controller,
  ) async {
    var canGoBack = false;
    try {
      canGoBack = await controller.canGoBack();
    } catch (_) {
      // The controller can be gone mid-dispose; nothing to update then.
    }
    if (!mounted || canGoBack == _canGoBack) return;
    setState(() => _canGoBack = canGoBack);
  }

  Future<void> _openInBrowser() async {
    await _launchExternally(Uri.parse(_url));
  }

  /// Hands a URL to the system browser / handler. Downloads and mail
  /// links are useless inside the WebView, and this also keeps the
  /// portal's own sign-in flows (which may leave the app) working.
  Future<void> _launchExternally(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not open $url: $e');
    }
  }

  /// Asks before signing out — re-entering university credentials on a
  /// phone is annoying enough to be worth one extra tap.
  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.navBar,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text(
          'Sign out of Flex?',
          style: TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: const Text(
          "You'll need your university credentials to sign back in.",
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.cardOrange,
              foregroundColor: AppColors.textDark,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed == true) await _signOut();
  }

  /// Wipes the session and leaves the portal on its sign-in page.
  ///
  /// Cookies, the HTTP cache and web storage all go. The storage clear
  /// has to run while the authenticated page is still alive —
  /// `localStorage` is per-origin, so once we navigate away the
  /// dashboard's copy is no longer reachable. Clearing the cache doesn't
  /// tear down the page's script context, so that ordering is safe.
  ///
  /// Navigating to the portal root rather than reloading matters too:
  /// several pages deep, a reload would flash the stale dashboard before
  /// the server had a chance to redirect.
  Future<void> _signOut() async {
    final controller = _controller;
    if (mounted) setState(() => _loading = true);

    await FlexSessionService.instance.signOut();

    if (controller == null) return;
    try {
      // Static because the WebView cache is shared platform-wide rather
      // than owned by this one controller.
      await InAppWebViewController.clearAllCache(includeDiskFiles: true);
      await controller.evaluateJavascript(
        source:
            "try { localStorage.clear(); sessionStorage.clear(); } "
            'catch (e) {}',
      );
    } catch (e) {
      // Best-effort: the session is already gone, so a failed cache wipe
      // shouldn't block signing out.
      debugPrint('Flex sign-out cleanup failed: $e');
    }
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(FlexSessionService.baseUrl)),
    );
  }

  /// Same shape as the timetable's empty/error card so the app reads as
  /// one design.
  Widget _buildMessage({
    required IconData icon,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.navBar,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: AppColors.cardOrange),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.cardOrange,
                  foregroundColor: AppColors.textDark,
                ),
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
