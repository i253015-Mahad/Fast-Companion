// lib/Screens/flex_screen.dart

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
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
  /// roll number box is found the way a browser finds it — the text
  /// field that comes before the password box — rather than by a name or
  /// an id, which the portal is free to rename, and rather than by a
  /// shared `<form>`, which the portal is equally free not to use.
  ///
  /// The form does not exist when this script first runs, so the work is
  /// done by an observer rather than once at start-up.
  ///
  /// The observer rescans the *whole* document rather than only what just
  /// arrived. The HTML parser adds elements one at a time, so the roll
  /// number box and the password box arrive in separate callbacks — and
  /// a scan limited to the new subtree sees one of them without the
  /// other, which is exactly the pairing this exists to make.
  ///
  /// Tagging the field is not on its own enough. The portal also binds
  /// Inputmask to the roll number box, and the mask hides the field from
  /// the autofill framework: with the mask attached the system has
  /// nothing to offer, and the moment the mask is dropped the saved roll
  /// number is offered. So the mask is dropped. It only inserts the
  /// hyphen the saved value already carries, and the field keeps the
  /// example in its placeholder, so nothing is lost but the obstacle.
  static const String _autofillScript = '''
(function () {
  if (window.__fcAutofillApplied) return;
  window.__fcAutofillApplied = true;

  // Detach a mask the portal may have bound to this field, and clear
  // what the mask leaves in it. Checked on every pass and on focus,
  // because the portal installs the mask after this script has already
  // seen the element.
  function unmask(el) {
    try {
      if (!el || !el.inputmask || !el.inputmask.remove) return;
      el.inputmask.remove();
      // The mask writes its separator into the field as soon as the
      // field is focused, so an untouched roll number is not empty any
      // more — and an offer is only made into an empty field. That is
      // why the offer stayed away even once the mask itself was gone.
      // A field holding nothing but separators is the mask talking, not
      // the user, and is cleared.
      if (!/[A-Za-z0-9]/.test(el.value || '')) el.value = '';
    } catch (e) {
      // A portal change must never take the page down over this.
    }
  }

  // Walk the inputs in document order. Everything the system can treat
  // as a username is remembered, and the one that counts is the last
  // such field before a password box — which is the roll number, however
  // the portal has chosen to group the fields.
  function label() {
    try {
      var inputs = document.querySelectorAll('input');
      var lastText = null;
      for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i];
        var type = (el.getAttribute('type') || 'text').toLowerCase();

        if (type === 'password') {
          el.setAttribute('autocomplete', 'current-password');
          if (!lastText) continue;
          // A token the portal chose ("email", "one-time-code") is kept:
          // it describes the field better than this guess does. "off" is
          // not — it is the portal declining autofill, and it is exactly
          // the reason the roll number was never offered.
          var existing =
            (lastText.getAttribute('autocomplete') || '').toLowerCase();
          if (existing && existing !== 'off' && existing !== 'on') continue;
          lastText.setAttribute('autocomplete', 'username');
          unmask(lastText);
        } else if (
          type === 'text' ||
          type === 'tel' ||
          type === 'number' ||
          type === 'email'
        ) {
          lastText = el;
        }
      }
    } catch (e) {
      // A portal change must never take the page down over this.
    }
  }

  // The mask is removed the moment the field is focused as well, ahead
  // of the portal's own focus handling, so that autofill meets a plain
  // field rather than a masked one.
  try {
    document.addEventListener('focusin', function (ev) {
      unmask(ev.target);
    }, true);
  } catch (e) {
    // A portal change must never take the page down over this.
  }

  function boot() {
    var root = document.documentElement;
    if (!root) { setTimeout(boot, 10); return; }

    label();
    // The mask is bound on the portal's own schedule, so the field is
    // swept again a few times before the user can reach it.
    setTimeout(label, 300);
    setTimeout(label, 1200);
    try {
      new MutationObserver(function () { label(); }).observe(root, {
        childList: true,
        subtree: true,
      });
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

  /// The portal opens its downloads with `window.open(url, '_blank')` —
  /// the fee challan's Print button does exactly that.
  ///
  /// A WebView has no windows to give: with `supportMultipleWindows` off
  /// the call is discarded before any request goes out, and with it on
  /// Android reports `request.url` as `null` for a JavaScript-created
  /// window, so there is still nothing to load. Rather than grow a
  /// hidden popup WebView just to host a response that cannot be
  /// displayed anyway, the call is folded into a navigation of the
  /// current page. The document is replaced, but it is replaced by the
  /// file — which [onDownloadStarting] then catches and saves, exactly
  /// as it does for the admit card's plain link.
  static final String _windowOpenScript = '''
