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
  /// Styles injected before the portal paints, so it comes up dark and
  /// sits inside the app's palette rather than glaring white.
  ///
  /// The site's own colours are unknown and will change over time, so
  /// instead of guessing at its CSS we darken the finished render — the
  /// standard trick for an arbitrary page. `invert` flips every colour;
  /// the `hue-rotate` afterwards undoes the hue shift that flip causes,
  /// so accents stay recognisable (a blue link stays blue rather than
  /// turning orange) and the white page background lands on a soft
  /// near-black instead of pure #000.
  ///
  /// Images are inverted a second time to cancel the first, leaving
  /// photos and the university logo their real colours against the dark
  /// chrome. Iframes are deliberately left alone — their contents are
  /// already inverted once by the parent, which is what we want.
  ///
  /// Known trade-off: a CSS filter makes its element the containing
  /// block for `position: fixed` descendants, so a portal sidebar that
  /// was meant to stay pinned may scroll with the page. Content stays
  /// fully usable; it is a cosmetic quirk of darkening a site we don't
  /// control.
  static const String _darkModeScript = '''
(function () {
  var root = document.head || document.documentElement;
  if (!root) return;
  var style = document.createElement('style');
  style.textContent =
    'html { background-color: #f4f4f4 !important;' +
    '       filter: invert(1) hue-rotate(180deg) !important; }' +
    'img, picture, video, canvas, svg {' +
    '  filter: invert(1) hue-rotate(180deg) !important; }';
  root.appendChild(style);
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
