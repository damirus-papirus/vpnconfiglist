import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sing_box/sing_box.dart';

const appVersion = '1.0.0';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Object? startupError;
  try {
    await SingBox.instance.initialize(
      const SingBoxOptions(
        android: SingBoxAndroidOptions(
          notificationTitle: 'ONVPN',
          stopActionTitle: 'Отключить',
          showTrafficInNotification: true,
        ),
      ),
    );
  } catch (e) {
    startupError = e;
  }
  runApp(OnvpnApp(startupError: startupError));
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class ServerProfile {
  const ServerProfile({required this.name, required this.link});
  final String name;
  final String link;

  String get protocol {
    final value = link.toLowerCase();
    if (value.startsWith('hysteria2://') || value.startsWith('hy2://')) {
      return 'Hysteria2';
    }
    if (value.contains('type=grpc')) return 'gRPC';
    return 'TCP';
  }

  String get host => Uri.tryParse(link)?.host ?? '';
}

class OnvpnApp extends StatefulWidget {
  const OnvpnApp({super.key, this.startupError});
  final Object? startupError;

  @override
  State<OnvpnApp> createState() => _OnvpnAppState();
}

class _OnvpnAppState extends State<OnvpnApp> {
  int tab = 0;
  final profiles = <ServerProfile>[];
  String? selectedLink;
  String subscriptionUrl = '';
  String? errorText;
  bool busy = false;
  Position? devicePosition;
  Offset? serverPosition;
  StreamSubscription<Position>? positionSub;
  StreamSubscription<SingBoxConnectionStatus>? statusSub;
  SingBoxConnectionStatus connectionStatus =
      SingBoxConnectionStatus.disconnected;
  SingBoxConnectionStats? stats;
  StreamSubscription<SingBoxConnectionStats>? statsSub;

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _watchEngine();
    _locateDevice();
  }

  @override
  void dispose() {
    positionSub?.cancel();
    statusSub?.cancel();
    statsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final links = prefs.getStringList('profiles') ?? <String>[];
    final savedUrl = prefs.getString('subscription_url') ?? '';
    final active = prefs.getString('selected_link');
    if (!mounted) return;
    setState(() {
      subscriptionUrl = savedUrl;
      profiles
        ..clear()
        ..addAll(links.map(_profileFromLink));
      selectedLink = profiles.any((p) => p.link == active)
          ? active
          : (profiles.isNotEmpty ? profiles.first.link : null);
    });
    _resolveServer();
  }

  ServerProfile _profileFromLink(String link) {
    final uri = Uri.tryParse(link);
    final label = uri?.fragment.trim();
    return ServerProfile(
      name: (label == null || label.isEmpty) ? (uri?.host ?? 'Сервер') : Uri.decodeComponent(label),
      link: link,
    );
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('profiles', profiles.map((e) => e.link).toList());
    if (selectedLink != null) await prefs.setString('selected_link', selectedLink!);
  }

  void _watchEngine() {
    try {
      statusSub = SingBox.instance.watchConnectionStatus().listen((value) {
        if (mounted) setState(() => connectionStatus = value);
      });
      statsSub = SingBox.instance.watchConnectionStats().listen((value) {
        if (mounted) setState(() => stats = value);
      });
    } catch (_) {
      // Initialization errors are shown in the UI; the app remains navigable.
    }
  }

  Future<void> _locateDevice() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) return;
      final position = await Geolocator.getCurrentPosition();
      if (mounted) setState(() => devicePosition = position);
      positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          distanceFilter: 1000,
        ),
      ).listen((p) {
        if (mounted) setState(() => devicePosition = p);
      });
    } catch (_) {
      // Location is optional; no fake device marker is drawn.
    }
  }

  Future<void> _resolveServer() async {
    final link = selectedLink;
    if (link == null) return;
    final host = Uri.tryParse(link)?.host ?? '';
    if (host.isEmpty) return;
    try {
      final addresses = await InternetAddress.lookup(host);
      if (addresses.isEmpty) return;
      final ip = addresses.first.address;
      final response = await http.get(
        Uri.https('ipwho.is', '/$ip'),
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 8));
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['success'] == true) {
        final lat = (json['latitude'] as num).toDouble();
        final lon = (json['longitude'] as num).toDouble();
        if (mounted) setState(() => serverPosition = Offset(lon, lat));
      }
    } catch (_) {
      if (mounted) setState(() => serverPosition = null);
    }
  }

  String get _userAgent => 'Onvpn/$appVersion/vpnconnection';

  Future<void> _importSubscription(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => errorText = 'Проверь URL подписки');
      return;
    }
    setState(() {
      busy = true;
      errorText = null;
    });
    try {
      final response = await http.get(
        uri,
        headers: {'User-Agent': _userAgent, 'Accept': '*/*'},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      var body = response.body.trim();
      if (!body.contains('://')) {
        try {
          body = utf8.decode(base64.decode(base64.normalize(body)));
        } catch (_) {
          // Plain-text subscriptions are also accepted.
        }
      }
      final links = body
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) =>
              line.startsWith('vless://') ||
              line.startsWith('hysteria2://') ||
              line.startsWith('hy2://'))
          .toSet()
          .toList();
      if (links.isEmpty) throw const FormatException('Подписка не содержит поддерживаемых ссылок');
      profiles
        ..clear()
        ..addAll(links.map(_profileFromLink));
      selectedLink = profiles.first.link;
      subscriptionUrl = url.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('subscription_url', subscriptionUrl);
      await _saveProfiles();
      serverPosition = null;
      await _resolveServer();
    } catch (e) {
      errorText = 'Не удалось обновить подписку: $e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _toggleConnection() async {
    if (busy) return;
    setState(() {
      busy = true;
      errorText = null;
    });
    try {
      if (connectionStatus == SingBoxConnectionStatus.connected ||
          connectionStatus == SingBoxConnectionStatus.connecting) {
        await SingBox.instance.disconnect();
      } else {
        final link = selectedLink;
        if (link == null) throw StateError('Сначала добавь подписку в настройках');
        await SingBox.instance.connect(link);
      }
    } catch (e) {
      errorText = e.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _selectProfile(ServerProfile profile) async {
    setState(() {
      selectedLink = profile.link;
      serverPosition = null;
    });
    await _saveProfiles();
    await _resolveServer();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _homePage(),
      _serversPage(),
      _settingsPage(),
    ];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF090B12),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C5CFF),
          brightness: Brightness.dark,
          surface: const Color(0xFF111521),
        ),
        fontFamily: 'Roboto',
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('ONVPN', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          centerTitle: false,
          backgroundColor: const Color(0xFF090B12),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Center(child: Text('v$appVersion', style: const TextStyle(color: Colors.white38))),
            ),
          ],
        ),
        body: SafeArea(child: IndexedStack(index: tab, children: pages)),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (value) => setState(() => tab = value),
          backgroundColor: const Color(0xFF101420),
          indicatorColor: const Color(0xFF33275D),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Главная'),
            NavigationDestination(icon: Icon(Icons.dns_rounded), label: 'Серверы'),
            NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Настройки'),
          ],
        ),
      ),
    );
  }

  Widget _homePage() {
    final connected = connectionStatus == SingBoxConnectionStatus.connected;
    final connecting = connectionStatus == SingBoxConnectionStatus.connecting ||
        connectionStatus == SingBoxConnectionStatus.disconnecting;
    final protocol = profiles.where((p) => p.link == selectedLink).firstOrNull?.protocol ?? '—';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      children: [
        _panel(
          child: Column(
            children: [
              Text(
                connected ? 'ЗАЩИЩЁННОЕ СОЕДИНЕНИЕ' : (connecting ? 'ПОДКЛЮЧЕНИЕ' : 'СОЕДИНЕНИЕ ОТКЛЮЧЕНО'),
                style: TextStyle(
                  color: connected ? const Color(0xFF69E6B2) : Colors.white54,
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              GestureDetector(
                onTap: _toggleConnection,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: connected
                          ? const [Color(0xFF19B985), Color(0xFF126B70)]
                          : const [Color(0xFF765BFF), Color(0xFF3945A8)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (connected ? const Color(0xFF20D9A0) : const Color(0xFF765BFF)).withOpacity(.25),
                        blurRadius: 35,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Icon(
                    connected ? Icons.lock_rounded : Icons.power_settings_new_rounded,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 15),
              Text(
                connected ? 'Отключить' : 'Подключить',
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              Text(
                profiles.where((p) => p.link == selectedLink).firstOrNull?.name ?? 'Сервер не выбран',
                style: const TextStyle(color: Colors.white54),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _metric('↓', _speed(stats?.downloadSpeed ?? 0)),
                  const SizedBox(width: 34),
                  _metric('↑', _speed(stats?.uploadSpeed ?? 0)),
                  const SizedBox(width: 34),
                  _metric('ПРОТОКОЛ', protocol),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _panel(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 15, 16, 0),
                child: Text('МАРШРУТ СОЕДИНЕНИЯ', style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: Colors.white54, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 210,
                width: double.infinity,
                child: AnimatedRouteMap(
                  device: devicePosition == null ? null : Offset(devicePosition!.longitude, devicePosition!.latitude),
                  server: serverPosition,
                  protocol: protocol,
                  active: connected || connecting,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Row(
                  children: [
                    const Icon(Icons.my_location, size: 14, color: Color(0xFF62A8FF)),
                    const SizedBox(width: 6),
                    const Text('Устройство', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    const Spacer(),
                    const Icon(Icons.circle, size: 8, color: Color(0xFF9B7CFF)),
                    const SizedBox(width: 6),
                    Text(serverPosition == null ? 'Сервер не определён' : 'VPN-сервер', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 12),
          _error(errorText!),
        ],
        if (widget.startupError != null) ...[
          const SizedBox(height: 12),
          _error('Ошибка запуска VPN-движка: ${widget.startupError}'),
        ],
      ],
    );
  }

  Widget _serversPage() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Мои серверы', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
            Text('${profiles.length} проф.', style: const TextStyle(color: Colors.white54)),
          ],
        ),
        const SizedBox(height: 14),
        if (profiles.isEmpty)
          _panel(child: const Text('Серверов пока нет. Добавь URL подписки во вкладке «Настройки».', style: TextStyle(color: Colors.white60)))
        else
          ...profiles.map((profile) {
            final active = profile.link == selectedLink;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _selectProfile(profile),
                child: _panel(
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(color: const Color(0xFF292443), borderRadius: BorderRadius.circular(13)),
                        child: const Icon(Icons.public_rounded, color: Color(0xFFAA98FF)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text('${profile.protocol} • ${profile.host}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          ],
                        ),
                      ),
                      Icon(active ? Icons.check_circle : Icons.circle_outlined, color: active ? const Color(0xFF69E6B2) : Colors.white24),
                    ],
                  ),
                ),
              ),
            );
          }),
        if (errorText != null) _error(errorText!),
      ],
    );
  }

  Widget _settingsPage() {
    final controller = TextEditingController(text: subscriptionUrl);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Настройки', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('URL подписки', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: 'https://example.com/subscription',
                  filled: true,
                  fillColor: const Color(0xFF090D16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
                ),
                onSubmitted: (value) => _importSubscription(value),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy ? null : () => _importSubscription(controller.text),
                  icon: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync_rounded),
                  label: Text(busy ? 'Обновление…' : 'Сохранить и обновить'),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Запрос подписки отправляется с User-Agent Onvpn/1.0.0/vpnconnection.', style: TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('О приложении', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              _settingRow('Версия', appVersion),
              _settingRow('Движок', 'sing-box'),
              _settingRow('Поддержка', 'VLESS Reality / Hysteria2'),
              _settingRow('Хранение профилей', 'Локально на устройстве'),
            ],
          ),
        ),
        if (errorText != null) ...[const SizedBox(height: 12), _error(errorText!)],
      ],
    );
  }

  Widget _settingRow(String title, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(color: Colors.white54))),
          Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );

  Widget _metric(String title, String value) => Column(
        children: [
          Text(title, style: const TextStyle(color: Colors.white38, fontSize: 10)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ],
      );

  String _speed(num bytesPerSecond) {
    final value = bytesPerSecond.toDouble();
    if (value >= 1024 * 1024) return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KB/s';
    return '${value.toStringAsFixed(0)} B/s';
  }

  Widget _panel({required Widget child, EdgeInsets padding = const EdgeInsets.all(17)}) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: const Color(0xFF111521),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withOpacity(.045)),
        ),
        child: child,
      );

  Widget _error(String message) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: const Color(0xFF3A2028), borderRadius: BorderRadius.circular(14)),
        child: Text(message, style: const TextStyle(color: Color(0xFFFFB6C1), fontSize: 12)),
      );
}

