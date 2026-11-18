import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sing_box/sing_box.dart';

const appVersion = '1.0.2';

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
  String serverLocationLabel = '';
  String serverRegion = 'United States';
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
    final savedRegion = prefs.getString('server_region') ?? 'United States';
    final active = prefs.getString('selected_link');
    if (!mounted) return;
    setState(() {
      subscriptionUrl = savedUrl;
      serverRegion = savedRegion;
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

  Offset? _locationFromProfileName(String name) {
    final value = name.toLowerCase();
    if (value.contains('🇺🇸') ||
        RegExp(r'\b(usa|us|united states|america)\\b').hasMatch(value)) {
      if (value.contains('new york')) return const Offset(-74.0060, 40.7128);
      if (value.contains('los angeles')) return const Offset(-118.2437, 34.0522);
      if (value.contains('miami')) return const Offset(-80.1918, 25.7617);
      if (value.contains('chicago')) return const Offset(-87.6298, 41.8781);
      return const Offset(-98.5795, 39.8283);
    }
    if (value.contains('🇷🇺') || RegExp(r'\b(russia|ru|moscow)\\b').hasMatch(value)) {
      return const Offset(37.6173, 55.7558);
    }
    if (value.contains('🇩🇪') || RegExp(r'\b(germany|de|frankfurt)\\b').hasMatch(value)) {
      return const Offset(8.6821, 50.1109);
    }
    if (value.contains('🇳🇱') || RegExp(r'\b(netherlands|nl|amsterdam)\\b').hasMatch(value)) {
      return const Offset(4.9041, 52.3676);
    }
    if (value.contains('🇬🇧') || RegExp(r'\b(uk|united kingdom|london)\\b').hasMatch(value)) {
      return const Offset(-0.1276, 51.5072);
    }
    if (value.contains('🇸🇬') || RegExp(r'\b(singapore|sg)\\b').hasMatch(value)) {
      return const Offset(103.8198, 1.3521);
    }
    return null;
  }

  Offset? _regionCoordinates(String region) {
    const regions = <String, Offset>{
      'United States': Offset(-98.5795, 39.8283),
      'Canada': Offset(-106.3468, 56.1304),
      'Germany': Offset(10.4515, 51.1657),
      'Estonia': Offset(25.0136, 58.5953),
      'Russia': Offset(105.3188, 61.5240),
      'United Kingdom': Offset(-3.4360, 55.3781),
      'Singapore': Offset(103.8198, 1.3521),
      'Netherlands': Offset(5.2913, 52.1326),
      'France': Offset(2.2137, 46.2276),
      'Japan': Offset(138.2529, 36.2048),
    };
    return regions[region];
  }

  Future<void> _setServerRegion(String region) async {
    setState(() {
      serverRegion = region;
      serverPosition = null;
      serverLocationLabel = '';
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_region', region);
    await _resolveServer();
  }

  Future<void> _resolveServer() async {
    final link = selectedLink;
    if (link == null) return;
    final profile = profiles.where((p) => p.link == link).firstOrNull;
    if (profile == null) return;

    // Manual region avoids incorrect GeoIP results from CDN/anycast addresses.
    if (serverRegion != 'Auto') {
      final manualPoint = _regionCoordinates(serverRegion);
      if (manualPoint != null && mounted) {
        setState(() {
          serverPosition = manualPoint;
          serverLocationLabel = '$serverRegion · вручную';
        });
      }
      return;
    }

    // An explicit region in the subscription's server name is more useful
    // than GeoIP for anycast/CDN addresses.
    final namedLocation = _locationFromProfileName(profile.name);
    if (namedLocation != null) {
      if (mounted) {
        setState(() {
          serverPosition = namedLocation;
          serverLocationLabel = profile.name;
        });
      }
      return;
    }

    final host = Uri.tryParse(link)?.host ?? '';
    if (host.isEmpty) return;
    try {
      final addresses = await InternetAddress.lookup(host);
      final candidates = <({Offset point, String country, String code})>[];
      for (final address in addresses) {
        try {
          final response = await http.get(
            Uri.https('ipwho.is', '/${address.address}'),
            headers: {'User-Agent': _userAgent},
          ).timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) continue;
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['success'] != true ||
              data['latitude'] is! num ||
              data['longitude'] is! num) continue;
          final lat = (data['latitude'] as num).toDouble();
          final lon = (data['longitude'] as num).toDouble();
          if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) continue;
          candidates.add((
            point: Offset(lon, lat),
            country: (data['country'] ?? '').toString(),
            code: (data['country_code'] ?? '').toString().toUpperCase(),
          ));
        } catch (_) {
          // Try the next DNS address; one bad GeoIP response must not win.
        }
      }
      if (candidates.isNotEmpty && mounted) {
        final chosen = candidates.first;
        setState(() {
          serverPosition = chosen.point;
          serverLocationLabel = chosen.country.isEmpty ? 'VPN-сервер' : chosen.country;
        });
      } else if (mounted) {
        setState(() {
          serverPosition = null;
          serverLocationLabel = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          serverPosition = null;
          serverLocationLabel = '';
        });
      }
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
                    Text(serverPosition == null ? 'Сервер не определён' : (serverLocationLabel.isEmpty ? 'VPN-сервер' : serverLocationLabel), style: const TextStyle(color: Colors.white54, fontSize: 11)),
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
              const Text('Страна VPN-сервера', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: serverRegion,
                isExpanded: true,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF090D16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
                ),
                items: const [
                  DropdownMenuItem(value: 'United States', child: Text('США')),
                  DropdownMenuItem(value: 'Canada', child: Text('Канада')),
                  DropdownMenuItem(value: 'Germany', child: Text('Германия')),
                  DropdownMenuItem(value: 'Estonia', child: Text('Эстония')),
                  DropdownMenuItem(value: 'Russia', child: Text('Россия')),
                  DropdownMenuItem(value: 'United Kingdom', child: Text('Великобритания')),
                  DropdownMenuItem(value: 'Singapore', child: Text('Сингапур')),
                  DropdownMenuItem(value: 'Netherlands', child: Text('Нидерланды')),
                  DropdownMenuItem(value: 'France', child: Text('Франция')),
                  DropdownMenuItem(value: 'Japan', child: Text('Япония')),
                  DropdownMenuItem(value: 'Auto', child: Text('Автоопределение (GeoIP)')),
                ],
                onChanged: (value) {
                  if (value != null) _setServerRegion(value);
                },
              ),
              const SizedBox(height: 6),
              const Text('Выбери фактическую страну сервера. Ручной выбор точнее GeoIP для VPN и CDN.', style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 18),
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
              const Text('Запрос подписки отправляется с User-Agent Onvpn/$appVersion/vpnconnection.', style: TextStyle(color: Colors.white54, fontSize: 11)),
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

class _AnimatedRouteMapState extends State<AnimatedRouteMap>
    with SingleTickerProviderStateMixin {
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
      controller..reset()..repeat();
    }
  }

  LatLng _latLng(Offset value) => LatLng(value.dy, value.dx);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Widget _marker(String label, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF101725).withOpacity(.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withOpacity(.75)),
          boxShadow: [BoxShadow(color: color.withOpacity(.25), blurRadius: 10)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800)),
        ]),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final markers = <Marker>[];
          if (widget.device != null) {
            markers.add(Marker(
              point: _latLng(widget.device!),
              width: 76,
              height: 34,
              child: _marker('YOU', const Color(0xFF58A9FF), Icons.my_location),
            ));
          }
          if (widget.server != null) {
            markers.add(Marker(
              point: _latLng(widget.server!),
              width: 76,
              height: 34,
              child: _marker('VPN', const Color(0xFFAB8AFF), Icons.shield_rounded),
            ));
          }
          final bothKnown = widget.device != null && widget.server != null;
          if (bothKnown && widget.active) {
            final a = widget.device!;
            final b = widget.server!;
            final moving = Offset(
              a.dx + (b.dx - a.dx) * controller.value,
              a.dy + (b.dy - a.dy) * controller.value,
            );
            markers.add(Marker(
              point: _latLng(moving),
              width: 14,
              height: 14,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFB8A6FF),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [BoxShadow(color: Color(0x779B83FF), blurRadius: 10, spreadRadius: 3)],
                ),
              ),
            ));
          }

          return ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                FlutterMap(
                  options: const MapOptions(
                    initialCenter: LatLng(18, 0),
                    initialZoom: 1.05,
                    minZoom: 1.0,
                    maxZoom: 6.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.onvpn.app',
                      maxNativeZoom: 19,
                    ),
                    if (bothKnown)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [_latLng(widget.device!), _latLng(widget.server!)],
                            strokeWidth: 2.5,
                            color: const Color(0xFF9B83FF),
                            pattern: StrokePattern.dashed(
                              segments: widget.protocol == 'Hysteria2'
                                  ? const [9, 5]
                                  : widget.protocol == 'gRPC'
                                      ? const [7, 7]
                                      : const [5, 9],
                            ),
                          ),
                        ],
                      ),
                    if (markers.isNotEmpty) MarkerLayer(markers: markers),
                  ],
                ),
                Positioned(
                  right: 7,
                  bottom: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xCC090D16),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      child: Text(
                        '© OpenStreetMap contributors',
                        style: TextStyle(color: Colors.white54, fontSize: 8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
}