(function () {
  var originalOpen = window.open;
  window.open = function (url) {
    if (!url) { return originalOpen.apply(window, arguments); }
    window.location.href = url;
    // A stub rather than null: a page that keeps the handle and calls
    // .focus() or .close() on it would throw otherwise, and none of
    // those operations mean anything here.
    return { focus: function () {}, close: function () {} };
  };
})();
''';

  /// Lowers the portal's navigation mask — `[id^="overlay"]` holding
  /// the `.loader-box` spinner, the pair [_darkModeScript] recolours
  /// for dark mode. The portal raises it before a navigation and only
  /// lowers it once the next page loads, so a response that turns into
  /// a *file* instead of a page leaves it frozen over a perfectly
  /// interactive screen until a manual refresh rebuilds the document —
  /// the "keeps loading after I cancel" bug.
  ///
  /// [_saveDownload] is the one point that knows the load ended as a
  /// file rather than a page, so it runs this for both the saved and
  /// the cancelled outcome. Nothing outlives the fix: the next real
  /// navigation replaces the document anyway, mask included.
  static const String _hideMaskScript = '''
(function () {
  var masks = document.querySelectorAll('[id^="overlay"], .loader-box');
  for (var i = 0; i < masks.length; i++) {
    masks[i].style.setProperty('display', 'none', 'important');
  }
})();
''';

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
            // Registers the Android DownloadListener that fires
            // onDownloadStarting. Without this the callback never runs —
            // the portal's attachments are dropped in silence, which is
            // exactly the "keeps loading forever" bug this fixes.
            useOnDownloadStart: true,
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
            // Main frame only: popups are a top-level document concern,
            // and a nested frame rewriting window.open would rewrite it
            // for itself alone.
            UserScript(
              source: _windowOpenScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: true,
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
                // Saved through the session rather than opened in a
                // browser: these links sit behind the Flex login, and an
                // external browser carries no cookie — it would show the
                // sign-in page instead of the file.
                unawaited(_saveDownload(url));
                return NavigationActionPolicy.CANCEL;
              }
              // A normal page: keep it in the tab.
              return NavigationActionPolicy.ALLOW;
            }

            // mailto:, tel:, intent:… anything that isn't a web page.
            await _launchExternally(url);
            return NavigationActionPolicy.CANCEL;
          },
          // Fires for every response the portal marks as a download,
          // whatever the URL looks like — which is the only reason the
          // admit card is catchable at all: its link
          // (/Student/PrintAdmitCard?semid=…) carries no file extension,
          // so URL matching can never see it coming.
          onDownloadStarting: (controller, downloadStartRequest) async {
            unawaited(
              _saveDownload(
                downloadStartRequest.url,
                suggestedName: downloadStartRequest.suggestedFilename,
                mimeType: downloadStartRequest.mimeType,
              ),
            );
            // Nothing left for the WebView to do — the response was an
            // attachment it cannot display, and the fetch above already
            // replays the session it would have needed.
            return null;
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

  /// Fetches a portal download under the Flex session and hands it to
  /// the system's own "Save as" picker.
  ///
  /// This is the fix for the admit card / fee challan hanging forever.
  /// Chrome shows a download prompt because it registered a
  /// `DownloadListener`; a bare WebView has none, so a
  /// `Content-Disposition: attachment` response was dropped without a
  /// word and the page sat loading indefinitely. The file is therefore
  /// fetched here — with the session cookie the WebView established, so
  /// an expired session is reported rather than saved as the sign-in
  /// page wearing a PDF's name — and SAF does the saving, which needs
  /// no storage permission and lets the student choose the destination
  /// (Downloads, Drive, anywhere) exactly like Chrome's prompt would.
  ///
  /// [suggestedName] and [mimeType] come from the download event when
  /// there is one; the URL is the fallback for links intercepted before
  /// a response existed to describe them.
  Future<void> _saveDownload(
    Uri url, {
    String? suggestedName,
    String? mimeType,
  }) async {
    // The aborted navigation never reaches onLoadStop, so the header
    // spinner would keep turning over a page that is already back on
    // screen. This is the "just kept loading" symptom, cleared at the
    // one point that knows the load ended as a download.
    if (mounted) setState(() => _loading = false);

    // The portal's own mask went up when Print was pressed, and only
    // the next page load — which this download replaces with a file —
    // could take it down again, leaving "Loading, please wait…"
    // frozen over an interactive page until a manual refresh. Hidden
    // here, before the fetch, so the student lands on a usable page
    // whichever way the picker below ends (saved or cancelled).
    try {
      await _controller?.evaluateJavascript(source: _hideMaskScript);
    } catch (e) {
      // Controller gone mid-dispose — the page is being torn down
      // with it, so there is no mask left to clear.
      debugPrint('Flex mask hide failed: $e');
    }

    final result = await FlexSessionService.instance.fetchBytes(url);
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final bytes = result.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(
          // Themed at the call site: MaterialApp sets no theme, so the
          // default Material grey is what shows without this. Failures
          // take the dark teal surface (as the dialogs do), success the
          // card orange used by home_screen's confirmations.
          backgroundColor: AppColors.navBar,
          content: Text(
            result.loginRedirect
                ? 'Your Flex session has expired. '
                      'Sign in again, then retry the download.'
                : 'Could not download the file. '
                      'Check your connection and try again.',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
      return;
    }

    final name = _downloadFileName(url, suggestedName, mimeType);
    try {
      final saved = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(data: bytes, fileName: name),
      );
      // null means the student dismissed the picker — not an error, so
      // no message; the file simply was not saved anywhere.
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.cardOrange,
            content: Text(
              'Saved $name',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Flex save failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.navBar,
            content: Text(
              'Could not save the file.',
              style: TextStyle(color: Colors.white),
            ),
          ),
        );
      }
    }
  }

  /// The file name the save picker opens with, best source first.
  ///
  /// The download event's suggestion already reflects the portal's
  /// `Content-Disposition` header, so it wins when present. The URL's
  /// last segment is the fallback for intercepted links, and a missing
  /// extension is filled from the MIME type — a file the system cannot
  /// type is a file no app will offer to open.
  static String _downloadFileName(
    Uri url,
    String? suggested,
    String? mimeType,
  ) {
    var name = (suggested ?? '').trim();
    if (name.isEmpty) {
      final segment = url.pathSegments.isNotEmpty ? url.pathSegments.last : '';
      name = segment.trim();
    }
    if (name.isEmpty || !name.contains('.')) {
      final ext = switch (mimeType?.toLowerCase() ?? '') {
        'application/pdf' => 'pdf',
        'text/csv' => 'csv',
        var m when m.contains('wordprocessingml') => 'docx',
        var m when m.contains('msword') => 'doc',
        var m when m.contains('spreadsheetml') => 'xlsx',
        var m when m.contains('ms-excel') => 'xls',
        var m when m.contains('zip') => 'zip',
        _ => 'pdf', // what the portal serves more than anything else
      };
      name = name.isEmpty ? 'flex-download.$ext' : '$name.$ext';
    }
    return name;
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
