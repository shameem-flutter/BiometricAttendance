import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:printing/printing.dart';
import 'package:http/http.dart' as http;
import 'package:odoo_mobile/constants/color_constants.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/widgets/account_switcher_sheet.dart';
import 'dart:convert';

class Webview extends StatefulWidget {
  const Webview({super.key});

  @override
  State<Webview> createState() => _WebviewState();
}

class _WebviewState extends State<Webview> {
  InAppWebViewController? controller;
  String? serverUrl;
  bool _isLoading = false;
  bool _hasInternet = true;
  bool _pdfInjected = false;
  bool isDisposed = false;
  bool _webViewReady = false;
  double _progress = 0;
  late PullToRefreshController pullToRefreshController;

  Timer? _loaderDelay;

  @override
  void initState() {
    super.initState();
    pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(
        color: primaryColor,
      ),
      onRefresh: () async {
        if (Platform.isAndroid) {
          controller?.reload();
        } else if (Platform.isIOS) {
          controller?.loadUrl(
              urlRequest: URLRequest(url: await controller?.getUrl()));
        }
      },
    );
    AccountManager.instance.addListener(_onAccountChanged);
    _loadSetup();
  }

  @override
  void dispose() {
    AccountManager.instance.removeListener(_onAccountChanged);
    _loaderDelay?.cancel();
    isDisposed = true;
    controller = null;
    super.dispose();
  }

  void _onAccountChanged() {
    final account = AccountManager.instance.activeAccount;
    if (account != null && account.serverUrl != serverUrl) {
      serverUrl = account.serverUrl;
      _refreshWebView();
    }
  }

  void safeSetState(VoidCallback fn) {
    if (!isDisposed && mounted) setState(fn);
  }

  Future<void> _loadSetup() async {
    await _checkInternet();
    await _loadUrl();
  }

  bool _isSamePageNavigation(String? url) {
    if (url == null) return false;
    return url.contains('#');
  }

  Future<void> _checkInternet() async {
    final connected = await InternetConnection().hasInternetAccess;
    safeSetState(() => _hasInternet = connected);
  }

  Future<void> _loadUrl() async {
    final account = AccountManager.instance.activeAccount;

    if (account == null) {
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, "/login", (_) => false);
      }
      return;
    }

    serverUrl = account.serverUrl;
    if (controller != null) {
      final currentUrl = await controller!.getUrl();
      if (currentUrl == null ||
          currentUrl.toString() == 'about:blank' ||
          currentUrl.toString().isEmpty) {
        controller!.loadUrl(
          urlRequest: URLRequest(url: WebUri(serverUrl!)),
        );
      }
    }
  }

  Future<String> _getCookieHeader(String url) async {
    final uri = Uri.parse(url);
    final cookies =
        await CookieManager.instance().getCookies(url: WebUri(uri.origin));

    if (cookies.isEmpty) return "";

    return cookies.map((c) => "${c.name}=${c.value}").join("; ");
  }

  Future<void> _refreshWebView() async {
    await _checkInternet();
    if (!_hasInternet) return;

    if (!_webViewReady || controller == null || serverUrl == null) {
      log("⚠️ WebView not ready yet, refresh ignored");
      return;
    }

    try {
      safeSetState(() => _isLoading = true);

      await controller!.loadUrl(
        urlRequest: URLRequest(url: WebUri(serverUrl!)),
      );
    } catch (e) {
      log("❌ Refresh failed safely: $e");
    }
  }

  bool isPdfUrl(String url) {
    return url.contains("/report/pdf") ||
        url.contains("/report/download") ||
        url.endsWith(".pdf");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Color(0XFFF8F9FA),
        title: Text(
          "Wasla-Hr",
          style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold, color: const Color(0XFF71639e)),
        ),
        leading: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Image.asset("assets/wasla_logo.png"),
        ),
        centerTitle: true,
        actions: [
          IconButton(
              onPressed: _webViewReady ? _refreshWebView : null,
              icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'attendance') {
                Navigator.pushNamed(context, '/attendance');
              } else if (value == 'switch_account') {
                AccountSwitcherSheet.show(context);
              } else if (value == 'logout') {
                AccountSwitcherSheet.showLogoutDialog(context);
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  value: 'attendance',
                  child: Row(
                    children: [
                      const Icon(Icons.co_present, color: Colors.black54),
                      const SizedBox(width: 10),
                      Text('Attendance Screen', style: GoogleFonts.poppins(fontSize: 14)),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'switch_account',
                  child: Row(
                    children: [
                      const Icon(Icons.account_circle, color: Colors.black54),
                      const SizedBox(width: 10),
                      Text('Switch Account', style: GoogleFonts.poppins(fontSize: 14)),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'logout',
                  child: Row(
                    children: [
                      const Icon(Icons.logout, color: Colors.redAccent),
                      const SizedBox(width: 10),
                      Text(
                        'Log Out',
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          color: Colors.redAccent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: AccountManager.instance,
        builder: (context, _) {
          return Stack(
            children: [
              PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, result) async {
                  if (didPop) return;

                  if (controller != null && await controller!.canGoBack()) {
                    controller!.goBack();
                    return;
                  }
                  SystemNavigator.pop();
                },
                child: !_hasInternet
                    ? _noInternetView()
                    : Stack(
                        children: [
                          Container(
                            color: whiteColor,
                            child: InAppWebView(
                                initialUrlRequest: AccountManager.instance.activeAccount != null
                                    ? URLRequest(
                                        url: WebUri(AccountManager.instance.activeAccount!.serverUrl))
                                    : null,
                                pullToRefreshController: pullToRefreshController,
                                initialSettings: InAppWebViewSettings(
                                  transparentBackground: true,
                                  javaScriptEnabled: true,
                                  domStorageEnabled: true,
                                  useHybridComposition: true,
                                  disableHorizontalScroll: false,
                                  disableVerticalScroll: false,
                                  verticalScrollBarEnabled: false,
                                  horizontalScrollBarEnabled: false,
                                  supportZoom: false,
                                  builtInZoomControls: false,
                                  displayZoomControls: false,
                                  databaseEnabled: true,
                                  clearSessionCache: false,
                                  clearCache: false,
                                  mixedContentMode: MixedContentMode
                                      .MIXED_CONTENT_ALWAYS_ALLOW,
                                  useShouldInterceptRequest: false,
                                  allowsInlineMediaPlayback: true,
                                  mediaPlaybackRequiresUserGesture: false,
                                  cacheEnabled: true,
                                  thirdPartyCookiesEnabled: true,
                                  useOnDownloadStart: true,
                                  underPageBackgroundColor: whiteColor,
                                ),
                                onWebViewCreated: (c) {
                                  controller = c;
                                  _webViewReady = true;

                                  // Add JavaScript handler for PDF capture
                                  c.addJavaScriptHandler(
                                    handlerName: 'PdfDataHandler',
                                    callback: (args) {
                                      if (args.isNotEmpty) {
                                        final base64Data = args[0] as String;
                                        _handleBase64Pdf(base64Data);
                                      }
                                    },
                                  );
                                },
                                shouldOverrideUrlLoading:
                                    (controller, action) async {
                                  return NavigationActionPolicy.ALLOW;
                                },
                                onLoadStart: (_, url) {
                                  if (_isSamePageNavigation(url?.toString())) {
                                    return;
                                  }
                                  log("🌐 Loading: $url");
                                  safeSetState(() {
                                    _isLoading = true;
                                    _progress = 0.1;
                                  });
                                },
                                onLoadStop: (_, url) async {
                                  log("✅ Loaded: $url");
                                  pullToRefreshController.endRefreshing();
                                  safeSetState(() {
                                    _isLoading = false;
                                    _progress = 1.0;
                                  });
                                  await _injectPdfInterceptor();
                                },
                                onProgressChanged: (controller, progress) {
                                  if (progress == 100) {
                                    pullToRefreshController.endRefreshing();
                                  }
                                  safeSetState(() {
                                    _progress = progress / 100;
                                  });
                                },

                                // Handle downloads (this catches PDF downloads)
                                onDownloadStartRequest:
                                    (controller, downloadRequest) async {
                                  final url = downloadRequest.url.toString();
                                  log("📥 Download detected: $url");

                                  // Fetch and display the PDF
                                  await _fetchAndDisplayPdf(url);
                                },
                                onConsoleMessage: (controller, consoleMessage) {
                                  if (consoleMessage.message
                                      .startsWith('PDF_BASE64:')) {
                                    final base64Data =
                                        consoleMessage.message.substring(11);
                                    _handleBase64Pdf(base64Data);
                                  } else {
                                    log("JS Console: ${consoleMessage.message}");
                                  }
                                },
                                onReceivedError: (controller, request, error) {
                                  final url = request.url.toString();

                                  // Ignore non-critical Odoo assets
                                  if (url.contains("favicon") ||
                                      url.contains("/web/static/") ||
                                      url.contains("/web/image/") ||
                                      url.contains("/web/webclient/locale") ||
                                      url.contains(
                                          "/web/webclient/translations")) {
                                    return;
                                  }

                                  log("❌ WebView critical error: ${error.description}");
                                }),
                          ),
                          if (_isLoading && _progress < 1.0)
                            Positioned.fill(
                              child: Center(
                                child: CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(secondaryColor),
                                ),
                              ),
                            )
                        ],
                      ),
              ),
              if (AccountManager.instance.isLoading)
                Container(
                  color: Colors.white,
                  child: Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(secondaryColor),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  //  Inject JavaScript to intercept PDF responses
  Future<void> _injectPdfInterceptor() async {
    if (controller == null || _pdfInjected) return;
    _pdfInjected = true;

    try {
      await controller!.evaluateJavascript(source: '''
        (function() {
          if (window.pdfInterceptorInstalled) return;
          window.pdfInterceptorInstalled = true;
          
          // Intercept XMLHttpRequest
          const originalOpen = XMLHttpRequest.prototype.open;
          const originalSend = XMLHttpRequest.prototype.send;
          
          XMLHttpRequest.prototype.open = function(method, url) {
            this._url = url;
            this._method = method;
            return originalOpen.apply(this, arguments);
          };
          
          XMLHttpRequest.prototype.send = function(body) {
            this.addEventListener('load', function() {
              const url = this._url || '';
              
              if (url.includes('/report/download') || url.includes('/report/pdf')) {
                console.log('📄 PDF XHR detected: ' + url);
                
                if (this.responseType === 'blob' || this.response instanceof Blob) {
                  const blob = this.response;
                  const reader = new FileReader();
                  reader.onloadend = function() {
                    const base64 = reader.result.split(',')[1];
                    console.log('PDF_BASE64:' + base64);
                    window.flutter_inappwebview.callHandler('PdfDataHandler', base64);
                  };
                  reader.readAsDataURL(blob);
                } else if (this.responseType === 'arraybuffer') {
                  const bytes = new Uint8Array(this.response);
                  const binary = bytes.reduce((acc, byte) => acc + String.fromCharCode(byte), '');
                  const base64 = btoa(binary);
                  console.log('PDF_BASE64:' + base64);
                  window.flutter_inappwebview.callHandler('PdfDataHandler', base64);
                }
              }
            });
            return originalSend.apply(this, arguments);
          };
          
          console.log('✅ PDF interceptor installed');
        })();
      ''');

      log("✅ PDF interceptor injected");
    } catch (e) {
      log("❌ Failed to inject interceptor: $e");
    }
  }

  // Track processed PDFs to avoid duplicates
  final Set<String> _processedPdfs = {};

  // Handle base64 PDF from JavaScript
  Future<void> _handleBase64Pdf(String base64Data) async {
    try {
      log("📦 Received PDF data from JavaScript: ${base64Data.length} chars");

      // Generate a hash to detect duplicates
      final pdfHash = base64Data.length.toString() +
          base64Data.substring(0, 50.clamp(0, base64Data.length));

      if (_processedPdfs.contains(pdfHash)) {
        log("⚠️ Duplicate PDF detected, skipping");
        return;
      }

      _processedPdfs.add(pdfHash);

      // Clean up old hashes after 5 seconds
      Future.delayed(const Duration(seconds: 5), () {
        _processedPdfs.remove(pdfHash);
      });

      final pdfBytes = base64Decode(base64Data);

      if (pdfBytes.isEmpty) {
        throw Exception("Decoded PDF is empty");
      }

      // Verify it's a valid PDF
      if (pdfBytes.length < 4 ||
          (pdfBytes[0] != 0x25 ||
              pdfBytes[1] != 0x50 ||
              pdfBytes[2] != 0x44 ||
              pdfBytes[3] != 0x46)) {
        throw Exception("Invalid PDF format");
      }

      log("✅ Valid PDF (${pdfBytes.length} bytes), opening...");

      await Printing.layoutPdf(
        onLayout: (_) => pdfBytes,
      );

      // if (mounted) {
      //   ScaffoldMessenger.of(context).showSnackBar(
      //     const SnackBar(
      //       content: Text('PDF opened successfully'),
      //       backgroundColor: Colors.green,
      //       duration: Duration(seconds: 2),
      //     ),
      //   );
      // }
    } catch (e) {
      log("❌ PDF handling error: $e");

      // if (mounted) {
      //   ScaffoldMessenger.of(context).showSnackBar(
      //     SnackBar(
      //       content: Text('Failed to open PDF: $e'),
      //       backgroundColor: Colors.red,
      //       duration: const Duration(seconds: 3),
      //     ),
      //   );
      // }
    } finally {
      //  safeSetState(() => _isLoading = false);
    }
  }

  Future<void> _fetchAndDisplayPdf(String url) async {
    try {
      var secureUrl = url.trim();
      if (secureUrl.startsWith('http://')) {
        secureUrl = 'https://${secureUrl.substring(7)}';
      }
      log("🔄 Fetching PDF from: $secureUrl");

      //  safeSetState(() => _isLoading = true);

      final cookieHeader = await _getCookieHeader(secureUrl);

      final response = await http.get(
        Uri.parse(secureUrl),
        headers: {
          'Cookie': cookieHeader,
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final pdfBytes = response.bodyBytes;

        if (pdfBytes.isEmpty) {
          throw Exception("Empty response");
        }

        // Verify PDF
        if (pdfBytes.length < 4 ||
            (pdfBytes[0] != 0x25 ||
                pdfBytes[1] != 0x50 ||
                pdfBytes[2] != 0x44 ||
                pdfBytes[3] != 0x46)) {
          throw Exception("Invalid PDF format");
        }

        log("✅ PDF fetched (${pdfBytes.length} bytes)");

        await Printing.layoutPdf(
          onLayout: (_) => pdfBytes,
        );

        // if (mounted) {
        //   ScaffoldMessenger.of(context).showSnackBar(
        //     const SnackBar(
        //       content: Text('PDF opened successfully'),
        //       backgroundColor: Colors.green,
        //       duration: Duration(seconds: 2),
        //     ),
        //   );
        // }
      } else {
        throw Exception("HTTP ${response.statusCode}");
      }
    } catch (e) {
      log("❌ Fetch error: $e");

      // if (mounted) {
      //   ScaffoldMessenger.of(context).showSnackBar(
      //     SnackBar(
      //       content: Text('Failed to fetch PDF: $e'),
      //       backgroundColor: Colors.red,
      //       duration: const Duration(seconds: 3),
      //     ),
      //   );
      // }
    } finally {
      //safeSetState(() => _isLoading = false);
    }
  }

  Widget _noInternetView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text("Connect to network !!!",
              style: TextStyle(fontSize: 20, color: Colors.red)),
          const SizedBox(height: 16),
          //   ElevatedButton.icon(
          //    icon: const Icon(Icons.refresh),
          //    label: const Text(''),
          //   onPressed: () {
          // await _checkInternet();
          // if (_hasInternet) controller?.reload();
          //   },
          // )
        ],
      ),
    );
  }
}