class AnimatedRouteMap extends StatefulWidget {
  const AnimatedRouteMap({
    super.key,
    required this.device,
    required this.server,
    required this.protocol,
    required this.active,
  });
  final Offset? device;
  final Offset? server;
  final String protocol;
  final bool active;

  @override
  State<AnimatedRouteMap> createState() => _AnimatedRouteMapState();
}

class _AnimatedRouteMapState extends State<AnimatedRouteMap> with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(vsync: this, duration: _duration)..repeat();
  }

  Duration get _duration {
    if (widget.protocol == 'Hysteria2') return const Duration(milliseconds: 700);
    if (widget.protocol == 'gRPC') return const Duration(milliseconds: 1500);
    return const Duration(milliseconds: 2800);
  }

  @override
  void didUpdateWidget(covariant AnimatedRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.protocol != widget.protocol) {
      controller.duration = _duration;
      controller
        ..reset()
        ..repeat();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => CustomPaint(
          painter: _WorldPainter(
            phase: controller.value,
            device: widget.device,
            server: widget.server,
            active: widget.active,
          ),
          size: Size.infinite,
        ),
      );
}

class _WorldPainter extends CustomPainter {
  _WorldPainter({required this.phase, required this.device, required this.server, required this.active});
  final double phase;
  final Offset? device;
  final Offset? server;
  final bool active;

