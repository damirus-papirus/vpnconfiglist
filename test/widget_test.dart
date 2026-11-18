import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ONVPN versioned request header format', () {
    const version = '1.0.0';
    expect('Onvpn/$version/vpnconnection', 'Onvpn/1.0.0/vpnconnection');
  });
}
