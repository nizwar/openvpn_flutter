// The stage names below mirror the raw names the native side reports, which
// is why some of them are not lowerCamelCase.
// ignore_for_file: constant_identifier_names

/// Stages of a VPN connection, as reported by the native engine.
///
/// Not every platform reports every stage: iOS and macOS only know
/// [connecting], [connected], [reconnect], [disconnecting] and
/// [disconnected] (plus [denied] and [error]), Android reports the detailed
/// OpenVPN states in between.
enum VPNStage {
  /// Waiting for the user to grant the VPN permission (Android).
  prepare,

  /// Authenticating with the server.
  authenticating,

  /// Connecting to the server.
  connecting,

  /// Kept for compatibility; not reported by the bundled engines.
  authentication,

  /// The tunnel is up.
  connected,

  /// No tunnel. The resting state.
  disconnected,

  /// The tunnel is being stopped.
  disconnecting,

  /// The user refused the VPN permission.
  denied,

  /// The connection attempt failed or the tunnel stopped unexpectedly.
  /// See [OpenVPN.lastError] and [OpenVPN.getLogs] for the reason.
  error,

  /// Waiting for the server to answer.
  wait_connection,

  /// Building the OpenVPN configuration (Android).
  vpn_generate_config,

  /// Downloading the configuration the server pushes.
  get_config,

  /// Connecting over TCP.
  tcp_connect,

  /// Kept for compatibility; not reported by the bundled engines.
  udp_connect,

  /// Assigning the tunnel IP address.
  assign_ip,

  /// Resolving the server host name.
  resolve,

  /// OpenVPN is exiting.
  exiting,

  /// Adding the routes the server pushed (Android).
  add_routes,

  /// The connection dropped and is being re-established.
  reconnect,

  /// Waiting for additional authentication, for example a challenge or
  /// credentials that were not provided (Android).
  auth_pending,

  /// The server rejected the credentials or the certificate.
  auth_failed,

  /// No network is available; the engine reconnects once there is (Android).
  no_network,

  /// The VPN is paused, for example while the screen is off (Android).
  paused,

  /// A stage this version of the plugin does not know.
  unknown;

  /// Whether the tunnel is up.
  bool get isConnected => this == connected;

  /// Whether a connection attempt is in progress.
  bool get isConnecting => _connectingStages.contains(this);

  /// Whether there is neither a tunnel nor a connection attempt.
  bool get isDisconnected => _disconnectedStages.contains(this);

  static const Set<VPNStage> _connectingStages = {
    prepare,
    authenticating,
    connecting,
    authentication,
    wait_connection,
    vpn_generate_config,
    get_config,
    tcp_connect,
    udp_connect,
    assign_ip,
    resolve,
    add_routes,
    reconnect,
    auth_pending,
    no_network,
    paused,
  };

  static const Set<VPNStage> _disconnectedStages = {
    disconnected,
    denied,
    error,
    auth_failed,
  };

  /// Raw names some engines report for a known stage.
  static const Map<String, VPNStage> _aliases = {
    'idle': disconnected,
    'invalid': disconnected,
    'noprocess': disconnected,
    'no_process': disconnected,
    'connecting': connecting,
    'reasserting': reconnect,
    'reconnecting': reconnect,
    'wait': wait_connection,
    'auth': authenticating,
    'no_connection': no_network,
    'nonetwork': no_network,
    'screenoff': paused,
    'userpause': paused,
    'need': auth_pending,
    'user_input': auth_pending,
    'user_vpn_permission': prepare,
    'user_vpn_permission_cancelled': denied,
  };

  /// Converts a raw stage name reported by the native side.
  ///
  /// Missing or empty names mean [disconnected]; names this version does not
  /// know become [unknown].
  static VPNStage fromRaw(String? raw) {
    final name = raw?.trim().toLowerCase() ?? '';
    if (name.isEmpty) return disconnected;
    for (final stage in values) {
      if (stage.name == name) return stage;
    }
    return _aliases[name] ?? unknown;
  }
}