  Offset project(Offset lonLat, Size size) => Offset(
        (lonLat.dx + 180) / 360 * size.width,
        (90 - lonLat.dy) / 180 * size.height,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final land = Paint()..color = const Color(0xFF1B2230);
    final outline = Paint()
      ..color = const Color(0xFF283246)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    final continents = <List<Offset>>[
      [Offset(-168, 70), Offset(-135, 72), Offset(-120, 58), Offset(-105, 50), Offset(-124, 32), Offset(-110, 22), Offset(-98, 18), Offset(-82, 8), Offset(-78, 25), Offset(-92, 45), Offset(-110, 60), Offset(-145, 62)],
      [Offset(-80, 12), Offset(-66, 8), Offset(-52, -4), Offset(-48, -22), Offset(-60, -55), Offset(-72, -42), Offset(-78, -15)],
      [Offset(-12, 72), Offset(30, 70), Offset(50, 55), Offset(42, 38), Offset(30, 30), Offset(22, 8), Offset(5, -5), Offset(-15, 10), Offset(-18, 35), Offset(-8, 55)],
      [Offset(35, 68), Offset(70, 75), Offset(110, 65), Offset(150, 58), Offset(170, 48), Offset(145, 32), Offset(120, 10), Offset(105, -5), Offset(80, 8), Offset(65, 25), Offset(45, 38)],
      [Offset(112, -10), Offset(154, -12), Offset(150, -40), Offset(132, -44), Offset(114, -30)],
      [Offset(46, -13), Offset(50, -25), Offset(40, -35), Offset(32, -25)],
      [Offset(-48, 82), Offset(-20, 80), Offset(-30, 60), Offset(-48, 58), Offset(-58, 72)],
    ];
    for (final polygon in continents) {
      final path = Path();
      for (var i = 0; i < polygon.length; i++) {
        final point = project(polygon[i], size);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(path, land);
      canvas.drawPath(path, outline);
    }

    if (device != null && server != null) {
      final start = project(device!, size);
      final end = project(server!, size);
      final route = Path()..moveTo(start.dx, start.dy);
      final control = Offset((start.dx + end.dx) / 2, math.min(start.dy, end.dy) - 24);
      route.quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
      final routePaint = Paint()
        ..color = active ? const Color(0xFF9B83FF).withOpacity(.85) : Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      canvas.drawPath(route, routePaint);
      if (active) {
        final metric = route.computeMetrics().first;
        final dashPaint = Paint()
          ..color = const Color(0xFFB7A7FF)
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round;
        const dashLength = 7.0;
        const gap = 11.0;
        final total = metric.length;
        final shift = phase * (dashLength + gap);
        for (double d = -shift; d < total; d += dashLength + gap) {
          final a = d.clamp(0.0, total);
          final b = (d + dashLength).clamp(0.0, total);
          if (b > a) canvas.drawPath(metric.extractPath(a, b), dashPaint);
        }
      }
      _marker(canvas, start, const Color(0xFF58A9FF), 'YOU');
      _marker(canvas, end, const Color(0xFF9B83FF), 'VPN');
    } else {
      if (device != null) _marker(canvas, project(device!, size), const Color(0xFF58A9FF), 'YOU');
      if (server != null) _marker(canvas, project(server!, size), const Color(0xFF9B83FF), 'VPN');
    }
  }

  void _marker(Canvas canvas, Offset point, Color color, String label) {
    final glow = Paint()..color = color.withOpacity(.18);
    final dot = Paint()..color = color;
    canvas.drawCircle(point, 10, glow);
    canvas.drawCircle(point, 4.2, dot);
    final text = TextPainter(
      text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: .7)),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, point + const Offset(7, -13));
  }

  @override
  bool shouldRepaint(covariant _WorldPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.device != device ||
      oldDelegate.server != server ||
      oldDelegate.active != active;
}
